--[[
Substack for KOReader
Follow Substack publications, sync new posts as EPUBs, read through an Inbox,
and keep what matters. See README.md.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local SH = require("substack_html")
local Epub = require("substack_epub")
local Library = require("substack_library")
local Net = require("substack_net")
local Export = require("substack_export")

local VERSION = "2.5"
local PAGE_SIZE = 20
-- Recent posts remembered per publication for offline browsing. Kept modest so
-- the cache stays small even when following dozens of publications.
local CACHE_PER_PUB = 40
-- Stop downloading when less than this much space (MB) is left on the device.
local MIN_FREE_MB = 150
-- "standard" (default) roughly matches a 6–7" e-reader screen; bigger images
-- only make articles slower to open on e-ink.
local IMAGE_WIDTH = { full = 1200, standard = 900, small = 600 }

local function str(v)
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

local function mkdirp(path)
    local acc = path:sub(1, 1) == "/" and "/" or ""
    for part in path:gmatch("[^/]+") do
        acc = acc .. part
        if lfs.attributes(acc, "mode") ~= "directory" then
            local ok, err = lfs.mkdir(acc)
            if not ok and lfs.attributes(acc, "mode") ~= "directory" then return nil, err end
        end
        acc = acc .. "/"
    end
    return true
end

local function isPaid(post)
    return post.audience == "only_paid" or post.audience == "founding"
end

local function postDate(post)
    local d = str(post.post_date)
    return d and d:sub(1, 10) or nil
end

local function postAuthor(post)
    local bylines = post.publishedBylines
    if type(bylines) == "table" then
        -- Substack can list the same person twice (e.g. as author and as
        -- publication owner): keep each name once.
        local names, seen = {}, {}
        for _i, b in ipairs(bylines) do
            if type(b) == "table" and str(b.name) then
                local name = b.name:gsub("\194\160", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
                local key = name:lower()
                if name ~= "" and not seen[key] then
                    seen[key] = true
                    names[#names + 1] = name
                end
            end
        end
        if #names > 0 then return table.concat(names, ", ") end
    end
    return nil
end

local function isoDaysAgo(days)
    return os.date("!%Y-%m-%dT%H:%M:%S", os.time() - days * 86400)
end

local function ago(ts)
    if not ts then return _("never") end
    local d = os.time() - ts
    if d < 90 then return _("just now") end
    if d < 3600 then return T(_("%1 min ago"), math.floor(d / 60)) end
    if d < 86400 then return T(_("%1 h ago"), math.floor(d / 3600)) end
    return T(_("%1 days ago"), math.floor(d / 86400))
end

local function humanSize(bytes)
    if bytes > 1048576 then return string.format("%.1f MB", bytes / 1048576) end
    return string.format("%d KB", math.floor(bytes / 1024))
end

local function showMsg(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

--- Minimal post record kept in the offline cache.
local function slimPost(p)
    return {
        id = p.id, title = str(p.title), subtitle = str(p.subtitle), slug = str(p.slug),
        post_date = str(p.post_date), audience = str(p.audience), type = str(p.type),
        wordcount = tonumber(p.wordcount), canonical_url = str(p.canonical_url),
        publication_id = p.publication_id, cover_image = str(p.cover_image),
        publishedBylines = postAuthor(p) and { { name = postAuthor(p), handle = SH.postHandle(p) } } or nil,
    }
end

--- "The Cute Club (@amymatt)": the publication's name plus its writer's handle,
-- so it's clear who an article is from.
local function pubLabel(pub)
    return SH.whoLabel(pub and pub.name, pub and pub.handle)
end

--- How far back a sync looks for new posts, in days (0 = no limit).
-- Older posts are never downloaded automatically, which saves space.
local SYNC_DAYS_DEFAULT = 7

-- Where to go back to when an article is closed. Module-level on purpose:
-- KOReader runs separate plugin instances for the reader and the file
-- browser, so this note has to outlive the instance that wrote it.
--   Return.to      = the list the open article came from (a small description)
--   Return.pending = set when such an article closes; the file browser's
--                    instance picks it up and reopens that list.
local Return = { to = nil, pending = nil, closed = false }

local Substack = WidgetContainer:extend{
    name = "substack",
    is_doc_only = false,
}

function Substack:init()
    local dir = DataStorage:getSettingsDir()
    self.settings = LuaSettings:open(dir .. "/substack.lua")
    self.cache = LuaSettings:open(dir .. "/substack_cache.lua")
    self.publications = self.settings:readSetting("publications") or {}
    -- People you follow on Substack who have no publication of their own (or
    -- whose publication couldn't be found): synced from their profile.
    self.people = self.settings:readSetting("people") or {}
    self.net = Net.new(self.settings)
    self.library = Library.new{
        store = LuaSettings:open(dir .. "/substack_library.lua"),
        lfs = lfs,
        docsettings = DocSettings,
    }
    self:applyLibraryPrefs()
    self.open_menus = {}
    -- Move v2's <home>/Substack folder out of the home folder (file browser only,
    -- never while a document is open).
    if not (self.ui and self.ui.document) then
        local ok, err = pcall(self.migrateOutOfHome, self)
        if not ok then logger.warn("Substack: migration failed", err) end
        -- An article was just closed: Bookshelf (if installed) as the home
        -- screen underneath, then the list it came from on top.
        if Return.closed or Return.pending then
            local o, closed = Return.pending, Return.closed
            Return.pending, Return.closed = nil, false
            UIManager:nextTick(function()
                local shelf = closed and self:showBookshelf()
                if o then
                    if shelf then
                        UIManager:scheduleIn(0.3, function() self:reopenOrigin(o) end)
                    else
                        self:reopenOrigin(o)
                    end
                end
            end)
        end
        -- Clear any article/digest entries that slipped into the history.
        if self.settings:nilOrTrue("hide_from_history") then
            pcall(self.purgeHistory, self, self:getDownloadDir())
        end
    end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Substack:saveSettings()
    self.settings:saveSetting("publications", self.publications)
    self.settings:saveSetting("people", self.people)
    self.settings:flush()
end

--- Where articles are saved. Default: inside KOReader's own folder
-- (koreader/substack), deliberately outside the home folder so articles
-- don't show up next to real books in the file browser or shelf/home-screen
-- plugins that list the home folder.
function Substack:defaultDownloadDir()
    return DataStorage:getFullDataDir() .. "/substack"
end

function Substack:getDownloadDir()
    return self.settings:readSetting("download_dir") or self:defaultDownloadDir()
end

--- Removes KOReader history entries for files under root (RECENT lists, "current read").
function Substack:purgeHistory(root)
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or type(ReadHistory.hist) ~= "table" then return 0 end
    local prefix = root .. "/"
    local n = 0
    for i = #ReadHistory.hist, 1, -1 do
        local item = ReadHistory.hist[i]
        if item and item.file and item.file:sub(1, #prefix) == prefix then
            pcall(function() ReadHistory:removeItem(item, i, true) end)
            n = n + 1
        end
    end
    if n > 0 then pcall(function() ReadHistory:_flush() end) end
    return n
end

--- One-time move: version 2 saved articles in <home>/Substack, which made them
-- show up among books. Move that folder into KOReader's folder.
function Substack:migrateOutOfHome()
    if self.settings:readSetting("download_dir") then return end -- user chose a folder
    if self.settings:isTrue("moved_out_of_home") then return end
    local home = G_reader_settings:readSetting("home_dir")
    local old = home and (home .. "/Substack")
    local new = self:defaultDownloadDir()
    if old and old ~= new and lfs.attributes(old, "mode") == "directory" then
        if lfs.attributes(new, "mode") == nil then
            local ok, err = os.rename(old, new)
            if ok then
                self.library:relocate(old, new)
                logger.info("Substack: moved articles out of the home folder", old, "->", new)
            else
                logger.warn("Substack: could not move article folder", old, err)
                return -- try again next start
            end
        else
            logger.warn("Substack: both old and new article folders exist; leaving", old)
        end
        self:purgeHistory(old)
    end
    self:purgeHistory(new)
    self.settings:saveSetting("moved_out_of_home", true)
    self.settings:flush()
end

function Substack:isLoggedIn()
    return str(self.settings:readSetting("cookie")) ~= nil
end

function Substack:pubByHost(host)
    for _i, p in ipairs(self.publications) do
        if p.host == host then return p end
    end
    return nil
end

function Substack:personById(id)
    id = tonumber(id)
    for _i, p in ipairs(self.people) do
        if tonumber(p.id) == id then return p end
    end
    return nil
end

--- Days a sync looks back (0 = no limit).
function Substack:syncDays()
    local d = tonumber(self.settings:readSetting("sync_days"))
    if not d then return SYNC_DAYS_DEFAULT end
    return d
end

--- "last 7 days", "last 12 hours", "no limit".
function Substack:syncWindowLabel(days)
    days = days or self:syncDays()
    if days <= 0 then return _("any date") end
    if days < 1 then return T(_("last %1 hours"), math.floor(days * 24 + 0.5)) end
    if days == 1 then return _("last 24 hours") end
    return T(_("last %1 days"), days)
end

--- Oldest post date (ISO string) a sync will download, or "" for no limit.
function Substack:syncCutoff()
    local days = self:syncDays()
    if days <= 0 then return "" end
    return isoDaysAgo(days)
end

local SORT_LABELS = {
    newest = _("Newest first"), oldest = _("Oldest first"),
    shortest = _("Shortest first"), publication = _("By publication"),
}

--- Is the device nearly full? Returns true/false and the free space in MB
-- (nil if it can't be measured, in which case downloads go ahead).
function Substack:lowOnSpace()
    local ok, free_mb = pcall(function()
        local util = require("util")
        if util.diskUsage then
            local usage = util.diskUsage(self:getDownloadDir())
            if type(usage) == "table" and usage.available then
                return math.floor(usage.available / (1024 * 1024))
            end
        end
        return nil
    end)
    if not ok or not free_mb then return false, nil end
    return free_mb < MIN_FREE_MB, free_mb
end

--- Hands the list preferences (sort order, short-read length, muted
-- publications) to the library, so every list agrees.
function Substack:applyLibraryPrefs()
    local muted, handles = {}, {}
    for _i, p in ipairs(self.publications) do
        if p.muted then muted[p.host] = true end
        if p.handle then handles[p.host] = p.handle end
    end
    self.library:setPrefs{
        muted = muted,
        handles = handles, -- for articles saved before handles were recorded
        sort = self.settings:readSetting("inbox_sort") or "newest",
        short_words = (self.settings:readSetting("short_minutes") or 5) * 230,
    }
end

function Substack:scanLibrary()
    self:applyLibraryPrefs()
    if not self.scanned then
        self.library:scan(self:getDownloadDir())
        self.scanned = true
    end
end

--- Runs fn inside a Trapper coroutine once Wi-Fi is up.
function Substack:online(fn)
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(fn)
    end)
end

---------------------------------------------------------------------------
-- Gestures & events
---------------------------------------------------------------------------

function Substack:onDispatcherRegisterActions()
    Dispatcher:registerAction("substack_sync",
        { category = "none", event = "SubstackSync", title = _("Substack: sync now"), general = true })
    Dispatcher:registerAction("substack_inbox",
        { category = "none", event = "SubstackInbox", title = _("Substack: inbox"), general = true })
    Dispatcher:registerAction("substack_next",
        { category = "none", event = "SubstackNextUnread", title = _("Substack: next unread article"), general = true })
    Dispatcher:registerAction("substack_close",
        { category = "none", event = "SubstackClose", title = _("Substack: close article (back to list)"), reader = true })
    Dispatcher:registerAction("substack_latest",
        { category = "none", event = "SubstackLatest", title = _("Substack: latest posts"), general = true })
end

function Substack:onSubstackSync() self:sync() return true end
function Substack:onSubstackInbox() self:showLibraryList("inbox") return true end
function Substack:onSubstackLatest() self:showLatest() return true end
function Substack:onSubstackClose()
    local file = self.ui and self.ui.document and self.ui.document.file
    if self:isArticleFile(file) then self:closeToHome() return true end
end
function Substack:onSubstackNextUnread()
    self:scanLibrary()
    local current = self.ui and self.ui.document and self.ui.document.file
    local nxt = self.library:nextUnread(current)
    if nxt then self:openFile(nxt.path) else showMsg(_("You're all caught up."), 2) end
    return true
end

function Substack:onNetworkConnected()
    if not self.settings:isTrue("auto_sync") or self.syncing then return end
    if os.time() - (self.settings:readSetting("last_sync") or 0) < 3 * 3600 then return end
    UIManager:scheduleIn(3, function() self:sync({ auto = true }) end)
end

--- When a Substack article is opened: clear a manual "unread" flag and hook
-- KOReader's end-of-book action to offer the next unread article.
function Substack:onReaderReady()
    local file = self.ui and self.ui.document and self.ui.document.file
    Return.pending, Return.closed = nil, false
    if not self:isArticleFile(file) then Return.to = nil end -- reading a book now
    -- Articles and digests: keep them out of KOReader's history right away
    -- (not only on close), so shelf/home-screen plugins never pick them up.
    if self:isArticleFile(file) then
        UIManager:nextTick(function() self:hideFromHistory(file) end)
        self:returnHomeOnClose()
        if not self.library:get(file) then
            -- The dashboard or a digest: not a book to rate or review.
            self:hookEndOfExtra(file)
        end
    end
    if not file or not self.library:get(file) then return end
    self.library:touch(file)
    local status = self.ui.status
    if status and not status._substack_hooked and self.settings:nilOrTrue("end_prompt") then
        status._substack_hooked = true
        local orig = status.onEndOfBook
        status.onEndOfBook = function(st, ...)
            local args = { ... }
            self:showEndOfArticle(file, function()
                if orig then return orig(st, unpack(args)) end
            end)
            return true
        end
    end
end

--- A book's display title: its own metadata if KOReader has read it,
-- else a tidied-up file name ("Ghosts-Dolly_Alderton.epub" → "Ghosts").
function Substack:bookTitle(path)
    local ok, title = pcall(function()
        local ds = DocSettings:open(path)
        local props = ds:readSetting("doc_props")
        return type(props) == "table" and type(props.title) == "string" and props.title ~= "" and props.title or nil
    end)
    if ok and title then return title end
    local name = (path:match("([^/]+)$") or path):gsub("%.%w+$", "")
    -- "Title-Author_Name" style file names: keep the title part.
    local before_dash = name:match("^(.-)%s*%-%s*[^%-]+$")
    if before_dash and before_dash ~= "" and name:find("_") then name = before_dash end
    name = name:gsub("_", " "):gsub("%s+", " ")
    return name
end

--- Short name for where an article came from, for "Back to …" labels.
function Substack:originLabel(o)
    o = o or Return.to
    if not o then return nil end
    if o.kind == "archive" then return o.name or SH.displayName(o.host) end
    if o.kind == "library" and o.group_label then return o.group_label end
    if o.kind == "person" then
        local p = self:personById(o.id)
        return p and SH.whoLabel(p.name, p.handle) or _("People you follow")
    end
    if o.kind == "library" then
        return ({ inbox = _("Inbox"), short = _("Short reads"), archive = _("Archive"),
                  kept = _("Kept & highlighted"), all = _("All saved articles") })[o.list] or _("Inbox")
    end
    return ({ latest = _("Latest posts"), saved = _("Saved on Substack"), digests = _("Digests") })[o.kind]
end

--- Shows the Bookshelf home screen plugin, if it's installed and wanted.
function Substack:hasBookshelf()
    return self.ui and self.ui.bookshelf ~= nil
end

function Substack:showBookshelf()
    if not (self:hasBookshelf() and self.settings:nilOrTrue("return_to_bookshelf")) then return false end
    local ok, err = pcall(function()
        self.ui:handleEvent(require("ui/event"):new("SetBookshelf", true))
    end)
    if not ok then logger.warn("Substack: couldn't open Bookshelf", err) end
    return ok
end

--- Reopens the list an article came from (on top of the file browser).
function Substack:reopenOrigin(o)
    if not o then return end
    local ok, err = pcall(function()
        if o.kind == "archive" then
            -- Publications underneath, so Back from the list goes there.
            self:showPublications()
            self:showArchive(self:pubByHost(o.host) or { host = o.host, name = o.name or SH.displayName(o.host) })
        elseif o.kind == "library" then
            self:showLibraryList(o.list or "inbox")
            if o.group then
                -- The writer's list on top of the grouped Inbox, so Back goes there.
                self:showLibraryList(o.list or "inbox", { key = o.group, label = o.group_label or "?" })
            end
        elseif o.kind == "person" then
            local p = self:personById(o.id)
            self:showPeople()
            if p then self:showPerson(p) end
        elseif o.kind == "latest" then
            self:showLatest()
        elseif o.kind == "saved" then
            self:showSavedOnSubstack()
        elseif o.kind == "digests" then
            self:showDigests()
        end
    end)
    if not ok then logger.warn("Substack: couldn't reopen list", o.kind, err) end
end

--- Closes the open document and shows the file browser (at the home folder,
-- via returnHomeOnClose). Closing the reader on its own would leave KOReader
-- with nothing on screen, and it quits.
function Substack:closeToHome()
    local ui = self.ui
    if not ui then return end
    local file = ui.document and ui.document.file
    if type(ui.onHome) == "function" then
        ui:onHome() -- KOReader's own "close and go to the file browser"
        return
    end
    if type(ui.showFileManager) == "function" then
        ui:showFileManager(file) -- opens the browser first, so KOReader never runs out of screens
    end
    if type(ui.onClose) == "function" then ui:onClose() end
end

--- Where to go when closing one of our documents, so the hidden Substack
-- folder never shows up. Best: return as if the last real book had just been
-- closed. That's the situation home-screen/shelf plugins are built for, so
-- they show their own screen. Else the home folder, else KOReader's default.
function Substack:closeTarget(current)
    local prev = self:previousBook(current)
    if prev then return prev end
    local home = G_reader_settings:readSetting("home_dir")
    if home and lfs.attributes(home, "mode") == "directory" then
        return home:gsub("/+$", "") .. "/"
    end
    return nil
end

--- KOReader opens the file browser in the folder of the document you just
-- closed. For our documents, send it to closeTarget() instead.
function Substack:returnHomeOnClose()
    local ui = self.ui
    if not ui or ui._substack_home_hooked or type(ui.showFileManager) ~= "function" then return end
    ui._substack_home_hooked = true
    local orig = ui.showFileManager
    ui.showFileManager = function(this, file, ...)
        local current = this.document and this.document.file or file
        if self:isArticleFile(current) or self:isArticleFile(file) then
            local target = self:closeTarget(current)
            if target then
                local ok, res = pcall(orig, this, target, ...)
                if ok then return res end
                logger.warn("Substack: couldn't open the file browser at", target, res)
            end
        end
        return orig(this, file, ...)
    end
end

--- End of the dashboard or a digest: a short, relevant choice instead of
-- KOReader's book-review screen.
function Substack:hookEndOfExtra(file)
    local status = self.ui and self.ui.status
    if not status or status._substack_hooked then return end
    status._substack_hooked = true
    status.onEndOfBook = function()
        local is_report = file:find("/Reports/", 1, true) ~= nil
        local dlg
        local buttons = {}
        local prev = self:previousBook(file)
        if prev then
            local name = self:bookTitle(prev)
            table.insert(buttons, {{ text = T(_("Back to my book: %1"), name), callback = function()
                UIManager:close(dlg)
                self:openFile(prev, false)
            end }})
        end
        table.insert(buttons, {
            { text = _("Inbox"), callback = function() UIManager:close(dlg) self:showLibraryList("inbox") end },
            { text = _("Close"), callback = function()
                UIManager:close(dlg)
                self:closeToHome()
            end },
        })
        table.insert(buttons, {{ text = _("Stay on this page"), callback = function() UIManager:close(dlg) end }})
        dlg = ButtonDialog:new{
            title = is_report and _("That's your reading so far.") or _("End of the digest."),
            buttons = buttons,
        }
        UIManager:show(dlg)
        return true
    end
end

--- Is this file one of ours (an article or digest in the download folder)?
function Substack:isArticleFile(file)
    if type(file) ~= "string" then return false end
    if self.library:get(file) then return true end
    local dir = self:getDownloadDir()
    return file:sub(1, #dir + 1) == dir .. "/"
end

--- The most recent non-article book in KOReader's history that still exists.
function Substack:previousBook(exclude)
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or type(ReadHistory.hist) ~= "table" then return nil end
    for _i, item in ipairs(ReadHistory.hist) do
        local f = item.file
        if f and f ~= exclude and not self:isArticleFile(f) and lfs.attributes(f, "mode") == "file" then
            return f
        end
    end
    return nil
end

--- Takes an article out of KOReader's history and puts the last real book
-- back as the "current read" (what the home screen and "open last book" use).
function Substack:hideFromHistory(file)
    if not self.settings:nilOrTrue("hide_from_history") then return end
    if not self:isArticleFile(file) then return end
    local prev = self:previousBook(file)
    local ok, ReadHistory = pcall(require, "readhistory")
    if ok and type(ReadHistory.hist) == "table" then
        pcall(function()
            if ReadHistory.removeItemByPath then
                ReadHistory:removeItemByPath(file)
            else
                for i, item in ipairs(ReadHistory.hist) do
                    if item.file == file then ReadHistory:removeItem(item, i) break end
                end
            end
        end)
    end
    if G_reader_settings:readSetting("lastfile") == file then
        if prev then
            G_reader_settings:saveSetting("lastfile", prev)
        else
            G_reader_settings:delSetting("lastfile")
        end
    end
end

--- Closing an article: KOReader writes history/lastfile while closing, so
-- undo it now and once more right after the reader has gone.
function Substack:onCloseDocument()
    local file = self.ui and self.ui.document and self.ui.document.file
    -- Reading progress just changed: lists must re-check it.
    if self.library then self.library:invalidate() end
    if self:isArticleFile(file) then
        Return.closed = true
        if Return.to then Return.pending = Return.to end
    end
    if not self:isArticleFile(file) then return end
    self:hideFromHistory(file)
    UIManager:nextTick(function() self:hideFromHistory(file) end)
    UIManager:scheduleIn(1, function()
        self:hideFromHistory(file)
        -- Safety net: if the file browser still opened inside the Substack
        -- folder (older KOReader versions), move it to the home folder.
        pcall(function()
            local FileManager = require("apps/filemanager/filemanager")
            local fm = FileManager.instance
            local dir = self:getDownloadDir()
            local here = fm and fm.file_chooser and fm.file_chooser.path
            if here and (here == dir or here:sub(1, #dir + 1) == dir .. "/") then
                local target = self:closeTarget(file)
                if target and target:sub(-1) ~= "/" and fm.reinit then
                    fm:reinit(target:match("^(.*)/[^/]*$"), target) -- the last book's folder, book selected
                elseif fm.goHome then
                    fm:goHome()
                end
            end
        end)
    end)
end

--- Sets KOReader's own book status (shown in its file browser too).
function Substack:setKOStatus(path, status)
    local ok, err = pcall(function()
        local open_doc = self.ui and self.ui.document and self.ui.document.file == path
        local ds = open_doc and self.ui.doc_settings or DocSettings:open(path)
        local summary = ds:readSetting("summary") or {}
        summary.status = status
        summary.modified = os.date("%Y-%m-%d", os.time())
        ds:saveSetting("summary", summary)
        if not open_doc then ds:flush() end
    end)
    if not ok then logger.warn("Substack: could not set status", path, err) end
end

function Substack:showEndOfArticle(file)
    self.library:setOverride(file, "finished")
    self:setKOStatus(file, "complete")
    local a = self.library:get(file) or {}
    local nxt = self.library:nextUnread(file)
    local dlg
    local title = T(_("Finished “%1”."), a.title or "")
    local buttons = {}
    if nxt then
        local rt = SH.readingTime(nxt.meta.words)
        title = title .. "\n\n" .. T(_("Up next: %1"), nxt.meta.title or "")
            .. "\n" .. (nxt.meta.publication or "") .. (rt and (" · " .. rt) or "")
        table.insert(buttons, {{ text = _("Read next"), callback = function()
            UIManager:close(dlg)
            self:openFile(nxt.path)
        end }})
    else
        title = title .. "\n\n" .. _("You're all caught up.")
    end
    -- Back to the book you were reading before the article (if any).
    local prev = self:previousBook(file)
    if prev then
        local name = self:bookTitle(prev)
        table.insert(buttons, {{ text = T(_("Back to my book: %1"), name), callback = function()
            UIManager:close(dlg)
            self:openFile(prev, false)
        end }})
    end
    table.insert(buttons, {
        { text = _("Inbox"), callback = function() UIManager:close(dlg) self:showLibraryList("inbox") end },
        { text = a.kept and _("Kept ✓") or _("Keep"), callback = function()
            UIManager:close(dlg)
            self.library:setKept(file, not a.kept)
            showMsg(a.kept and _("No longer kept.") or _("Kept. It won't be auto-deleted."), 2)
        end },
    })
    table.insert(buttons, {
        { text = _("Delete article"), callback = function()
            UIManager:close(dlg)
            UIManager:show(ConfirmBox:new{
                text = T(_("Delete “%1”?"), a.title or ""),
                ok_text = _("Delete"),
                ok_callback = function()
                    -- Close the reader first; the file can't be removed while open.
                    self:closeToHome()
                    UIManager:nextTick(function()
                        self.library:delete(file)
                        showMsg(_("Article deleted."), 2)
                    end)
                end,
            })
        end },
        { text = self:originLabel() and T(_("Back to %1"), self:originLabel()) or _("Close article"), callback = function()
            UIManager:close(dlg)
            self:closeToHome()
        end },
    })
    -- Dismiss and stay on the last page (e.g. to re-read or highlight).
    table.insert(buttons, {{ text = _("Stay on this page"), callback = function() UIManager:close(dlg) end }})
    dlg = ButtonDialog:new{ title = title, buttons = buttons }
    UIManager:show(dlg)
end

---------------------------------------------------------------------------
-- Saving articles
---------------------------------------------------------------------------

function Substack:articlePath(pub_name, post)
    local base = SH.safeFilename((postDate(post) or "undated") .. " - " .. (str(post.title) or str(post.slug) or "post"))
    local dir = self:getDownloadDir() .. "/" .. SH.safeFilename(pub_name, 60)
    return dir, base, dir .. "/" .. base .. ".epub"
end

--- Returns saved?, path (EPUB, or a legacy HTML file from version 1).
function Substack:isSaved(pub_name, post)
    local dir, base, path = self:articlePath(pub_name, post)
    if lfs.attributes(path, "mode") == "file" then return true, path end
    local legacy = dir .. "/" .. base .. ".html"
    if lfs.attributes(legacy, "mode") == "file" then return true, legacy end
    return false, path
end

--- Downloads one image into tmp_dir; returns file name or nil.
function Substack:fetchImage(src, tmp_dir, name, width)
    local url = SH.cdnUrl(src, width)
    local ext = url:find("f_jpg") and "jpg" or ((src:match("%.(%a%a%a%a?)$") or "jpg"):lower())
    if ext == "jpeg" then ext = "jpg" end
    local fname = name .. "." .. ext
    if self.net:get(url, tmp_dir .. "/" .. fname, false) then return fname end
    os.remove(tmp_dir .. "/" .. fname)
    return nil
end

--- Builds the EPUB for a full post. Must run inside Trapper. Returns path or nil, err.
function Substack:saveArticle(host, pub_name, post)
    local dir, base, path = self:articlePath(pub_name, post)
    local ok, err = mkdirp(dir)
    if not ok then return nil, T(_("Cannot create folder %1: %2"), dir, tostring(err)) end
    local tmp = DataStorage:getDataDir() .. "/cache/substack-tmp"
    mkdirp(tmp)
    for f in lfs.dir(tmp) do if f ~= "." and f ~= ".." then os.remove(tmp .. "/" .. f) end end

    local body = str(post.body_html)
    if not body and str(post.truncated_body_text) then
        body = "<p>" .. SH.escape(post.truncated_body_text) .. "</p>"
    end
    body = SH.cleanBody(body or "")

    local quality = self.settings:readSetting("image_quality") or "standard"
    local width = IMAGE_WIDTH[quality]
    local map, images, cover = {}, {}, nil
    if width then
        local list = SH.collectImages(body)
        for i, src in ipairs(list) do
            if not Trapper:info(T(_("Downloading images… %1 / %2\n\nTap to skip the rest."), i, #list)) then break end
            local fname = self:fetchImage(src, tmp, string.format("img%03d", i), width)
            if fname then
                map[src] = "images/" .. fname
                images[#images + 1] = { name = fname, path = tmp .. "/" .. fname }
            end
        end
        if str(post.cover_image) then
            local fname = self:fetchImage(post.cover_image, tmp, "cover", 600)
            if fname then cover = { name = fname, path = tmp .. "/" .. fname } end
        end
    end
    body = SH.toXhtml(SH.rewriteImages(body, map))

    local comments_xhtml
    local n_comments = self.settings:readSetting("comments") or 0
    if n_comments > 0 and post.id then
        Trapper:info(_("Downloading comments…"))
        local list, cerr = self.net:comments(host, post.id)
        -- No Comments chapter at all when there are none (or Substack refused).
        if list then
            comments_xhtml = SH.renderComments(list, n_comments)
        else
            logger.warn("Substack: comments not added", host, post.id, cerr)
        end
    end

    local paid = isPaid(post)
    local followed = self:pubByHost(host)
    local handle = SH.postHandle(post) or (followed and followed.handle) or nil
    local meta = {
        title = str(post.title) or str(post.slug) or "Untitled",
        subtitle = str(post.subtitle),
        author = postAuthor(post),
        publication = pub_name,
        date = postDate(post),
        url = str(post.canonical_url),
        words = tonumber(post.wordcount) or SH.countWords(body),
        id = post.id,
        paywalled = paid and not self:isLoggedIn(),
    }
    local built, berr = Epub.buildArticle(path, {
        title = meta.title, subtitle = meta.subtitle, author = meta.author, publication = pub_name,
        date = meta.date, url = meta.url, words = meta.words, id = meta.id, paywalled = meta.paywalled,
        body = body, images = images, cover = cover, comments = comments_xhtml,
    })
    for f in lfs.dir(tmp) do if f ~= "." and f ~= ".." then os.remove(tmp .. "/" .. f) end end
    if not built then return nil, T(_("Could not write the article: %1"), tostring(berr)) end

    self.library:add{
        path = path, title = meta.title, subtitle = meta.subtitle, author = meta.author,
        publication = pub_name, host = host, slug = str(post.slug), id = post.id,
        date = meta.date, url = meta.url, words = meta.words, paid = paid or nil,
        handle = handle,
    }
    -- A re-download whose title changed lands in a new file: drop the old copy.
    self.library:removeOlderCopies(path)
    return path
end

--- Fetches (if needed) and saves a post. Must run inside Trapper.
function Substack:downloadPost(host, pub_name, stub)
    local post = stub
    if not str(stub.body_html) then
        local err
        post, err = self.net:fetchPost(host, stub.slug)
        if not post then return nil, Net.friendly(err) end
    end
    return self:saveArticle(host, pub_name, post)
end

function Substack:closeMenus()
    for _i, m in ipairs(self.open_menus) do UIManager:close(m) end
    self.open_menus = {}
end

function Substack:refreshMenus()
    for _i, m in ipairs(self.open_menus) do
        if m.rebuild then m:switchItemTable(m.rebuild_title and m.rebuild_title() or nil, m.rebuild(), -1) end
    end
end

--- origin: where the article was opened from ({ kind = "archive" | "library"
-- | "latest" | "saved" | "digests", ... }), false to forget any origin (e.g.
-- opening a book), or nil to keep the current one (e.g. "Read next").
function Substack:openFile(path, origin)
    if origin ~= nil then Return.to = origin or nil end
    self:closeMenus()
    self.library:touch(path)
    UIManager:nextTick(function()
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(path)
    end)
end

--- Opens a post, or (open == false) just saves it for offline reading.
function Substack:openPost(host, pub_name, stub, force, open, origin)
    if open == nil then open = true end
    local saved_already, path = self:isSaved(pub_name, stub)
    if saved_already and not force then
        if open then self:openFile(path, origin) else showMsg(_("Already saved."), 2) end
        return
    end
    self:online(function()
        Trapper:info(T(_("Downloading “%1”…"), str(stub.title) or stub.slug))
        local saved, err = self:downloadPost(host, pub_name, stub)
        Trapper:clear()
        if not saved then showMsg(err) return end
        if open then
            self:openFile(saved, origin)
        else
            self:refreshMenus()
            showMsg(_("Saved for offline reading."), 2)
        end
    end)
end

--- Saves every not-yet-saved post in entries.
function Substack:saveAll(entries)
    self:online(function()
        local todo = {}
        for _i, e in ipairs(entries) do
            if not self:isSaved(e.pub.name, e.post) then todo[#todo + 1] = e end
        end
        if #todo == 0 then
            Trapper:clear()
            showMsg(_("Everything here is already saved."), 2)
            return
        end
        local done, failed = 0, 0
        for i, e in ipairs(todo) do
            if not Trapper:info(T(_("Saving %1 / %2\n%3\n\nTap to stop."), i, #todo, str(e.post.title) or "")) then break end
            if self:downloadPost(e.pub.host, e.pub.name, e.post) then done = done + 1 else failed = failed + 1 end
        end
        Trapper:clear()
        self:refreshMenus()
        local msg = T(_("Saved %1 article(s) for offline reading."), done)
        if failed > 0 then msg = msg .. "\n" .. T(_("%1 failed."), failed) end
        showMsg(msg)
    end)
end

---------------------------------------------------------------------------
-- Offline cache of post lists
---------------------------------------------------------------------------

--- no_flush = true during sync: the cache file is written once at the end
-- instead of after every publication (it can get large with many publications).
function Substack:cachePosts(host, posts, no_flush)
    local c = self.cache:readSetting(host) or {}
    local by_slug, list = {}, {}
    for _i, p in ipairs(posts) do
        if type(p) == "table" and str(p.slug) and not by_slug[p.slug] then
            by_slug[p.slug] = true
            list[#list + 1] = slimPost(p)
        end
    end
    for _i, p in ipairs(c.posts or {}) do
        if p.slug and not by_slug[p.slug] then
            by_slug[p.slug] = true
            list[#list + 1] = p
        end
    end
    table.sort(list, function(a, b) return (a.post_date or "") > (b.post_date or "") end)
    while #list > CACHE_PER_PUB do table.remove(list) end
    c.posts = list
    c.fetched = os.time()
    self.cache:saveSetting(host, c)
    if not no_flush then self.cache:flush() end
    local pub = self:pubByHost(host)
    local changed = false
    if pub and not pub.id and posts[1] and posts[1].publication_id then
        pub.id = posts[1].publication_id
        changed = true
    end
    -- Remember who writes it, for labels like "The Cute Club (@amymatt)".
    if pub and not pub.handle then
        local h = SH.mainHandle(posts)
        if h then pub.handle = h changed = true end
    end
    if changed then
        if no_flush then self.settings:saveSetting("publications", self.publications) else self:saveSettings() end
    end
    return c
end

function Substack:cached(host)
    return self.cache:readSetting(host)
end

---------------------------------------------------------------------------
-- Sync
---------------------------------------------------------------------------

function Substack:sync(opts)
    opts = opts or {}
    if self.syncing then return end
    if #self.publications == 0 and not self:isLoggedIn() then
        showMsg(_("Follow a publication or sign in first (Substack → Publications / Account)."))
        return
    end
    -- Remember whether Wi-Fi was already on, so a sync that switched it on can
    -- switch it off again afterwards (saves battery).
    local wifi_was_on = true
    pcall(function() wifi_was_on = NetworkMgr:isWifiOn() and true or false end)
    self:online(function()
        if self.syncing then return end
        self.syncing = true
        local per_pub = self.settings:readSetting("per_pub") or 3
        local saved_count, failed, cancelled = 0, {}, false
        local session_expired = false
        local low_space = nil -- free MB when downloads stopped for lack of space
        local skipped_by_cap = 0
        local function step(text)
            if not Trapper:info(text .. "\n\n" .. _("Tap to stop.")) then cancelled = true end
            return not cancelled
        end
        -- Phase 1: check every publication and collect its newest posts
        -- (up to per_pub each). Nothing is downloaded yet.
        local skip_podcasts = (self.settings:readSetting("podcasts") or "skip") == "skip"
        local pool, in_pool = {}, {}
        local function addToPool(pub, post)
            local key = pub.host .. "|" .. tostring(post.slug)
            if in_pool[key] then return false end
            in_pool[key] = true
            pool[#pool + 1] = { pub = pub, post = post }
            return true
        end
        -- Only posts from the sync window (Settings → Download posts from the
        -- last…) are fetched; older ones stay browsable but never take up space.
        local cutoff = self:syncCutoff()
        for i, pub in ipairs(self.publications) do
            if not step(T(_("Checking %1 (%2 / %3)…"), pubLabel(pub), i, #self.publications)) then break end
            local posts, err = self.net:archive(pub.host, 0, math.max(per_pub, 12))
            if posts then
                self:cachePosts(pub.host, posts, true) -- written once, after the loop
                -- Added by address, so only the subdomain is known: look up the real name once.
                if not pub.name_checked and pub.name == SH.displayName(pub.host) then
                    pub.name_checked = true
                    local real = self.net:publicationName(pub.host)
                    if real then pub.name = real end
                end
                local since = pub.last_seen or ""
                if cutoff > since then since = cutoff end
                local newest = pub.last_seen
                local candidates = {}
                for _i, p in ipairs(posts) do
                    local d = str(p.post_date) or ""
                    local is_podcast = p.type == "podcast"
                    if d > since and not (skip_podcasts and is_podcast) then candidates[#candidates + 1] = p end
                    if not newest or d > newest then newest = d end
                end
                if pub.auto ~= false and not pub.muted then
                    for j = 1, math.min(per_pub, #candidates) do
                        if not self:isSaved(pub.name, candidates[j]) then
                            addToPool(pub, candidates[j])
                        end
                    end
                end
                pub.last_seen = newest
            else
                failed[#failed + 1] = pub.name
                logger.warn("Substack: sync failed for", pub.host, err)
            end
            if cancelled then break end
        end

        -- People you follow who have no publication of their own: their newest
        -- posts, wherever they were published.
        if not cancelled and #self.people > 0 then
            for i, person in ipairs(self.people) do
                local who = SH.whoLabel(person.name, person.handle)
                if not step(T(_("Checking %1 (%2 / %3)…"), who, i, #self.people)) then break end
                if not person.muted and person.auto ~= false then
                    local feed, err = self.net:profileFeed(person.id)
                    if feed then
                        if feed.person then
                            person.name = feed.person.name or person.name
                            person.handle = feed.person.handle or person.handle
                        end
                        local since = person.last_seen or ""
                        if cutoff > since then since = cutoff end
                        local newest, n = person.last_seen, 0
                        for _j, e in ipairs(feed.posts) do
                            local d = str(e.post.post_date) or ""
                            if not newest or d > newest then newest = d end
                            local is_podcast = e.post.type == "podcast"
                            if n < per_pub and d > since and not (skip_podcasts and is_podcast) then
                                local followed = self:pubByHost(e.host)
                                local pub = {
                                    host = e.host,
                                    name = followed and followed.name or e.pub_name or SH.displayName(e.host),
                                    handle = person.handle,
                                }
                                if not (followed and followed.muted) and not self:isSaved(pub.name, e.post)
                                        and addToPool(pub, e.post) then
                                    n = n + 1
                                end
                            end
                        end
                        person.last_seen = newest
                    else
                        failed[#failed + 1] = who
                        if tostring(err):find("HTTP 40[13]") then session_expired = true end
                        logger.warn("Substack: sync failed for person", person.id, err)
                    end
                end
                if cancelled then break end
            end
        end
        self.cache:flush()
        self:saveSettings()

        -- Phase 2: download the newest posts across all publications, up to
        -- the per-sync limit, so following many publications never floods the
        -- Inbox. The rest stay browsable under Publications.
        local max_new = self.settings:readSetting("max_per_sync") or 20
        table.sort(pool, function(a, b) return (str(a.post.post_date) or "") > (str(b.post.post_date) or "") end)
        skipped_by_cap = math.max(0, #pool - max_new)
        for j = 1, math.min(max_new, #pool) do
            if cancelled then break end
            local low, free = self:lowOnSpace()
            if low then
                low_space = free
                break
            end
            local e = pool[j]
            if not step(T(_("Downloading %1 / %2 from %3:\n%4"), j, math.min(max_new, #pool), pubLabel(e.pub), str(e.post.title) or "")) then break end
            if self:downloadPost(e.pub.host, e.pub.name, e.post) then saved_count = saved_count + 1 end
        end

        if not cancelled and self:isLoggedIn() and self.settings:nilOrTrue("sync_saved") then
            if step(_("Checking posts you saved in the Substack app…")) then
                local saved, serr = self.net:savedPosts(20)
                if not saved and tostring(serr):find("HTTP 40[13]") then
                    session_expired = true
                end
                local n = 0
                for _i, s in ipairs(saved or {}) do
                    local pub = self:pubByHost(s.host)
                    local name = pub and pub.name
                        or (type(s.post.publication) == "table" and str(s.post.publication.name))
                        or SH.displayName(s.host)
                    local stub = s.post
                    stub.slug = stub.slug or s.slug
                    if n < 10 and not low_space and not self:isSaved(name, stub) then
                        local low, free = self:lowOnSpace()
                        if low then low_space = free break end
                        if not step(T(_("Downloading saved post:\n%1"), str(stub.title) or s.slug)) then break end
                        if self:downloadPost(s.host, name, stub) then
                            saved_count = saved_count + 1
                            n = n + 1
                        end
                    end
                    if low_space then break end
                end
            end
        end

        local weekly_path
        if not cancelled then
            local okw, res = pcall(self.maybeWeeklyDigest, self)
            if okw then weekly_path = res else logger.warn("Substack: weekly digest failed", res) end
        end

        -- Default: finished articles go after 30 days (kept/highlighted never do).
        local deleted = self.library:cleanup(self.settings:readSetting("cleanup_days") or 30)
        self.settings:saveSetting("last_sync", os.time())
        self.settings:flush()
        Trapper:clear()
        self.syncing = false
        if not wifi_was_on and self.settings:nilOrTrue("wifi_off_after_sync") then
            UIManager:scheduleIn(2, function()
                pcall(function() NetworkMgr:turnOffWifi() end)
            end)
        end
        self:refreshMenus()

        local msg = saved_count > 0 and T(_("%1 new article(s) in your Inbox."), saved_count) or _("No new articles.")
        if deleted > 0 then msg = msg .. "\n" .. T(_("Cleaned up %1 finished article(s)."), deleted) end
        if #failed > 0 then msg = msg .. "\n" .. T(_("Couldn't reach: %1"), table.concat(failed, ", ")) end
        if cancelled then msg = _("Sync stopped.") .. "\n" .. msg end
        if skipped_by_cap > 0 then
            msg = msg .. "\n" .. T(_("%1 more new post(s) left out to keep your Inbox manageable. Browse them under Publications."), skipped_by_cap)
        end
        if low_space then
            msg = msg .. "\n\n" .. T(_("Downloads stopped: only %1 MB free on the device. Delete finished articles (Library → Delete finished articles now) or some books."), low_space)
        end
        if weekly_path then
            msg = msg .. "\n" .. _("Your weekly digest is ready (Library → Digests).")
        end
        if session_expired then
            msg = msg .. "\n\n" .. _("Your Substack sign-in has expired, so posts from people you follow and posts saved in the Substack app were skipped. Sign in again under Account.")
        end
        if opts.auto and saved_count == 0 and #failed == 0 then
            showMsg(msg, 2)
        elseif saved_count > 0 and not opts.auto then
            UIManager:show(ConfirmBox:new{
                text = msg, ok_text = _("Open Inbox"), cancel_text = _("Close"),
                ok_callback = function() self:showLibraryList("inbox") end,
            })
        else
            showMsg(msg, opts.auto and 4 or nil)
        end
    end)
end

---------------------------------------------------------------------------
-- Menus (generic)
---------------------------------------------------------------------------

--- items may be a table or a function returning one (then the menu can refresh itself).
function Substack:newMenu(title, items, title_func)
    local rebuild = type(items) == "function" and items or nil
    local menu
    menu = Menu:new{
        title = title_func and title_func() or title,
        item_table = rebuild and rebuild() or items,
        rebuild = rebuild,
        rebuild_title = title_func,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuChoice = function(_m, item)
            -- KOReader closes a Menu after any item is chosen. Items like
            -- Refresh / Load older posts update this list in place, so mark
            -- them keep_open and swallow that one automatic close.
            if item.keep_open then menu._keep_open_once = true end
            if item.action then item.action() end
            return true
        end,
        onMenuHold = function(_m, item)
            if item.hold_action then item.hold_action() end
            return true
        end,
        close_callback = function()
            if menu._keep_open_once then
                menu._keep_open_once = nil
                return
            end
            UIManager:close(menu)
            for i, m in ipairs(self.open_menus) do
                if m == menu then table.remove(self.open_menus, i) break end
            end
        end,
    }
    table.insert(self.open_menus, menu)
    UIManager:show(menu)
    return menu
end

local function buttonDialog(title, rows)
    local dlg
    local buttons = {}
    for _i, row in ipairs(rows) do
        local r = {}
        for _j, b in ipairs(row) do
            r[#r + 1] = { text = b[1], callback = function()
                UIManager:close(dlg)
                b[2]()
            end }
        end
        buttons[#buttons + 1] = r
    end
    dlg = ButtonDialog:new{ title = title, buttons = buttons }
    UIManager:show(dlg)
end

function Substack:followPub(host, name, on_done)
    if self:pubByHost(host) then
        showMsg(T(_("You already follow %1."), name), 2)
        return
    end
    table.insert(self.publications, { host = host, name = name or SH.displayName(host) })
    table.sort(self.publications, function(a, b) return a.name:lower() < b.name:lower() end)
    self:saveSettings()
    showMsg(T(_("Now following %1. New posts will arrive when you sync."), name or host), 3)
    if on_done then on_done() end
    self:refreshMenus()
end

---------------------------------------------------------------------------
-- Post lists (publication archive, latest, saved, previews)
---------------------------------------------------------------------------

function Substack:postItem(entry)
    local post, pub = entry.post, entry.pub
    local prefix = ""
    if isPaid(post) then prefix = "[paid] " end
    if post.type == "podcast" then prefix = prefix .. "[audio] " end
    local text = prefix .. (str(post.title) or str(post.slug) or "?")
    if entry.show_pub then text = text .. "  — " .. SH.whoLabel(pub.name, pub.handle or SH.postHandle(post)) end
    local saved = self:isSaved(pub.name, post)
    local rt = SH.readingTime(post.wordcount)
    local mandatory = (saved and "✓ " or "") .. (postDate(post) or "")
    if rt and not saved then mandatory = rt .. " · " .. mandatory end
    return {
        text = text,
        mandatory = mandatory,
        action = function() self:openPost(pub.host, pub.name, post, false, true, entry.origin) end,
        hold_action = function()
            local rows = { { { _("Read now"), function() self:openPost(pub.host, pub.name, post, false, true, entry.origin) end } } }
            if saved then
                table.insert(rows, { { _("Re-download"), function() self:openPost(pub.host, pub.name, post, true, false) end } })
            else
                table.insert(rows, { { _("Save for later"), function() self:openPost(pub.host, pub.name, post, false, false) end } })
            end
            if not self:pubByHost(pub.host) then
                table.insert(rows, { { T(_("Follow %1"), pub.name), function() self:followPub(pub.host, pub.name) end } })
            end
            local subtitle = str(post.subtitle)
            buttonDialog((str(post.title) or "") .. (subtitle and ("\n\n" .. subtitle) or ""), rows)
        end,
    }
end

--- Generic list. state = { entries, title, refresh = fn|nil, load_more = fn|nil, has_more, extra_top = {items} }
function Substack:showPostList(state)
    local menu
    local function build()
        local items = {}
        for _i, it in ipairs(state.extra_top or {}) do items[#items + 1] = it end
        if state.refresh then
            items[#items + 1] = {
                text = state.updated and T(_("Refresh (updated %1)"), ago(state.updated)) or _("Refresh"),
                keep_open = true,
                action = function() state.refresh(menu) end,
            }
        end
        if #state.entries > 0 then
            items[#items + 1] = { text = _("Save all in this list for offline…"), keep_open = true, action = function() self:saveAll(state.entries) end }
        end
        for _i, e in ipairs(state.entries) do
            e.origin = state.origin
            items[#items + 1] = self:postItem(e)
        end
        if state.has_more and state.load_more then
            items[#items + 1] = { text = _("Load older posts…"), keep_open = true, action = function() state.load_more(menu) end }
        end
        if #state.entries == 0 then items[#items + 1] = { text = _("No posts.") } end
        return items
    end
    state.rebuild = build
    menu = self:newMenu(state.title, build)
    return menu
end

function Substack:showArchive(pub)
    local function entriesFrom(posts)
        local list = {}
        for _i, p in ipairs(posts) do list[#list + 1] = { post = p, pub = pub } end
        return list
    end
    local state = { title = pub.name, entries = {}, has_more = true,
                    origin = { kind = "archive", host = pub.host, name = pub.name } }
    local function fetchInner(menu, offset)
        Trapper:info(T(_("Loading %1…"), pub.name))
        local posts, err_or_feed = self.net:archive(pub.host, offset, PAGE_SIZE)
        Trapper:clear()
        if not posts then
            showMsg(T(offset > 0 and _("Could not load older posts from %1:\n%2") or _("Could not load %1:\n%2"),
                pub.name, Net.friendly(err_or_feed)))
            return
        end
        if offset == 0 and #posts == 0 then
            showMsg(T(_("%1 has no posts yet."), pub.name))
            return
        end
        local from_feed = err_or_feed == true
        local c = self:cachePosts(pub.host, posts)
        if offset == 0 then
            c.from_feed = from_feed
            self.cache:saveSetting(pub.host, c)
            self.cache:flush()
            state.entries = entriesFrom(c.posts)
            state.updated = c.fetched
            state.has_more = true -- older posts can come from the 50-post page or the sitemap
        else
            local seen = {}
            for _i, e in ipairs(state.entries) do
                if e.post.slug then seen[e.post.slug] = true end
            end
            local function addNew(list)
                local n = 0
                for _i, p in ipairs(list or {}) do
                    if str(p.slug) and not seen[p.slug] then
                        seen[p.slug] = true
                        local slim = slimPost(p)
                        slim.from_sitemap = p.from_sitemap
                        state.entries[#state.entries + 1] = { post = slim, pub = pub }
                        n = n + 1
                    end
                end
                return n
            end
            local added = addNew(posts)
            if added > 0 and err_or_feed ~= "no_offset" then
                -- Paging still works for this publication.
                state.has_more = #posts >= PAGE_SIZE
            elseif added > 0 then
                -- Got the 50-post page; the sitemap is the next (and last) step.
                state.has_more = true
                state.used_big_page = true
            else
                -- Nothing new from the API: use the sitemap, which lists every post.
                Trapper:info(T(_("Loading the full post list for %1…"), pub.name))
                local all, serr = self.net:sitemapPosts(pub.host)
                Trapper:clear()
                added = addNew(all)
                state.has_more = false
                if added == 0 then
                    if menu then menu:switchItemTable(nil, state.rebuild(), -1) end
                    if all then
                        showMsg(T(_("No older posts from %1."), pub.name), 3)
                    else
                        showMsg(T(_("Could not load older posts from %1:\n%2"), pub.name, Net.friendly(serr)))
                    end
                    return
                end
            end
            -- Keep the list in date order after merging.
            table.sort(state.entries, function(a, b)
                return (a.post.post_date or "") > (b.post.post_date or "")
            end)
        end
        if menu then
            menu:switchItemTable(nil, state.rebuild(), offset == 0 and 1 or -1)
        else
            self:showPostList(state)
        end
    end
    local function fetch(menu, offset)
        self:online(function()
            -- An error here would otherwise take the whole list (or KOReader) down silently.
            local ok, e = pcall(fetchInner, menu, offset)
            if not ok then
                Trapper:clear()
                logger.err("Substack: loading posts failed", pub.host, offset, e)
                showMsg(T(_("Something went wrong loading %1:\n%2"), pub.name, tostring(e)))
            end
        end)
    end
    state.refresh = function(menu) fetch(menu, 0) end
    state.load_more = function(menu) fetch(menu, #state.entries) end
    if not self:pubByHost(pub.host) then
        state.extra_top = { { text = T(_("+ Follow %1"), pub.name), keep_open = true, action = function() self:followPub(pub.host, pub.name) end } }
    end
    local c = self:cached(pub.host)
    if c and c.posts and #c.posts > 0 then
        state.entries = entriesFrom(c.posts)
        state.updated = c.fetched
        state.has_more = true -- older posts come from the 50-post page or the sitemap
        self:showPostList(state)
    else
        fetch(nil, 0)
    end
end

function Substack:showLatest()
    if #self.publications == 0 then
        showMsg(_("Follow a publication first (Substack → Publications)."))
        return
    end
    local state = { title = _("Latest posts"), entries = {}, origin = { kind = "latest" } }
    local function fromCache()
        local list, oldest = {}, nil
        for _i, pub in ipairs(self.publications) do
            local c = (not pub.muted) and self:cached(pub.host)
            if c then
                if not oldest or c.fetched < oldest then oldest = c.fetched end
                for j = 1, math.min(10, #(c.posts or {})) do
                    list[#list + 1] = { post = c.posts[j], pub = pub, show_pub = true }
                end
            end
        end
        table.sort(list, function(a, b) return (a.post.post_date or "") > (b.post.post_date or "") end)
        state.entries = list
        state.updated = oldest
        return #list > 0
    end
    local function fetchAll(menu)
        self:online(function()
            local failed = {}
            for i, pub in ipairs(self.publications) do
                if not pub.muted then
                    if not Trapper:info(T(_("Loading %1 (%2 / %3)…"), pub.name, i, #self.publications)) then break end
                    local posts = self.net:archive(pub.host, 0, 10)
                    if posts then self:cachePosts(pub.host, posts) else failed[#failed + 1] = pub.name end
                end
            end
            Trapper:clear()
            fromCache()
            if menu then menu:switchItemTable(nil, state.rebuild(), 1) else self:showPostList(state) end
            if #failed > 0 then showMsg(T(_("Couldn't load: %1"), table.concat(failed, ", "))) end
        end)
    end
    state.refresh = fetchAll
    if fromCache() then self:showPostList(state) else fetchAll(nil) end
end

function Substack:showSavedOnSubstack()
    if not self:isLoggedIn() then
        showMsg(_("Sign in first (Substack → Account). Then posts you bookmark in the Substack app on your phone show up here."))
        return
    end
    self:online(function()
        Trapper:info(_("Loading your saved posts…"))
        local saved, err = self.net:savedPosts(30)
        Trapper:clear()
        if not saved then
            showMsg(T(_("Could not load saved posts:\n%1\n\n(This uses an unofficial Substack feature that may change.)"), Net.friendly(err)))
            return
        end
        local entries = {}
        for _i, s in ipairs(saved) do
            local pub = self:pubByHost(s.host)
            local name = pub and pub.name
                or (type(s.post.publication) == "table" and str(s.post.publication.name))
                or SH.displayName(s.host)
            local p = s.post
            p.slug = p.slug or s.slug
            entries[#entries + 1] = { post = p, pub = { host = s.host, name = name }, show_pub = true }
        end
        self:showPostList({ title = _("Saved on Substack"), entries = entries, origin = { kind = "saved" } })
    end)
end

---------------------------------------------------------------------------
-- Library views (Inbox / Archive / Kept / All)
---------------------------------------------------------------------------

--- nested = true: shown indented under its writer's heading in the grouped Inbox.
function Substack:libraryItem(e, kind, group, nested)
    local a = e.meta
    local origin = { kind = "library", list = kind, group = group and group.key, group_label = group and group.label }
    local rt = SH.readingTime(a.words)
    local state
    if e.status == "reading" then
        state = string.format("%d%%", math.floor((e.percent or 0) * 100))
    elseif e.status == "finished" then
        state = "✓"
    else
        state = _("new")
    end
    if a.kept then state = "★ " .. state end
    return {
        -- Inside one writer's list the name is in the title already.
        text = (nested and "      " or "") .. (a.title or "?")
            .. ((not group and not nested and (a.publication or a.handle))
                and ("  — " .. SH.whoLabel(a.publication, self.library:handleOf(a))) or ""),
        mandatory = state .. (rt and (" · " .. rt) or ""),
        action = function() self:openFile(e.path, origin) end,
        hold_action = function()
            local rows = { { { _("Read"), function() self:openFile(e.path, origin) end } } }
            if e.status == "finished" then
                table.insert(rows, { { _("Mark as unread"), function()
                    self.library:setOverride(e.path, "unread")
                    self:setKOStatus(e.path, nil)
                    self:refreshMenus()
                end } })
            else
                table.insert(rows, { { _("Mark as finished"), function()
                    self.library:setOverride(e.path, "finished")
                    self:setKOStatus(e.path, "complete")
                    self:refreshMenus()
                end } })
            end
            if a.host and a.slug then
                -- Fetch the post again (e.g. after changing the image or comments setting).
                table.insert(rows, { { _("Re-download"), function()
                    local open_file = self.ui and self.ui.document and self.ui.document.file
                    if open_file == e.path then
                        showMsg(_("Close this article first, then re-download it from the Inbox."))
                        return
                    end
                    self:online(function()
                        Trapper:info(T(_("Re-downloading “%1”…"), a.title or a.slug))
                        local saved, err = self:downloadPost(a.host, a.publication or SH.displayName(a.host), { slug = a.slug })
                        Trapper:clear()
                        if saved then
                            self:refreshMenus()
                            showMsg(_("Re-downloaded."), 2)
                        else
                            showMsg(T(_("Could not re-download:\n%1"), tostring(err)))
                        end
                    end)
                end } })
            end
            table.insert(rows, { { a.kept and _("Don't keep") or _("Keep (never auto-delete)"), function()
                self.library:setKept(e.path, not a.kept)
                self:refreshMenus()
            end } })
            if a.host and not self:pubByHost(a.host) then
                table.insert(rows, { { T(_("Follow %1"), a.publication or a.host), function()
                    self:followPub(a.host, a.publication)
                end } })
            end
            table.insert(rows, { { _("Delete"), function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Delete “%1”?"), a.title or ""),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        self.library:delete(e.path)
                        self:refreshMenus()
                    end,
                })
            end } })
            buttonDialog(a.title or "", rows)
        end,
    }
end

local LIST_TITLES = {
    inbox = _("Inbox"), archive = _("Archive (finished)"), kept = _("Kept & highlighted"), all = _("All saved articles"),
    short = _("Short reads"),
}

--- kind: "inbox" | "short" | "archive" | "kept" | "all".
-- group (optional): { key, label } to show only one writer's articles.
function Substack:showLibraryList(kind, group)
    self:scanLibrary()
    local function title()
        if group then
            return T(_("%1 (%2)"), group.label, #self.library:list(kind, group.key))
        end
        if kind == "inbox" then return T(_("Inbox (%1 unread)"), self.library:unreadCount()) end
        if kind == "short" then
            return T(_("Short reads (up to %1 min)"), self.settings:readSetting("short_minutes") or 5)
        end
        return LIST_TITLES[kind]
    end
    local grouped = function()
        return not group and (kind == "inbox" or kind == "all") and self.settings:nilOrTrue("group_by_writer")
    end
    self:newMenu(nil, function()
        self:applyLibraryPrefs()
        local items = {}
        if (kind == "inbox" or kind == "short") and not group then
            -- Sort order (shared by Inbox and Short reads).
            items[#items + 1] = {
                text = T(_("Sort: %1"), SORT_LABELS[self.settings:readSetting("inbox_sort") or "newest"]),
                keep_open = true,
                action = function()
                    local rows = {}
                    for _i, key in ipairs({ "newest", "oldest", "shortest", "publication" }) do
                        rows[#rows + 1] = { { SORT_LABELS[key], function()
                            self.settings:saveSetting("inbox_sort", key)
                            self.settings:flush()
                            self:applyLibraryPrefs()
                            self:refreshMenus()
                        end } }
                    end
                    buttonDialog(_("Sort articles"), rows)
                end,
            }
        end
        if (kind == "inbox" or kind == "all") and not group then
            items[#items + 1] = {
                text = grouped() and _("Grouped by writer (tap for one list)") or _("One list (tap to group by writer)"),
                keep_open = true,
                action = function()
                    self.settings:saveSetting("group_by_writer", not self.settings:nilOrTrue("group_by_writer"))
                    self.settings:flush()
                    self:refreshMenus()
                end,
            }
        end
        if kind == "inbox" and not group then
            local short_n = #self.library:list("short")
            if short_n > 0 then
                items[#items + 1] = {
                    text = T(_("Short reads (up to %1 min): %2"), self.settings:readSetting("short_minutes") or 5, short_n),
                    keep_open = true,
                    action = function() self:showLibraryList("short") end,
                }
            end
            items[#items + 1] = {
                text = T(_("Sync now (last: %1)"), ago(self.settings:readSetting("last_sync"))),
                keep_open = true, -- the Inbox refreshes itself when the sync finishes
                action = function() self:sync() end,
            }
        end
        if (kind == "inbox" or (group and kind ~= "archive")) and self.library:unreadCount() > 0 then
            local gkey = group and group.key
            items[#items + 1] = {
                text = group and _("Mark all from this writer as finished…") or _("Mark all as finished…"),
                keep_open = true,
                action = function()
                    local todo = {}
                    for _i, e in ipairs(self.library:list(kind, gkey)) do
                        if e.status ~= "finished" then todo[#todo + 1] = e end
                    end
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Mark %1 article(s) as finished, including ones you've started? They move to the Archive."), #todo),
                        ok_text = _("Mark finished"),
                        ok_callback = function()
                            for _i, e in ipairs(todo) do
                                self.library:setOverride(e.path, "finished", true)
                                self:setKOStatus(e.path, "complete")
                            end
                            self:refreshMenus()
                        end,
                    })
                end,
            }
        end
        local count
        if grouped() then
            -- Each writer is a heading with their articles listed underneath.
            -- Tap a heading to fold it away (▸) or open it again (▾).
            local groups = self.library:groups(kind)
            count = #groups
            local collapsed = self.settings:readSetting("collapsed_writers") or {}
            local any_open = false
            for _i, g in ipairs(groups) do if not collapsed[g.key] then any_open = true end end
            if #groups > 1 then
                items[#items + 1] = {
                    text = any_open and _("▴ Collapse all writers") or _("▾ Expand all writers"),
                    keep_open = true,
                    action = function()
                        local c = {}
                        if any_open then for _i, g in ipairs(groups) do c[g.key] = true end end
                        self.settings:saveSetting("collapsed_writers", c)
                        self.settings:flush()
                        self:refreshMenus()
                    end,
                }
            end
            for _i, g in ipairs(groups) do
                local label = SH.whoLabel(g.meta.publication, g.handle)
                local parts = {}
                if g.reading > 0 then parts[#parts + 1] = T(_("%1 reading"), g.reading) end
                if g.unread > 0 then parts[#parts + 1] = T(_("%1 new"), g.unread) end
                if #parts == 0 then parts[1] = tostring(g.count) end
                local folded = collapsed[g.key]
                items[#items + 1] = {
                    text = (folded and "▸ " or "▾ ") .. label,
                    mandatory = table.concat(parts, " · "),
                    bold = true,
                    keep_open = true,
                    action = function()
                        local c = self.settings:readSetting("collapsed_writers") or {}
                        c[g.key] = (not c[g.key]) or nil
                        self.settings:saveSetting("collapsed_writers", c)
                        self.settings:flush()
                        self:refreshMenus()
                    end,
                    -- Long-press: just this writer, full screen.
                    hold_action = function() self:showLibraryList(kind, { key = g.key, label = label }) end,
                }
                if not folded then
                    for _j, e in ipairs(g.entries) do
                        items[#items + 1] = self:libraryItem(e, kind, nil, true)
                    end
                end
            end
        else
            local list = self.library:list(kind, group and group.key)
            count = #list
            for _i, e in ipairs(list) do items[#items + 1] = self:libraryItem(e, kind, group) end
        end
        if count == 0 then
            local empty = {
                inbox = _("Nothing to read. Sync, or open a publication and save some posts."),
                archive = _("Finished articles appear here."),
                kept = _("Articles you keep or highlight appear here."),
                all = _("No saved articles yet."),
                short = _("No short articles in your Inbox right now."),
            }
            items[#items + 1] = { text = group and _("Nothing left from this writer.") or empty[kind] }
        end
        return items
    end, title)
end

---------------------------------------------------------------------------
-- Digest
---------------------------------------------------------------------------

--- Unread Inbox articles for a digest (oldest first) and where to save it.
-- days = nil for all unread. Returns items, paths, title, path.
function Substack:collectDigest(days, title)
    self:scanLibrary()
    local cutoff = days and os.date("%Y-%m-%d", os.time() - days * 86400) or nil
    local items, paths = {}, {}
    for _i, e in ipairs(self.library:list("inbox")) do
        local a = e.meta
        local recent = not cutoff or (a.date or "") >= cutoff
        if e.path:match("%.epub$") and e.status == "unread" and recent then
            items[#items + 1] = { path = e.path, title = a.title, publication = a.publication, author = a.author, date = a.date }
            paths[#paths + 1] = e.path
        end
    end
    -- Oldest first reads like a magazine issue.
    table.sort(items, function(x, y) return (x.date or "") < (y.date or "") end)
    local dir = self:getDownloadDir() .. "/Digests"
    mkdirp(dir)
    title = title or T(_("Substack Digest — %1"), os.date("%d %b %Y"))
    local path = dir .. "/" .. SH.safeFilename(title) .. ".epub"
    if lfs.attributes(path, "mode") == "file" then
        path = dir .. "/" .. SH.safeFilename(title .. " " .. os.date("%H%M")) .. ".epub"
    end
    return items, paths, title, path
end

function Substack:createDigest(days)
    local items, paths, title, path = self:collectDigest(days)
    if #items == 0 then
        showMsg(_("No unread articles to put in a digest."))
        return
    end
    Trapper:wrap(function()
        Trapper:info(T(_("Building digest of %1 articles…"), #items))
        local n, err = Epub.buildDigest(path, title, items)
        Trapper:clear()
        if not n then showMsg(T(_("Could not build the digest: %1"), tostring(err))) return end
        buttonDialog(T(_("Digest ready with %1 articles."), n), {
            { { _("Open digest & move articles to Archive"), function()
                for _j, p in ipairs(paths) do self.library:setOverride(p, "finished", true) end
                self:openFile(path, { kind = "digests" })
            end } },
            { { _("Open digest, keep articles in Inbox"), function() self:openFile(path, { kind = "digests" }) end } },
            { { _("Close"), function() end } },
        })
    end)
end

--- Weekly digest, built during sync (already inside Trapper). Runs on the
-- first sync on a Monday, or if a week has passed. Returns the path or nil.
function Substack:maybeWeeklyDigest()
    if not self.settings:isTrue("weekly_digest") then return nil end
    local now = os.time()
    local last = self.settings:readSetting("last_weekly_digest")
    local monday = os.date("*t", now).wday == 2
    local due = (monday and (not last or now - last > 2 * 86400)) or (last and now - last >= 8 * 86400)
    if not due then return nil end
    local items, _paths, title, path = self:collectDigest(7, T(_("Weekly Substack — %1"), os.date("%d %b %Y")))
    self.settings:saveSetting("last_weekly_digest", now)
    self.settings:flush()
    if #items < 2 then return nil end -- not worth a digest
    Trapper:info(T(_("Building your weekly digest (%1 articles)…"), #items))
    local n = Epub.buildDigest(path, title, items)
    return n and path or nil
end

--- Saved digests, newest first. Works offline.
function Substack:showDigests()
    local dir = self:getDownloadDir() .. "/Digests"
    local function build()
        local files = {}
        if lfs.attributes(dir, "mode") == "directory" then
            for name in lfs.dir(dir) do
                if name:match("%.epub$") then
                    local full = dir .. "/" .. name
                    files[#files + 1] = { path = full, name = name:gsub("%.epub$", ""),
                                          t = lfs.attributes(full, "modification") or 0 }
                end
            end
        end
        table.sort(files, function(a, b) return a.t > b.t end)
        local items = {}
        for _i, f in ipairs(files) do
            items[#items + 1] = {
                text = f.name,
                mandatory = os.date("%Y-%m-%d", f.t),
                action = function() self:openFile(f.path, { kind = "digests" }) end,
                hold_action = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Delete “%1”?"), f.name),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            os.remove(f.path)
                            local sdr = f.path:gsub("%.epub$", ".sdr")
                            if lfs.attributes(sdr, "mode") == "directory" then
                                for n in lfs.dir(sdr) do
                                    if n ~= "." and n ~= ".." then os.remove(sdr .. "/" .. n) end
                                end
                                lfs.rmdir(sdr)
                            end
                            self:refreshMenus()
                        end,
                    })
                end,
            }
        end
        if #items == 0 then items[1] = { text = _("No digests yet. Make one, or turn on the weekly digest in Settings.") } end
        return items
    end
    self:newMenu(_("Digests"), build)
end

---------------------------------------------------------------------------
-- Exports: highlights, backup & restore
---------------------------------------------------------------------------

function Substack:exportsDir()
    local dir = self:getDownloadDir() .. "/Exports"
    mkdirp(dir)
    return dir
end

local function writeFile(path, content)
    local fh = io.open(path, "wb")
    if not fh then return nil end
    fh:write(content)
    fh:close()
    return true
end

local function readFile(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local content = fh:read("*a")
    fh:close()
    return content
end

--- All highlights and notes from Substack articles, as one Markdown file.
function Substack:exportHighlights()
    self:scanLibrary()
    local articles = {}
    for _i, e in ipairs(self.library:list("all")) do
        local hl = {}
        if e.highlights then
            local ok, ds = pcall(DocSettings.open, DocSettings, e.path)
            if ok and ds then
                hl = Export.readHighlights(function(k) return ds:readSetting(k) end)
            end
        end
        if #hl > 0 then
            local a = e.meta
            articles[#articles + 1] = { title = a.title, author = a.author, publication = a.publication,
                                        url = a.url, date = a.date, highlights = hl }
        end
    end
    table.sort(articles, function(x, y) return (x.date or "") > (y.date or "") end)
    local md, total = Export.highlightsMarkdown(articles)
    if total == 0 then
        showMsg(_("No highlights yet. Highlight text in a Substack article, then export again."))
        return
    end
    local path = self:exportsDir() .. "/substack-highlights-" .. os.date("%Y-%m-%d") .. ".md"
    if not writeFile(path, md) then showMsg(T(_("Could not write %1"), path)) return end
    showMsg(T(_("Exported %1 highlight(s) from %2 article(s) to:\n\n%3\n\nConnect the device by USB to copy it (koreader/substack/Exports)."),
        total, #articles, path))
end

-- Settings a "reset to defaults" clears: everything the Settings menu sets.
-- Not publications, sign-in (cookie, email) or the download folder.
local DEFAULT_RESET_KEYS = {
    "auto_sync", "weekly_digest", "per_pub", "image_quality", "comments", "podcasts",
    "end_prompt", "hide_from_history", "cleanup_days", "short_minutes", "inbox_sort",
    "weekly_goal", "sync_saved", "max_per_sync", "wifi_off_after_sync", "return_to_bookshelf",
    "sync_days", "group_by_writer", "collapsed_writers",
}

local BACKUP_SETTINGS = {
    "auto_sync", "per_pub", "image_quality", "comments", "end_prompt", "hide_from_history",
    "cleanup_days", "sync_saved", "weekly_digest", "short_minutes", "inbox_sort", "weekly_goal", "podcasts", "max_per_sync", "wifi_off_after_sync", "return_to_bookshelf",
    "sync_days", "group_by_writer",
}

--- Saves publications (OPML, readable by any feed reader) and settings
-- (never the sign-in) to the Exports folder.
function Substack:backup()
    local dir = self:exportsDir()
    local pubs = {}
    for _i, p in ipairs(self.publications) do
        pubs[#pubs + 1] = { host = p.host, name = p.name, id = p.id, auto = p.auto, muted = p.muted,
                            handle = p.handle, author = p.author }
    end
    local people = {}
    for _i, p in ipairs(self.people) do
        people[#people + 1] = { id = p.id, name = p.name, handle = p.handle, auto = p.auto, muted = p.muted }
    end
    local settings = {}
    for _i, k in ipairs(BACKUP_SETTINGS) do settings[k] = self.settings:readSetting(k) end
    local ok1 = writeFile(dir .. "/substack-publications.opml", Export.opml(pubs))
    local ok2 = writeFile(dir .. "/substack-backup.lua",
        "-- Substack for KOReader backup (" .. os.date("%Y-%m-%d %H:%M") .. "). No sign-in details.\n"
        .. Export.serialize({ version = VERSION, publications = pubs, people = people, settings = settings }) .. "\n")
    if not (ok1 and ok2) then showMsg(_("Could not write the backup files.")) return end
    showMsg(T(_("Backed up %1 publication(s) and your settings to:\n\n%2\n\n• substack-backup.lua: everything, for this plugin\n• substack-publications.opml: your publications, for any feed reader\n\nYour sign-in is not included."),
        #pubs, dir))
end

--- Merges publications (and, from a .lua backup, settings) into the current setup.
function Substack:restoreFrom(path)
    local content = readFile(path)
    if not content then showMsg(T(_("Can't open %1"), path)) return end
    local added, restored_settings = 0, false
    local function addPub(host, name, extra)
        if not host or self:pubByHost(host) then return end
        local p = { host = host, name = name or SH.displayName(host) }
        if extra then
            p.id, p.auto, p.muted = extra.id, extra.auto, extra.muted
            p.handle, p.author = extra.handle, extra.author
        end
        table.insert(self.publications, p)
        added = added + 1
    end
    if path:lower():match("%.opml$") or path:lower():match("%.xml$") then
        for _i, f in ipairs(Export.parseOpml(content)) do
            local host = SH.normalizeHost(f.url)
            -- Only Substack-style feeds (https://host/feed) can be followed here.
            if host and f.url:match("/feed/?$") then addPub(host, f.name) end
        end
    else
        local data, err = Export.deserialize(content)
        if not data then showMsg(T(_("That isn't a backup file from this plugin (%1)."), tostring(err))) return end
        for _i, p in ipairs(type(data.publications) == "table" and data.publications or {}) do
            if type(p) == "table" and type(p.host) == "string" then addPub(SH.normalizeHost(p.host), p.name, p) end
        end
        for _i, p in ipairs(type(data.people) == "table" and data.people or {}) do
            if type(p) == "table" and tonumber(p.id) and not self:personById(p.id) then
                table.insert(self.people, { id = tonumber(p.id), name = p.name, handle = p.handle, auto = p.auto, muted = p.muted })
            end
        end
        if type(data.settings) == "table" then
            for _i, k in ipairs(BACKUP_SETTINGS) do
                if data.settings[k] ~= nil then self.settings:saveSetting(k, data.settings[k]) end
            end
            restored_settings = true
        end
    end
    table.sort(self.publications, function(a, b) return a.name:lower() < b.name:lower() end)
    self:saveSettings()
    self:applyLibraryPrefs()
    self:refreshMenus()
    showMsg(T(_("Restored: %1 new publication(s)."), added)
        .. (restored_settings and ("\n" .. _("Settings restored.")) or "")
        .. "\n" .. T(_("You now follow %1."), #self.publications))
end

function Substack:restoreDialog()
    local PathChooser = require("ui/widget/pathchooser")
    local start = self:exportsDir()
    UIManager:show(PathChooser:new{
        select_directory = false,
        select_file = true,
        file_filter = function(name)
            local n = name:lower()
            return n:match("%.lua$") or n:match("%.opml$") or n:match("%.xml$")
        end,
        path = start,
        onConfirm = function(path) self:restoreFrom(path) end,
    })
end

---------------------------------------------------------------------------
-- Dashboard ("My reading")
---------------------------------------------------------------------------

--- Builds the reading dashboard page and opens it. It's saved in the hidden
-- Substack folder (Reports/) and kept out of KOReader's history like articles,
-- so it never shows up on the bookshelf or home screen.
function Substack:showDashboard()
    self:scanLibrary()
    Trapper:wrap(function()
        Trapper:info(_("Putting your reading stats together…"))
        local stats = Export.computeStats(self.library:allEvents())
        local all = self.library:list("all")
        local highlights, hl_articles, kept = 0, 0, 0
        for _i, e in ipairs(all) do
            if e.meta.kept then kept = kept + 1 end
            if e.highlights then
                local ok, ds = pcall(DocSettings.open, DocSettings, e.path)
                if ok and ds then
                    local n = #Export.readHighlights(function(k) return ds:readSetting(k) end)
                    if n > 0 then
                        highlights = highlights + n
                        hl_articles = hl_articles + 1
                    end
                end
            end
        end
        local muted = 0
        for _i, p in ipairs(self.publications) do if p.muted then muted = muted + 1 end end
        local html = Export.dashboardHtml(stats, {
            unread = self.library:unreadCount(), saved = #all,
            following = #self.publications, muted = muted,
            highlights = highlights, highlighted_articles = hl_articles, kept = kept,
            goal = self.settings:readSetting("weekly_goal") or 5,
        })
        local dir = self:getDownloadDir() .. "/Reports"
        mkdirp(dir)
        local path = dir .. "/My reading.html"
        -- KOReader caches a rendered copy and remembers the position: start
        -- fresh each time so the page shows today's numbers from the top.
        local sdr = path:gsub("%.html$", ".sdr")
        if lfs.attributes(sdr, "mode") == "directory" then
            for n in lfs.dir(sdr) do
                if n ~= "." and n ~= ".." then os.remove(sdr .. "/" .. n) end
            end
            lfs.rmdir(sdr)
        end
        local fh = io.open(path, "wb")
        Trapper:clear()
        if not fh then showMsg(T(_("Could not write %1"), path)) return end
        fh:write(html)
        fh:close()
        self:openFile(path, false)
    end)
end

---------------------------------------------------------------------------
-- Publications & discovery
---------------------------------------------------------------------------

function Substack:addPublication(input, on_done)
    local host = SH.normalizeHost(input)
    if not host then
        showMsg(_("That doesn't look like a Substack name or address."))
        return
    end
    if self:pubByHost(host) then
        showMsg(T(_("%1 is already in your list."), self:pubByHost(host).name))
        return
    end
    self:online(function()
        Trapper:info(T(_("Checking %1…"), host))
        local posts, err = self.net:archive(host, 0, 12)
        Trapper:clear()
        if not posts then
            showMsg(T(_("Could not add %1:\n%2"), host, Net.friendly(err)))
            return
        end
        self:cachePosts(host, posts)
        self:followPub(host, SH.displayName(host), on_done)
    end)
end

function Substack:addPublicationDialog(on_done)
    local dialog
    dialog = InputDialog:new{
        title = _("Add Substack publication"),
        description = _("Enter a Substack name (e.g. astralcodexten), a xyz.substack.com address, or a custom domain."),
        input_hint = "example.substack.com",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Add"), is_enter_default = true, callback = function()
                local text = dialog:getInputText()
                UIManager:close(dialog)
                self:addPublication(text, on_done)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Substack:showPublications()
    local menu
    local function build()
        local items = { { text = _("+ Add publication…"), keep_open = true, action = function()
            self:addPublicationDialog(function() if menu then menu:switchItemTable(nil, build()) end end)
        end } }
        if self:isLoggedIn() then
            items[#items + 1] = { text = _("+ Import my subscriptions & the people I follow"), keep_open = true, action = function() self:importSubscriptions() end }
        end
        if #self.people > 0 then
            items[#items + 1] = {
                text = T(_("People you follow (%1) ›"), #self.people),
                mandatory = _("no publication"),
                keep_open = true,
                action = function() self:showPeople() end,
            }
        end
        for i, pub in ipairs(self.publications) do
            local c = self:cached(pub.host)
            local latest = c and c.posts and c.posts[1] and postDate(c.posts[1])
            items[#items + 1] = {
                text = pubLabel(pub) .. (pub.muted and _("  (muted)") or (pub.auto == false and _("  (no auto-download)") or "")),
                mandatory = latest or "",
                -- Keep the publication list underneath, so Back returns to it.
                keep_open = true,
                action = function() self:showArchive(pub) end,
                hold_action = function()
                    buttonDialog(pubLabel(pub) .. "\n" .. pub.host, {
                        { { pub.muted and _("Unmute") or _("Mute (hide from Inbox, no downloads)"), function()
                            -- Muted: still browsable here, but nothing lands in the Inbox.
                            pub.muted = (not pub.muted) or nil
                            self:saveSettings()
                            self:applyLibraryPrefs()
                            menu:switchItemTable(nil, build(), -1)
                            showMsg(pub.muted and T(_("%1 muted. Its posts stay out of your Inbox; open it here any time."), pub.name)
                                or T(_("%1 unmuted."), pub.name), 2)
                        end } },
                        { { pub.auto == false and _("Turn on auto-download on sync") or _("Turn off auto-download on sync"), function()
                            pub.auto = (pub.auto == false) and nil or false
                            self:saveSettings()
                            menu:switchItemTable(nil, build(), -1)
                        end } },
                        { { T(_("Publications %1 recommends"), pub.name), function() self:showRecommendations({ pub }) end } },
                        { { _("Unfollow"), function()
                            UIManager:show(ConfirmBox:new{
                                text = T(_("Stop following %1? Saved articles stay."), pub.name),
                                ok_text = _("Unfollow"),
                                ok_callback = function()
                                    table.remove(self.publications, i)
                                    self:saveSettings()
                                    menu:switchItemTable(nil, build(), -1)
                                end,
                            })
                        end } },
                    })
                end,
            }
        end
        if #self.publications == 0 then
            items[#items + 1] = { text = _("You don't follow any publications yet.") }
        end
        return items
    end
    menu = self:newMenu(T(_("Publications (%1)"), #self.publications), build)
    menu.rebuild_title = function() return T(_("Publications (%1)"), #self.publications) end
end

--- People you follow who have no publication of their own.
function Substack:showPeople()
    local menu
    local function build()
        local items = {}
        for i, person in ipairs(self.people) do
            local who = SH.whoLabel(person.name, person.handle)
            items[#items + 1] = {
                text = who .. (person.muted and _("  (muted)") or (person.auto == false and _("  (no auto-download)") or "")),
                keep_open = true,
                action = function() self:showPerson(person) end,
                hold_action = function()
                    buttonDialog(who, {
                        { { person.muted and _("Unmute") or _("Mute (no downloads)"), function()
                            person.muted = (not person.muted) or nil
                            self:saveSettings()
                            menu:switchItemTable(nil, build(), -1)
                        end } },
                        { { _("Unfollow (on this device)"), function()
                            UIManager:show(ConfirmBox:new{
                                text = T(_("Stop syncing %1 here? Saved articles stay. (This doesn't unfollow them on Substack.)"), who),
                                ok_text = _("Unfollow"),
                                ok_callback = function()
                                    table.remove(self.people, i)
                                    self:saveSettings()
                                    menu:switchItemTable(nil, build(), -1)
                                end,
                            })
                        end } },
                    })
                end,
            }
        end
        if #self.people == 0 then items[#items + 1] = { text = _("Nobody here. Import the people you follow from Publications.") } end
        return items
    end
    menu = self:newMenu(T(_("People you follow (%1)"), #self.people), build)
end

--- A person's recent posts (from their Substack profile).
function Substack:showPerson(person)
    local who = SH.whoLabel(person.name, person.handle)
    self:online(function()
        Trapper:info(T(_("Loading %1…"), who))
        local feed, err = self.net:profileFeed(person.id)
        Trapper:clear()
        if not feed then
            showMsg(T(_("Could not load %1:\n%2"), who, Net.friendly(err)))
            return
        end
        local entries = {}
        for _i, e in ipairs(feed.posts) do
            local followed = self:pubByHost(e.host)
            entries[#entries + 1] = {
                post = e.post, show_pub = true,
                pub = { host = e.host, name = followed and followed.name or e.pub_name or SH.displayName(e.host), handle = person.handle },
            }
        end
        self:showPostList({ title = who, entries = entries, origin = { kind = "person", id = person.id } })
    end)
end

--- Shows a list of publications (search results, recommendations).
function Substack:showPubList(title, pubs, note)
    self:newMenu(title, function()
        local items = {}
        if note then items[#items + 1] = { text = note } end
        for _i, p in ipairs(pubs) do
            local following = self:pubByHost(p.host) ~= nil
            items[#items + 1] = {
                text = p.name .. (p.description and ("  — " .. p.description) or ""),
                mandatory = following and _("following") or (p.count and p.count > 1 and ("×" .. p.count) or ""),
                keep_open = true, -- Back returns to these results
                action = function() self:showArchive({ host = p.host, name = p.name }) end,
                hold_action = function()
                    if following then
                        showMsg(T(_("You already follow %1."), p.name), 2)
                    else
                        self:followPub(p.host, p.name)
                    end
                end,
            }
        end
        if #pubs == 0 then items[#items + 1] = { text = _("Nothing found.") } end
        return items
    end)
end

function Substack:searchDialog()
    if not self:isLoggedIn() then
        showMsg(_("Substack only allows search for signed-in users. Sign in under Substack → Account first."))
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Search Substack publications"),
        input_hint = _("e.g. economics, design, cooking"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local q = SH.trim(dialog:getInputText() or "")
                UIManager:close(dialog)
                if q == "" then return end
                self:online(function()
                    Trapper:info(T(_("Searching for “%1”…"), q))
                    local pubs, err = self.net:searchPublications(q)
                    Trapper:clear()
                    if not pubs then showMsg(T(_("Search failed:\n%1"), Net.friendly(err))) return end
                    self:showPubList(T(_("Results for “%1”"), q), pubs, _("Tap to preview · long-press to follow"))
                end)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Recommendations from the given publications (default: up to 8 you follow), ranked by how often they're recommended.
function Substack:showRecommendations(sources)
    sources = sources or self.publications
    if #sources == 0 then showMsg(_("Follow some publications first.")) return end
    self:online(function()
        local counts, order = {}, {}
        local limit = math.min(#sources, 8)
        for i = 1, limit do
            local pub = sources[i]
            if not Trapper:info(T(_("Asking %1 for recommendations (%2 / %3)…"), pub.name, i, limit)) then break end
            local id = pub.id
            if not id then
                local c = self:cached(pub.host)
                id = c and c.posts and c.posts[1] and c.posts[1].publication_id
                if not id then
                    local posts = self.net:archive(pub.host, 0, 1)
                    id = posts and posts[1] and posts[1].publication_id
                end
            end
            if id then
                local recs = self.net:recommendations(pub.host, id)
                for _i, r in ipairs(recs or {}) do
                    if not counts[r.host] then
                        counts[r.host] = r
                        r.count = 0
                        order[#order + 1] = r
                    end
                    counts[r.host].count = counts[r.host].count + 1
                end
            end
        end
        Trapper:clear()
        local list = {}
        for _i, r in ipairs(order) do
            if not self:pubByHost(r.host) then list[#list + 1] = r end
        end
        table.sort(list, function(a, b) return a.count > b.count end)
        local title = #sources == 1 and T(_("Recommended by %1"), sources[1].name) or _("Recommended for you")
        self:showPubList(title, list, _("Tap to preview · long-press to follow"))
    end)
end

function Substack:login(email, password)
    self:online(function()
        Trapper:info(_("Signing in to Substack…"))
        local sid, err = self.net:login(email, password)
        Trapper:clear()
        if sid then
            self.settings:saveSetting("cookie", sid)
            self.settings:saveSetting("email", email)
            self.settings:flush()
            UIManager:show(ConfirmBox:new{
                text = _("Signed in.\n\nImport the publications you subscribe to and the people you follow?"),
                ok_text = _("Import"),
                ok_callback = function() self:importSubscriptions() end,
            })
            return
        end
        local hint
        if tostring(err):lower():find("captcha") then
            hint = _("Substack wants a captcha. Use Account → Paste session cookie instead.")
        else
            hint = _("No password, or forgot it? Use Account → Sign in with an email code instead.")
        end
        showMsg(T(_("Sign-in failed: %1"), tostring(err)) .. "\n\n" .. hint)
    end)
end

function Substack:loginDialog()
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Sign in to Substack"),
        fields = {
            { description = _("Email"), text = self.settings:readSetting("email") or "", hint = "you@example.com" },
            { description = _("Password"), text = "", hint = _("password"), text_type = "password" },
        },
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Sign in"), is_enter_default = true, callback = function()
                local f = dialog:getFields()
                local email = SH.trim(f[1] or "")
                local password = f[2] or ""
                if email == "" or password == "" then
                    showMsg(_("Please enter your email and password."))
                    return
                end
                UIManager:close(dialog)
                self:login(email, password)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Saves a new session and offers to import subscriptions.
function Substack:signedIn(sid, email)
    self.settings:saveSetting("cookie", sid)
    self.settings:saveSetting("email", email)
    self.settings:flush()
    UIManager:show(ConfirmBox:new{
        text = _("Signed in.\n\nImport the publications you subscribe to and the people you follow?"),
        ok_text = _("Import"),
        ok_callback = function() self:importSubscriptions() end,
    })
end

--- Sign-in with a 6-digit code emailed by Substack (no password needed).
--- Sign-in with a 6-digit email code.
-- Substack only *sends* codes to real browsers (requests from the e-reader get
-- an empty reply and no email), but it accepts the code from anywhere. So the
-- code is requested on the phone and typed in here.
function Substack:emailCodeDialog()
    local dialog
    local function next_step()
        local email = SH.trim(dialog:getInputText() or "")
        if email == "" then
            showMsg(_("Type your email address in the box first."))
            return
        end
        if not email:match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then
            showMsg(_("That doesn't look like an email address. Check it and try again."))
            return
        end
        self.settings:saveSetting("email", email)
        self.settings:flush()
        UIManager:close(dialog)
        self:online(function()
            -- Pick up Substack's session cookie like a browser would.
            local jar = self.net:collectCookies("https://substack.com/sign-in")
            UIManager:nextTick(function()
                self:enterCodeDialog({ email = email, jar = jar, external = true })
            end)
        end)
    end
    dialog = InputDialog:new{
        title = _("Sign in with an email code"),
        description = _("1. On your phone, open substack.com/sign-in in the browser (not the Substack app), enter your email and ask for a code.\n2. Don't type the code on the phone.\n3. Enter your email below, tap Next, and type the code here."),
        input = self.settings:readSetting("email") or "",
        input_hint = "you@example.com",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Next"), is_enter_default = true, callback = next_step },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Substack:enterCodeDialog(state)
    local dialog
    dialog = InputDialog:new{
        title = _("Enter your code"),
        description = (state.external
                and T(_("Type the 6-digit code Substack emailed to %1. Use it within 10 minutes, and don't enter it anywhere else."), state.email)
                or T(_("Substack sent a 6-digit code to %1. It can take a minute. In Gmail, look in the Updates tab (and spam). The subject is “123456 is your Substack verification code”."), state.email))
            .. ((state.reply and state.reply.verification_code == nil and state.raw)
                and ("\n\n" .. T(_("Substack replied: %1"), tostring(state.raw):sub(1, 200))) or ""),
        input = "",
        input_hint = "123456",
        input_type = "number",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Need a new code?"), callback = function()
                showMsg(_("Ask for a new code at substack.com/sign-in in your phone's browser, then type the newest code here."))
            end },
            { text = _("Sign in"), is_enter_default = true, callback = function()
                local otp = (dialog:getInputText() or ""):gsub("%D", "")
                if #otp ~= 6 then
                    showMsg(_("The code has 6 digits."))
                    return
                end
                UIManager:close(dialog)
                self:online(function()
                    Trapper:info(_("Signing in to Substack…"))
                    local sid, err = self.net:completeEmailCode(state, otp)
                    Trapper:clear()
                    if sid then
                        self:signedIn(sid, state.email)
                    else
                        UIManager:show(ConfirmBox:new{
                            text = T(_("Sign-in failed: %1\n\nThe code may be wrong or expired. Try again?"), tostring(err)),
                            ok_text = _("Try again"),
                            ok_callback = function() self:enterCodeDialog(state) end,
                        })
                    end
                end)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Adds one publication found while importing (or fills in who writes it).
-- Returns true if it was new.
function Substack:addImportedPub(p, extra)
    local existing = self:pubByHost(p.host)
    if existing then
        existing.handle = existing.handle or p.handle or (extra and extra.handle)
        existing.author = existing.author or p.author or (extra and extra.author)
        return false
    end
    table.insert(self.publications, {
        host = p.host, name = p.name or SH.displayName(p.host), id = p.id,
        handle = p.handle or (extra and extra.handle), author = p.author or (extra and extra.author),
        via = extra and extra.via or nil,
    })
    return true
end

--- Imports both kinds of "following" on Substack, which are separate there:
-- 1. publications you subscribe to (/subscriptions), and
-- 2. people you follow (/feed/following). For each person, their own
--    publication is added; people without one are followed directly and
--    their posts arrive with each sync.
-- Must run inside Trapper. Returns a summary table, or nil, err.
function Substack:doImport()
    local r = { pubs = 0, people_pubs = 0, people = 0, people_total = 0, missed = 0 }
    Trapper:info(_("Fetching the publications you subscribe to…"))
    local pubs, err = self.net:subscriptions()
    if not pubs then return nil, err end
    r.subscribed = #pubs
    for _i, p in ipairs(pubs) do
        if self:addImportedPub(p) then r.pubs = r.pubs + 1 end
    end
    self:saveSettings()

    if not Trapper:info(_("Fetching the people you follow…")) then return r end
    local ids, ferr = self.net:followingIds()
    if not ids then
        r.people_error = ferr
        return r
    end
    r.people_total = #ids
    for i, uid in ipairs(ids) do
        if not Trapper:info(T(_("Looking up the people you follow… %1 / %2\n\nTap to stop."), i, #ids)) then
            r.stopped = true
            break
        end
        local person = self.net:person(uid)
        if not person then
            r.missed = r.missed + 1
        elseif #person.publications > 0 then
            for _j, pub in ipairs(person.publications) do
                if self:addImportedPub(pub, { handle = person.handle, author = person.name, via = "following" }) then
                    r.people_pubs = r.people_pubs + 1
                end
            end
            -- Their own publication covers them now.
            for k = #self.people, 1, -1 do
                if tonumber(self.people[k].id) == tonumber(uid) then table.remove(self.people, k) end
            end
        else
            local known = self:personById(uid)
            if known then
                known.name = person.name or known.name
                known.handle = person.handle or known.handle
            else
                table.insert(self.people, { id = tonumber(uid), name = person.name, handle = person.handle })
                r.people = r.people + 1
            end
        end
        if i % 10 == 0 then self:saveSettings() end
    end
    table.sort(self.people, function(a, b)
        return SH.whoLabel(a.name, a.handle):lower() < SH.whoLabel(b.name, b.handle):lower()
    end)
    return r
end

function Substack:importSubscriptions()
    if not self:isLoggedIn() then showMsg(_("Sign in first.")) return end
    self:online(function()
        local r, err = self:doImport()
        Trapper:clear()
        if not r then
            showMsg(T(_("Could not fetch subscriptions:\n%1"), Net.friendly(err)))
            return
        end
        table.sort(self.publications, function(a, b) return a.name:lower() < b.name:lower() end)
        self:saveSettings()
        self:applyLibraryPrefs()
        self:refreshMenus()
        local lines = {
            T(_("Publications you subscribe to: %1 new."), r.pubs),
        }
        if r.people_error then
            lines[#lines + 1] = T(_("Couldn't fetch the people you follow:\n%1"), Net.friendly(r.people_error))
        else
            lines[#lines + 1] = T(_("People you follow: %1."), r.people_total)
            lines[#lines + 1] = T(_("• %1 new publication(s) written by them"), r.people_pubs)
            lines[#lines + 1] = T(_("• %1 writer(s) without a publication of their own, followed directly"), r.people)
            if r.missed > 0 then lines[#lines + 1] = T(_("• %1 couldn't be looked up"), r.missed) end
            if r.stopped then lines[#lines + 1] = _("(Stopped early. Import again to finish.)") end
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = T(_("You now follow %1 publication(s) and %2 writer(s)."), #self.publications, #self.people)
        lines[#lines + 1] = ""
        lines[#lines + 1] = T(_("Sync now? (Downloads posts from: %1)"), self:syncWindowLabel())
        UIManager:show(ConfirmBox:new{
            text = table.concat(lines, "\n"),
            ok_text = _("Sync now"),
            ok_callback = function() self:sync() end,
        })
    end)
end

function Substack:cookieDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Substack session cookie"),
        description = _("Alternative to signing in. On a computer, sign in to substack.com, open the browser's developer tools → Storage/Application → Cookies, and copy the value of “connect.sid” (older accounts: “substack.sid”). Leave empty to remove."),
        input = self.settings:readSetting("cookie") or "",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local v = SH.trim(dialog:getInputText() or "")
                if v == "" then self.settings:delSetting("cookie") else self.settings:saveSetting("cookie", v) end
                self.settings:flush()
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local COOKIE_FILE = "substack_cookie.txt"

--- Places a user is likely to drop substack_cookie.txt over USB.
function Substack:cookieFileCandidates()
    local list, seen = {}, {}
    local function add(dir)
        if dir and dir ~= "" and not seen[dir] then
            seen[dir] = true
            list[#list + 1] = dir .. "/" .. COOKIE_FILE
        end
    end
    add(G_reader_settings:readSetting("home_dir"))
    add("/mnt/us")                       -- Kindle USB root
    add("/mnt/us/documents")             -- Kindle documents folder
    add("/mnt/onboard")                  -- Kobo USB root
    add(DataStorage:getDataDir())        -- KOReader folder
    add(self:getDownloadDir())           -- the Substack articles folder
    add(self.path)                       -- the plugin's own folder (substack.koplugin)
    return list
end

--- Reads a session cookie from a text file. Returns the cleaned
-- "substack.sid=…" string, or nil, message.
function Substack:readCookieFile(path)
    local fh = io.open(path, "rb")
    if not fh then return nil, T(_("Can't open %1"), path) end
    local content = fh:read("*a") or ""
    fh:close()
    -- Strip a UTF-8 byte-order mark and surrounding whitespace (editors add these).
    content = content:gsub("^\239\187\191", "")
    -- Drop instruction lines (the template ships with "#" comments) and blank lines.
    local kept = {}
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        local l = SH.trim((line:gsub("\r", "")))
        if l ~= "" and l:sub(1, 1) ~= "#" then kept[#kept + 1] = l end
    end
    content = table.concat(kept, "")
    if content:find("PASTE_YOUR_SUBSTACK_SID") then
        return nil, _("The cookie file still has the placeholder text. Replace PASTE_YOUR_SUBSTACK_SID_VALUE_HERE with your connect.sid (or substack.sid) value.")
    end
    local cookie = Net.cleanCookie(SH.trim(content))
    if not cookie then
        return nil, _("That file doesn't contain a session value. Put only the connect.sid (or substack.sid) value in it, or connect.sid=value.")
    end
    return cookie
end

function Substack:useCookieFile(path)
    local cookie, err = self:readCookieFile(path)
    if not cookie then showMsg(err) return end
    local previous = self.settings:readSetting("cookie")
    self.settings:saveSetting("cookie", cookie)
    self.settings:flush()
    self:online(function()
        Trapper:info(_("Checking your session with Substack…"))
        local ok, verr = self.net:verifySession()
        Trapper:clear()
        if not ok then
            -- Don't claim to be signed in with a session Substack rejects.
            if previous then self.settings:saveSetting("cookie", previous) else self.settings:delSetting("cookie") end
            self.settings:flush()
            showMsg(T(_("Substack didn't accept the cookie in:\n%1\n\n%2"), path, Net.friendly(verr)))
            return
        end
        self:cookieAccepted(path)
    end)
end

function Substack:cookieAccepted(path)
    UIManager:show(ConfirmBox:new{
        text = T(_("Signed in with the cookie from:\n%1\n\nThis file works like a password. Delete it from the device now?"), path),
        ok_text = _("Delete file"),
        cancel_text = _("Keep it"),
        ok_callback = function()
            os.remove(path)
            UIManager:show(ConfirmBox:new{
                text = _("File deleted.\n\nImport the publications you subscribe to and the people you follow?"),
                ok_text = _("Import"),
                ok_callback = function() self:importSubscriptions() end,
            })
        end,
        cancel_callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Import the publications you subscribe to and the people you follow?"),
                ok_text = _("Import"),
                ok_callback = function() self:importSubscriptions() end,
            })
        end,
    })
end

--- Looks for substack_cookie.txt in the usual places; if none, lets the user pick a file.
function Substack:cookieFromFile()
    for _i, path in ipairs(self:cookieFileCandidates()) do
        if lfs.attributes(path, "mode") == "file" then
            self:useCookieFile(path)
            return
        end
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("No %1 found.\n\nCopy it over USB to the top level of the Kindle, the Substack articles folder or the substack.koplugin folder, or pick the file yourself."), COOKIE_FILE),
        ok_text = _("Pick file…"),
        ok_callback = function()
            local PathChooser = require("ui/widget/pathchooser")
            UIManager:show(PathChooser:new{
                select_directory = false,
                select_file = true,
                file_filter = function(name) return name:lower():match("%.txt$") ~= nil end,
                path = G_reader_settings:readSetting("home_dir") or "/",
                onConfirm = function(path) self:useCookieFile(path) end,
            })
        end,
    })
end

function Substack:accountMenu()
    local items = {}
    if self:isLoggedIn() then
        table.insert(items, { text = _("Check sign-in"), callback = function()
            self:online(function()
                Trapper:info(_("Checking your session with Substack…"))
                local ok, err = self.net:verifySession()
                Trapper:clear()
                if ok then
                    showMsg(_("You're signed in, and Substack accepts your session."), 3)
                else
                    showMsg(T(_("Substack didn't accept your session:\n%1\n\nSign out and sign in again."), Net.friendly(err)))
                end
            end)
        end })
        table.insert(items, { text = _("Import my subscriptions & the people I follow"), callback = function() self:importSubscriptions() end })
        table.insert(items, {
            text = _("Include posts I save in the Substack app when syncing"),
            checked_func = function() return self.settings:nilOrTrue("sync_saved") end,
            callback = function()
                self.settings:saveSetting("sync_saved", not self.settings:nilOrTrue("sync_saved"))
                self.settings:flush()
            end,
        })
        table.insert(items, { text = _("Sign out"), callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Sign out of Substack on this device?"),
                ok_text = _("Sign out"),
                ok_callback = function()
                    self.settings:delSetting("cookie")
                    -- Keep the email address: it pre-fills the next sign-in.
                    self.settings:flush()
                    showMsg(_("Signed out."), 2)
                end,
            })
        end })
    else
        table.insert(items, { text = _("Sign in with an email code…"), callback = function() self:emailCodeDialog() end })
        table.insert(items, { text = _("Sign in with email & password…"), callback = function() self:loginDialog() end })
    end
    table.insert(items, { text = T(_("Load session cookie from file (%1)…"), COOKIE_FILE), callback = function() self:cookieFromFile() end })
    table.insert(items, { text = _("Paste session cookie (advanced)…"), separator = true, callback = function() self:cookieDialog() end })
    return items
end

---------------------------------------------------------------------------
-- Main menu
---------------------------------------------------------------------------

local function radio(self, key, default, options)
    local items = {}
    for _i, o in ipairs(options) do
        items[#items + 1] = {
            text = o[2],
            checked_func = function() return (self.settings:readSetting(key) or default) == o[1] end,
            radio = true,
            callback = function()
                self.settings:saveSetting(key, o[1])
                self.settings:flush()
            end,
        }
    end
    return items
end

local SYNC_WINDOWS = { 0.5, 1, 3, 7, 14, 30, 90, 0 }

function Substack:syncWindowMenu()
    local items = {}
    local preset = {}
    for _i, d in ipairs(SYNC_WINDOWS) do
        preset[d] = true
        items[#items + 1] = {
            text = d == 0 and _("Any date (no limit)") or (self:syncWindowLabel(d):gsub("^%l", string.upper)),
            radio = true,
            checked_func = function() return self:syncDays() == d end,
            callback = function()
                self.settings:saveSetting("sync_days", d)
                self.settings:flush()
            end,
        }
    end
    items[#items + 1] = {
        text_func = function()
            local d = self:syncDays()
            if not preset[d] then return T(_("Custom: %1"), self:syncWindowLabel(d)) end
            return _("Custom…")
        end,
        radio = true,
        checked_func = function() return not preset[self:syncDays()] end,
        keep_menu_open = true,
        callback = function(touchmenu)
            local dialog
            dialog = InputDialog:new{
                title = _("Download posts from the last…"),
                description = _("Number of days (e.g. 2, 10, 60). Use 0.25 for 6 hours, 0 for any date."),
                input = tostring(self:syncDays()),
                input_type = "number",
                buttons = {{
                    { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                    { text = _("Save"), is_enter_default = true, callback = function()
                        local d = tonumber((dialog:getInputText() or ""):gsub(",", "."))
                        if not d or d < 0 or d > 3650 then
                            showMsg(_("Enter a number of days between 0 and 3650."))
                            return
                        end
                        self.settings:saveSetting("sync_days", d)
                        self.settings:flush()
                        UIManager:close(dialog)
                        if touchmenu then touchmenu:updateItems() end
                    end },
                }},
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end,
    }
    return items
end

function Substack:settingsMenu()
    return {
        {
            text = _("Sync automatically when Wi-Fi connects"),
            help_text = _("At most every 3 hours. Tap the progress message to stop a sync."),
            checked_func = function() return self.settings:isTrue("auto_sync") end,
            callback = function()
                self.settings:saveSetting("auto_sync", not self.settings:isTrue("auto_sync"))
                self.settings:flush()
            end,
        },
        {
            text = _("Weekly digest"),
            help_text = _("Every Monday, the first sync bundles last week's unread posts into one magazine-style e-book (Library → Digests)."),
            checked_func = function() return self.settings:isTrue("weekly_digest") end,
            callback = function()
                self.settings:saveSetting("weekly_digest", not self.settings:isTrue("weekly_digest"))
                self.settings:flush()
            end,
        },
        {
            text = _("Turn Wi-Fi off after syncing"),
            help_text = _("Only when the sync switched Wi-Fi on. Saves battery."),
            checked_func = function() return self.settings:nilOrTrue("wifi_off_after_sync") end,
            callback = function()
                self.settings:saveSetting("wifi_off_after_sync", not self.settings:nilOrTrue("wifi_off_after_sync"))
                self.settings:flush()
            end,
        },
        {
            text_func = function() return T(_("New articles per sync (all publications): up to %1"), self.settings:readSetting("max_per_sync") or 20) end,
            help_text = _("Each sync downloads the newest posts across everything you follow, up to this many. Keeps the Inbox manageable when you follow lots of publications."),
            sub_item_table = radio(self, "max_per_sync", 20, { { 10, "10" }, { 20, "20" }, { 40, "40" }, { 80, "80" } }),
        },
        {
            text_func = function() return T(_("New posts per publication per sync: %1"), self.settings:readSetting("per_pub") or 3) end,
            sub_item_table = radio(self, "per_pub", 3, { { 1, "1" }, { 3, "3" }, { 5, "5" }, { 10, "10" } }),
        },
        {
            text_func = function() return T(_("Download posts from: %1"), self:syncWindowLabel()) end,
            help_text = _("Sync only downloads posts published within this window, from publications and people you follow. Older posts stay browsable under Publications but don't take up space. Posts you bookmark in the Substack app always come through."),
            sub_item_table_func = function() return self:syncWindowMenu() end,
        },
        {
            text = _("Images"),
            help_text = _("Smaller images make articles open faster. Re-download an article to apply a new setting to it."),
            sub_item_table = radio(self, "image_quality", "standard", {
                { "standard", _("Standard (recommended)") }, { "full", _("Large (sharpest, slower)") },
                { "small", _("Small (fastest, saves space)") }, { "none", _("No images") },
            }),
        },
        {
            text_func = function() return T(_("Weekly reading goal: %1 articles"), self.settings:readSetting("weekly_goal") or 5) end,
            help_text = _("Shown as a progress bar at the top of My reading."),
            sub_item_table = radio(self, "weekly_goal", 5, { { 3, "3" }, { 5, "5" }, { 7, "7" }, { 10, "10" }, { 15, "15" } }),
        },
        {
            text_func = function() return T(_("Short reads: up to %1 min"), self.settings:readSetting("short_minutes") or 5) end,
            sub_item_table = radio(self, "short_minutes", 5, { { 5, _("5 minutes") }, { 10, _("10 minutes") }, { 15, _("15 minutes") } }),
        },
        {
            text = _("Podcast episodes"),
            help_text = _("KOReader can't play audio. With \"Show notes only\", sync downloads the text written under an episode."),
            sub_item_table = radio(self, "podcasts", "skip", {
                { "skip", _("Skip (don't download)") }, { "notes", _("Show notes only") },
            }),
        },
        {
            text = _("Comments"),
            sub_item_table = radio(self, "comments", 0, { { 0, _("Don't include") }, { 10, _("Top 10") }, { 25, _("Top 25") } }),
        },
        {
            text = _("Offer the next unread article when I finish one"),
            checked_func = function() return self.settings:nilOrTrue("end_prompt") end,
            callback = function()
                self.settings:saveSetting("end_prompt", not self.settings:nilOrTrue("end_prompt"))
                self.settings:flush()
            end,
        },
        {
            text = _("Return to Bookshelf after closing an article"),
            help_text = _("For the Bookshelf home screen plugin. Closing an article shows Bookshelf, with the list you came from on top; Back from the list leaves you on Bookshelf. Turn off to go to the file browser instead."),
            enabled_func = function() return self:hasBookshelf() end,
            checked_func = function() return self:hasBookshelf() and self.settings:nilOrTrue("return_to_bookshelf") end,
            callback = function()
                self.settings:saveSetting("return_to_bookshelf", not self.settings:nilOrTrue("return_to_bookshelf"))
                self.settings:flush()
            end,
        },
        {
            text = _("Keep articles out of “current read” and history"),
            help_text = _("When you close an article, the book you were reading stays as your current read, and the article isn't added to KOReader's reading history. Your Substack Inbox still tracks it."),
            checked_func = function() return self.settings:nilOrTrue("hide_from_history") end,
            callback = function()
                self.settings:saveSetting("hide_from_history", not self.settings:nilOrTrue("hide_from_history"))
                self.settings:flush()
            end,
        },
        {
            text = _("Auto-delete finished articles"),
            help_text = _("Articles you keep or highlight are never deleted."),
            sub_item_table = radio(self, "cleanup_days", 30, {
                { 0, _("Never") }, { 7, _("After 7 days") }, { 30, _("After 30 days") }, { 90, _("After 90 days") },
            }),
        },
        {
            text_func = function() return T(_("Download folder: %1"), self:getDownloadDir()) end,
            keep_menu_open = true,
            callback = function(touchmenu)
                local PathChooser = require("ui/widget/pathchooser")
                local start = self:getDownloadDir()
                if lfs.attributes(start, "mode") ~= "directory" then
                    start = G_reader_settings:readSetting("home_dir") or "/"
                end
                UIManager:show(PathChooser:new{
                    select_directory = true, select_file = false, path = start,
                    onConfirm = function(dir)
                        self.settings:saveSetting("download_dir", dir)
                        self.settings:flush()
                        self.scanned = false
                        if touchmenu then touchmenu:updateItems() end
                    end,
                })
            end,
        },
        {
            text = _("Reset settings to defaults…"),
            help_text = _("Your publications, sign-in, saved articles and download folder stay as they are."),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Put all Substack settings back to their defaults?\n\nYour publications, sign-in, saved articles and download folder stay as they are."),
                    ok_text = _("Reset"),
                    ok_callback = function()
                        for _i, k in ipairs(DEFAULT_RESET_KEYS) do self.settings:delSetting(k) end
                        self.settings:flush()
                        self:applyLibraryPrefs()
                        showMsg(_("Settings reset to defaults."), 2)
                    end,
                })
            end,
        },
        {
            text = _("Gesture shortcuts…"),
            callback = function()
                showMsg(_("You can put Sync, Inbox, Next unread and Latest posts on a tap or swipe:\n\nSettings (⚙) → Taps and gestures → Gesture manager → pick a gesture → General → Substack: …"))
            end,
        },
    }
end

function Substack:libraryMenu()
    return {
        { text = _("Archive (finished)"), callback = function() self:showLibraryList("archive") end },
        { text = _("Kept & highlighted"), callback = function() self:showLibraryList("kept") end },
        { text = _("All saved articles"), callback = function() self:showLibraryList("all") end, separator = true },
        { text = _("Digests"), callback = function() self:showDigests() end },
        {
            text = _("Make a digest of unread articles"),
            sub_item_table = {
                { text = _("From the last 7 days"), callback = function() self:createDigest(7) end },
                { text = _("All unread"), callback = function() self:createDigest(nil) end },
            },
            separator = true,
        },
        { text = _("Export highlights (Markdown)"), callback = function() self:exportHighlights() end },
        { text = _("Back up publications & settings"), callback = function() self:backup() end },
        { text = _("Restore from backup or OPML…"), callback = function() self:restoreDialog() end, separator = true },
        {
            text_func = function()
                local bytes, count = self.library:usage(self:getDownloadDir())
                return T(_("Storage: %1 articles, %2"), count, humanSize(bytes))
            end,
            keep_menu_open = true,
            callback = function() end,
        },
        {
            text = _("Delete finished articles now…"),
            callback = function()
                self:scanLibrary()
                UIManager:show(ConfirmBox:new{
                    text = _("Delete all finished articles? Kept and highlighted ones stay."),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        local n = self.library:deleteAllFinished()
                        showMsg(T(_("Deleted %1 article(s)."), n), 2)
                    end,
                })
            end,
        },
    }
end

function Substack:about()
    self:scanLibrary()
    local bytes, count = self.library:usage(self:getDownloadDir())
    showMsg(table.concat({
        T(_("Substack for KOReader %1"), VERSION),
        "",
        T(_("Following: %1 publications, %2 writers"), #self.publications, #self.people),
        T(_("Downloads posts from: %1"), self:syncWindowLabel()),
        T(_("Saved: %1 articles (%2)"), count, humanSize(bytes)),
        T(_("Unread: %1"), self.library:unreadCount()),
        T(_("Last sync: %1"), ago(self.settings:readSetting("last_sync"))),
        T(_("Account: %1"), self:isLoggedIn() and (self.settings:readSetting("email") or _("signed in")) or _("not signed in")),
        T(_("Folder: %1"), self:getDownloadDir()),
        "",
        _("Uses Substack's unofficial website endpoints. If something stops working, Substack may have changed them."),
    }, "\n"))
end

function Substack:mainMenuItems()
    local items = {}
    local in_article = self.ui and self.ui.document and self.ui.document.file and self.library:get(self.ui.document.file)
    if in_article then
        local label = self:originLabel()
        table.insert(items, {
            text = label and T(_("‹ Back to %1"), label) or _("‹ Close article"),
            callback = function() self:closeToHome() end,
        })
        table.insert(items, { text = _("Next unread article"), callback = function() self:onSubstackNextUnread() end })
        local a = self.library:get(self.ui.document.file)
        if a.host and not self:pubByHost(a.host) then
            table.insert(items, { text = T(_("Follow %1"), a.publication or a.host), callback = function()
                self:followPub(a.host, a.publication)
            end })
        end
        items[#items].separator = true
    end
    local more = {
        {
            text_func = function()
                self:scanLibrary()
                return T(_("Inbox (%1 unread)"), self.library:unreadCount())
            end,
            callback = function() self:showLibraryList("inbox") end,
        },
        { text = _("My reading (stats)"), callback = function() self:showDashboard() end },
        {
            text_func = function() return T(_("Sync now (last: %1)"), ago(self.settings:readSetting("last_sync"))) end,
            callback = function() self:sync() end,
            separator = true,
        },
        { text = _("Publications"), callback = function() self:showPublications() end },
        { text = _("Latest from all publications"), callback = function() self:showLatest() end },
        { text = _("Saved on Substack (from your phone)"), callback = function() self:showSavedOnSubstack() end, separator = true },
        {
            text = _("Discover"),
            sub_item_table = {
                { text = _("Search publications…"), callback = function() self:searchDialog() end },
                { text = _("Recommended for you"), callback = function() self:showRecommendations() end },
            },
        },
        { text = _("Library"), sub_item_table_func = function() return self:libraryMenu() end },
        {
            text_func = function()
                if self:isLoggedIn() then return T(_("Account: %1"), self.settings:readSetting("email") or _("signed in")) end
                return _("Account: not signed in")
            end,
            sub_item_table_func = function() return self:accountMenu() end,
        },
        { text = _("Settings"), sub_item_table_func = function() return self:settingsMenu() end },
        { text = _("About"), callback = function() self:about() end },
    }
    for _i, it in ipairs(more) do items[#items + 1] = it end
    return items
end

function Substack:addToMainMenu(menu_items)
    menu_items.substack = {
        text = _("Substack"),
        sorting_hint = "more_tools",
        sub_item_table_func = function() return self:mainMenuItems() end,
    }
end

return Substack
