--[[
Library of saved articles: what's saved, reading status, clean-up.

Reading status is taken from KOReader's own per-book data (percent read,
"finished" status, highlights), so the Inbox always agrees with KOReader.
Dependencies are injected so this can be tested outside KOReader.
]]

local Library = {}
Library.__index = Library

local FINISHED_AT = 0.985 -- treat >=98.5% read as finished

--- deps: { store = LuaSettings-like, lfs = lfs, docsettings = DocSettings|nil, now = function|nil }
function Library.new(deps)
    local self = setmetatable({}, Library)
    self.store = deps.store
    self.lfs = deps.lfs
    self.DocSettings = deps.docsettings
    self.now = deps.now or os.time
    self.articles = self.store:readSetting("articles") or {}
    -- Reading log for stats. Kept when articles are deleted, so the
    -- dashboard remembers what you read. Capped at MAX_EVENTS.
    self.events = self.store:readSetting("events")
    if not self.events then
        self.events = {}
        self:backfillEvents()
    end
    return self
end

--- First run with stats: seed the log from articles already finished/opened,
-- using the times we already stored.
function Library:backfillEvents()
    for _, a in pairs(self.articles) do
        local base = { title = a.title, pub = a.publication, host = a.host,
                       author = a.author, words = tonumber(a.words), slug = a.slug }
        if a.opened_at then
            local e = {} for k, v in pairs(base) do e[k] = v end
            e.t, e.ev = a.opened_at, "open"
            self.events[#self.events + 1] = e
        end
        if a.finished_at then
            local e = {} for k, v in pairs(base) do e[k] = v end
            e.t, e.ev = a.finished_at, a.opened_at and "finish" or "cleared"
            self.events[#self.events + 1] = e
            a.finish_logged = true
        end
    end
    table.sort(self.events, function(x, y) return x.t < y.t end)
    self.events_dirty = #self.events > 0 or nil
end

local MAX_EVENTS = 2500

--- Records "open" | "finish" | "cleared" for an article (with the details
-- stats need, copied so they survive deletion).
-- "finish" only counts as reading if the article was opened at least once;
-- articles marked finished without opening, or in bulk, log "cleared".
function Library:logEvent(path, ev)
    local a = self.articles[path]
    if not a then return end
    if ev == "open" then
        -- One open per sitting: opening goes through two code paths.
        if a.open_logged_at and self.now() - a.open_logged_at < 600 then return end
        a.open_logged_at = self.now()
    elseif ev == "finish" then
        if a.finish_logged then return end
        a.finish_logged = true
        if not a.opened_at then ev = "cleared" end
    end
    self.events[#self.events + 1] = {
        t = self.now(), ev = ev, title = a.title, pub = a.publication, host = a.host,
        author = a.author, words = tonumber(a.words), slug = a.slug,
    }
    while #self.events > MAX_EVENTS do table.remove(self.events, 1) end
    self.events_dirty = true
end

function Library:allEvents()
    return self.events
end

function Library:save()
    self.store:saveSetting("articles", self.articles)
    self.store:saveSetting("events", self.events)
    self.events_dirty = nil
    self.store:flush()
end

function Library:exists(path)
    return self.lfs.attributes(path, "mode") == "file"
end

--- Adds or updates an article. meta must include `path`.
function Library:add(meta)
    self:invalidate()
    local old = self.articles[meta.path] or {}
    for k, v in pairs(meta) do old[k] = v end
    old.saved_at = old.saved_at or self.now()
    self.articles[meta.path] = old
    self:save()
    return old
end

function Library:get(path)
    return self.articles[path]
end

function Library:isSavedPath(path)
    return self.articles[path] ~= nil and self:exists(path)
end

--- Reads KOReader's sidecar for a document. Returns percent (0..1), status string, has_highlights.
function Library:sidecar(path)
    local DS = self.DocSettings
    if not DS then return 0, nil, false end
    local ok, has = pcall(DS.hasSidecarFile, DS, path)
    if not ok or not has then return 0, nil, false end
    local ok2, ds = pcall(DS.open, DS, path)
    if not ok2 or not ds then return 0, nil, false end
    local percent = tonumber(ds:readSetting("percent_finished")) or 0
    local summary = ds:readSetting("summary")
    local status = type(summary) == "table" and summary.status or nil
    local function nonEmpty(t) return type(t) == "table" and next(t) ~= nil end
    local hl = nonEmpty(ds:readSetting("annotations")) or nonEmpty(ds:readSetting("highlight"))
    return percent, status, hl
end

-- Reading each article's progress means opening a file per article; with
-- hundreds of articles, menus that ask several times per screen get slow.
-- So remember results briefly, and forget them whenever anything changes.
local STATUS_TTL = 20 -- seconds

function Library:invalidate()
    self.status_cache = {}
end

function Library:cachedSidecar(path)
    self.status_cache = self.status_cache or {}
    local c = self.status_cache[path]
    local now = os.time()
    if c and now - c.t < STATUS_TTL then return c.percent, c.status, c.hl end
    local percent, status, hl = self:sidecar(path)
    self.status_cache[path] = { t = now, percent = percent, status = status, hl = hl }
    return percent, status, hl
end

--- Returns "unread" | "reading" | "finished", percent, has_highlights.
function Library:status(path)
    local a = self.articles[path] or {}
    local percent, status, hl = self:cachedSidecar(path)
    local result
    if a.override == "finished" then
        result = "finished"
    elseif a.override == "unread" then
        result = "unread" -- cleared again as soon as the article is opened (see touch)
    elseif status == "complete" or percent >= FINISHED_AT then
        result = "finished"
    elseif percent > 0 or status == "reading" then
        result = "reading"
    else
        result = "unread"
    end
    -- Remember when we first saw it finished (for auto clean-up).
    if result == "finished" and not a.finished_at and self.articles[path] then
        self.articles[path].finished_at = self.now()
        self:logEvent(path, "finish")
        self.dirty = true
    end
    return result, percent, hl
end

--- bulk = true (e.g. "Mark all as finished"): logged as cleared, not read.
function Library:setOverride(path, value, bulk)
    self:invalidate()
    local a = self.articles[path]
    if not a then return end
    a.override = value
    if value == "finished" then
        a.finished_at = a.finished_at or self.now()
        self:logEvent(path, bulk and "cleared" or "finish")
        if bulk then a.finish_logged = true end
    else
        a.finished_at = nil
        a.finish_logged = nil -- finishing it again later counts again
    end
    self:save()
end

function Library:setKept(path, kept)
    self:invalidate()
    local a = self.articles[path]
    if a then a.kept = kept or nil self:save() end
end

--- Called when the user opens an article: manual "unread" no longer applies.
function Library:touch(path)
    self:invalidate()
    local a = self.articles[path]
    if a then
        if a.override == "unread" then a.override = nil end
        a.opened_at = self.now()
        self:logEvent(path, "open")
        self:save()
    end
end

--- After the download folder moved: re-keys every article under old_root to new_root.
function Library:relocate(old_root, new_root)
    self:invalidate()
    local moved = {}
    local prefix = old_root .. "/"
    for path, a in pairs(self.articles) do
        if path:sub(1, #prefix) == prefix then
            local np = new_root .. "/" .. path:sub(#prefix + 1)
            a.path = np
            moved[np] = a
        else
            moved[path] = a
        end
    end
    self.articles = moved
    self:save()
end

--- Walks the download folder: adds files we don't know yet, drops entries whose file is gone.
function Library:scan(root)
    local lfs = self.lfs
    local seen = {}
    local function walk(dir, pub, depth)
        if depth > 2 or lfs.attributes(dir, "mode") ~= "directory" then return end
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." and not name:match("%.sdr$") and not name:match("_files$") then
                local full = dir .. "/" .. name
                local mode = lfs.attributes(full, "mode")
                if mode == "directory" then
                    -- Our own folders that aren't publications.
                    if name ~= "Digests" and name ~= "Reports" and name ~= "Exports" then
                        walk(full, name, depth + 1)
                    end
                elseif mode == "file" and (name:match("%.epub$") or name:match("%.html$")) then
                    seen[full] = true
                    if not self.articles[full] then
                        local base = name:gsub("%.%w+$", "")
                        local date, title = base:match("^(%d%d%d%d%-%d%d%-%d%d) %- (.*)$")
                        self.articles[full] = {
                            path = full, title = title or base, date = date,
                            publication = pub, saved_at = lfs.attributes(full, "modification") or self.now(),
                        }
                        self.dirty = true
                    end
                end
            end
        end
    end
    walk(root, nil, 0)
    for path in pairs(self.articles) do
        if not seen[path] and not self:exists(path) then
            self.articles[path] = nil
            self.dirty = true
        end
    end
    self:flushIfDirty()
end

function Library:flushIfDirty()
    if self.dirty or self.events_dirty then
        self.dirty = nil
        self:save()
    end
end

--- Preferences the lists follow (set by the plugin from its settings):
-- muted = { [host] = true } hidden from the Inbox, sort = "newest" | "oldest"
-- | "shortest" | "publication", short_words = max words for "short".
function Library:setPrefs(prefs)
    self.prefs = prefs or {}
end

local function sortKeyWords(e)
    -- Unknown length sorts last when sorting by length.
    return tonumber(e.meta.words) or math.huge
end

--- Entries with status info.
-- filter: "inbox" | "short" | "archive" | "kept" | "all"
-- ("short" = Inbox articles of known length up to prefs.short_words)
function Library:list(filter)
    local prefs = self.prefs or {}
    local muted = prefs.muted or {}
    local short_words = prefs.short_words or 1150
    local inboxy = filter == "inbox" or filter == "short"
    local out = {}
    for path, a in pairs(self.articles) do
        if self:exists(path) then
            local status, percent, hl = self:status(path)
            local include = filter == "all"
                or (inboxy and status ~= "finished" and not (a.host and muted[a.host]))
                or (filter == "archive" and status == "finished")
                or (filter == "kept" and (a.kept or hl))
            if include and filter == "short" then
                local w = tonumber(a.words)
                include = w ~= nil and w <= short_words
            end
            if include then
                out[#out + 1] = { path = path, meta = a, status = status, percent = percent, highlights = hl }
            end
        end
    end
    local order = inboxy and (prefs.sort or "newest") or "newest"
    table.sort(out, function(x, y)
        -- In the Inbox, articles you've started always come first.
        if inboxy and (x.status == "reading") ~= (y.status == "reading") then
            return x.status == "reading"
        end
        local dx, dy = x.meta.date or "", y.meta.date or ""
        if order == "oldest" then
            if dx ~= dy then return dx < dy end
        elseif order == "shortest" then
            local wx, wy = sortKeyWords(x), sortKeyWords(y)
            if wx ~= wy then return wx < wy end
        elseif order == "publication" then
            local px, py = (x.meta.publication or ""):lower(), (y.meta.publication or ""):lower()
            if px ~= py then return px < py end
        end
        if dx ~= dy then return dx > dy end
        return (x.meta.title or "") < (y.meta.title or "")
    end)
    self:flushIfDirty()
    return out
end

function Library:unreadCount()
    local n = 0
    for _, e in ipairs(self:list("inbox")) do
        if e.status == "unread" then n = n + 1 end
    end
    return n
end

--- Next article to read after `current_path` (in-progress first, then newest unread).
function Library:nextUnread(current_path)
    for _, e in ipairs(self:list("inbox")) do
        if e.path ~= current_path then return e end
    end
    return nil
end

local function rmTree(lfs, dir)
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local full = dir .. "/" .. name
            if lfs.attributes(full, "mode") == "directory" then rmTree(lfs, full) else os.remove(full) end
        end
    end
    lfs.rmdir(dir)
end

function Library:delete(path)
    self:invalidate()
    os.remove(path)
    local base = path:gsub("%.%w+$", "")
    rmTree(self.lfs, base .. "_files")        -- images of legacy HTML articles
    rmTree(self.lfs, base .. ".sdr")          -- KOReader's per-book data
    self.articles[path] = nil
    self:save()
end

--- After saving `path`: remove older copies of the same post (same
-- publication + slug, different file, e.g. because the title changed on
-- Substack), carrying over what the person did with them. Returns how many.
function Library:removeOlderCopies(path)
    local a = self.articles[path]
    if not a or not a.host or not a.slug then return 0 end
    local n = 0
    for other, b in pairs(self.articles) do
        if other ~= path and b.host == a.host and b.slug == a.slug then
            a.kept = a.kept or b.kept
            a.override = a.override or b.override
            a.opened_at = a.opened_at or b.opened_at
            a.finished_at = a.finished_at or b.finished_at
            a.finish_logged = a.finish_logged or b.finish_logged
            a.saved_at = math.min(a.saved_at or self.now(), b.saved_at or self.now())
            self:delete(other)
            n = n + 1
        end
    end
    if n > 0 then self:save() end
    return n
end

--- Deletes finished articles older than `days` (kept or highlighted ones are spared).
-- Returns number deleted.
function Library:cleanup(days)
    if not days or days <= 0 then return 0 end
    local cutoff = self.now() - days * 86400
    local n = 0
    for _, e in ipairs(self:list("archive")) do
        local a = e.meta
        if not a.kept and not e.highlights and (a.finished_at or self.now()) < cutoff then
            self:delete(e.path)
            n = n + 1
        end
    end
    return n
end

function Library:deleteAllFinished()
    local n = 0
    for _, e in ipairs(self:list("archive")) do
        if not e.meta.kept and not e.highlights then
            self:delete(e.path)
            n = n + 1
        end
    end
    return n
end

--- Total bytes used under root.
function Library:usage(root)
    local lfs = self.lfs
    local total, count = 0, 0
    local function walk(dir)
        if lfs.attributes(dir, "mode") ~= "directory" then return end
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then
                local full = dir .. "/" .. name
                local mode = lfs.attributes(full, "mode")
                if mode == "directory" then walk(full)
                elseif mode == "file" then
                    total = total + (lfs.attributes(full, "size") or 0)
                    if name:match("%.epub$") or name:match("%.html$") then count = count + 1 end
                end
            end
        end
    end
    walk(root)
    return total, count
end

return Library
