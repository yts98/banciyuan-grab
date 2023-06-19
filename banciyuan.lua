dofile("urlcode.lua")
local urlparse = require("socket.url")
local http = require("socket.http")
local https = require("ssl.https")
local base64 = require("base64")
JSON = (loadfile "JSON.lua")()

local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")
local concurrency = tonumber(os.getenv("concurrency"))
local item_type = nil
local item_name = nil
local item_value = nil
local item_user = nil

if urlparse == nil or http == nil then
  io.stdout:write("socket not corrently installed.\n")
  io.stdout:flush()
  abortgrab = true
end

local url_count = 0
local tries = 0
local downloaded = {}
local addedtolist = {}
local abortgrab = false
local killgrab = false
local logged_response = false

local new_locations = {}

local discovered_outlinks = {}
local discovered_items = {}
local bad_items = {}
local ids = {}

local retry_url = false
local allow_video = false

local postpagebeta = false
local webpage_404 = false

math.randomseed(os.time())

for ignore in io.open("ignore-list", "r"):lines() do
  downloaded[ignore:gsub("^https://", "http://")] = true
  downloaded[ignore:gsub("^http://", "https://")] = true
end

abort_item = function(item)
  abortgrab = true
  if not item then
    item = item_name
  end
  if not bad_items[item] then
    io.stdout:write("Aborting item " .. item .. ".\n")
    io.stdout:flush()
    bad_items[item] = true
  end
end

kill_grab = function(item)
  io.stdout:write("Aborting crawling.\n")
  killgrab = true
end

read_file = function(file)
  if file then
    local f = assert(io.open(file))
    local data = f:read("*all")
    f:close()
    return data
  else
    return ""
  end
end

processed = function(url)
  if downloaded[url] or addedtolist[url] then
    return true
  end
  return false
end

discover_item = function(target, item)
  if not target[item] then
    target[item] = true
    return true
  end
  return false
end

discover_integer = function(n_type, n_value)
  assert(n_type and n_value, n_type)
  if type(n_value) == "number" then
    n_value = string.format("%.0f", n_value)
  end
  assert(string.match(n_type, "^[^:]+$"), n_type .. ":" .. n_value)
  assert(string.match(n_value, "^[0-9]+$"), n_type .. ":" .. n_value)
  return discover_item(discovered_items, n_type .. ":" .. n_value)
end

find_item = function(url)
  local value = nil
  local type_ = nil
  if not value then
    value = string.match(url, "^https?://bcy%.net/collection/([0-9]+)")
    type_ = "c"
  end
  if not value then
    value = string.match(url, "^https?://bcy%.net/item/set/detail/([0-9]+)")
    type_ = "c"
  end
  if not value then
    value = string.match(url, "^https?://bcy%.net/group/list/([0-9]+)")
    type_ = "g"
  end
  if not value then
    value = string.match(url, "^https?://bcy%.net/huodong/([0-9]+)")
    type_ = "h"
  end
  if not value then
    value = string.match(url, "^https?://bcy%.net/item/detail/([0-9]+)")
    type_ = "i"
  end
  if not value then
    value = string.match(url, "^https?://bcy%.net/s/([0-9A-Za-z]+)/$")
    type_ = "s"
  end
  if not value then
    value = string.match(url, "^https?://bcy%.net/circle/index/([0-9]+)")
    type_ = "t"
  end
  if not value then
    value = string.match(url, "^https?://bcy%.net/tag/([0-9]+)")
    type_ = "t"
  end
  if not value then
    value = string.match(url, "^https?://bcy%.net/u/([0-9]+)")
    type_ = "u"
  end
  if not value then
    value = string.match(url, "^https?://bcy%.net/video/list/([0-9]+)")
    type_ = "vl"
  end
  if not value then
    if string.match(url, "^https?://p3%-bcy%-sign%.bcyimg%.com/")
      or string.match(url, "^https?://p3%-bcy%.bcyimg%.com/")
      or string.match(url, "^https?://p9%-bcy%.bcyimg%.com/") then
      local image_path = string.match(url, "^https?://[^/]*bcyimg%.com/(banciyuan/[^~?]+)~[^?]+%.image")
      if not image_path then
        image_path = string.match(url, "^https?://[^/]*bcyimg%.com/img/(banciyuan/[^~?]+)~[^?]+%.image")
      end
      if not image_path then
        image_path = string.match(url, "^https?://[^/]*bcyimg%.com/(bcy%-static/[^~?]+)~[^?]+%.image")
      end
      if image_path then
        assert(string.match(image_path, "[0-9A-Za-z/]*[0-9a-f]+$") or string.match(image_path, "^[0-9A-Za-z/]*[0-9a-f]+%.[0-9a-z]+$") or string.match(image_path, "^[0-9A-Za-z/]*[0-9a-f]+/fat%.[0-9a-z]+$"), "Unrecognizeg image URL: " .. url)
      end
      if not image_path then
        image_path = string.match(url, "^https?://[^/]*bcyimg%.com/([a-z%-]+/[^~?]+)~[^?]+%.image")
      end
      if image_path then
        assert(string.match(image_path, "^img/banciyuan/") == nil)
        value = image_path
        type_ = "img"
      else
        error("Unrecognizeg image URL: " .. url)
      end
      if string.match(url, "^https?://[^/]*bcyimg%.com/banciyuan/user/[0-9]+/")
        or string.match(url, "^https?://[^/]*bcyimg%.com/img/banciyuan/user/[0-9]+/") then
        local user_id = string.match(url, "/banciyuan/user/([0-9]+)/")
        discover_integer("u", user_id)
      end
    end
  end
  if not value then
    if string.match(url, "^https?://img5%.bcyimg%.com/")
      or string.match(url, "^https?://img9%.bcyimg%.com/")
      or string.match(url, "^https?://static%.bcyimg%.com/")
      or string.match(url, "^https?://img%-bcy%-qn%.pstatp%.com/") then
      local image_path = string.match(url, "^https?://[^/]+/([^~?]*)[^/]$")
      if not image_path then
        image_path = string.match(url, "^https?://[^/]+/([^~?]*)/([^~?]*)[^/]%?[^?]*$")
      end
      if not image_path then
        image_path = string.match(url, "^https?://[^/]+/([^~?]*)/[0-9a-z]$")
      end
      if not image_path then
        image_path = string.match(url, "^https?://[^/]+/([^~?]*)/[0-9a-z]%?[^?]*$")
      end
      if image_path then
        assert(string.match(image_path, "^banciyuan/") == nil and string.match(image_path, "^img/banciyuan/") == nil)
        assert(string.match(image_path, "^[0-9A-Za-z/]*[0-9a-f]+%.[0-9a-z]+$"), "Unrecognizeg image URL: " .. url)
        value = "banciyuan/" .. image_path
        type_ = "img"
      else
        error("Unrecognizeg image URL: " .. url)
      end
    end
  end

  if value then
    return {
      ["value"]=value,
      ["type"]=type_,
      ["other"]=nil
    }
  end
end

set_item = function(url)
  found = find_item(url)
  if found then
    item_type = found["type"]
    item_value = found["value"]
    item_name_new = item_type .. ":" .. item_value
    if item_name_new ~= item_name then
      ids = {}
      ids[item_value] = true
      abortgrab = false
      initial_allowed = false
      tries = 0
      retry_url = false
      allow_video = false
      webpage_404 = false
      item_name = item_name_new
      print("Archiving item " .. item_name)
    end
  end
end

local VIDEO_LIST_DEPTH_THRESHOLD = 100

allowed = function(url, parenturl)
  if
    -- images with x-signature should be downloaded immediately
       string.match(url, "^https?://p3%-bcy%-sign%.bcyimg%.com/")
    -- videos with session key should be downloaded immediately
    or string.match(url, "^https?://v[0-9]+%-video%.bcy%.net/") then
    return true
  elseif string.match(url, "^https?://[^/]*video%.bcy%.net/") then
    error("Unrecognizeg video URL: " .. url)
  end

  -- separate items and strip _source_page
  if string.match(url, "^https?://bcy%.net/collection/[0-9]+$")
    or string.match(url, "^https?://bcy%.net/collection/[0-9]+%?_source_page=[a-z]+$")
    or string.match(url, "^https?://bcy%.net/item/set/detail/[0-9]+$")
    or string.match(url, "^https?://bcy%.net/item/set/detail/[0-9]+%?_source_page=[a-z]+$")
    or string.match(url, "^https?://bcy%.net/group/list/[0-9]+$")
    or string.match(url, "^https?://bcy%.net/group/list/[0-9]+%?_source_page=[a-z]+$")
    or string.match(url, "^https?://bcy%.net/huodong/[0-9]+$")
    or string.match(url, "^https?://bcy%.net/huodong/[0-9]+%?_source_page=[a-z]+$")
    or string.match(url, "^https?://bcy%.net/item/detail/[0-9]+$")
    or string.match(url, "^https?://bcy%.net/item/detail/[0-9]+%?_source_page=[a-z]+$")
    or string.match(url, "^https?://bcy%.net/s/[0-9A-Za-z]+/$")
    or string.match(url, "^https?://bcy%.net/circle/index/[0-9]+$")
    or string.match(url, "^https?://bcy%.net/circle/index/[0-9]+%?_source_page=[a-z]+$")
    or string.match(url, "^https?://bcy%.net/tag/[0-9]+$")
    or string.match(url, "^https?://bcy%.net/tag/[0-9]+%?_source_page=[a-z]+$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+%?_source_page=[a-z]+$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+%?filter=[a-z]+$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/like%?_source_page=[a-z]+$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/collection%?_source_page=[a-z]+$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/post%?_source_page=[a-z]+$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/following%?_source_page=[a-z]+$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/follower%?_source_page=[a-z]+$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/circle%?_source_page=[a-z]+$")
    or string.match(url, "^https?://bcy%.net/video/list/[0-9]+$")
    or string.match(url, "^https?://bcy%.net/video/list/[0-9]+?_source_page=[a-z]+$") then
    set_item(url)
    return false
  elseif string.match(url, "^https?://bcy%.net/huodong/[0-9]+%?order=[a-z]+$")
    or string.match(url, "^https?://bcy%.net/huodong/[0-9]+%?order=[a-z]+&p=[0-9]+$") then
    local huodong_id = string.match(url, "^https?://bcy%.net/huodong/([0-9]+)")
    local parent_huodong_id = string.match(parenturl, "^https?://bcy%.net/huodong/([0-9]+)")
    if huodong_id == parent_huodong_id then
      return true
    else
      set_item(url)
      return false
    end
  elseif string.match(url, "^https?://bcy%.net/u/[0-9]+/like$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/collection$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/post$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/post/$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/post/note$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/post/article$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/post/ganswer$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/post/video$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/post/%?p=[0-9]+$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/post/note%?p=[0-9]+$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/post/article%?p=[0-9]+$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/post/ganswer%?p=[0-9]+$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/post/video%?p=[0-9]+$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/following$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/follower$")
    or string.match(url, "^https?://bcy%.net/u/[0-9]+/circle$") then
    local user_id = string.match(url, "^https?://bcy%.net/u/([0-9]+)")
    local parent_user_id = string.match(parenturl, "^https?://bcy%.net/u/([0-9]+)")
    if user_id == parent_user_id then
      return true
    else
      set_item(url)
      return false
    end
  elseif string.match(url, "^https?://bcy%.net/[a-z]+/toppost100$")
    or string.match(url, "^https?://bcy%.net/[a-z]+/toppost100%?_source_page=[a-z]+$") then
    return false
  elseif string.match(url, "^https?://bcy%.snssdk%.com/magic/eco/runtime/release/.+$") then
    -- these are "Magic" pages that should be handled manually
    local url_suffix = string.match(url, "^https?://bcy%.snssdk%.com/(magic/eco/runtime/release/.+)$")
    discover_item(discovered_outlinks, url)
    discovered_items["url:https://bcy.net/" .. url_suffix] = true
    return false
  elseif string.match(url, "^https?://bcy%.net/magic/eco/runtime/release/.+$") then
    local url_suffix = string.match(url, "^https?://bcy%.net/(magic/eco/runtime/release/.+)$")
    discover_item(discovered_outlinks, "https://bcy.snssdk.com/" .. url_suffix)
  end

  -- item boundary
  if true or item_type == "c" then
    if false
      -- ./src/common/services/CollectSvc.js
      or string.match(url, "^https?://bcy%.net/apiv3/collection/getMyCollectionList%?")
      or string.match(url, "^https?://bcy%.net/apiv3/collection/getSubscribeCollectionList%?")
      or string.match(url, "^https?://bcy%.net/apiv3/collection/collectionItemList%?") then
      return true
    end
  end
  if true or item_type == "g" then
    if false
      -- ./src/common/services/Common.js
      or string.match(url, "^https?://bcy%.net/apiv3/common/getFeeds%?")
      -- ./src/common/services/GroupSvc.js
      or string.match(url, "^https?://bcy%.net/apiv3/common/getGroupInfoMap%?")
      or string.match(url, "^https?://bcy%.net/apiv3/common/getGroupIndexRec%?") then
      return true
    end
  end
  if true or item_type == "h" then
    if false then
      return true
    end
  end
  if true or item_type == "i" then
    if
      -- ./src/common/services/CommentSvc.js
         string.match(url, "^https?://bcy%.net/apiv3/cmt/reply/list%?")
      or string.match(url, "^https?://bcy%.net/apiv3/cmt/comment/list%?")
      -- ./src/common/services/DanmakuSvc.js
      or string.match(url, "^https?://bcy%.net/apiv3/danmaku/get%?")
      -- vod
      or string.match(url, "^https?://vod%.bytedanceapi%.com/%?") then
      return true
    end
  end
  if true or item_type == "s" then
  end
  if true or item_type == "t" then
    if string.match(url, "^https?://bcy%.net/tags/name/[^?]+$")
      -- ./src/common/services/CircleSvc.js
      or string.match(url, "^https?://bcy%.net/apiv3/common/circleFeed%?")
      or string.match(url, "^https?://bcy%.net/apiv3/common/circleProperty%?")
      or string.match(url, "^https?://bcy%.net/apiv3/user/circleHotGroup%?")
      or string.match(url, "^https?://bcy%.net/apiv3/user/getTagsByName%?") then
      return true
    end
  end
  if true or item_type == "u" then
    if string.match(url, "^https?://bcy%.net/u/[0-9]+/following$")
      or string.match(url, "^https?://bcy%.net/u/[0-9]+/follower$")
      or string.match(url, "^https?://bcy%.net/u/[0-9]+/circle$")
      or string.match(url, "^https?://bcy%.net/u/[0-9]+/like$")
      or string.match(url, "^https?://bcy%.net/u/[0-9]+/collection$")
      -- ./src/common/services/CollectSvc.js
      or string.match(url, "^https?://bcy%.net/apiv3/collection/getMyCollectionList%?")
      -- ./src/common/services/UserSvc.js
      or string.match(url, "^https?://bcy%.net/apiv3/user/info%?")
      or string.match(url, "^https?://bcy%.net/apiv3/user/post$")
      or string.match(url, "^https?://bcy%.net/apiv3/user/favor%?")
      -- or string.match(url, "^https?://bcy%.net/apiv3/user/followedCircles%?")
      or string.match(url, "^https?://bcy%.net/apiv3/user/friendsFeed%?")
      or string.match(url, "^https?://bcy%.net/apiv3/user/friendsFeed%?")
      or string.match(url, "^https?://bcy%.net/apiv3/user/selfPosts%?")
      or string.match(url, "^https?://bcy%.net/apiv3/user/pcAnnounce%?")
      or string.match(url, "^https?://bcy%.net/apiv3/collection/getUserPostTimeline%?")
      or string.match(url, "^https?://bcy%.net/apiv3/follow%-list%?")
      or string.match(url, "^https?://bcy%.net/apiv3/block%-list%?") then
      return true
    end
  end
  if true or item_type == "top" or item_type == "top-v" then
    if
      -- ./src/common/services/RankSvc.js
         string.match(url, "^https?://bcy%.net/apiv3/rank/list/itemInfo%?")
      or string.match(url, "^https?://bcy%.net/apiv3/rank/list/channelItemInfo%?") then
      return true
    end
  end
  if true or item_type == "vl" then
    if
      -- ./src/common/services/Common.js
         string.match(url, "^https?://bcy%.net/apiv3/common/getFeeds%?") then
      return true
    end
  end

  if string.match(url, "^https?://bcy%.net/") then
    print("Discovered " .. url .. " from " .. parenturl)
    discovered_items["url:" .. url] = true
    return false
  elseif not string.match(url, "^/[^/]")
    and not string.match(url, "^https?://[^/]*bcy%.net/")
    and not string.match(url, "^https?://[^/]*bcyimg%.com/")
    and not string.match(url, "^https?://img%-bcy%-qn%.pstatp%.com/") then
    discover_item(discovered_outlinks, url)
  end

  return false
end

wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  local url = urlpos["url"]["url"]
  local html = urlpos["link_expect_html"]

  if allowed(url, parent["url"]) and not processed(url) then
    addedtolist[url] = true
    return true
  end

  return false
end

local user_exists = {}
local video_props_post_data_item_id = {}
local user_col_props_page_list_len = {}
local video_list_depth = {}

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil
  local json = nil
  local ssr_data = nil

  downloaded[url] = true

  if abortgrab then
    return {}
  end

  local function decode_codepoint(newurl)
    newurl = string.gsub(
      newurl, "\\[uU]([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])",
      function (s)
        return unicode_codepoint_as_utf8(tonumber(s, 16))
      end
    )
    return newurl
  end

  local function fix_case(newurl)
    if not string.match(newurl, "^https?://.") then
      return newurl
    end
    if string.match(newurl, "^https?://[^/]+$") then
      newurl = newurl .. "/"
    end
    local a, b = string.match(newurl, "^(https?://[^/]+/)(.*)$")
    return string.lower(a) .. b
  end

  local function check(newurl, referer)
    newurl = decode_codepoint(newurl)
    newurl = fix_case(newurl)
    local origurl = url
    if string.len(url) == 0 then
      return nil
    end
    local url = string.match(newurl, "^([^#]+)")
    local url_ = string.match(url, "^(.-)[%.\\]*$")
    while string.find(url_, "&amp;") do
      url_ = string.gsub(url_, "&amp;", "&")
    end
    if not processed(url_)
      and not processed(url_ .. "/")
      and allowed(url_, origurl) then
      if string.match(url_, "^https?://bcy%.net/apiv3/") then
        assert(referer)
        table.insert(urls, {
          url=url_,
          headers={
            ["Referer"] = referer,
            ["X-Requested-With"] = "XMLHttpRequest"
          }
        })
      elseif string.match(url_, "^https?://vod%.bytedanceapi%.com/") then
        assert(referer == "https://bcy.net/")
        table.insert(urls, {
          url=url_,
          headers={
            ["Origin"] = "https://bcy.net",
            ["Referer"] = referer
          }
        })
      elseif string.match(url_, "^https?://[^/]*video%.bcy%.net/") then
        assert(referer == "https://bcy.net/")
        table.insert(urls, {
          url=url_,
          headers={
            -- ./node_modules/xgplayer/dist/index.min.js
            ["Range"] = "bytes=0-",
            ["Referer"] = referer
          }
        })
      elseif referer then
        table.insert(urls, {
          url=url_,
          headers={
            ["Referer"] = referer
          }
        })
      else
        table.insert(urls, { url=url_ })
      end
      addedtolist[url_] = true
      addedtolist[url] = true
    end
  end

  local function checknewurl(newurl)
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    if string.match(newurl, "^https?:////") then
      check(string.gsub(newurl, ":////", "://"))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^\\/\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (
      string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^data:")
      or string.match(newurl, "^irc:")
      or string.match(newurl, "^%${")
    ) then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function get_ssr_data(html)
    local ssr_data_string = string.match(html, "<script>window%.__ssr_data = JSON%.parse%(([^<>]+)%);\n")
    if ssr_data_string then
      local ssr_data_unescpaed_string = JSON:decode(ssr_data_string)
      local ssr_data = JSON:decode(ssr_data_unescpaed_string)
      return ssr_data
    else
      return nil
    end
  end

  -- analyze props
  local function analyze_multi(multi)
    for _, item in ipairs(multi) do
      assert(item["type"] == "" or item["type"] == "1" or item["type"] == "image", item["type"])
      if item["detail_origin_path"] and item["detail_origin_path"]:len() >= 1 then
        check(item["detail_origin_path"])
      end
      if item["detail_path"] and item["detail_path"]:len() >= 1 then
        check(item["detail_path"])
      end
      -- item["mid"]
      if item["origin"] and item["origin"]:len() >= 1 then
        check(item["origin"])
      end
      if item["original_path"] and item["original_path"]:len() >= 1 then
        check(item["original_path"])
      end
      if item["path"] and item["path"]:len() >= 1 then
        check(item["path"])
      end
      if item["url_map"] then
        for _, url_map in pairs(item["url_map"]) do
          check(url_map)
        end
      end
    end
  end
  local function analyze_pics(pics)
    analyze_multi(pics)
  end
  local function analyze_rights(rights)
    for _, right in ipairs(rights) do
      if right["extra"]:len() >= 1 then
        check(right["extra"])
      end
      -- right["id"]
      if right["link"]:len() >= 1 then
        check(right["link"])
      end
      -- right["rid"]
    end
  end
  local function analyze_tag_list(tag_list)
    for _, tag in ipairs(tag_list) do
      if tag["cover"]:len() >= 1 then
        check(tag["cover"])
      end
      discover_integer("t", tag["tag_id"])
      assert(tag["type"] == "event" or tag["type"] == "tag" or tag["type"] == "work", tag["type"])
    end
  end
  local function analyze_tagInfo(tagInfo)
    if tagInfo["admin_uid"] then
      discover_integer("u", tagInfo["admin_uid"])
    end
    discover_integer("t", tagInfo["circle_id"])
    if tagInfo["circle_owner_info"] then
      discover_integer("u", tagInfo["circle_owner_info"]["uid"])
    end
    if tagInfo["cover"]["url"]:len() >= 1 then
      check(tagInfo["cover"]["url"])
    end
    if tagInfo["creator_uid"] then
      discover_integer("u", tagInfo["creator_uid"])
    end
  end
  local function analyze_collections(collections)
    for _, collection in ipairs(collections) do
      assert(collection["collection"] and collection["tags"] and collection["user"])
      for _, col in ipairs(collection["collection"]) do
        discover_integer("c", col["collection_id"])
        if col["cover_uri"]:len() >= 1 then
          check(col["cover_uri"])
        end
      end
      for _, tag in ipairs(collection["tags"]) do
        discover_integer("t", tag["circle_id"])
      end
      for _, user in ipairs(collection["user"]) do
        if user["avatar"]:len() >= 1 then
          check(user["avatar"])
        end
        discover_integer("u", user["uid"])
      end
    end
  end
  local function analyze_reply_data(reply_data)
    for _, reply in ipairs(reply_data) do
      if reply["avatar"]:len() >= 1 then
        check(reply["avatar"])
      end
      -- reply["id"]
      analyze_multi(reply["multi"])
      discover_integer("u", reply["uid"])
    end
  end
  local function analyze_groupInfo(groupInfo)
    if groupInfo["avatar"]:len() >= 1 then
      check(groupInfo["avatar"])
    end
    discover_integer("g", groupInfo["group_id"])
    analyze_multi(groupInfo["multi"])
    -- groupInfo["pics"]
    analyze_tag_list(groupInfo["tag_list"])
    discover_integer("u", groupInfo["uid"])
    -- groupInfo["wid"]
    if groupInfo["work_cover"] and groupInfo["work_cover"]:len() >= 1 then
      check(groupInfo["work_cover"])
    end
  end
  local function analyze_groupInfoList(groupInfoList)
    for _, groupInfo in ipairs(groupInfoList) do
      if groupInfo["avatar"]:len() >= 1 then
        check(groupInfo["avatar"])
      end
      discover_integer("g", groupInfo["gid"])
      discover_integer("i", groupInfo["item_id"])
      analyze_multi(groupInfo["multi"])
      analyze_pics(groupInfo["pics"])
      -- groupInfo["replies"]
      analyze_reply_data(groupInfo["reply_data"])
      analyze_rights(groupInfo["rights"])
      assert(groupInfo["type"] == "ganswer", groupInfo["type"])
      discover_integer("u", groupInfo["uid"])
    end
  end
  local function analyze_comments(comments)
    for _, comment in ipairs(comments) do
      if comment["avatar"]:len() >= 1 then
        check(comment["avatar"])
      end
      discover_integer("i", comment["item_id"])
      discover_integer("u", comment["uid"])
    end
  end
  local function analyze_homeInfo(homeInfo)
    if homeInfo["avatar"]:len() >= 1 then
      check(homeInfo["avatar"])
    end
    if homeInfo["rights"] then
      analyze_rights(homeInfo["rights"])
    end
    if homeInfo["ttuid"] then
      -- assert(homeInfo["ttuid"] == 0 or homeInfo["ttuid"] == homeInfo["uid"])
    end
    discover_integer("u", homeInfo["uid"])
  end
  local function analyze_userinfo(userinfo)
    -- userinfo["fund_account_id"]
    -- userinfo["fund_virtual_account_id"]
    analyze_homeInfo(userinfo)
  end
  -- TA 关注的圈子
  local function analyze_followCircles(followCircles)
    for _, circie in ipairs(followCircles) do
      discover_integer("t", circie["circle_id"])
      if circie["cover"]:len() >= 1 then
        check(circie["cover"])
      end
    end
  end
  -- TA 关注的用户
  local function analyze_followUsers(followUsers)
    for _, user in ipairs(followUsers) do
      if user["avatar"]:len() >= 1 then
        check(user["avatar"])
      end
      analyze_rights(user["rights"])
      discover_integer("u", user["uid"])
    end
  end
  local function analyze_item(item)
    if item["at_user_infos"] then
      for _, at_user_info in ipairs(item["at_user_infos"]) do
        discover_integer("u", user_info["uid"])
      end
    end
    if item["avatar"]:len() >= 1 then
      check(item["avatar"])
    end
    if item["collection"] then
      discover_integer("c", item["collection"]["collection_id"])
      discover_integer("u", item["collection"]["user"]["uid"])
    end
    if item["cover"] and item["cover"]:len() >= 1 then
      check(item["cover"])
    end
    if item["image_list"] then
      analyze_pics(item["image_list"])
    end
    discover_integer("i", item["item_id"])
    analyze_multi(item["multi"])
    analyze_tag_list(item["post_tags"])
    analyze_rights(item["rights"])
    discover_integer("u", item["uid"])
    -- item["wid"]
    if item["work_cover"] and item["work_cover"]:len() >= 1 then
      check(item["work_cover"])
    end
  end
  local function analyze_items(items)
    for _, item in ipairs(items) do
      analyze_item(item["item_detail"])
      assert(item["since"])
      assert(item["tl_type"] == "item")
    end
  end
  local function analyze_detail(detail)
    for _, banner in ipairs(detail["detail_banners"]) do
      if banner["link"]:len() >= 1 then
        check(banner["link"])
      end
      if banner["path"]:len() >= 1 then
        check(banner["path"])
      end
    end
    if detail["detail_user"] then
      analyze_homeInfo(detail["detail_user"])
    end
    if detail["post_data"] then
      if detail["post_data"]["at_user_infos"] then
        for _, at_user_info in ipairs(detail["post_data"]["at_user_infos"]) do
          discover_integer("u", at_user_info["uid"])
        end
      end
      if detail["post_data"]["collection"] then
        discover_integer("c", detail["post_data"]["collection"]["collection_id"])
        if detail["post_data"]["collection"]["next_post"] then
          discover_integer("i", detail["post_data"]["collection"]["next_post"]["item_id"])
        end
        if detail["post_data"]["collection"]["prev_post"] then
          discover_integer("i", detail["post_data"]["collection"]["prev_post"]["item_id"])
        end
      end
      if detail["post_data"]["cover"] and detail["post_data"]["cover"]:len() >= 1 then
        check(detail["post_data"]["cover"])
      end
      discover_integer("i", detail["post_data"]["item_id"])
      if detail["post_data"]["item_like_users"] then
        for _, user in ipairs(detail["post_data"]["item_like_users"]) do
          analyze_homeInfo(user)
        end
      end
      analyze_multi(detail["post_data"]["multi"])
      analyze_tag_list(detail["post_data"]["post_tags"])
      discover_integer("u", detail["post_data"]["uid"])
      -- detail["post_data"]["wid"]
    end
    analyze_homeInfo(detail["post_user_info"])
    if detail["recommend"] then
      analyze_items(detail["recommend"])
    end
  end
  local function analyze_page(page)
    -- 绘画活动 COS活动 写作活动 视频活动 问答活动
    if page["activityList"] then
      for _, activity in ipairs(page["activityList"]) do
        check(activity["link"])
      end
    end
    if page["banners"] then
      for _, banner in ipairs(page["banners"]) do
        if banner["cover"]:len() >= 1 then
          check(banner["cover"])
        end
        if banner["link"]:len() >= 1 then
          check(banner["link"])
        end
      end
    end
    if page["followCircles"] then
      analyze_followCircles(page["followCircles"])
    end
    if page["followUsers"] then
      analyze_followUsers(page["followUsers"])
    end
    if page["ptype"] == "user_index" then
      analyze_items(page["list"])
    elseif page["ptype"] == "following" or page["ptype"] == "follower" then
      analyze_followUsers(page["list"])
    elseif page["ptype"] == "circle" then
      analyze_followCircles(page["list"])
    elseif page["ptype"] == "user_like" then
      local list = page["list"]
      assert(#list == 0, "TODO: is user_like always empty?")
    elseif page["ptype"] == "user_collection" then
      analyze_collections(page["list"])
    end
    if page["type"] == "circle" then
      analyze_items(page["circleFeeds"])
      assert(#page["followdCircles"] == 0)
      for _, circle in ipairs(page["recHotCircleList"]) do
        analyze_tagInfo(circle["info"])
      end
      -- 相关圈子
      for _, circle in ipairs(page["relativeCircles"]) do
        analyze_tagInfo(circle["info"])
      end
      analyze_tagInfo(page["tagInfo"])
    elseif page["type"] == "collection" then
      analyze_homeInfo(page["collectUserInfo"])
      analyze_collections(page["collectionInfo"])
      discover_integer("c", page["collection_id"])
      analyze_items(page["itemList"])
    elseif page["type"] == "cos" or page["type"] == "illust" or page["type"] == "novel" then
      for banners in pairs({page["asideBanners"], page["headBanner"]}) do
        if banners then
          for _, banner in ipairs(banners) do
            if type(banner["eb_id"]) == "string" and string.match(banner["eb_id"], "^https?://") then
              check(banner["eb_id"])
            end
            if type(banner["link"]) == "string" and string.match(banner["link"], "^https?://") then
              check(banner["link"])
            end
          end
        end
      end
      if page["feedData"] then
        analyze_items(page["feedData"])
      end
      if page["activeTitle"] == "榜单" then
        analyze_items(page["rankList"])
      else
        for _, item in ipairs(page["rankList"]) do
          analyze_item(page["rankList"])
        end
      end
      -- 优秀画手推荐
      -- 优秀 COSER 推荐
      -- 优秀写手推荐
      if page["recommendList"] then
        for _, recommend in ipairs(page["recommendList"]) do
          check(recommend["avatar"])
          for _, item in ipairs(recommend["items"]) do
            discover_integer("i", item["item_id"])
            analyze_tag_list(item["tags"])
          end
          discover_integer("u", recommend["uid"])
        end
      end
    elseif page["type"] == "sitetop" then
      analyze_items(page["list"])
    elseif page["type"] == "sub_channel" then
      assert(#page["bangumi"]["list"] == 0)
      for _, channel in ipairs(page["channels"]) do
        discover_integer("vl", channel["cid"])
        if channel["url"] and channel["url"]:len() >= 1 then
          check(channel["url"])
        end
      end
      discover_integer("vl", page["cid"])
      for _, banner in ipairs(page["getVideoBanner"]) do
        if type(banner["eb_id"]) == "string" and string.match(banner["eb_id"], "^https?://") then
          check(banner["eb_id"])
        end
        if type(banner["link"]) == "string" and string.match(banner["link"], "^https?://") then
          check(banner["link"])
        end
      end
      analyze_items(page["hotList"])
      analyze_items(page["list"])
      analyze_items(page["newList"])
      assert(page["page_info"]["current_page"] == "video_sub_channel")
    end
  end
  local function analyze_huodong(huodong)
    for _, banner in pairs({
      huodong["app_banner"],
      huodong["banner"],
      huodong["share"],
    }) do
      check(banner["url"])
    end
    if huodong["circle_id"] then
      discover_integer("t", huodong["circle_id"])
    end
    discover_integer("h", huodong["event_id"])
    analyze_items(huodong["items"])
    assert(huodong["otherItems"] and #huodong["otherItems"] == 0)
  end

  if true or item_type == "c" then
    if string.match(url, "^https?://bcy%.net/collection/[0-9]+$") then
      html = read_file(file)
      ssr_data = get_ssr_data(html)
      assert(ssr_data)
      assert(ssr_data["page"]["collection_id"] and ssr_data["page"]["since"] and ssr_data["page"]["sort"])
      analyze_page(ssr_data["page"])
      -- ./src/pages/pc/home/index/components/WaterFalls/index.js handleScroll()
      -- ./src/pages/pc/collect/detail/components/DetailMain/index.js loadMore()
      local props_page_collection_id = ssr_data["page"]["collection_id"]
      local props_page_since = ssr_data["page"]["since"]
      local props_page_sort = ssr_data["page"]["sort"]
      check("https://bcy.net/apiv3/collection/collectionItemList?collection_id=" .. props_page_collection_id .. "&since=" .. props_page_since .. "&sort=" .. props_page_sort, url)
      -- ./src/pages/pc/collect/detail/components/DetailMain/index.js handleChangeSort()
      check("https://bcy.net/apiv3/collection/collectionItemList?collection_id=" .. props_page_collection_id .. "&sort=0", url)
      check("https://bcy.net/apiv3/collection/collectionItemList?collection_id=" .. props_page_collection_id .. "&sort=1", url)
    elseif string.match(url, "^https?://bcy%.net/apiv3/collection/collectionItemList%?collection_id=[0-9]+&sort=[01]$")
      or string.match(url, "^https?://bcy%.net/apiv3/collection/collectionItemList%?collection_id=[0-9]+&since=[^&]+&sort=[01]$") then
      html = read_file(file)
      json = JSON:decode(html)
      if json["code"] == 0 then
        local items = json["data"]["items"]
        analyze_items(items)
        if #items > 0 then
          local props_page_collection_id = string.match(url, "^https?://bcy%.net/apiv3/collection/collectionItemList%?collection_id=([0-9]+)")
          local props_page_since = items[#items]["since"]
          local props_page_sort = string.match(url, "&sort=([0-9]+)$")
          local referer = "https://bcy.net/collection/" .. props_page_collection_id
          check("https://bcy.net/apiv3/collection/collectionItemList?collection_id=" .. props_page_collection_id .. "&since=" .. props_page_since .. "&sort=" .. props_page_sort, referer)
        end
      end
    end
  end
  if true or item_type == "g" then
    if string.match(url, "^https?://bcy%.net/group/list/[0-9]+$") then
      html = read_file(file)
      ssr_data = get_ssr_data(html)
      assert(ssr_data)
      assert(ssr_data["page"]["gid"] and ssr_data["page"]["groupInfo"] and ssr_data["page"]["groupInfoList"] and ssr_data["page"]["userinfo"])
      assert(ssr_data["user"]["uid"])
      analyze_groupInfo(json["page"]["groupInfo"])
      analyze_groupInfoList(json["page"]["groupInfoList"])
      analyze_userinfo(json["page"]["userinfo"])
      -- ./src/pages/pc/group/list/components/GroupMainContent/index.js handleChangeSortType()
      local props_page_gid = ssr_data["page"]["gid"]
      local props_user_uid = ssr_data["user"]["uid"]
      check("https://bcy.net/apiv3/common/getGroupInfoMap?gid=" .. props_page_gid .. "&uid=" .. props_user_uid .. "&order_type=hot&page=1", url)
      check("https://bcy.net/apiv3/common/getGroupInfoMap?gid=" .. props_page_gid .. "&uid=" .. props_user_uid .. "&order_type=time&page=1", url)
      -- page >= 2 requires login
    elseif string.match(url, "^https?://bcy%.net/apiv3/common/getGroupInfoMap%?gid=[0-9]+&uid=[0-9]+&order_type=[a-z]+&page=1$") then
      html = read_file(file)
      json = JSON:decode(html)
      if json["code"] == 0 then
        analyze_groupInfoList(json["data"]["group_info"])
      end
    end
  end
  if true or item_type == "h" then
    if string.match(url, "^https?://bcy%.net/huodong/[0-9]+$") then
      html = read_file(file)
      ssr_data = get_ssr_data(html)
      assert(ssr_data)
      assert(ssr_data["huodong"]["event_id"] and ssr_data["huodong"]["order"] and ssr_data["huodong"]["total"])
      analyze_huodong(ssr_data["huodong"])
      -- ./node_modules/byted-dimension-ui/lib/pager/Pager.js changePage()
      -- ./src/pages/pc/static/huodong/nevent/index.js onPageChange()
      local props_huodong_event_id = ssr_data["huodong"]["event_id"]
      -- local props_huodong_order = ssr_data["huodong"]["order"]
      local props_huodong_total = ssr_data["huodong"]["total"]
      local state_pageSize = 42
      local state_page = ssr_data["huodong"]["p"] or 1
      for p = math.ceil(props_huodong_total / state_pageSize), 1, -1 do
        check("https://bcy.net/huodong/" .. props_huodong_event_id .. "?order=hot&p=" .. p)
        check("https://bcy.net/huodong/" .. props_huodong_event_id .. "?order=index&p=" .. p)
      end
      -- 按最赞排序
      check("https://bcy.net/huodong/" .. props_huodong_event_id .. "?order=hot")
      -- 按最新排序
      check("https://bcy.net/huodong/" .. props_huodong_event_id .. "?order=index")
    elseif string.match(url, "^https?://bcy%.net/huodong/[0-9]+%?order=[a-z]+$")
      or string.match(url, "^https?://bcy%.net/huodong/[0-9]+%?order=[a-z]+&p=[0-9]+$") then
      html = read_file(file)
      ssr_data = get_ssr_data(html)
      assert(ssr_data)
      assert(ssr_data["huodong"])
      analyze_huodong(ssr_data["huodong"])
    end
  end
  if true or item_type == "i" then
    if string.match(url, "^https?://bcy%.net/item/detail/[0-9]+$") then
      html = read_file(file)
      ssr_data = get_ssr_data(html)
      assert(ssr_data)
      assert(ssr_data["detail"]["post_data"]["item_id"])
      assert(ssr_data["detail"]["post_data"]["type"] == "article" or ssr_data["detail"]["post_data"]["type"] == "ganswer" or ssr_data["detail"]["post_data"]["type"] == "note" or ssr_data["detail"]["post_data"]["type"] == "video")
      analyze_detail(ssr_data["detail"])
      -- ./src/pages/pc/item/detail/components/Comment/index.js changeSort() loadMore()
      local state_currentPage = 1
      local props_post_data_item_id = ssr_data["detail"]["post_data"]["item_id"]
      local state_sort = "hot"
      check("https://bcy.net/apiv3/cmt/reply/list?page=" .. string.format("%.0f", state_currentPage) .. "&item_id=" .. props_post_data_item_id .. "&limit=15&sort=hot", url)
      check("https://bcy.net/apiv3/cmt/reply/list?page=" .. string.format("%.0f", state_currentPage) .. "&item_id=" .. props_post_data_item_id .. "&limit=15&sort=time", url)
      if ssr_data["detail"]["post_data"]["type"] == "video" then
        video_props_post_data_item_id[ssr_data["detail"]["post_data"]["video_info"]["vid"]] = props_post_data_item_id
        -- ./src/pages/pc/item/detail/components/LeftPanel/Video.js componentDidMount()
        -- ./node_modules/xgplayer-service/dist/index.js
        -- www.52 pojie.cn/thread-1741682-1-1.html
        -- blog.cs dn.net/s_kangkang_A/article/details/112846345
        assert(ssr_data["detail"]["post_data"]["postStatus"] == "normal")
        print("Found video " .. ssr_data["detail"]["post_data"]["video_info"]["vid"])
        local play_auth_token = JSON:decode(base64.decode(ssr_data["detail"]["post_data"]["video_info"]["play_auth_token"]))
        assert(play_auth_token["GetPlayInfoToken"])
        check("https://vod.bytedanceapi.com/?" .. play_auth_token["GetPlayInfoToken"] .. "&Ssl=1", "https://bcy.net/")
      end
    elseif string.match(url, "^https?://bcy%.net/apiv3/cmt/reply/list%?page=[0-9]+&item_id=[0-9]+&limit=15&sort=[a-z]+$") then
      html = read_file(file)
      json = JSON:decode(html)
      if json["code"] == 0 then
        local data = json["data"]["data"]
        analyze_comments(data)
        if #data > 0 then
          local state_currentPage, props_post_data_item_id, state_sort = string.match(url, "^https?://bcy%.net/apiv3/cmt/reply/list%?page=([0-9]+)&item_id=([0-9]+)&limit=15&sort=([a-z]+)$")
          assert(state_sort == "hot" or state_sort == "time")
          local referer = "https://bcy.net/item/detail/" .. props_post_data_item_id
          check("https://bcy.net/apiv3/cmt/reply/list?page=" .. string.format("%.0f", tonumber(state_currentPage) + 1) .. "&item_id=" .. props_post_data_item_id .. "&limit=15&sort=hot", referer)
        end
      end
    elseif string.match(url, "^https?://vod%.bytedanceapi%.com/%?") then
      html = read_file(file)
      json = JSON:decode(html)
      assert(json["ResponseMetadata"] and json["Result"])
      assert(json["Result"]["CipherText"] == "" and json["Result"]["EncryptKey"] == "" and json["Result"]["Data"])
      local Data = json["Result"]["Data"]
      -- ./src/pages/pc/item/detail/components/LeftPanel/Video.js getBullets()
      local props_post_data_item_id = video_props_post_data_item_id[json["Result"]["Data"]["VideoID"]]
      local state_duration = math.floor(1000 * Data["Duration"] + 0.1)
      local state_end_offset_time = 0
      assert(props_post_data_item_id)
      local referer = "https://bcy.net/item/detail/" .. props_post_data_item_id
      if state_duration > state_end_offset_time then
        check("https://bcy.net/apiv3/danmaku/get?item_id=" .. props_post_data_item_id .. "&duration=" .. state_duration .. "&offset_time=" .. state_end_offset_time, referer)
      end
      -- wget.callbacks.get_urls is first in first out
      for _, PlayInfo in ipairs(Data["PlayInfoList"]) do
        -- check(PlayInfo["BackupPlayUrl"], "https://bcy.net/")
        check(PlayInfo["MainPlayUrl"], "https://bcy.net/")
      end
      check(Data["CoverUrl"])
    elseif string.match(url, "^https?://bcy%.net/apiv3/danmaku/get%?item_id=[0-9]+&duration=[0-9]+&offset_time=[0-9]+$") then
      html = read_file(file)
      json = JSON:decode(html)
      if json["code"] == 0 then
        local danmakus = json["data"]["danmakus"]
        for _, danmaku in ipairs(danmakus) do
          discover_integer("u", danmaku["bcy_uid"])
        end
        local props_post_data_item_id, state_duration = string.match(url, "^https?://bcy%.net/apiv3/danmaku/get%?item_id=([0-9]+)&duration=([0-9]+)&offset_time=[0-9]+$")
        local state_end_offset_time = json["data"]["end_offset_time"]
        local referer = "https://bcy.net/item/detail/" .. props_post_data_item_id
        if tonumber(state_duration) > state_end_offset_time then
          check("https://bcy.net/apiv3/danmaku/get?item_id=" .. props_post_data_item_id .. "&duration=" .. state_duration .. "&offset_time=" .. state_end_offset_time, referer)
        end
      end
    end
  end
  if true or item_type == "s" then
    if string.match(url, "^https?://bcy%.net/s/[0-9A-Za-z]+/$") then
      assert(new_locations[url] and string.match(new_locations[url], "^https?://"), new_locations[url])
      check(new_locations[url])
    end
  end
  if true or item_type == "t" then
    if string.match(url, "^https?://bcy%.net/tag/[0-9]+$") then
      html = read_file(file)
      ssr_data = get_ssr_data(html)
      if ssr_data then
        assert(ssr_data["page"]["circleSince"] and ssr_data["page"]["isHasData"] ~= nil and ssr_data["page"]["sort_type"] and ssr_data["page"]["tagInfo"]["circle_name"] and ssr_data["page"]["type"] == "circle")
        analyze_page(ssr_data["page"])
        -- ./src/pages/pc/home/index/components/WaterFalls/index.js handleScroll()
        -- ./src/pages/pc/circle/index.js getMoreDisplayCircle()
        local state_circle_id = ssr_data["page"]["tagInfo"]["circle_id"]
        local props_circleSince = ssr_data["page"]["circleSince"]
        local state_sortType = ssr_data["page"]["sort_type"]
        if ssr_data["page"]["isHasData"] then
          check("https://bcy.net/apiv3/common/circleFeed?circle_id=" .. state_circle_id .. "&since=" .. props_circleSince .. "&sort_type=" .. state_sortType .. "&grid_type=10", url)
        end
        -- ./src/pages/pc/circle/index.js changeSortType() initCircleMessage()
        -- 热门动态
        check("https://bcy.net/apiv3/common/circleFeed?circle_id=" .. state_circle_id .. "&since=&sort_type=1&grid_type=10", url)
        -- 最新动态
        check("https://bcy.net/apiv3/common/circleFeed?circle_id=" .. state_circle_id .. "&since=0&sort_type=2&grid_type=10", url)
        check("https://bcy.net/tags/name/" .. ssr_data["page"]["tagInfo"]["circle_name"])
      else
        -- tags of type "event" produce HTTP 302 to /huodong/
        assert(new_locations[url] and string.match(new_locations[url], "^https?://"), new_locations[url])
        check(new_locations[url])
      end
    elseif string.match(url, "^https?://bcy%.net/tag/name/[^?]+$") then
      -- do nothing
    elseif string.match(url, "^https?://bcy%.net/circle/index/[0-9]+$") then
      -- do nothing
    elseif string.match(url, "^https?://bcy%.net/apiv3/common/circleFeed%?circle_id=[0-9]+&since=[^&]*&sort_type=[0-9]+&grid_type=10$") then
      html = read_file(file)
      json = JSON:decode(html)
      if json["code"] == 0 then
        local items = json["data"]["items"]
        analyze_items(items)
        if #items > 0 then
          local state_circle_id, state_sortType = string.match(url, "^https?://bcy%.net/apiv3/common/circleFeed%?circle_id=([0-9]+)&since=[^&]*&sort_type=([0-9]+)&grid_type=10$")
          local props_circleSince = items[#items]["since"]
          local referer = "https://bcy.net/tag/" .. state_circle_id
          check("https://bcy.net/apiv3/common/circleFeed?circle_id=" .. state_circle_id .. "&since=" .. props_circleSince .. "&sort_type=" .. state_sortType .. "&grid_type=10", referer)
        end
      end
    end
  end
  if true or item_type == "u" then
    -- TA 的发布
    if string.match(url, "^https?://bcy%.net/u/[0-9]+$") then
      html = read_file(file)
      ssr_data = get_ssr_data(html)
      assert(ssr_data)
      if ssr_data["homeInfo"] and ssr_data["page"] then
        assert(ssr_data["homeInfo"]["uid"])
        assert(ssr_data["page"]["filter"] == "all" and ssr_data["page"]["hasMore"] ~= nil and ssr_data["page"]["ptype"] == "user_index")
        analyze_homeInfo(ssr_data["homeInfo"])
        analyze_page(ssr_data["page"])
        -- ./src/pages/pc/profile/index/index.js loadMore() getPost(false, state.filter)
        local props_homeInfo_uid = string.format("%.0f", ssr_data["homeInfo"]["uid"])
        local props_page_since = ssr_data["page"]["since"]
        user_exists[props_homeInfo_uid] = true
        if ssr_data["page"]["hasMore"] == true then
          check("https://bcy.net/apiv3/user/selfPosts?uid=" .. props_homeInfo_uid .. "&since=" .. props_page_since, url)
        end
        check("https://bcy.net/u/" .. props_homeInfo_uid .. "/circle")
        check("https://bcy.net/u/" .. props_homeInfo_uid .. "/follower")
        check("https://bcy.net/u/" .. props_homeInfo_uid .. "/following")
        check("https://bcy.net/u/" .. props_homeInfo_uid .. "/post/video")
        check("https://bcy.net/u/" .. props_homeInfo_uid .. "/post/ganswer")
        check("https://bcy.net/u/" .. props_homeInfo_uid .. "/post/article")
        check("https://bcy.net/u/" .. props_homeInfo_uid .. "/post/note")
        check("https://bcy.net/u/" .. props_homeInfo_uid .. "/post/")
        check("https://bcy.net/u/" .. props_homeInfo_uid .. "/post")
        check("https://bcy.net/u/" .. props_homeInfo_uid .. "/collection")
        check("https://bcy.net/u/" .. props_homeInfo_uid .. "/like")
      else
        assert(ssr_data["message"] and ssr_data["message"]["success"] == false)
      end
    -- TA 的喜欢
    elseif string.match(url, "^https?://bcy%.net/u/[0-9]+/like$") then
      html = read_file(file)
      ssr_data = get_ssr_data(html)
      assert(ssr_data)
      assert(ssr_data["homeInfo"]["uid"])
      assert(ssr_data["page"]["filter"] == "all" and ssr_data["page"]["hasMore"] ~= nil and ssr_data["page"]["ptype"] == "user_like")
      assert(ssr_data["user"]["uid"])
      analyze_homeInfo(ssr_data["homeInfo"])
      analyze_page(ssr_data["page"])
      -- ./src/pages/pc/profile/index/index.js loadMore() getLikeData(false, "like")
      if ssr_data["page"]["hasMore"] == true then
        local props_homeInfo_uid = string.format("%.0f", ssr_data["homeInfo"]["uid"])
        local props_mid = ssr_data["user"]["uid"]
        local props_page_since = ssr_data["page"]["since"]
        check("https://bcy.net/apiv3/user/favor?uid=" .. props_homeInfo_uid .. "&ptype=like&mid=" .. props_mid .. "&since=" .. props_page_since .. "&size=35", url)
      end
    -- TA 的合集
    elseif string.match(url, "^https?://bcy%.net/u/[0-9]+/collection$") then
      html = read_file(file)
      ssr_data = get_ssr_data(html)
      assert(ssr_data)
      assert(ssr_data["homeInfo"]["uid"])
      assert(ssr_data["page"]["filter"] == "all" and ssr_data["page"]["hasMore"] ~= nil and ssr_data["page"]["ptype"] == "user_collection")
      analyze_homeInfo(ssr_data["homeInfo"])
      analyze_page(ssr_data["page"])
      -- ./src/pages/pc/profile/index/index.js loadMore() getCollectionData(false)
      local props_homeInfo_uid = string.format("%.0f", ssr_data["homeInfo"]["uid"])
      local props_page_since = ssr_data["page"]["since"]
      user_col_props_page_list_len[props_homeInfo_uid] = #ssr_data["page"]
      if ssr_data["page"]["hasMore"] == true then
        check("https://bcy.net/apiv3/collection/getMyCollectionList?uid=" .. props_homeInfo_uid .. "&since=" .. props_page_since, url)
      end
    -- TA的作品
    elseif string.match(url, "^https?://bcy%.net/u/[0-9]+/post") then
      html = read_file(file)
      ssr_data = get_ssr_data(html)
      assert(ssr_data)
      assert(ssr_data["homeInfo"]["uid"] and ssr_data["post_data"]["page"] and ssr_data["post_data"]["ptype"] and ssr_data["post_data"]["total"] and ssr_data["user"]["uid"])
      analyze_homeInfo(ssr_data["homeInfo"])
      analyze_items(ssr_data["post_data"]["list"])
      -- ./node_modules/byted-dimension-ui/lib/pager/Pager.js changePage()
      -- ./src/pages/pc/home/post/postRight.js onTabChange() onPageChange() getPostData()
      local props_uid = ssr_data["homeInfo"]["uid"]
      local props_ptype = ssr_data["post_data"]["ptype"]
      local props_mid = ssr_data["user"]["uid"]
      assert(props_ptype == "all" or props_ptype == "note" or props_ptype == "article" or props_ptype == "ganswer" or props_ptype == "video")
      assert(props_mid == "0")
      local state_pageSize = 35
      local state_post_data_total = ssr_data["post_data"]["total"]
      for p = math.ceil(state_post_data_total / state_pageSize), 1, -1 do
        check("https://bcy.net/u/" .. props_uid .. "/post/" .. (props_ptype ~= "all" and props_ptype or "") .. "?p=" .. p)
        local referer = "https://bcy.net/u/" .. props_uid .. "/post/" .. (props_ptype ~= "all" and props_ptype or "") .. (p >= 2 and ("?p=" .. string.format("%.0f", p - 1)) or "")
        -- error("TODO: how to retrieve cookie _csrf_token?")
        -- local _csrf_token = nil
        -- table.insert(urls, {
        --   url="https://bcy.net/apiv3/user/post",
        --   headers={ ["Content-Type"] = "application/json;charset=UTF-8", ["Referer"] = url, ["X-Requested-With"] = "XMLHttpRequest" },
        --   post_data='{"uid":"'..string.format("%.0f", props_uid)..'","ptype":"'..(1 or props_ptype)..'","page":'..(string.format("%.0f", p) or "1")..',"mid":"'..props_mid..'","_csrf_token":"'.._csrf_token..'"}'
        -- })
      end
    -- TA 的关注
    elseif string.match(url, "^https?://bcy%.net/u/[0-9]+/following$") then
      html = read_file(file)
      ssr_data = get_ssr_data(html)
      assert(ssr_data)
      assert(ssr_data["homeInfo"]["uid"])
      assert(ssr_data["page"]["hasMore"] ~= nil and ssr_data["page"]["pageNum"] and ssr_data["page"]["ptype"] == "following")
      analyze_homeInfo(ssr_data["homeInfo"])
      analyze_page(ssr_data["page"])
      -- ./src/pages/pc/profile/follow/index.js loadMore()
      if ssr_data["page"]["hasMore"] == true then
        local props_homeInfo_uid = string.format("%.0f", ssr_data["homeInfo"]["uid"])
        local props_page_pageNum = ssr_data["page"]["pageNum"]
        check("https://bcy.net/apiv3/follow-list?uid=" .. props_homeInfo_uid .. "&page=" .. string.format("%.0f", tonumber(props_page_pageNum) + 1) .. "&follow_type=0", url)
      end
    -- TA 的粉丝
    elseif string.match(url, "^https?://bcy%.net/u/[0-9]+/follower$") then
      html = read_file(file)
      ssr_data = get_ssr_data(html)
      assert(ssr_data)
      assert(ssr_data["homeInfo"]["uid"])
      assert(ssr_data["page"]["hasMore"] ~= nil and ssr_data["page"]["pageNum"] and ssr_data["page"]["ptype"] == "follower")
      analyze_homeInfo(ssr_data["homeInfo"])
      analyze_page(ssr_data["page"])
      -- ./src/pages/pc/profile/follow/index.js loadMore()
      if ssr_data["page"]["hasMore"] == true then
        local props_homeInfo_uid = string.format("%.0f", ssr_data["homeInfo"]["uid"])
        local props_page_pageNum = ssr_data["page"]["pageNum"]
        check("https://bcy.net/apiv3/follow-list?uid=" .. props_homeInfo_uid .. "&page=" .. string.format("%.0f", tonumber(props_page_pageNum) + 1) .. "&follow_type=1", url)
      end
    -- TA 关注的圈子
    elseif string.match(url, "^https?://bcy%.net/u/[0-9]+/circle$") then
      html = read_file(file)
      ssr_data = get_ssr_data(html)
      assert(ssr_data)
      assert(ssr_data["homeInfo"]["uid"])
      assert(ssr_data["page"]["hasMore"] == false and ssr_data["page"]["ptype"] == "circle")
      analyze_homeInfo(ssr_data["homeInfo"])
      analyze_page(ssr_data["page"])
    -- apiv3
    elseif string.match(url, "^https?://bcy%.net/apiv3/user/selfPosts%?uid=[0-9]+&since=[0-9]+$") then
      html = read_file(file)
      json = JSON:decode(html)
      if json["code"] == 0 then
        local items = json["data"]["items"]
        if items ~= nil then
          analyze_items(items)
          local hasMore = (#items > 0)
          if hasMore == true then
            local props_homeInfo_uid = string.match(url, "^https?://bcy%.net/apiv3/user/selfPosts%?uid=([0-9]+)&since=[0-9]+$")
            local props_page_since = items[#items]["since"]
            local referer = "https://bcy.net/u/" .. props_homeInfo_uid
            check("https://bcy.net/apiv3/user/selfPosts?uid=" .. props_homeInfo_uid .. "&since=" .. props_page_since, referer)
          end
        end
      elseif string.match(url, "^https?://bcy%.net/apiv3/user/favor%?uid=[0-9]+&ptype=like&mid=[0-9]+&since=[0-9]+&size=35$") then
        html = read_file(file)
        json = JSON:decode(html)
        if json["code"] == 0 then
          local list = json["data"]["list"]
          if list ~= nil then
            -- error("TODO: what is the structure of the favor list?")
            -- analyze_favor(list)
            local hasMore = (#list > 0)
            if hasMore == true then
              local props_homeInfo_uid, props_mid = string.match(url, "^https?://bcy%.net/apiv3/user/favor%?uid=([0-9]+)&ptype=like&mid=([0-9]+)&since=[0-9]+&size=35$")
              local props_page_since = list[#list]["since"]
              local referer = "https://bcy.net/u/" .. props_homeInfo_uid
              check("https://bcy.net/apiv3/user/favor?uid=" .. props_homeInfo_uid .. "&ptype=like&mid=" .. props_mid .. "&since=" .. props_page_since .. "&size=35", url)
            end
          end
        end
      elseif string.match(url, "^https?://bcy%.net/apiv3/collection/getMyCollectionList%?uid=[0-9]+&since=[0-9]+$") then
        html = read_file(file)
        json = JSON:decode(html)
        if json["code"] == 0 then
          local collections = json["data"]["collections"]
          if collections ~= nil then
            analyze_collections(collections)
            local props_homeInfo_uid = string.match(url, "^https?://bcy%.net/apiv3/collection/getMyCollectionList%?uid=([0-9]+)&since=[0-9]+$")
            local props_page_since = collections[#collections]["since"]
            local props_page_list_len = user_col_props_page_list_len[props_homeInfo_uid]
            assert(props_page_list_len)
            props_page_list_len = props_page_list_len + #json["data"]["collections"]
            user_col_props_page_list_len[props_homeInfo_uid] = props_page_list_len
            local hasMore = (props_page_list_len < json["data"]["total"])
            if hasMore == true then
              local referer = "https://bcy.net/u/" .. props_homeInfo_uid .. "/collection"
              check("https://bcy.net/apiv3/collection/getMyCollectionList?uid=" .. props_homeInfo_uid .. "&since=" .. props_page_since, referer)
            end
          end
        elseif string.match(url, "^https?://bcy%.net/apiv3/user/post$") then
          html = read_file(file)
          json = JSON:decode(html)
          if json["code"] == 0 then
            local items = json["data"]["items"]
            analyze_items(items or {})
          end
        elseif string.match(url, "^https?://bcy%.net/apiv3/follow%-list%?uid=[0-9]+&page=[0-9]+&follow_type=[013]$") then
          local props_homeInfo_uid, props_page_pageNum, follow_type = string.match(url, "^https?://bcy%.net/apiv3/follow%-list%?uid=([0-9]+)&page=([0-9]+)&follow_type=([013])$")
          html = read_file(file)
          json = JSON:decode(html)
          if json["code"] == 0 then
            if follow_type == "0" or follow_type == "1" or follow_type == "2" then
              local user_follow_info = json["data"]["user_follow_info"]
              analyze_followUsers(user_follow_info)
              local hasMore = (#user_follow_info >= 20)
              if hasMore == true then
                local referer = "https://bcy.net/u/" .. props_homeInfo_uid .. (follow_type == "0" and "/following" or (follow_type == "1" and "/follower" or "/eachfollow"))
                check("https://bcy.net/apiv3/follow-list?uid=" .. props_homeInfo_uid .. "&page=" .. string.format("%.0f", tonumber(props_page_pageNum) + 1) .. "&follow_type=1", referer)
              end
            elseif follow_type == 3 then
              local user_follow_circles = json["data"]["user_follow_circles"]
              analyze_followCircles(user_follow_circles)
            else
              error('follow_type should be "0", "1", or 3')
            end
          end
        end
      end
    end
  end
  if true or item_type == "top" then
    if string.match(url, "^https?://bcy%.net/[a-z]+/toppost100$")
      or string.match(url, "^https?://bcy%.net/[a-z]+/toppost100%?type=[A-Za-z]+&date=[0-9]+$") then
      local top_ptype = string.match(url, "^https?://bcy%.net/([a-z]+)/toppost100")
      local top_rtype, top_date = string.match(url, "^https?://bcy%.net/[a-z]+/toppost100%?type=([A-Za-z]+)&date=([0-9]+)$")
      if top_ptype == "coser" then
        top_ptype = "cos"
      end
      assert(top_ptype == "illust" or top_ptype == "cos" or top_ptype == "novel")
      if top_rtype and top_date then
        assert(top_rtype == "week" or top_rtype == "lastday" or top_rtype == "newPeople")
      else
        assert(top_rtype == nil and top_date == nil)
        top_rtype = "week"
      end
      html = read_file(file)
      ssr_data = get_ssr_data(html)
      assert(ssr_data)
      assert(ssr_data["page"]["pageInfo"]["date"] and ssr_data["page"]["p"] and ssr_data["page"]["pageInfo"]["pageType"] == top_ptype and ssr_data["page"]["pageInfo"]["rankType"] == top_rtype)
      analyze_page(ssr_data["page"])
      local props_page_p = ssr_data["page"]["p"]
      local props_page_pageInfo_pageType = ssr_data["page"]["pageInfo"]["pageType"]
      local props_page_pageInfo_rankType = ssr_data["page"]["pageInfo"]["rankType"]
      local props_page_pageInfo_date = ssr_data["page"]["pageInfo"]["date"]
      -- ./node_modules/react-infinite-scroller/index.js
      -- ./src/pages/pc/rank/index/index.js getMoreList()
      if ssr_data["page"]["hasMore"] == true then
        check("https://bcy.net/apiv3/rank/list/itemInfo?p=" .. string.format("%.0f", props_page_p + 1) .. "&ttype=" .. props_page_pageInfo_pageType .. "&sub_type=" .. props_page_pageInfo_rankType .. "&date=" .. props_page_pageInfo_date, url)
      end
      -- ./src/pages/pc/rank/index/components/DataPage/index.js handleClick()
      -- ./src/pages/pc/rank/index/index.js initList()
      check("https://bcy.net/apiv3/rank/list/itemInfo?p=1&ttype=" .. props_page_pageInfo_pageType .. "&sub_type=" .. props_page_pageInfo_rankType .. "&date=" .. props_page_pageInfo_date, url)
    elseif string.match(url, "^https?://bcy%.net/apiv3/rank/list/itemInfo%?p=[0-9]+&ttype=illust&sub_type=[A-Za-z]+&date=[0-9]+$")
      or string.match(url, "^https?://bcy%.net/apiv3/rank/list/itemInfo%?p=[0-9]+&ttype=cos&sub_type=[A-Za-z]+&date=[0-9]+$")
      or string.match(url, "^https?://bcy%.net/apiv3/rank/list/itemInfo%?p=[0-9]+&ttype=novel&sub_type=[A-Za-z]+&date=[0-9]+$") then
      html = read_file(file)
      json = JSON:decode(html)
      if json["code"] == 0 then
        local top_list_item_info = json["data"]["top_list_item_info"]
        analyze_items(top_list_item_info)
        local hasMore = (#top_list_item_info > 0)
        if hasMore == true then
          local props_page_p, props_page_pageInfo_pageType, props_page_pageInfo_rankType, props_page_pageInfo_date = string.match(url, "^https?://bcy%.net/apiv3/rank/list/itemInfo%?p=([0-9]+)&ttype=([a-z]+)&sub_type=([A-Za-z]+)&date=([0-9]+)$")
          local referer = "https://bcy.net/" .. props_page_pageInfo_pageType .. "/toppost100?type=" .. props_page_pageInfo_pageType .. "&date=" .. props_page_pageInfo_date
          check("https://bcy.net/apiv3/rank/list/itemInfo?p=" .. string.format("%.0f", props_page_p + 1) .. "&ttype=" .. props_page_pageInfo_pageType .. "&sub_type=" .. props_page_pageInfo_rankType .. "&date=" .. props_page_pageInfo_date, referer)
        end
      end
    end
  end
  if true or item_type == "top-v" then
    if string.match(url, "^https?://bcy%.net/video/toppost100$")
      or string.match(url, "^https?://bcy%.net/video/toppost100%?type=[A-Za-z]+$")
      or string.match(url, "^https?://bcy%.net/video/toppost100%?type=[A-Za-z]+&date=[0-9]+$") then
      local top_type = string.match(url, "^https?://bcy%.net/video/toppost100%?type=([A-Za-z]+)")
      if top_type == nil then
        top_type = "sitetop"
      end
      html = read_file(file)
      ssr_data = get_ssr_data(html)
      assert(ssr_data)
      assert(ssr_data["page"]["dateStr"] and ssr_data["page"]["p"] and ssr_data["page"]["period"] and ssr_data["page"]["type"] == top_type)
      analyze_page(ssr_data["page"])
      local props_p = ssr_data["page"]["p"]
      local props_type = ssr_data["page"]["type"]
      -- local props_period = ssr_data["page"]["period"]
      local props_dateStr = ssr_data["page"]["dateStr"]
      assert(props_p == 1)
      assert(props_type == "sitetop" or props_type == "newPeople")
      for _, period in pairs(props_type == "sitetop" and {"month", "3day", "week"} or {"week", "lastday", "3day"}) do
        -- ./src/pages/pc/video/rank/index.js handleScroll() appendList()
        check("https://bcy.net/apiv3/rank/list/itemInfo?p=" .. string.format("%.0f", props_p + 1) .. "&ttype=video&sub_type=" .. props_type .. "&duration_type=" .. period .. "&date=" .. props_dateStr, url)
        -- ./src/pages/pc/video/rank/index.js changePeriod() initList()
        check("https://bcy.net/apiv3/rank/list/itemInfo?p=1&ttype=video&sub_type=" .. props_type .. "&duration_type=" .. period .. "&date=" .. props_dateStr, url)
      end
    elseif string.match(url, "^https?://bcy%.net/apiv3/rank/list/itemInfo%?p=[0-9]+&ttype=video&sub_type=[A-Za-z]+&duration_type=[0-9a-z]+&date=[0-9]+$") then
      html = read_file(file)
      json = JSON:decode(html)
      if json["code"] == 0 then
        local top_list_item_info = json["data"]["top_list_item_info"]
        analyze_items(top_list_item_info)
        if #top_list_item_info > 0 then
          local props_p, props_type, props_period, props_dateStr = string.match(url, "^https?://bcy%.net/apiv3/rank/list/itemInfo%?p=([0-9]+)&ttype=video&sub_type=([A-Za-z]+)&duration_type=([0-9a-z]+)&date=([0-9]+)$")
          local referer = "https://bcy.net/video/toppost100?type=" .. props_type
          check("https://bcy.net/apiv3/rank/list/itemInfo?p=" .. string.format("%.0f", tonumber(props_p) + 1) .. "&ttype=video&sub_type=" .. props_type .. "&duration_type=" .. props_period .. "&date=" .. props_dateStr, referer)
        end
      end
    end
  end
  if true or item_type == "vl" then
    if string.match(url, "^https?://bcy%.net/video/list/[0-9]+$") then
      html = read_file(file)
      ssr_data = get_ssr_data(html)
      assert(ssr_data)
      assert(ssr_data["page"]["cid"])
      analyze_page(ssr_data["page"])
      -- ./src/pages/pc/video/index/index.js handleScroll() loadMore()
      local props_page_cid = ssr_data["page"]["cid"]
      check("https://bcy.net/apiv3/common/getFeeds?refer=channel_video&direction=loadmore&cid=" .. props_page_cid, url)
      -- ./src/pages/pc/video/components/rankList/index.js clickChangePeriod() getList()
      if props_page_cid == "8103" then
        -- 新人榜
        check("https://bcy.net/apiv3/rank/list/itemInfo?p=1&ttype=video&sub_type=newPeople&duration_type=week", url)
        check("https://bcy.net/apiv3/rank/list/itemInfo?p=1&ttype=video&sub_type=newPeople&duration_type=3day", url)
        check("https://bcy.net/apiv3/rank/list/itemInfo?p=1&ttype=video&sub_type=newPeople&duration_type=lastday", url)
        -- 全站热度榜
        check("https://bcy.net/apiv3/rank/list/itemInfo?p=1&ttype=video&sub_type=sitetop&duration_type=month", url)
        check("https://bcy.net/apiv3/rank/list/itemInfo?p=1&ttype=video&sub_type=sitetop&duration_type=week", url)
        check("https://bcy.net/apiv3/rank/list/itemInfo?p=1&ttype=video&sub_type=sitetop&duration_type=3day", url)
      end
    elseif string.match(url, "^https?://bcy%.net/apiv3/common/getFeeds%?refer=channel_video&direction=loadmore&cid=[0-9]+$") then
      html = read_file(file)
      json = JSON:decode(html)
      if json["code"] == 0 then
        local props_page_cid = string.match(url, "^https?://bcy%.net/apiv3/common/getFeeds%?refer=channel_video&direction=loadmore&cid=([0-9]+)$")
        local item_info = json["data"]["item_info"]
        video_list_depth[props_page_cid] = video_list_depth[props_page_cid] and video_list_depth[props_page_cid] + 1 or 1
        if item_info and #item_info > 0 and video_list_depth[props_page_cid] <= VIDEO_LIST_DEPTH_THRESHOLD then
          analyze_items(item_info)
          table.insert(urls, {
            url=url,
            headers={ ["Referer"] = "https://bcy.net/video/list/" .. props_page_cid, ["X-Requested-With"] = "XMLHttpRequest" }
          })
        else
          -- ./src/pages/pc/video/index/index.js removeScroll()
        end
      end
    elseif string.match(url, "^https?://bcy%.net/apiv3/rank/list/itemInfo%?p=[0-9]+&ttype=video&sub_type=[A-Za-z]+&duration_type=[0-9a-z]+$") then
      html = read_file(file)
      json = JSON:decode(html)
      if json["code"] == 0 then
        local top_list_item_info = json["data"]["top_list_item_info"]
        analyze_items(top_list_item_info)
      end
    end
  end
  if true or item_type == "url" then
    if string.match(url, "^https?://bcy%.net/$") then
      error("TODO: /")
    elseif string.match(url, "^https?://bcy%.net/group/discover$") then
      error("TODO: /group/discover")
    end
  end

  return urls
end

wget.callbacks.write_to_warc = function(url, http_stat)
  status_code = http_stat["statcode"]
  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
  io.stdout:flush()
  logged_response = true
  set_item(url["url"])
  if not item_name then
    error("No item name found.")
  end
  if string.match(url["url"], "^https?://[^/]*video%.bcy%.net/") then
    if 200 <= status_code and status_code <= 299 then
      assert(status_code == 206, status_code)
      -- error("TODO: how to get response headers?")
      -- assert(string.match(header["Content-Length"], "^[0-9]+$"), header["Content-Length"])
      -- local content_length = tonumber(header["Content-Length"])
      -- assert(header["Content-Range"] == "bytes 0-" .. string.format("%.0f", content_length - 1) .. "/" .. string.format("%.0f", content_length - 1), header["Content-Range"])
      return true
    else
      retry_url = true
      return false
    end
  end
  -- web pages sometimes require several retries
  if status_code == 404 and string.match(url["url"], "^https?://bcy%.net/[a-z]+/") then
    retry_url = true
    return false
  end
  if http_stat["statcode"] ~= 200
    and http_stat["statcode"] ~= 301 then
    retry_url = true
    return false
  end
  if abortgrab then
    print("Not writing to WARC.")
    return false
  end
  retry_url = false
  tries = 0
  return true
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]

  if not logged_response then
    url_count = url_count + 1
    io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
    io.stdout:flush()
  end
  logged_response = false

  if killgrab then
    return wget.actions.ABORT
  end

  set_item(url["url"])

  if status_code >= 300 and status_code <= 399 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    new_locations[url["url"]] = newloc
    if processed(newloc) or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    end
  end

  if status_code < 400 then
    downloaded[url["url"]] = true
  end

  if abortgrab then
    abort_item()
    return wget.actions.EXIT
  end

  if status_code == 0 or retry_url then
    io.stdout:write("Server returned bad response.")
    io.stdout:flush()
    tries = tries + 1
    if tries > 5 then
      io.stdout:write(" Skipping.\n")
      io.stdout:flush()
      tries = 0
      abort_item()
      return wget.actions.EXIT
    end
    local sleep_time = math.random(
      math.floor(math.pow(2, tries-0.5)),
      math.floor(math.pow(2, tries))
    )
    io.stdout:write("Sleeping " .. sleep_time .. " seconds.\n")
    io.stdout:flush()
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  end

  tries = 0

  return wget.actions.NOTHING
end

wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  local function submit_backfeed(items, key)
    local tries = 0
    local maxtries = 10
    while tries < maxtries do
      if killgrab then
        return false
      end
      local body, code, headers, status = http.request(
        "https://legacy-api.arpa.li/backfeed/legacy/" .. key,
        items .. "\0"
      )
      if code == 200 and body ~= nil and JSON:decode(body)["status_code"] == 200 then
        io.stdout:write(string.match(body, "^(.-)%s*$") .. "\n")
        io.stdout:flush()
        return nil
      end
      io.stdout:write("Failed to submit discovered URLs." .. tostring(code) .. tostring(body) .. "\n")
      io.stdout:flush()
      os.execute("sleep " .. math.floor(math.pow(2, tries)))
      tries = tries + 1
    end
    kill_grab()
    error()
  end

  local file = io.open(item_dir .. "/" .. warc_file_base .. "_bad-items.txt", "w")
  for url, _ in pairs(bad_items) do
    file:write(url .. "\n")
  end
  file:close()
  for key, data in pairs({
    ["bcy-0000000000000000"] = discovered_items,
    ["urls-0000000000000000"] = discovered_outlinks
  }) do
    print('queuing for', string.match(key, "^(.+)%-"))
    local items = nil
    local count = 0
    for item, _ in pairs(data) do
      print("found item", item)
      if items == nil then
        items = item
      else
        items = items .. "\0" .. item
      end
      count = count + 1
      if count == 100 then
        submit_backfeed(items, key)
        items = nil
        count = 0
      end
    end
    if items ~= nil then
      submit_backfeed(items, key)
    end
  end
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if killgrab then
    return wget.exits.IO_FAIL
  end
  if abortgrab then
    abort_item()
  end
  return exit_status
end


