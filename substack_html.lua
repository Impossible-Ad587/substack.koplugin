--[[
Pure helpers for the Substack plugin (no KOReader dependencies, so they can be
tested with a plain Lua interpreter).
]]

local M = {}

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
M.trim = trim

---------------------------------------------------------------------------
-- URLs and names
---------------------------------------------------------------------------

--- Turns whatever the user typed into a bare host name.
-- "astralcodexten"                    -> "astralcodexten.substack.com"
-- "https://foo.substack.com/archive"  -> "foo.substack.com"
-- "www.example.com"                   -> "www.example.com" (custom domain)
function M.normalizeHost(input)
    if type(input) ~= "string" then return nil end
    local s = trim(input)
    s = s:gsub("^%a[%w+.-]*://", "")
    s = s:gsub("[/?#].*$", "")
    s = s:gsub("^@", "")
    s = s:lower()
    if s == "" then return nil end
    if not s:find("%.") then
        s = s .. ".substack.com"
    end
    if not s:match("^[%w%.%-]+$") then return nil end
    return s
end

--- Short display name for a host.
function M.displayName(host)
    local name = host:gsub("^www%.", ""):gsub("%.substack%.com$", "")
    return name
end

--- Host for a publication object from any Substack API (subdomain preferred,
-- since the substack.com sign-in cookie works there).
function M.hostForPublication(p)
    if type(p) ~= "table" then return nil end
    if type(p.subdomain) == "string" and p.subdomain ~= "" then
        return p.subdomain:lower() .. ".substack.com"
    end
    if type(p.custom_domain) == "string" and p.custom_domain ~= "" then
        return M.normalizeHost(p.custom_domain)
    end
    return nil
end

--- Extracts host and slug from a post URL. Returns nil if it isn't one.
-- Handles https://foo.substack.com/p/slug, custom domains, and
-- https://open.substack.com/pub/foo/p/slug share links.
function M.parsePostUrl(url)
    if type(url) ~= "string" then return nil end
    local s = trim(url)
    if not s:find("://") then s = "https://" .. s end
    local host, path = s:match("^%a[%w+.-]*://([^/?#]+)([^?#]*)")
    if not host then return nil end
    host = host:lower()
    local pub, slug = path:match("^/pub/([^/]+)/p/([^/]+)")
    if pub then
        return pub:lower() .. ".substack.com", slug
    end
    slug = path:match("^/p/([^/]+)")
    if slug then return host, slug end
    return nil
end

--- Safe file name (UTF-8 aware truncation).
function M.safeFilename(name, max_bytes)
    max_bytes = max_bytes or 90
    local s = tostring(name or "")
    s = s:gsub("[%c]", " "):gsub('[/\\:%*%?"<>|]', "-")
    s = trim(s:gsub("%s+", " "))
    s = s:gsub("^%.+", "")
    if s == "" then s = "untitled" end
    if #s > max_bytes then
        local out, len = {}, 0
        for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            if len + #ch > max_bytes then break end
            out[#out + 1] = ch
            len = len + #ch
        end
        s = trim(table.concat(out))
    end
    s = s:gsub("[%. ]+$", "")
    return s
end

---------------------------------------------------------------------------
-- Writers (people) and their handles
---------------------------------------------------------------------------

local function nonEmpty(v)
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

--- "The Cute Club", "amymatt" -> "The Cute Club (@amymatt)".
function M.whoLabel(name, handle)
    name, handle = nonEmpty(name), nonEmpty(handle)
    if handle then handle = handle:gsub("^@", "") end
    if name and handle then return name .. " (@" .. handle .. ")" end
    if handle then return "@" .. handle end
    return name or "?"
end

--- Handle of a post's (first) author, from its bylines.
function M.postHandle(post)
    local bylines = type(post) == "table" and post.publishedBylines
    if type(bylines) ~= "table" then return nil end
    for _, b in ipairs(bylines) do
        if type(b) == "table" and nonEmpty(b.handle) then return b.handle end
    end
    return nil
end

--- The handle that appears most often among these posts' authors (the
-- publication's main writer; guest posts are outvoted).
function M.mainHandle(posts)
    local count, best, best_n = {}, nil, 0
    for _, p in ipairs(posts or {}) do
        local h = M.postHandle(p)
        if h then
            count[h] = (count[h] or 0) + 1
            if count[h] > best_n then best, best_n = h, count[h] end
        end
    end
    return best
end

local function findUser(list, uid)
    if type(list) ~= "table" then return nil end
    for _, u in ipairs(list) do
        if type(u) == "table" and tonumber(u.id or u.user_id) == uid then return u end
    end
    return nil
end

--- Reads /api/v1/reader/feed/profile/{user_id}. Returns
-- { person = { id, name, handle } | nil, posts = { { host, pub_name, pub_id, post } } }
-- Only posts this person wrote are kept (not their restacks or likes), and
-- Notes are skipped: they aren't articles.
function M.parseProfileFeed(data, uid)
    uid = tonumber(uid)
    local items = {}
    if type(data) == "table" then
        items = type(data.items) == "table" and data.items or (type(data[1]) == "table" and data or {})
    end
    local person, posts, seen = nil, {}, {}
    local function takePerson(u)
        if not person and type(u) == "table" and (nonEmpty(u.name) or nonEmpty(u.handle)) then
            person = { id = uid, name = nonEmpty(u.name), handle = nonEmpty(u.handle) }
        end
    end
    for _, it in ipairs(items) do
        if type(it) == "table" then
            local ctx = type(it.context) == "table" and it.context or {}
            takePerson(findUser(it.users, uid) or findUser(ctx.users, uid))
            local post = type(it.post) == "table" and it.post or nil
            if post and nonEmpty(post.slug) then
                local mine
                if type(post.publishedBylines) == "table" and post.publishedBylines[1] then
                    local b = findUser(post.publishedBylines, uid)
                    if b then mine = true takePerson(b) end
                else
                    local kind = tostring(ctx.type or it.type or ""):lower()
                    mine = not (kind:find("restack") or kind:find("like") or kind:find("comment"))
                end
                local pub = type(it.publication) == "table" and it.publication
                    or (type(post.publication) == "table" and post.publication) or nil
                local host = M.hostForPublication(pub) or M.parsePostUrl(post.canonical_url)
                local key = tostring(host) .. "|" .. post.slug
                if mine and host and not seen[key] then
                    seen[key] = true
                    posts[#posts + 1] = {
                        host = host, post = post,
                        pub_name = pub and nonEmpty(pub.name) or nil,
                        pub_id = pub and pub.id or post.publication_id,
                    }
                end
            end
        end
    end
    table.sort(posts, function(a, b) return (a.post.post_date or "") > (b.post.post_date or "") end)
    return { person = person, posts = posts }
end

--- Reads /api/v1/user/{handle}/public_profile. Returns
-- { id, name, handle, publications = { { host, name, id } } } with the
-- person's own publications (primary first; ones they only contribute to are left out).
function M.parsePublicProfile(data)
    if type(data) ~= "table" then return nil end
    local out = { id = tonumber(data.id), name = nonEmpty(data.name), handle = nonEmpty(data.handle), publications = {} }
    local seen = {}
    local function add(p)
        local h = M.hostForPublication(p)
        if h and not seen[h] then
            seen[h] = true
            out.publications[#out.publications + 1] = { host = h, name = nonEmpty(p.name) or M.displayName(h), id = p.id }
        end
    end
    if type(data.primaryPublication) == "table" then add(data.primaryPublication) end
    for _, pu in ipairs(type(data.publicationUsers) == "table" and data.publicationUsers or {}) do
        if type(pu) == "table" and type(pu.publication) == "table" then
            local role = tostring(pu.role or ""):lower()
            if role == "" or role == "admin" or role == "owner" or pu.is_primary then add(pu.publication) end
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Post lists (JSON archive and RSS feed)
---------------------------------------------------------------------------

--- Pulls the post array out of an archive response, whatever its shape.
function M.extractPosts(data)
    if type(data) ~= "table" then return nil end
    if type(data[1]) == "table" then return data end
    for _, key in ipairs({ "posts", "items", "results", "data" }) do
        local v = data[key]
        if type(v) == "table" and (type(v[1]) == "table" or next(v) == nil) then
            return v
        end
    end
    if next(data) == nil then return {} end -- empty JSON array
    return nil
end

local MONTHS = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
                 Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }

local function xmlText(s)
    if not s then return nil end
    s = s:gsub("^%s*<!%[CDATA%[(.-)%]%]>%s*$", "%1")
    s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
         :gsub("&#39;", "'"):gsub("&apos;", "'"):gsub("&amp;", "&")
    s = trim(s)
    return s ~= "" and s or nil
end

--- "Mon, 10 Nov 2026 14:03:22 GMT" -> "2026-11-10T14:03:22Z" (nil if unparseable).
function M.rssDate(s)
    if type(s) ~= "string" then return nil end
    local d, mon, y = s:match("(%d+)%s+(%a%a%a)%s+(%d%d%d%d)")
    if not (d and MONTHS[mon]) then return nil end
    local hh, mm, ss = s:match("(%d%d):(%d%d):(%d%d)")
    return string.format("%s-%02d-%02dT%s:%s:%sZ", y, MONTHS[mon], tonumber(d),
        hh or "00", mm or "00", ss or "00")
end

--- Parses a Substack RSS feed into archive-like post stubs
-- ({ title, subtitle, slug, post_date, canonical_url, audience }).
function M.parseFeed(xml)
    local posts = {}
    if type(xml) ~= "string" then return posts end
    for item in xml:gmatch("<item>(.-)</item>") do
        local link = xmlText(item:match("<link>(.-)</link>"))
        local slug = link and link:match("/p/([^/?#]+)")
        if slug then
            posts[#posts + 1] = {
                title = xmlText(item:match("<title>(.-)</title>")),
                subtitle = xmlText(item:match("<description>(.-)</description>")),
                slug = slug,
                post_date = M.rssDate(item:match("<pubDate>(.-)</pubDate>")),
                canonical_url = link,
                audience = "everyone",
            }
        end
    end
    return posts
end

--- The publication's real name from its RSS feed (<channel><title>), or nil.
function M.feedTitle(xml)
    if type(xml) ~= "string" then return nil end
    local head = xml:match("<channel>(.-)<item>") or xml:match("<channel>(.*)") or ""
    return xmlText(head:match("<title>(.-)</title>"))
end

--- "how-authors-are-using-substack" -> "How authors are using substack"
function M.titleFromSlug(slug)
    local s = tostring(slug or ""):gsub("%-%d+$", ""):gsub("[%-_]+", " ")
    s = trim(s)
    if s == "" then return nil end
    return s:sub(1, 1):upper() .. s:sub(2)
end

--- Post entries (<url> with a /p/ link) in a sitemap.
function M.parseSitemap(xml)
    local posts = {}
    if type(xml) ~= "string" then return posts end
    for block in xml:gmatch("<url>(.-)</url>") do
        local loc = xmlText(block:match("<loc>(.-)</loc>"))
        local slug = loc and loc:match("/p/([^/?#]+)")
        if slug then
            local lastmod = xmlText(block:match("<lastmod>(.-)</lastmod>"))
            posts[#posts + 1] = {
                title = M.titleFromSlug(slug),
                slug = slug,
                post_date = lastmod,
                canonical_url = loc,
                from_sitemap = true,
            }
        end
    end
    return posts
end

--- Child sitemap URLs in a sitemap index, newest-looking first.
function M.sitemapChildren(xml)
    local list = {}
    if type(xml) ~= "string" then return list end
    for block in xml:gmatch("<sitemap>(.-)</sitemap>") do
        local loc = xmlText(block:match("<loc>(.-)</loc>"))
        if loc then list[#list + 1] = loc end
    end
    -- Year-based names (…/2026, …/2025) sort newest first this way.
    table.sort(list, function(a, b) return a > b end)
    return list
end

function M.escape(s)
    s = tostring(s or "")
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function unescapeAttr(s)
    return (s:gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"))
end
M.unescapeAttr = unescapeAttr

--- Approximate word count of an HTML fragment.
function M.countWords(html)
    local text = (html or ""):gsub("<[^>]*>", " "):gsub("&[#%w]+;", " ")
    local n = 0
    for _ in text:gmatch("%S+") do n = n + 1 end
    return n
end

--- "9 min" style reading time.
function M.readingTime(words, wpm)
    words = tonumber(words)
    if not words or words <= 0 then return nil end
    local mins = math.max(1, math.floor(words / (wpm or 230) + 0.5))
    return mins .. " min"
end

---------------------------------------------------------------------------
-- Body cleanup
---------------------------------------------------------------------------

--- Removes Substack UI chrome (subscribe buttons, icons, forms…) from body HTML.
function M.cleanBody(html)
    if type(html) ~= "string" then return "" end
    local s = html
    s = s:gsub("<!%-%-.-%-%->", "")
    s = s:gsub("<script.-</script>", "")
    s = s:gsub("<style.-</style>", "")
    s = s:gsub("<svg.-</svg>", "")
    s = s:gsub("<audio.-</audio>", "")
    s = s:gsub("<video.-</video>", "")
    s = s:gsub("<source[^>]*>", "")
    s = s:gsub("<button.-</button>", "")
    s = s:gsub("<form.-</form>", "")
    s = s:gsub("<input[^>]*>", "")
    s = s:gsub('<p class="button%-wrapper".-</p>', "")
    s = s:gsub('<div class="subscription%-widget.-</div>%s*</div>', "")
    -- Image links open a zoomed copy on the web; unwrap them.
    s = s:gsub('<a[^>]-class="image%-link[^"]*"[^>]*>', "")
    -- Embedded media (YouTube, Spotify, tweets…) can't play here: link to them.
    s = s:gsub("<iframe[^>]-src=\"([^\"]+)\"[^>]*>.-</iframe>", function(src)
        return '<p class="embed"><a href="' .. src .. '">[Embedded media]</a></p>'
    end)
    s = s:gsub("<iframe.-</iframe>", "")
    return s
end

local VOID = { "br", "hr", "img", "meta", "link", "wbr", "col", "area", "base", "embed", "param", "track", "source", "input" }

local ENTITIES = {
    nbsp = 160, iexcl = 161, cent = 162, pound = 163, curren = 164, yen = 165, brvbar = 166, sect = 167,
    uml = 168, copy = 169, ordf = 170, laquo = 171, ["not"] = 172, shy = 173, reg = 174, macr = 175,
    deg = 176, plusmn = 177, sup2 = 178, sup3 = 179, acute = 180, micro = 181, para = 182, middot = 183,
    cedil = 184, sup1 = 185, ordm = 186, raquo = 187, frac14 = 188, frac12 = 189, frac34 = 190, iquest = 191,
    times = 215, divide = 247, eacute = 233, egrave = 232, agrave = 224, aacute = 225, ouml = 246, uuml = 252,
    auml = 228, ccedil = 231, ntilde = 241, szlig = 223,
    ndash = 8211, mdash = 8212, lsquo = 8216, rsquo = 8217, sbquo = 8218, ldquo = 8220, rdquo = 8221,
    bdquo = 8222, dagger = 8224, Dagger = 8225, bull = 8226, hellip = 8230, permil = 8240, prime = 8242,
    Prime = 8243, lsaquo = 8249, rsaquo = 8250, euro = 8364, trade = 8482, larr = 8592, uarr = 8593,
    rarr = 8594, darr = 8595, harr = 8596, minus = 8722, le = 8804, ge = 8805, ne = 8800, asymp = 8776,
    infin = 8734, thinsp = 8201, ensp = 8194, emsp = 8195, zwj = 8205, zwnj = 8204,
}
local XML_ENTITIES = { amp = true, lt = true, gt = true, quot = true, apos = true }

--- Makes Substack's HTML5 fragment well-formed enough for EPUB XHTML, and
-- turns Substack footnotes into proper EPUB pop-up footnotes.
function M.toXhtml(html)
    local s = html or ""
    -- Entities: keep XML ones, convert named HTML ones to numeric, escape stray "&".
    s = s:gsub("&([^;%s<&]*;?)", function(rest)
        local name = rest:match("^(#?%w+);$")
        if name then
            if name:sub(1, 1) == "#" or XML_ENTITIES[name] then return nil end
            if ENTITIES[name] then return "&#" .. ENTITIES[name] .. ";" end
            return nil -- unknown named entity: leave it, KOReader's engine knows HTML entities
        end
        return "&amp;" .. rest
    end)
    -- Self-close void elements.
    for _, tag in ipairs(VOID) do
        s = s:gsub("<" .. tag .. "(%f[%s/>][^>]*)>", function(attrs)
            if attrs:sub(-1) == "/" then return nil end
            return "<" .. tag .. attrs .. "/>"
        end)
    end
    -- Bare boolean attributes (e.g. "<details open>") are invalid XML.
    s = s:gsub("(<%a[%w]*[^>]-)%s+(allowfullscreen)([%s/>])", "%1%3")
    s = s:gsub(' contenteditable="[^"]*"', ""):gsub(' target="_self"', "")
    -- Footnotes: references become noterefs, the footnote block becomes the target.
    s = s:gsub('<a class="footnote%-anchor"', '<a epub:type="noteref" class="footnote-anchor"')
    s = s:gsub('<div class="footnote"([^>]*)>%s*<a id="([^"]+)"', function(attrs, id)
        return '<div class="footnote" id="' .. id .. '" epub:type="footnote"' .. attrs .. '><a'
    end)
    return s
end

---------------------------------------------------------------------------
-- Images
---------------------------------------------------------------------------

--- Asks Substack's image CDN for a reasonably sized JPEG (e-ink friendly,
-- and avoids WebP on older KOReader builds).
function M.cdnUrl(url, width)
    width = width or 800
    if url:find("substackcdn%.com/image/fetch/") then
        url = url:gsub("/image/fetch/[^/]*/",
            "/image/fetch/w_" .. width .. ",c_limit,f_jpg,q_auto:good,fl_progressive:steep/", 1)
    end
    return url
end

local function imgSrc(tag)
    return tag:match('%ssrc="([^"]+)"') or tag:match("%ssrc='([^']+)'")
end

local function isTiny(tag)
    local w = tonumber(tag:match('%swidth="(%d+)"') or "")
    local h = tonumber(tag:match('%sheight="(%d+)"') or "")
    return (w and w < 100) or (h and h < 60)
end

--- Ordered list of unique image src URLs in the HTML (tiny decorative images skipped).
function M.collectImages(html)
    local list, seen = {}, {}
    for tag in html:gmatch("<img[^>]*>") do
        local src = imgSrc(tag)
        if src and not isTiny(tag) then
            src = unescapeAttr(src)
            if src:match("^https?://") and not seen[src] then
                seen[src] = true
                list[#list + 1] = src
            end
        end
    end
    return list
end

--- Rewrites every <img> to a minimal tag pointing at map[src].
-- Images missing from the map are dropped (their alt text is kept).
function M.rewriteImages(html, map)
    map = map or {}
    return (html:gsub("<img[^>]*>", function(tag)
        local src = imgSrc(tag)
        local alt = tag:match('%salt="([^"]*)"') or ""
        local loc = src and map[unescapeAttr(src)]
        if loc then
            return '<img src="' .. M.escape(loc) .. '" alt="' .. alt .. '"/>'
        end
        if alt ~= "" and not isTiny(tag) then
            return '<span class="img-alt">[' .. alt .. ']</span>'
        end
        return ""
    end))
end

---------------------------------------------------------------------------
-- Comments
---------------------------------------------------------------------------

local function commentScore(c)
    local n = tonumber(c.reaction_count)
    if n then return n end
    n = 0
    if type(c.reactions) == "table" then
        for _, v in pairs(c.reactions) do
            if type(v) == "number" then n = n + v end
        end
    end
    return n
end

--- Comment text/author, whatever Substack calls the fields this week.
local function commentBody(c)
    for _, k in ipairs({ "body", "body_text", "text", "content" }) do
        if type(c[k]) == "string" and c[k] ~= "" then return c[k] end
    end
    return nil
end

local function commentName(c)
    if type(c.name) == "string" and c.name ~= "" then return c.name end
    local u = type(c.user) == "table" and c.user or (type(c.author) == "table" and c.author) or nil
    if u and type(u.name) == "string" then return u.name end
    return "Anonymous"
end

local function paragraphs(text)
    local out = {}
    for para in (text .. "\n"):gmatch("(.-)\n") do
        para = trim(para)
        if para ~= "" then out[#out + 1] = "<p>" .. M.escape(para) .. "</p>" end
    end
    return table.concat(out)
end

--- XHTML fragment with the top `max` comments (and their first replies).
function M.renderComments(comments, max)
    if type(comments) ~= "table" then return nil end
    local list = {}
    for _, c in ipairs(comments) do
        if type(c) == "table" and commentBody(c) then list[#list + 1] = c end
    end
    if #list == 0 then return nil end
    table.sort(list, function(a, b) return commentScore(a) > commentScore(b) end)
    local parts = { '<h2 class="comments-title">Comments</h2>' }
    local function render(c, depth)
        local name = commentName(c)
        local date = (type(c.date) == "string" and c.date:sub(1, 10))
            or (type(c.created_at) == "string" and c.created_at:sub(1, 10)) or ""
        local likes = commentScore(c)
        parts[#parts + 1] = '<div class="comment' .. (depth > 0 and " reply" or "") .. '">'
            .. '<p class="comment-meta"><b>' .. M.escape(name) .. '</b> · ' .. date
            .. (likes > 0 and (" · ♥ " .. likes) or "") .. '</p>'
            .. paragraphs(commentBody(c)) .. '</div>'
        if depth == 0 and type(c.children) == "table" then
            local shown = 0
            for _, r in ipairs(c.children) do
                if type(r) == "table" and commentBody(r) and shown < 2 then
                    render(r, 1)
                    shown = shown + 1
                end
            end
        end
    end
    for i = 1, math.min(max or 10, #list) do render(list[i], 0) end
    return table.concat(parts)
end

return M
