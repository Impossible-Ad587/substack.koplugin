--[[
Networking and Substack API calls.
Substack has no official API; these are the JSON endpoints its own website uses.
]]

local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local _ = require("gettext")
local T = require("ffi/util").template

local SH = require("substack_html")

local json_decode
do
    local ok, rapidjson = pcall(require, "rapidjson")
    if ok and rapidjson and rapidjson.decode then
        json_decode = rapidjson.decode
    else
        json_decode = require("json").decode
    end
end

local USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    .. "Chrome/124.0 Safari/537.36 KOReader-Substack/2.5"

local Net = {}
Net.__index = Net
Net.decode = json_decode

local function str(v)
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

local function absoluteUrl(base, location)
    if location:match("^https?://") then return location end
    if location:sub(1, 2) == "//" then return "https:" .. location end
    local root = base:match("^(https?://[^/]+)")
    if location:sub(1, 1) == "/" then return root .. location end
    return (base:gsub("[^/]*$", "")) .. location
end

--- Turns low-level errors into something a person can act on.
function Net.friendly(err)
    err = tostring(err or "")
    local code = tonumber(err:match("HTTP (%d+)"))
    if code == 404 then return _("Not found. The post or publication may have been deleted or renamed.") end
    if code == 401 or code == 403 then
        -- Keep Substack's own reply: it tells a rejected cookie (401, JSON)
        -- apart from bot protection blocking the device (403, HTML page).
        local looks_blocked = err:find("Just a moment") or err:find("Cloudflare") or err:find("Attention Required")
            or err:find("captcha") or err:find("challenge")
        local hint = looks_blocked
            and _("Substack's bot protection blocked this device for that request.")
            or _("Substack didn't accept your session. Sign out, copy a fresh connect.sid (or substack.sid), and load it again.")
        return hint .. "\n\n" .. err
    end
    if code == 429 then return _("Substack is getting too many requests from this device. Wait a few minutes and try again.") end
    if code and code >= 500 then return _("Substack is having problems right now. Try again later.") end
    -- Other HTTP errors (e.g. 400): show Substack's own reply, which names the problem.
    -- (Checked before the text matches below, which could hit words in the URL.)
    if code then return err end
    if err:find("timeout") then return _("The connection timed out. Check your Wi-Fi signal and try again.") end
    if err:find("name resolution") then
        return _("Wi-Fi is on, but the Kindle couldn't reach the internet yet. Wait a few seconds and try again.")
    end
    if err:find("host") or err:find("resolve") or err:find("connection refused") or err:find("closed") then
        return _("Couldn't connect to Substack. Check that Wi-Fi is on and working.")
    end
    if err:find("Unexpected response") then return _("That address doesn't look like a Substack site.") end
    return err
end

--- settings: LuaSettings with optional "cookie"
function Net.new(settings)
    return setmetatable({ settings = settings }, Net)
end

--- Builds the Cookie header for a session value. Substack renamed its session
-- cookie from substack.sid to connect.sid; accounts signed in recently only
-- have connect.sid. Sending the value under both names works for either.
function Net.sessionHeader(connect, legacy)
    connect = connect or legacy
    legacy = legacy or connect
    if not connect then return nil end
    return "connect.sid=" .. connect .. "; substack.sid=" .. legacy
end

--- Cleans a pasted cookie: drops newlines/quotes and a "Cookie:" prefix, and
-- keeps only the session pair(s) (connect.sid / substack.sid) if a whole
-- cookie string was pasted. Returns a ready-to-send Cookie header, or nil.
function Net.cleanCookie(raw)
    if type(raw) ~= "string" then return nil end
    local c = raw:gsub("[\r\n\t]", ""):gsub('^"', ""):gsub('"$', "")
    c = c:gsub("^[Cc]ookie:%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
    local connect = c:match("connect%.sid=([^;%s]+)")
    local legacy = c:match("substack%.sid=([^;%s]+)")
    if connect or legacy then return Net.sessionHeader(connect, legacy) end
    -- Some other cookie, or text that isn't a cookie value at all: don't send junk.
    if c == "" or c:find("[=;%s]") then return nil end
    return Net.sessionHeader(c, c)
end

--- Only substack.com hosts get the session cookie (never custom domains or CDNs).
function Net.cookieAllowed(url)
    local host = (url:match("^https?://([^/:?#]+)") or ""):lower()
    return host == "substack.com" or host:sub(-#".substack.com") == ".substack.com"
end

function Net:cookie()
    return Net.cleanCookie(str(self.settings:readSetting("cookie")))
end

--- First ~200 characters of an error body, tags stripped, for messages.
local function snippet(chunks)
    local s = table.concat(chunks or {})
    s = s:gsub("<[^>]*>", " "):gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if #s > 200 then s = s:sub(1, 200) .. "…" end
    return s
end

--- GET. Returns body (or true when written to file_path), or nil, err.
--- Network errors that usually clear by themselves within seconds, typically
-- right after Wi-Fi comes on (the address lookup isn't ready yet).
local function isTransientNetError(err)
    err = tostring(err or ""):lower()
    return err:find("name resolution") or err:find("resolve") or err:find("host not found")
        or err:find("network is unreachable") or err:find("connection refused")
        or err:find("timeout") or err:find("closed")
end

local sleep_fn
local function pause(seconds)
    if not sleep_fn then
        local ok, util = pcall(require, "ffi/util")
        sleep_fn = (ok and util and util.sleep) or function(s) socket.sleep(s) end
    end
    pcall(sleep_fn, seconds)
end

function Net:get(url, file_path, send_cookie, tries)
    tries = tries or 2
    local last_err
    local attempt = 0
    while true do
        attempt = attempt + 1
        local body, err, retry, wait = self:_get(url, file_path, send_cookie)
        if body then return body end
        last_err = err
        if not retry then break end
        if tostring(err):find("^HTTP 429") then
            -- Too many requests: wait (as asked, or 5 s, 10 s, capped at 30 s), then retry up to twice.
            if attempt >= 3 then break end
            local seconds = math.min(wait or (5 * attempt), 30)
            logger.info("Substack: rate-limited, waiting", seconds, "s before retrying", url)
            pause(seconds)
            goto continue
        end
        -- Wi-Fi just connected: give the network a few seconds (2s, 4s, 6s).
        local max_tries = isTransientNetError(err) and math.max(tries, 4) or tries
        if attempt >= max_tries then break end
        if isTransientNetError(err) then
            logger.info("Substack: network not ready, retrying", attempt, err)
            pause(2 * attempt)
        end
        ::continue::
    end
    return nil, last_err
end

--- send_cookie: true = the saved session, a string = that exact Cookie header
-- (used to test a new session before saving it), false/nil = none.
function Net:_get(url, file_path, send_cookie)
    url = url:gsub("^%s+", ""):gsub("%s+$", "")
    local cookie
    if type(send_cookie) == "string" then cookie = send_cookie
    elseif send_cookie then cookie = self:cookie() end
    local tried_without_cookie = false
    local first_error
    local hops = 0
    while hops < 7 do
        hops = hops + 1
        local headers = {
            ["User-Agent"] = USER_AGENT,
            ["Accept"] = file_path and "image/jpeg,image/png,image/gif,image/*;q=0.8"
                or "application/json, text/plain, */*",
            ["Accept-Language"] = "en-US,en;q=0.9",
            -- LuaSocket's default is "close, TE" (+ "TE: trailers"), which some
            -- CDN/proxy setups reject with 400.
            ["Connection"] = "close",
        }
        local use_cookie = cookie and Net.cookieAllowed(url)
        if use_cookie then headers["Cookie"] = cookie end

        local chunks, sink, fh = {}, nil, nil
        if file_path then
            fh = io.open(file_path, "wb")
            if not fh then return nil, "cannot write " .. file_path end
            sink = ltn12.sink.file(fh)
            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT or 15, socketutil.FILE_TOTAL_TIMEOUT or 60)
        else
            sink = socketutil.table_sink and socketutil.table_sink(chunks) or ltn12.sink.table(chunks)
            socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT or 10, socketutil.LARGE_TOTAL_TIMEOUT or 30)
        end
        local code, resp_headers = socket.skip(1, http.request{
            url = url, method = "GET", headers = headers, sink = sink, redirect = false,
        })
        socketutil:reset_timeout()
        if fh then pcall(fh.close, fh) end -- normally closed by the sink already

        if type(code) ~= "number" then
            logger.warn("Substack: request failed", url, code)
            return nil, tostring(code), true -- network hiccup: worth one retry
        end
        if code >= 300 and code < 400 and resp_headers and resp_headers.location then
            url = absoluteUrl(url, resp_headers.location)
        elseif code == 200 then
            if file_path then return true end
            return table.concat(chunks)
        elseif use_cookie and not tried_without_cookie and (code == 400 or code == 401 or code == 403)
                and not url:match("^https?://substack%.com/") then
            -- A stale or malformed cookie can make Substack reject even public
            -- publication requests. Try once more without it, but keep the
            -- original reply in case that fails too. (Account endpoints on
            -- substack.com need the cookie, so retrying there is pointless.)
            logger.warn("Substack: HTTP", code, "with cookie; retrying without", url)
            first_error = "HTTP " .. code .. "\n" .. url
            local d = (not file_path) and snippet(chunks) or ""
            if d ~= "" then first_error = first_error .. "\n\n" .. d end
            cookie = nil
            tried_without_cookie = true
            hops = hops - 1
        else
            local detail = (not file_path) and snippet(chunks) or ""
            logger.warn("Substack: HTTP", code, url, detail)
            local msg = "HTTP " .. code .. "\n" .. url
            if detail ~= "" then msg = msg .. "\n\n" .. detail end
            if code == 429 then
                -- Rate-limited: worth retrying after the wait Substack asks for.
                local wait = resp_headers and tonumber(resp_headers["retry-after"] or resp_headers["Retry-After"])
                return nil, msg, true, wait
            end
            return nil, first_error or msg, code >= 500
        end
    end
    return nil, "too many redirects\n" .. url
end

function Net:getJson(url, cookie)
    local body, err = self:get(url, nil, cookie or true)
    if not body then return nil, err end
    local ok, data = pcall(json_decode, body)
    if not ok or type(data) ~= "table" then
        return nil, "Unexpected response"
    end
    return data
end

--- Single POST without redirects. Returns code, headers, body.
-- cookie (optional): a "name=value; name2=value2" string to send along.
function Net:post(url, body, cookie)
    local chunks = {}
    local headers = {
        ["User-Agent"] = USER_AGENT,
        ["Accept"] = "application/json",
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#body),
        ["Accept-Language"] = "en-US,en;q=0.9",
        ["Origin"] = "https://substack.com",
        ["Referer"] = "https://substack.com/sign-in?redirect=%2F",
        ["Connection"] = "close",
    }
    if cookie and cookie ~= "" then headers["Cookie"] = cookie end
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT or 10, socketutil.LARGE_TOTAL_TIMEOUT or 30)
    local code, resp_headers = socket.skip(1, http.request{
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(chunks),
        redirect = false,
    })
    socketutil:reset_timeout()
    return code, resp_headers, table.concat(chunks)
end

local COOKIE_ATTRS = { path = true, domain = true, expires = true, ["max-age"] = true,
                       samesite = true, httponly = true, secure = true, priority = true, partitioned = true }

--- Turns Set-Cookie header(s) into a { name = value } table.
-- LuaSocket joins repeated Set-Cookie headers with ", ", and Expires dates
-- also contain commas, so we pick out name=value pairs and skip attributes.
function Net.parseSetCookie(set_cookie)
    local jar = {}
    if type(set_cookie) ~= "string" then return jar end
    local s = ", " .. set_cookie
    for name, value in s:gmatch("[,;]%s*([%w%._%-]+)=([^;,]*)") do
        if not COOKIE_ATTRS[name:lower()] then jar[name] = value end
    end
    return jar
end

local function jarToHeader(jar)
    local parts = {}
    for k, v in pairs(jar or {}) do parts[#parts + 1] = k .. "=" .. v end
    table.sort(parts)
    return table.concat(parts, "; ")
end

--- Pulls a readable error message out of a Substack JSON error body.
local function errorMessage(body, code)
    local ok, data = pcall(json_decode, body or "")
    if ok and type(data) == "table" then
        local msg = str(data.error) or str(data.message)
        if not msg and type(data.errors) == "table" and type(data.errors[1]) == "table" then
            msg = str(data.errors[1].msg) or str(data.errors[1].message)
        end
        if msg then return msg end
    end
    -- Not JSON: usually Cloudflare's bot check answering instead of Substack.
    local b = tostring(body or "")
    if b:find("<html") or b:find("Just a moment") or b:find("Cloudflare") or b:find("challenge") then
        return T(_("Substack's bot protection blocked the sign-in from this device (HTTP %1). Use Account → Load session cookie from file instead."), code)
    end
    return T("HTTP %1", code)
end

local function sessionFromJar(jar)
    if type(jar) ~= "table" then return nil end
    return Net.sessionHeader(jar["connect.sid"], jar["substack.sid"])
end
Net.sessionFromJar = sessionFromJar

--- Does Substack treat this Cookie header as signed in?
-- Returns true, false (definitely not), or nil (couldn't tell, e.g. no network).
function Net:checkSession(cookie)
    local unsure = false
    for _i, url in ipairs({
        "https://substack.com/api/v1/user/profile/self",
        "https://substack.com/api/v1/subscriptions?tvOnly=false",
    }) do
        local data, err = self:getJson(url, cookie)
        if data and (data.id or data.handle or data.subscriptions or data.publications) then return true end
        local code = tonumber(tostring(err or ""):match("HTTP (%d+)"))
        if not (code == 401 or code == 403 or (data and true)) then unsure = true end
    end
    if unsure then return nil end
    return false
end

--- Loads a page like a browser would (no redirects followed) and returns the
-- cookies it sets, merged into jar.
function Net:collectCookies(url, jar)
    jar = jar or {}
    local headers = {
        ["User-Agent"] = USER_AGENT,
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.9",
        ["Connection"] = "close",
    }
    local cookie = jarToHeader(jar)
    if cookie ~= "" then headers["Cookie"] = cookie end
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT or 10, socketutil.LARGE_TOTAL_TIMEOUT or 30)
    local code, resp_headers = socket.skip(1, http.request{
        url = url, method = "GET", headers = headers,
        sink = ltn12.sink.null(), redirect = false,
    })
    socketutil:reset_timeout()
    if type(code) == "number" and resp_headers then
        for k, v in pairs(Net.parseSetCookie(resp_headers["set-cookie"] or resp_headers["Set-Cookie"])) do
            jar[k] = v
        end
    end
    return jar, code
end

--- Step 2: submits the code. Returns the substack.sid session, or nil, message.
function Net:completeEmailCode(state, otp)
    local payload = "{" .. table.concat({
        '"code":' .. Net.jsonString(otp),
        '"email":' .. Net.jsonString(state.email),
        '"redirect":"https://substack.com/"',
    }, ",") .. "}"
    local code, headers, body = self:post("https://substack.com/api/v1/email-otp-login/complete",
        payload, jarToHeader(state.jar))
    if type(code) ~= "number" then return nil, Net.friendly(code) end
    if code < 200 or code >= 400 then
        logger.warn("Substack: email-otp-login failed", code, body)
        return nil, errorMessage(body, code)
    end
    -- Substack now names its session cookie connect.sid (older accounts:
    -- substack.sid). Version 2.4 only looked for substack.sid, so it either
    -- found nothing or kept the signed-OUT cookie from step 1, which Substack
    -- then rejected. Collect whichever comes back and test it before saving.
    local fresh = Net.parseSetCookie(headers and (headers["set-cookie"] or headers["Set-Cookie"]))
    local merged = {}
    for k, v in pairs(state.jar or {}) do merged[k] = v end
    for k, v in pairs(fresh) do merged[k] = v end
    local candidates = {}
    local from_reply, from_merged = sessionFromJar(fresh), sessionFromJar(merged)
    if from_reply then candidates[#candidates + 1] = from_reply end
    if from_merged and from_merged ~= from_reply then candidates[#candidates + 1] = from_merged end
    if #candidates == 0 then
        logger.warn("Substack: email-otp-login: no session cookie in reply", code)
        return nil, _("Substack accepted the code but didn't send a session. Try again, or use Load session cookie from file.")
    end
    local unsure
    for _i, cookie in ipairs(candidates) do
        local ok = self:checkSession(cookie)
        if ok then return cookie end
        if ok == nil then unsure = unsure or cookie end
    end
    -- Couldn't check (network blip): keep the newest cookie; Check sign-in can confirm later.
    if unsure then return unsure end
    return nil, _("Substack accepted the code, but the session it sent back doesn't work. Request a new code and try again, or use Load session cookie from file.")
end

---------------------------------------------------------------------------
-- API
---------------------------------------------------------------------------

--- Posts from the publication's RSS feed (fallback when the JSON archive is
-- empty). Items carry no body; downloadPost fetches the full post by slug.
function Net:feed(host, limit)
    local body, err = self:get(string.format("https://%s/feed", host), nil, false)
    if not body then return nil, err end
    local posts = SH.parseFeed(body)
    if limit and #posts > limit then
        for i = #posts, limit + 1, -1 do posts[i] = nil end
    end
    return posts
end

--- Every post in the publication's sitemap, newest first, as post stubs with
-- titles made from the URL (the real title arrives when the post is opened).
-- Used to page past what the archive API will return.
function Net:sitemapPosts(host, max_posts)
    max_posts = max_posts or 300
    local root, err = self:get(string.format("https://%s/sitemap.xml", host), nil, false)
    if not root then return nil, err end
    local posts, seen = {}, {}
    local function collect(xml)
        for _i, p in ipairs(SH.parseSitemap(xml)) do
            if not seen[p.slug] then
                seen[p.slug] = true
                posts[#posts + 1] = p
            end
        end
    end
    collect(root)
    -- A sitemap index points at child sitemaps; read a few of them.
    local children = SH.sitemapChildren(root)
    for i = 1, math.min(#children, 6) do
        if #posts >= max_posts then break end
        local child = self:get(children[i], nil, false)
        if child then collect(child) end
    end
    table.sort(posts, function(a, b) return (a.post_date or "") > (b.post_date or "") end)
    while #posts > max_posts do table.remove(posts) end
    return posts
end

--- Returns posts (array), or nil, err.
-- The second return value is true when the list came from the RSS feed,
-- which can't be paged.
function Net:archive(host, offset, limit)
    offset = offset or 0
    limit = limit or 20
    -- Substack rejects offset=0 ("Invalid value") and an empty search=,
    -- so only send offset when paging past the first page.
    local url = string.format("https://%s/api/v1/archive?sort=new&limit=%d", host, limit)
    if offset > 0 then url = url .. "&offset=" .. offset end
    local data, err = self:getJson(url)
    local posts = data and SH.extractPosts(data)
    if posts and #posts > 0 then return posts, false end
    -- Paging: the feed only has the newest posts, so falling back would just
    -- repeat the first page.
    if offset > 0 then
        if posts then return posts, false end
        -- Substack now rejects the offset parameter outright. Ask for one big
        -- page instead (Substack caps this at 50); the caller drops duplicates
        -- and can then fall back to sitemapPosts() for anything older.
        if tostring(err):find("offset") then
            local big = self:getJson(string.format("https://%s/api/v1/archive?sort=new&limit=50", host))
            local big_posts = big and SH.extractPosts(big)
            if big_posts then return big_posts, "no_offset" end
            return {}, "no_offset"
        end
        return nil, err or "Unexpected response"
    end

    -- First page empty or unreadable: fall back to the RSS feed.
    logger.warn("Substack: archive empty or failed, trying RSS feed", host, err)
    local feed_posts, ferr = self:feed(host, limit)
    if feed_posts and #feed_posts > 0 then return feed_posts, true end
    if posts then return posts, false end -- both empty: really no posts
    return nil, err or ferr
end

function Net:post_(host, slug)
    return self:getJson(string.format("https://%s/api/v1/posts/%s", host, slug))
end
Net.fetchPost = Net.post_

function Net:comments(host, post_id)
    -- Substack rejects empty parameters (like "token="), so try the plain
    -- forms; move on only while it complains about the query itself (400).
    local base = string.format("https://%s/api/v1/post/%s/comments", host, tostring(post_id))
    local last_err
    for _i, q in ipairs({ "?all_comments=true&sort=best_first", "?sort=best_first", "" }) do
        local data, err = self:getJson(base .. q)
        if data then
            if type(data.comments) == "table" then return data.comments end
            if data[1] then return data end
            return {}
        end
        last_err = err
        if not tostring(err):find("HTTP 400") then break end
    end
    logger.warn("Substack: comments failed", host, post_id, last_err)
    return nil, last_err
end

--- GET /api/v1/subscriptions. Substack now validates a tvOnly parameter,
-- so send it (false = all subscriptions); try other spellings if rejected.
function Net:subscriptionsData()
    local last_err
    for _i, q in ipairs({ "?tvOnly=false", "?tvOnly=0", "" }) do
        local data, err = self:getJson("https://substack.com/api/v1/subscriptions" .. q)
        if data then return data end
        last_err = err
        -- Only keep trying while Substack complains about the parameter itself.
        if not tostring(err):find("tvOnly") then break end
    end
    return nil, last_err
end

--- Checks that the saved session works. Returns true, or nil, err.
function Net:verifySession()
    local data, err = self:getJson("https://substack.com/api/v1/user/profile/self")
    if data and (data.id or data.handle) then
        self.self_id = tonumber(data.id)
        return true
    end
    if tostring(err or ""):find("^HTTP 40[13]") then return nil, err end
    data, err = self:subscriptionsData()
    if data then return true end
    return nil, err
end

--- Publications recommended by publication_id. Returns list of {host=, name=, description=}.
function Net:recommendations(host, publication_id)
    local data, err = self:getJson(string.format("https://%s/api/v1/recommendations/from/%s", host, tostring(publication_id)))
    if not data then return nil, err end
    local out = {}
    for _, rec in ipairs(data) do
        local p = type(rec) == "table" and (rec.recommendedPublication or rec.publication or rec) or nil
        local h = SH.hostForPublication(p)
        if h then
            out[#out + 1] = { host = h, name = str(p.name) or SH.displayName(h), description = str(p.hero_text) or str(p.description) }
        end
    end
    return out
end

--- Search publications (Substack only answers signed-in users).
function Net:searchPublications(query, page)
    local q = query:gsub("[^%w%-%._~ ]", function(c) return string.format("%%%02X", c:byte()) end):gsub(" ", "+")
    local data, err = self:getJson(string.format(
        "https://substack.com/api/v1/publication/search?query=%s&page=%d&limit=25&skipExplanation=true", q, page or 0))
    if not data then return nil, err end
    local items = type(data.results) == "table" and data.results or (type(data.publications) == "table" and data.publications or {})
    local out = {}
    for _, p in ipairs(items) do
        local h = SH.hostForPublication(p)
        if h then
            out[#out + 1] = {
                host = h, name = str(p.name) or SH.displayName(h),
                description = str(p.hero_text) or str(p.description) or str(p.author_name),
            }
        end
    end
    return out
end

--- Publications the signed-in account subscribes to. Returns list of {host=, name=}.
function Net:subscriptions()
    local found, seen = {}, {}
    local function addPub(p)
        local h = SH.hostForPublication(p)
        if h and not seen[h] then
            seen[h] = true
            found[#found + 1] = { host = h, name = str(p.name) or SH.displayName(h), id = p.id,
                                  author = str(p.author_name), handle = str(p.author_handle) }
        end
    end
    local data = self:subscriptionsData()
    if data then
        if type(data.publications) == "table" then
            for _, p in ipairs(data.publications) do addPub(p) end
        end
        if type(data.subscriptions) == "table" then
            for _, s in ipairs(data.subscriptions) do
                if type(s) == "table" and type(s.publication) == "table" then addPub(s.publication) end
            end
        end
    end
    if #found == 0 then
        -- Fallback: publications appearing in the reader feed.
        local feed, err = self:getJsonWithLimit("https://substack.com/api/v1/reader/posts", 50)
        if not feed then return nil, err end
        for _, post in ipairs(type(feed.posts) == "table" and feed.posts or {}) do
            if type(post) == "table" then
                if type(post.publication) == "table" then
                    addPub(post.publication)
                else
                    local h = SH.parsePostUrl(str(post.canonical_url) or "")
                    if h and not seen[h] then
                        seen[h] = true
                        found[#found + 1] = { host = h, name = SH.displayName(h) }
                    end
                end
            end
        end
    end
    return found
end

---------------------------------------------------------------------------
-- People you follow
-- On Substack, *subscribing to a publication* and *following a person* are
-- two different things. /subscriptions only lists publications; the people
-- you follow come from /feed/following (a list of user ids).
---------------------------------------------------------------------------

--- Your own Substack user id (cached), or nil.
function Net:selfId()
    if self.self_id then return self.self_id end
    local data = self:getJson("https://substack.com/api/v1/user/profile/self")
    if type(data) == "table" and data.id then self.self_id = tonumber(data.id) end
    return self.self_id
end

--- User ids of the people the signed-in account follows (yourself left out).
function Net:followingIds()
    local data, err = self:getJson("https://substack.com/api/v1/feed/following")
    if not data then return nil, err end
    local list = data
    if type(data[1]) == "nil" then
        list = data.ids or data.following or data.users or data.userIds or {}
    end
    local me = self:selfId()
    local out, seen = {}, {}
    for i, v in ipairs(list) do
        local id = tonumber(type(v) == "table" and (v.id or v.user_id) or v)
        -- Substack lists your own id first; skip it even if we couldn't look it up.
        local is_me = (me and id == me) or (not me and i == 1)
        if id and not is_me and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    return out
end

--- A person's recent activity: { person = {id, name, handle}|nil, posts = {...} }.
function Net:profileFeed(user_id)
    local data, err = self:getJson(string.format("https://substack.com/api/v1/reader/feed/profile/%d", tonumber(user_id) or 0))
    if not data then return nil, err end
    return SH.parseProfileFeed(data, user_id)
end

--- Public profile by handle: { id, name, handle, publications = {...} }.
function Net:publicProfile(handle)
    local h = tostring(handle or ""):gsub("^@", ""):gsub("[^%w%-_%.]", "")
    if h == "" then return nil, "no handle" end
    local data, err = self:getJson("https://substack.com/api/v1/user/" .. h .. "/public_profile")
    if not data then return nil, err end
    return SH.parsePublicProfile(data)
end

--- Everything needed to follow one person. Returns
-- { id, name, handle, publications = { {host, name, id} }, posts = {...} } or nil, err.
function Net:person(user_id)
    local feed, err = self:profileFeed(user_id)
    if not feed then return nil, err end
    local p = feed.person or {}
    local out = { id = tonumber(user_id), name = p.name, handle = p.handle, publications = {}, posts = feed.posts }
    if out.handle then
        local prof = self:publicProfile(out.handle)
        if prof then
            out.name = out.name or prof.name
            out.publications = prof.publications
        end
    end
    if not out.name and not out.handle then return nil, "Unexpected response" end
    return out
end

--- Real publication name from its RSS feed (for publications added by
-- address, which otherwise only show their subdomain).
function Net:publicationName(host)
    local body = self:get(string.format("https://%s/feed", host), nil, false)
    return body and SH.feedTitle(body) or nil
end

--- GET a list endpoint whose "limit" Substack validates against an
-- unpublished maximum: start with the wanted size and step down while
-- Substack says the limit is invalid.
function Net:getJsonWithLimit(url_without_limit, wanted)
    local sep = url_without_limit:find("?", 1, true) and "&" or "?"
    local tried, last_err = {}, nil
    for _i, n in ipairs({ wanted or 20, 20, 12, 10, 5 }) do
        if not tried[n] and n <= (wanted or 20) then
            tried[n] = true
            local data, err = self:getJson(url_without_limit .. sep .. "limit=" .. n)
            if data then return data end
            last_err = err
            if not tostring(err):find('"limit"') then break end
        end
    end
    return nil, last_err
end

--- Posts saved with the bookmark button in the Substack app (experimental endpoint).
-- Returns list of { host=, slug=, post= }.
function Net:savedPosts(limit)
    local data, err = self:getJsonWithLimit("https://substack.com/api/v1/reader/posts?inboxType=saved", limit or 20)
    if not data then return nil, err end
    local out = {}
    for _, post in ipairs(type(data.posts) == "table" and data.posts or {}) do
        if type(post) == "table" then
            local host, slug = SH.parsePostUrl(str(post.canonical_url) or "")
            if not host and type(post.publication) == "table" then host = SH.hostForPublication(post.publication) end
            slug = slug or str(post.slug)
            local item = type(post.inboxItem) == "table" and post.inboxItem or nil
            -- Only keep items Substack says are saved (if it tells us).
            local saved = not item or item.is_saved ~= false
            if host and slug and saved then
                out[#out + 1] = { host = host, slug = slug, post = post }
            end
        end
    end
    return out
end

function Net.jsonString(s)
    return '"' .. tostring(s):gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == "\\" then return "\\\\" end
        return string.format("\\u%04x", c:byte())
    end) .. '"'
end

--- Signs in. Returns sid, or nil, message.
function Net:login(email, password)
    local payload = "{" .. table.concat({
        '"email":' .. Net.jsonString(email),
        '"password":' .. Net.jsonString(password),
        '"captcha_response":null',
        '"redirect":"/"',
        '"for_pub":""',
    }, ",") .. "}"
    local code, headers, body = self:post("https://substack.com/api/v1/login", payload)
    if type(code) ~= "number" then return nil, Net.friendly(code) end
    local sid = sessionFromJar(Net.parseSetCookie(headers and (headers["set-cookie"] or headers["Set-Cookie"])))
    if code >= 200 and code < 400 and sid then return sid end
    local msg
    local ok, data = pcall(json_decode, body or "")
    if ok and type(data) == "table" then
        msg = str(data.error)
        if not msg and type(data.errors) == "table" and type(data.errors[1]) == "table" then
            msg = str(data.errors[1].msg) or str(data.errors[1].message)
        end
    end
    logger.warn("Substack: login failed", code, body)
    return nil, msg or T("HTTP %1", code)
end

return Net
