# encoding=utf8
import datetime
from distutils.version import StrictVersion
import hashlib
import os.path
import random
import re
from seesaw.config import realize, NumberConfigValue
from seesaw.externalprocess import ExternalProcess
from seesaw.item import ItemInterpolation, ItemValue
from seesaw.task import SimpleTask, LimitConcurrent
from seesaw.tracker import GetItemFromTracker, PrepareStatsForTracker, \
    UploadWithTracker, SendDoneToTracker
import shutil
import socket
import subprocess
import sys
import time
import string

import seesaw
from seesaw.externalprocess import WgetDownload
from seesaw.pipeline import Pipeline
from seesaw.project import Project
from seesaw.util import find_executable

from tornado import httpclient

import requests
import zstandard

if StrictVersion(seesaw.__version__) < StrictVersion('0.8.5'):
    raise Exception('This pipeline needs seesaw version 0.8.5 or higher.')


###########################################################################
# Find a useful Wget+Lua executable.
#
# WGET_AT will be set to the first path that
# 1. does not crash with --version, and
# 2. prints the required version string

WGET_AT = find_executable(
    'Wget+AT',
    [
        'GNU Wget 1.21.3-at.20230605.01'
    ],
    [
        './wget-at',
        '/home/warrior/data/wget-at-gnutls'
    ]
)

if not WGET_AT:
    raise Exception('No usable Wget+At found.')


###########################################################################
# The version number of this pipeline definition.
#
# Update this each time you make a non-cosmetic change.
# It will be added to the WARC files and reported to the tracker.
VERSION = '20230619.02'
USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36'
TRACKER_ID = 'banciyuan'
TRACKER_HOST = 'legacy-api.arpa.li'
MULTI_ITEM_SIZE = 1


###########################################################################
# This section defines project-specific tasks.
#
# Simple tasks (tasks that do not need any concurrency) are based on the
# SimpleTask class and have a process(item) method that is called for
# each item.
class CheckIP(SimpleTask):
    def __init__(self):
        SimpleTask.__init__(self, 'CheckIP')
        self._counter = 0

    def process(self, item):
        # NEW for 2014! Check if we are behind firewall/proxy

        if self._counter <= 0:
            item.log_output('Checking IP address.')
            ip_set = set()

            ip_set.add(socket.gethostbyname('twitter.com'))
            #ip_set.add(socket.gethostbyname('facebook.com'))
            ip_set.add(socket.gethostbyname('youtube.com'))
            ip_set.add(socket.gethostbyname('microsoft.com'))
            ip_set.add(socket.gethostbyname('icanhas.cheezburger.com'))
            ip_set.add(socket.gethostbyname('archiveteam.org'))

            if len(ip_set) != 5:
                item.log_output('Got IP addresses: {0}'.format(ip_set))
                item.log_output(
                    'Are you behind a firewall/proxy? That is a big no-no!')
                raise Exception(
                    'Are you behind a firewall/proxy? That is a big no-no!')

        # Check only occasionally
        if self._counter <= 0:
            self._counter = 10
        else:
            self._counter -= 1


class PrepareDirectories(SimpleTask):
    def __init__(self, warc_prefix):
        SimpleTask.__init__(self, 'PrepareDirectories')
        self.warc_prefix = warc_prefix

    def process(self, item):
        item_name = item['item_name']
        item_name_hash = hashlib.sha1(item_name.encode('utf8')).hexdigest()
        escaped_item_name = item_name_hash
        dirname = '/'.join((item['data_dir'], escaped_item_name))

        if os.path.isdir(dirname):
            shutil.rmtree(dirname)

        os.makedirs(dirname)

        item['item_dir'] = dirname
        item['warc_file_base'] = '-'.join([
            self.warc_prefix,
            item_name_hash,
            time.strftime('%Y%m%d-%H%M%S')
        ])

        open('%(item_dir)s/%(warc_file_base)s.warc.zst' % item, 'w').close()
        open('%(item_dir)s/%(warc_file_base)s_data.txt' % item, 'w').close()

class MoveFiles(SimpleTask):
    def __init__(self):
        SimpleTask.__init__(self, 'MoveFiles')

    def process(self, item):
        os.rename('%(item_dir)s/%(warc_file_base)s.warc.zst' % item,
              '%(data_dir)s/%(warc_file_base)s.%(dict_project)s.%(dict_id)s.warc.zst' % item)
        os.rename('%(item_dir)s/%(warc_file_base)s_data.txt' % item,
              '%(data_dir)s/%(warc_file_base)s_data.txt' % item)

        shutil.rmtree('%(item_dir)s' % item)


class SetBadUrls(SimpleTask):
    def __init__(self):
        SimpleTask.__init__(self, 'SetBadUrls')

    def process(self, item):
        item['item_name_original'] = item['item_name']
        items = item['item_name'].split('\0')
        items_lower = [s.lower() for s in items]
        with open('%(item_dir)s/%(warc_file_base)s_bad-items.txt' % item, 'r') as f:
            for aborted_item in f:
                aborted_item = aborted_item.strip().lower()
                index = items_lower.index(aborted_item)
                item.log_output('Item {} is aborted.'.format(aborted_item))
                items.pop(index)
                items_lower.pop(index)
        item['item_name'] = '\0'.join(items)


class MaybeSendDoneToTracker(SendDoneToTracker):
    def enqueue(self, item):
        if len(item['item_name']) == 0:
            return self.complete_item(item)
        return super(MaybeSendDoneToTracker, self).enqueue(item)


def get_hash(filename):
    with open(filename, 'rb') as in_file:
        return hashlib.sha1(in_file.read()).hexdigest()

CWD = os.getcwd()
PIPELINE_SHA1 = get_hash(os.path.join(CWD, 'pipeline.py'))
LUA_SHA1 = get_hash(os.path.join(CWD, 'banciyuan.lua'))

def stats_id_function(item):
    d = {
        'pipeline_hash': PIPELINE_SHA1,
        'lua_hash': LUA_SHA1,
        'python_version': sys.version,
    }

    return d


class ZstdDict(object):
    created = 0
    data = None

    @classmethod
    def get_dict(cls):
        if cls.data is not None and time.time() - cls.created < 1800:
            return cls.data
        response = requests.get(
            'https://legacy-api.arpa.li/dictionary',
            params={
                'project': TRACKER_ID
            }
        )
        response.raise_for_status()
        response = response.json()
        if cls.data is not None and response['id'] == cls.data['id']:
            cls.created = time.time()
            return cls.data
        print('Downloading latest dictionary.')
        response_dict = requests.get(response['url'])
        response_dict.raise_for_status()
        raw_data = response_dict.content
        if hashlib.sha256(raw_data).hexdigest() != response['sha256']:
            raise ValueError('Hash of downloaded dictionary does not match.')
        if raw_data[:4] == b'\x28\xB5\x2F\xFD':
            raw_data = zstandard.ZstdDecompressor().decompress(raw_data)
        cls.data = {
            'id': response['id'],
            'dict': raw_data
        }
        cls.created = time.time()
        return cls.data


class WgetArgs(object):
    def realize(self, item):
        wget_args = [
            WGET_AT,
            '-U', USER_AGENT,
            '-nv',
            '--content-on-error',
            '--no-http-keep-alive',
            '--lua-script', 'banciyuan.lua',
            '-o', ItemInterpolation('%(item_dir)s/wget.log'),
            '--no-check-certificate',
            '--output-document', ItemInterpolation('%(item_dir)s/wget.tmp'),
            '--truncate-output',
            '-e', 'robots=off',
            '--rotate-dns',
            '--recursive', '--level=inf',
            '--no-parent',
            '--page-requisites',
            '--timeout', '30',
            '--tries', 'inf',
            '--domains', 'bcy.net,bcy.snssdk.com',
            '--span-hosts',
            '--waitretry', '30',
            '--warc-file', ItemInterpolation('%(item_dir)s/%(warc_file_base)s_desktop'),
            '--warc-header', 'operator: Archive Team',
            '--warc-header', 'x-wget-at-project-version: ' + VERSION,
            '--warc-header', 'x-wget-at-project-name: ' + TRACKER_ID,
            '--warc-dedup-url-agnostic',
            '--warc-compression-use-zstd',
            '--warc-zstd-dict-no-include',
            '--header', 'Accept-Language: zh-Hans-CN'
        ]
        dict_data = ZstdDict.get_dict()
        with open(os.path.join(item['item_dir'], 'zstdict'), 'wb') as f:
            f.write(dict_data['dict'])
        item['dict_id'] = dict_data['id']
        item['dict_project'] = TRACKER_ID
        wget_args.extend([
            '--warc-zstd-dict', ItemInterpolation('%(item_dir)s/zstdict'),
        ])

        for item_name in item['item_name'].split('\0'):
            wget_args.extend(['--warc-header', 'x-wget-at-project-item-name: '+item_name])
            wget_args.append('item-name://'+item_name)
            item_type, item_value = item_name.split(':', 1)
            # collection
            if item_type == 'c':
                assert re.match(r'^[0-9]+$', item_value), item_value
                wget_args.extend(['--warc-header', 'banciyuan-collection: '+item_value])
                wget_args.append('https://bcy.net/collection/'+item_value)
                wget_args.append('https://bcy.net/item/set/detail/'+item_value)
            # group (ask and answer)
            if item_type == 'g':
                assert re.match(r'^[0-9]+$', item_value), item_value
                wget_args.extend(['--warc-header', 'banciyuan-group: '+item_value])
                wget_args.append('https://bcy.net/group/list/'+item_value)
            # huodong (event)
            elif item_type == 'h':
                assert re.match(r'^[0-9]+$', item_value), item_value
                wget_args.extend(['--warc-header', 'banciyuan-huodong: '+item_value])
                wget_args.append('https://bcy.net/huodong/'+item_value)
            # item
            elif item_type == 'i':
                assert re.match(r'^[0-9]+$', item_value), item_value
                wget_args.extend(['--warc-header', 'banciyuan-item: '+item_value])
                wget_args.append('https://bcy.net/item/detail/'+item_value)
            # short URL
            elif item_type == 's':
                assert re.match(r'^[0-9A-Za-z]+$', item_value), item_value
                wget_args.extend(['--warc-header', 'banciyuan-s: '+item_value])
                wget_args.append('https://bcy.net/s/'+item_value+'/')
            # tag (circle)
            elif item_type == 't':
                assert re.match(r'^[0-9]+$', item_value), item_value
                wget_args.extend(['--warc-header', 'banciyuan-tag: '+item_value])
                wget_args.append('https://bcy.net/circle/index/'+item_value)
                wget_args.append('https://bcy.net/tag/'+item_value)
            # user
            elif item_type == 'u':
                assert re.match(r'^[0-9]+$', item_value), item_value
                wget_args.extend(['--warc-header', 'banciyuan-user: '+item_value])
                wget_args.append('https://bcy.net/u/'+item_value)
                # wget_args.append('https://bcy.net/u/'+item_value+'/like')
                # wget_args.append('https://bcy.net/u/'+item_value+'/collection')
                # wget_args.append('https://bcy.net/u/'+item_value+'/post')
                # wget_args.append('https://bcy.net/u/'+item_value+'/following')
                # wget_args.append('https://bcy.net/u/'+item_value+'/follower')
                # wget_args.append('https://bcy.net/u/'+item_value+'/circle')
            # toppost100
            elif item_type == 'top':
                assert item_value.count(',') == 2
                top_pageType, top_rankType, top_date = item_value.split(',', 2)
                assert top_pageType in ['illust', 'coser', 'novel'], top_pageType
                if top_rankType == top_date == '':
                    wget_args.append('https://bcy.net/'+top_pageType+'/toppost100')
                else:
                    assert top_rankType in ['week', 'lastday', 'newPeople'], top_rankType
                    # ./src/pages/pc/rank/index/components/DataPage/index.js state.cutoffTime == "20180602"
                    assert re.match(r'^[0-9]{4}[01][0-9][0123][0-9]$', top_date) and 20180602 <= int(top_date) <= 20230712, top_date
                    wget_args.append('https://bcy.net/'+top_pageType+'/toppost100?type='+top_rankType+'&date='+top_date)
            elif item_type == 'top-v':
                assert item_value.count(',') == 1
                top_type, top_date = item_value.split(',', 1)
                if top_type == top_date == '':
                    wget_args.append('https://bcy.net/video/toppost100')
                else:
                    assert top_type in ['sitetop', 'newPeople'], top_type
                    if top_date == '':
                        wget_args.append('https://bcy.net/video/toppost100?type={}'.format(top_type))
                    else:
                        assert re.match(r'^[0-9]{4}[01][0-9][0123][0-9]$', top_date) and 20181206 <= int(top_date) <= 20230712, top_date
                        # undocumented URL
                        wget_args.append('https://bcy.net/video/toppost100?type={}&date={}'.format(top_type, top_date))
            # video list
            elif item_type == 'vl':
                assert re.match(r'^[0-9]+$', item_value), item_value
                wget_args.extend(['--warc-header', 'banciyuan-video-list: '+item_value])
                wget_args.append('https://bcy.net/video/list/'+item_value)
            # image
            # only p3-bcy-sign.bcyimg.com requires ?x-expires={[0-9]+}&x-signature={[0-9A-Za-z%2B%2F%3D]+}
            elif item_type == 'img':
                # git hub.com/saveweb/fourdimensions-archive/blob/main/fourdimensions/utils/image.py
                # git hub.com/mikf/gallery-dl/issues/592#issuecomment-582504626
                # git hub.com/mikf/gallery-dl/issues/613
                # blog.cs dn.net/hotdog233/article/details/119380498
                assert re.match(r'^[0-9A-Za-z]+/[0-9A-Za-z/]*[0-9a-f]{32}(?:/fat)(?:\.[0-9a-z]+)$', item_value), item_value
                image_space = item_name.split('/', 1)[0]
                # assert image_space in ['banciyuan', 'bcy-static' 'tos-cn-i-bcyx', 'ttfe'], item_value
                wget_args.extend(['--warc-header', 'banciyuan-image: '+item_value])
                if image_space in ['banciyuan']:
                    ### p1-bcy.byteimg.com.wsglb0.com
                    # wget_args.append('https://p1-bcy.byteimg.com/{}~tplv-banciyuan-obj.image'.format(item_value))
                    ### p3-bcy.bcyimg.com.w.alikunlun.com
                    wget_args.append('https://p3-bcy.bcyimg.com/{}~tplv-banciyuan-obj.image'.format(item_value))
                    # wget_args.append('https://p3-bcy.bcyimg.com/{}~tplv-banciyuan-ivs.image'.format(item_value))
                    # wget_args.append('https://p3-bcy.bcyimg.com/{}~tplv-banciyuan-w650.image'.format(item_value))
                    # wget_args.append('https://p3-bcy.bcyimg.com/{}~tplv-banciyuan-w230.image'.format(item_value))
                    # wget_args.append('https://p3-bcy.bcyimg.com/{}~tplv-banciyuan-sq360.image'.format(item_value))
                    # wget_args.append('https://p3-bcy.bcyimg.com/{}~tplv-banciyuan-sq90.image'.format(item_value))
                    # wget_args.append('https://p3-bcy.bcyimg.com/{}~tplv-banciyuan-abig.image'.format(item_value))
                    # wget_args.append('https://p3-bcy.bcyimg.com/{}~tplv-banciyuan-2X2.image'.format(item_value))
                    ### p9-bcy.bcyimg.com.bsgslb.com
                    # wget_args.append('https://p9-bcy.bcyimg.com/{}~tplv-banciyuan-obj.image'.format(item_value))
                if image_space in ['banciyuan'] and re.match(r'[0-9a-f]{32}\.[0-9a-z]+$', item_value):
                    item_banciyuan = re.match(r'^banciyuan/(.+)', item_value)[1]
                    ### 77fyex04.v5.com.z0.glb.qiniudns.com
                    # wget_args.append('https://img5.bcyimg.com/{}'.format(item_banciyuan))
                    ### 77fyex.v5.com.z0.glb.qiniudns.com
                    # wget_args.append('https://img9.bcyimg.com/{}'.format(item_banciyuan))
                    ### 77fyex02.v5.com.z0.glb.qiniudns.com
                    # wget_args.append('https://static.bcyimg.com/{}'.format(item_banciyuan))
                    ### img-bcy-qn.pstatp.com.qiniudns.com
                    wget_args.append('https://img-bcy-qn.pstatp.com/{}'.format(item_banciyuan))
                    # wget_args.append('https://img-bcy-qn.pstatp.com/{}/w650'.format(item_banciyuan))
                    # wget_args.append('https://img-bcy-qn.pstatp.com/{}/w230'.format(item_banciyuan))
            # other URLs
            elif item_type == 'url':
                wget_args.append(item_value)
            else:
                raise Exception('Unknown item')

        item['item_name_newline'] = item['item_name'].replace('\0', '\n')

        if 'bind_address' in globals():
            wget_args.extend(['--bind-address', globals()['bind_address']])
            print('')
            print('*** Wget will bind address at {0} ***'.format(
                globals()['bind_address']))
            print('')

        return realize(wget_args, item)

###########################################################################
# Initialize the project.
#
# This will be shown in the warrior management panel. The logo should not
# be too big. The deadline is optional.
project = Project(
    title=TRACKER_ID,
    project_html='''
        <img class="project-logo" alt="Project logo" src="" height="50px" title=""/>
        <h2>Banciyuan <span class="links"><a href="https://bcy.net/">Website</a> &middot; <a href="http://tracker.archiveteam.org/bcy/">Leaderboard</a> &middot; <a href="https://wiki.archiveteam.org/index.php/Xuite">Wiki</a></span></h2>
        <p>Archiving Banciyuan.</p>
    ''',
    utc_deadline = datetime.datetime(2023, 7, 12, 8, 0, 0) # Midnight Beijing
)

pipeline = Pipeline(
    CheckIP(),
    GetItemFromTracker('http://{}/{}/multi={}/'
        .format(TRACKER_HOST, TRACKER_ID, MULTI_ITEM_SIZE),
        downloader, VERSION),
    PrepareDirectories(warc_prefix=TRACKER_ID),
    WgetDownload(
        WgetArgs(),
        max_tries=2,
        accept_on_exit_code=[0, 4, 8],
        env={
            'item_dir': ItemValue('item_dir'),
            'item_names': ItemValue('item_name_newline'),
            'warc_file_base': ItemValue('warc_file_base'),
        }
    ),
    SetBadUrls(),
    PrepareStatsForTracker(
        defaults={'downloader': downloader, 'version': VERSION},
        file_groups={
            'data': [
                ItemInterpolation('%(item_dir)s/%(warc_file_base)s.warc.zst')
            ]
        },
        id_function=stats_id_function,
    ),
    MoveFiles(),
    LimitConcurrent(NumberConfigValue(min=1, max=20, default='20',
        name='shared:rsync_threads', title='Rsync threads',
        description='The maximum number of concurrent uploads.'),
        UploadWithTracker(
            'http://%s/%s' % (TRACKER_HOST, TRACKER_ID),
            downloader=downloader,
            version=VERSION,
            files=[
                ItemInterpolation('%(data_dir)s/%(warc_file_base)s.%(dict_project)s.%(dict_id)s.warc.zst'),
                ItemInterpolation('%(data_dir)s/%(warc_file_base)s_data.txt')
            ],
            rsync_target_source_path=ItemInterpolation('%(data_dir)s/'),
            rsync_extra_args=[
                '--recursive',
                '--partial',
                '--partial-dir', '.rsync-tmp',
                '--min-size', '1',
                '--no-compress',
                '--compress-level', '0'
            ]
        ),
    ),
    MaybeSendDoneToTracker(
        tracker_url='http://%s/%s' % (TRACKER_HOST, TRACKER_ID),
        stats=ItemValue('stats')
    )
)
