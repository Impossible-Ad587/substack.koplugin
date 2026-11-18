--[[
EPUB 2 builder for single articles and multi-article digests.
Pure Lua (uses substack_zip), so it can be tested outside KOReader.
]]

local SH = require("substack_html")
local Zip = require("substack_zip")

local M = {}

local CSS = [[
body { line-height: 1.45; }
.header { margin-bottom: 0.8em; }
p.pub { font-size: 0.8em; text-transform: uppercase; letter-spacing: 0.08em; margin: 0 0 0.4em 0; text-indent: 0; }
h1.title { font-size: 1.6em; margin: 0 0 0.25em 0; text-align: left; line-height: 1.2; }
p.subtitle { font-size: 1.1em; font-style: italic; margin: 0 0 0.6em 0; text-indent: 0; }
p.meta { font-size: 0.85em; margin: 0; text-indent: 0; }
img { max-width: 100%; }
figure { margin: 1em 0; text-align: center; }
figcaption, .image-caption { font-size: 0.85em; font-style: italic; text-align: center; }
blockquote { margin: 1em 0 1em 1em; padding-left: 0.8em; border-left: 3px solid #888; }
pre { white-space: pre-wrap; font-size: 0.85em; }
.paywall { border: 1px solid #000; padding: 0.6em; margin-top: 1.5em; }
.footer { font-size: 0.8em; margin-top: 2em; }
.footnote { font-size: 0.9em; }
.img-alt { font-style: italic; }
h2.comments-title { margin-top: 1.5em; }
.comment { margin: 0 0 1em 0; }
.comment.reply { margin-left: 1.5em; }
.comment p { text-indent: 0; margin: 0.2em 0; }
p.comment-meta { font-size: 0.85em; }
.digest-title { text-align: center; margin-top: 30%; }
.digest-toc p { text-indent: 0; margin: 0.4em 0; }
]]

local MEDIA = {
    jpg = "image/jpeg", jpeg = "image/jpeg", png = "image/png", gif = "image/gif",
    webp = "image/webp", svg = "image/svg+xml",
}

local function mediaType(name)
    return MEDIA[(name:match("%.(%w+)$") or "jpg"):lower()] or "image/jpeg"
end

local function xhtml(title, body)
    return '<?xml version="1.0" encoding="utf-8"?>\n'
        .. '<!DOCTYPE html>\n'
        .. '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en">\n'
        .. '<head><meta charset="utf-8"/>'
        .. '<title>' .. SH.escape(title) .. '</title>'
        .. '<link rel="stylesheet" type="text/css" href="style.css"/></head>\n<body>\n'
        .. body .. '\n</body></html>\n'
end

--- Header + body + footer for one article (an XHTML fragment).
function M.articleFragment(a)
    local parts = { '<div class="header">' }
    if a.publication then parts[#parts + 1] = '<p class="pub">' .. SH.escape(a.publication) .. '</p>' end
    parts[#parts + 1] = '<h1 class="title">' .. SH.escape(a.title) .. '</h1>'
    if a.subtitle and a.subtitle ~= "" then
        parts[#parts + 1] = '<p class="subtitle">' .. SH.escape(a.subtitle) .. '</p>'
    end
    local meta = {}
    if a.author then meta[#meta + 1] = SH.escape(a.author) end
    if a.date then meta[#meta + 1] = SH.escape(a.date) end
    local rt = SH.readingTime(a.words)
    if rt then meta[#meta + 1] = rt end
    if #meta > 0 then parts[#parts + 1] = '<p class="meta">' .. table.concat(meta, " · ") .. '</p>' end
    parts[#parts + 1] = '</div><hr/>'
    parts[#parts + 1] = a.body or ""
    if a.paywalled then
        parts[#parts + 1] = '<div class="paywall"><p><b>This post is for paid subscribers.</b> '
            .. 'Only the free preview was available. If you subscribe, sign in under Substack → Account '
            .. 'and re-download this post.</p></div>'
    end
    if a.url then
        parts[#parts + 1] = '<p class="footer">Original: <a href="' .. SH.escape(a.url) .. '">'
            .. SH.escape(a.url) .. '</a></p>'
    end
    return table.concat(parts)
end

local function opf(meta, manifest, spine)
    local m = {
        '<?xml version="1.0" encoding="utf-8"?>\n',
        '<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0">\n',
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">\n',
        '<dc:title>', SH.escape(meta.title), '</dc:title>\n',
        '<dc:language>', meta.language or "en", '</dc:language>\n',
        '<dc:identifier id="bookid">', SH.escape(meta.identifier), '</dc:identifier>\n',
    }
    m[#m + 1] = '<meta property="dcterms:modified">' .. os.date("!%Y-%m-%dT%H:%M:%SZ") .. '</meta>\n'
    if meta.author then m[#m + 1] = '<dc:creator>' .. SH.escape(meta.author) .. '</dc:creator>\n' end
    if meta.publisher then m[#m + 1] = '<dc:publisher>' .. SH.escape(meta.publisher) .. '</dc:publisher>\n' end
    if meta.date then m[#m + 1] = '<dc:date>' .. SH.escape(meta.date) .. '</dc:date>\n' end
    if meta.description then m[#m + 1] = '<dc:description>' .. SH.escape(meta.description) .. '</dc:description>\n' end
    if meta.source then m[#m + 1] = '<dc:source>' .. SH.escape(meta.source) .. '</dc:source>\n' end
    m[#m + 1] = '<dc:subject>Substack</dc:subject>\n'
    if meta.series then m[#m + 1] = '<meta name="calibre:series" content="' .. SH.escape(meta.series) .. '"/>\n' end
    if meta.cover_id then m[#m + 1] = '<meta name="cover" content="' .. meta.cover_id .. '"/>\n' end
    m[#m + 1] = '</metadata>\n<manifest>\n'
    m[#m + 1] = '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>\n'
    m[#m + 1] = '<item id="css" href="style.css" media-type="text/css"/>\n'
    m[#m + 1] = '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\n'
    for _, it in ipairs(manifest) do
        m[#m + 1] = '<item id="' .. it.id .. '" href="' .. SH.escape(it.href) .. '" media-type="' .. it.type .. '"'
            .. (it.properties and (' properties="' .. it.properties .. '"') or "") .. '/>\n'
    end
    m[#m + 1] = '</manifest>\n<spine toc="ncx">\n'
    for _, id in ipairs(spine) do m[#m + 1] = '<itemref idref="' .. id .. '"/>\n' end
    m[#m + 1] = '</spine>\n'
    m[#m + 1] = '</package>\n'
    return table.concat(m)
end

local function ncx(meta, points)
    local m = {
        '<?xml version="1.0" encoding="utf-8"?>\n',
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n',
        '<head><meta name="dtb:uid" content="', SH.escape(meta.identifier), '"/>',
        '<meta name="dtb:depth" content="1"/><meta name="dtb:totalPageCount" content="0"/>',
        '<meta name="dtb:maxPageNumber" content="0"/></head>\n',
        '<docTitle><text>', SH.escape(meta.title), '</text></docTitle>\n<navMap>\n',
    }
    for i, p in ipairs(points) do
        m[#m + 1] = '<navPoint id="np' .. i .. '" playOrder="' .. i .. '"><navLabel><text>'
            .. SH.escape(p.label) .. '</text></navLabel><content src="' .. SH.escape(p.src) .. '"/></navPoint>\n'
    end
    m[#m + 1] = '</navMap>\n</ncx>\n'
    return table.concat(m)
end

local function nav(title, points)
    local li = {}
    for _, p in ipairs(points) do
        li[#li + 1] = '<li><a href="' .. SH.escape(p.src) .. '">' .. SH.escape(p.label) .. '</a></li>'
    end
    return xhtml(title, '<nav epub:type="toc" id="toc"><h1>Contents</h1><ol>' .. table.concat(li) .. '</ol></nav>')
end

local CONTAINER = '<?xml version="1.0" encoding="UTF-8"?>\n'
    .. '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    .. '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
    .. '</rootfiles></container>\n'

local function finish(zip, tmp, out_path)
    zip:close()
    os.remove(out_path)
    local ok, err = os.rename(tmp, out_path)
    if not ok then os.remove(tmp) return nil, err end
    return true
end

--- Builds a single-article EPUB.
-- a = { title, subtitle, author, publication, date, url, words, paywalled, id,
--       body = XHTML fragment (images referenced as "images/<name>"),
--       images = { {name=, path=}, ... }, cover = {name=, path=} | nil,
--       comments = XHTML fragment | nil }
function M.buildArticle(out_path, a)
    local tmp = out_path .. ".part"
    local zip, err = Zip.newWriter(tmp)
    if not zip then return nil, err end
    zip:add("mimetype", "application/epub+zip")
    zip:add("META-INF/container.xml", CONTAINER)
    zip:add("OEBPS/style.css", CSS)

    local manifest, spine, points = {}, {}, {}
    local meta = {
        title = a.title, author = a.author, publisher = a.publication, series = a.publication,
        date = a.date, description = a.subtitle, source = a.url,
        identifier = "urn:substack:" .. tostring(a.id or a.url or a.title),
    }
    if a.cover then
        local cname = "images/" .. a.cover.name
        if zip:addFile("OEBPS/" .. cname, a.cover.path) then
            table.insert(manifest, { id = "cover-image", href = cname, type = mediaType(cname), properties = "cover-image" })
            meta.cover_id = "cover-image"
        end
    end
    zip:add("OEBPS/article.xhtml", xhtml(a.title, M.articleFragment(a)))
    table.insert(manifest, { id = "article", href = "article.xhtml", type = "application/xhtml+xml" })
    table.insert(spine, "article")
    table.insert(points, { label = a.title, src = "article.xhtml" })
    if a.comments then
        zip:add("OEBPS/comments.xhtml", xhtml("Comments", a.comments))
        table.insert(manifest, { id = "comments", href = "comments.xhtml", type = "application/xhtml+xml" })
        table.insert(spine, "comments")
        table.insert(points, { label = "Comments", src = "comments.xhtml" })
    end
    for i, img in ipairs(a.images or {}) do
        local href = "images/" .. img.name
        if zip:addFile("OEBPS/" .. href, img.path) then
            table.insert(manifest, { id = "img" .. i, href = href, type = mediaType(href) })
        end
    end
    zip:add("OEBPS/content.opf", opf(meta, manifest, spine))
    zip:add("OEBPS/toc.ncx", ncx(meta, points))
    zip:add("OEBPS/nav.xhtml", nav(meta.title, points))
    return finish(zip, tmp, out_path)
end

--- Builds a digest EPUB from article EPUBs this plugin created.
-- items = { {path=, title=, publication=, author=, date=}, ... }
-- Returns number of included articles, or nil, err.
function M.buildDigest(out_path, title, items)
    local tmp = out_path .. ".part"
    local zip, err = Zip.newWriter(tmp)
    if not zip then return nil, err end
    zip:add("mimetype", "application/epub+zip")
    zip:add("META-INF/container.xml", CONTAINER)
    zip:add("OEBPS/style.css", CSS)

    local manifest, spine, points, toc_lines = {}, {}, {}, {}
    local chapters = {}
    local n_img = 0
    for _, it in ipairs(items) do
        local entries = Zip.read(it.path)
        if entries then
            local files = {}
            for _, e in ipairs(entries) do files[e.name] = e.data end
            local art = files["OEBPS/article.xhtml"]
            local body = art and art:match("<body[^>]*>(.*)</body>")
            if body then
                local ch = #chapters + 1
                local prefix = string.format("images/ch%02d/", ch)
                local fix = function(s) return (s:gsub('src="images/', 'src="' .. prefix)) end
                body = fix(body)
                local comments = files["OEBPS/comments.xhtml"]
                comments = comments and comments:match("<body[^>]*>(.*)</body>")
                if comments then body = body .. fix(comments) end
                for name, data in pairs(files) do
                    local img = name:match("^OEBPS/images/(.+)$")
                    if img and not img:match("^cover%.") then
                        n_img = n_img + 1
                        local href = prefix .. img
                        zip:add("OEBPS/" .. href, data)
                        table.insert(manifest, { id = "img" .. n_img, href = href, type = mediaType(href) })
                    end
                end
                local fname = string.format("ch%02d.xhtml", ch)
                zip:add("OEBPS/" .. fname, xhtml(it.title or "Article", body))
                chapters[ch] = { file = fname, item = it }
            end
        end
    end
    if #chapters == 0 then
        zip:close()
        os.remove(tmp)
        return nil, "no articles could be read"
    end

    for i, c in ipairs(chapters) do
        local label = (c.item.title or "Article")
        local sub = c.item.publication and (" — " .. c.item.publication) or ""
        toc_lines[#toc_lines + 1] = '<p><a href="' .. c.file .. '">' .. SH.escape(label) .. '</a>'
            .. '<span class="meta">' .. SH.escape(sub) .. '</span></p>'
        table.insert(manifest, { id = "ch" .. i, href = c.file, type = "application/xhtml+xml" })
        table.insert(points, { label = label .. sub, src = c.file })
    end
    zip:add("OEBPS/title.xhtml", xhtml(title, '<h1 class="digest-title">' .. SH.escape(title) .. '</h1>'
        .. '<div class="digest-toc">' .. table.concat(toc_lines) .. '</div>'))
    table.insert(manifest, 1, { id = "titlepage", href = "title.xhtml", type = "application/xhtml+xml" })
    table.insert(spine, "titlepage")
    table.insert(points, 1, { label = "Contents", src = "title.xhtml" })
    for i = 1, #chapters do table.insert(spine, "ch" .. i) end

    local meta = {
        title = title, author = "Substack", publisher = "Substack", series = "Substack Digest",
        date = os.date("%Y-%m-%d"), identifier = "urn:substack:digest:" .. os.time(),
    }
    zip:add("OEBPS/content.opf", opf(meta, manifest, spine))
    zip:add("OEBPS/toc.ncx", ncx(meta, points))
    zip:add("OEBPS/nav.xhtml", nav(meta.title, points))
    local ok, ferr = finish(zip, tmp, out_path)
    if not ok then return nil, ferr end
    return #chapters
end

return M
