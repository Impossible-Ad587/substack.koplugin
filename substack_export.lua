--[[
Pure helpers for exports, backups and reading stats (no KOReader
dependencies, so they can be tested with a plain Lua interpreter).
]]

local M = {}

local function str(v)
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

---------------------------------------------------------------------------
-- Highlights
---------------------------------------------------------------------------

--- Normalises highlights from a KOReader sidecar into { text, note, chapter, date }.
-- Handles the current format ("annotations" list) and the older one
-- ("highlight" keyed by page, with notes kept in "bookmarks").
-- read = function(key) returning the sidecar setting.
function M.readHighlights(read)
    local out = {}
    local annotations = read("annotations")
    if type(annotations) == "table" and next(annotations) then
        for _, a in ipairs(annotations) do
            if type(a) == "table" and (str(a.text) or str(a.note)) and (a.pos0 or a.text) then
                out[#out + 1] = {
                    text = str(a.text), note = str(a.note), chapter = str(a.chapter),
                    date = str(a.datetime), page = a.pageno or a.page,
                }
            end
        end
        return out
    end
    local legacy = read("highlight")
    local notes = {}
    local bookmarks = read("bookmarks")
    if type(bookmarks) == "table" then
        for _, b in ipairs(bookmarks) do
            if type(b) == "table" and b.highlighted and str(b.text) and str(b.notes) and b.notes ~= b.text then
                notes[b.notes] = b.text -- legacy: "notes" holds the highlighted text, "text" the note
            end
        end
    end
    if type(legacy) == "table" then
        local pages = {}
        for page in pairs(legacy) do pages[#pages + 1] = page end
        table.sort(pages, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
        for _, page in ipairs(pages) do
            for _, h in ipairs(legacy[page]) do
                if type(h) == "table" and str(h.text) then
                    out[#out + 1] = { text = h.text, note = notes[h.text], chapter = str(h.chapter),
                                      date = str(h.datetime), page = tonumber(page) }
                end
            end
        end
    end
    return out
end

local function quote(text)
    local lines = {}
    for line in (trim(text) .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = "> " .. line
    end
    return table.concat(lines, "\n")
end

--- Markdown for a list of { title, author, publication, url, date, highlights }.
function M.highlightsMarkdown(articles, generated)
    local parts = { "# Substack highlights", "", "_Exported " .. (generated or os.date("%Y-%m-%d %H:%M")) .. "_", "" }
    local total = 0
    for _, a in ipairs(articles) do
        if #a.highlights > 0 then
            parts[#parts + 1] = "## " .. (a.title or "Untitled")
            local meta = {}
            if a.author then meta[#meta + 1] = a.author end
            if a.publication then meta[#meta + 1] = a.publication end
            if a.date then meta[#meta + 1] = a.date end
            if #meta > 0 then parts[#parts + 1] = "*" .. table.concat(meta, " · ") .. "*" end
            if a.url then parts[#parts + 1] = a.url end
            parts[#parts + 1] = ""
            for _, h in ipairs(a.highlights) do
                if h.text then parts[#parts + 1] = quote(h.text) end
                if h.note then
                    parts[#parts + 1] = ""
                    parts[#parts + 1] = "**Note:** " .. trim(h.note)
                end
                parts[#parts + 1] = ""
                total = total + 1
            end
        end
    end
    if total == 0 then
        parts[#parts + 1] = "No highlights yet. Highlight text in a Substack article and export again."
    end
    return table.concat(parts, "\n") .. "\n", total
end

---------------------------------------------------------------------------
-- Backup: OPML (publications) and a settings file
---------------------------------------------------------------------------

local function xmlEscape(s)
    return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function xmlUnescape(s)
    return (tostring(s or ""):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"))
end

--- OPML for a list of { host, name } (feed = https://host/feed), readable by
-- any feed reader.
function M.opml(pubs, generated)
    local parts = {
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<opml version="2.0">',
        '  <head><title>Substack publications</title><dateCreated>' .. xmlEscape(generated or os.date("%Y-%m-%d")) .. '</dateCreated></head>',
        '  <body>',
    }
    for _, p in ipairs(pubs) do
        parts[#parts + 1] = string.format(
            '    <outline type="rss" text="%s" title="%s" xmlUrl="https://%s/feed" htmlUrl="https://%s/"/>',
            xmlEscape(p.name), xmlEscape(p.name), xmlEscape(p.host), xmlEscape(p.host))
    end
    parts[#parts + 1] = '  </body>'
    parts[#parts + 1] = '</opml>'
    return table.concat(parts, "\n") .. "\n"
end

--- Feeds in an OPML file: list of { url, name } (from this plugin or any feed reader).
function M.parseOpml(xml)
    local out = {}
    if type(xml) ~= "string" then return out end
    for tag in xml:gmatch("<outline%s[^>]*>") do
        local url = tag:match('xmlUrl="([^"]+)"') or tag:match("xmlUrl='([^']+)'")
        if url then
            local name = tag:match('title="([^"]*)"') or tag:match('text="([^"]*)"')
            out[#out + 1] = { url = xmlUnescape(url), name = name and xmlUnescape(name) or nil }
        end
    end
    return out
end

--- Serialises plain data (strings, numbers, booleans, nested tables) as a
-- Lua table literal, for the settings backup.
function M.serialize(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t ~= "table" then return "nil" end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) == "number"
    end)
    local inner = indent .. "    "
    local parts = {}
    for _, k in ipairs(keys) do
        local key
        if type(k) == "number" then
            key = "[" .. k .. "]"
        elseif type(k) == "string" and k:match("^[%a_][%w_]*$") then
            key = k
        else
            key = "[" .. string.format("%q", tostring(k)) .. "]"
        end
        parts[#parts + 1] = inner .. key .. " = " .. M.serialize(v[k], inner) .. ","
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, "\n") .. "\n" .. indent .. "}"
end

--- Reads a settings backup written by serialize(). Runs with an empty
-- environment, so the file can only build a table.
function M.deserialize(text)
    if type(text) ~= "string" then return nil, "empty" end
    text = text:gsub("^%-%-[^\n]*\n", "") -- optional header comment
    local loader = loadstring or load
    local fn, err = loader("return " .. text, "backup")
    if not fn then return nil, err end
    if setfenv then setfenv(fn, {}) end
    local ok, data = pcall(fn)
    if not ok or type(data) ~= "table" then return nil, "not a backup file" end
    return data
end

---------------------------------------------------------------------------
-- Reading stats
---------------------------------------------------------------------------

local WPM = 230
local DAY = 86400

local function dayIndex(t) -- local calendar day number
    local d = os.date("*t", t)
    return os.time{ year = d.year, month = d.month, day = d.day, hour = 12 }
end

--- Computes stats from the reading log. Each event: { t, ev = "open" |
-- "finish" | "cleared", pub, author, words, title }. Only "finish" counts as
-- read. now defaults to os.time(). Returns a table for the dashboard.
function M.computeStats(events, now)
    now = now or os.time()
    local s = {
        read_total = 0, read_week = 0, read_month = 0, words_total = 0, words_week = 0,
        opened_total = 0, pubs = {}, authors = {}, author_names = {}, weekdays = { 0, 0, 0, 0, 0, 0, 0 },
        hours = { morning = 0, afternoon = 0, evening = 0, night = 0 },
        lengths = { short = 0, medium = 0, long = 0 }, weeks = {},
        streak = 0, best_streak = 0, longest = nil, first_t = nil,
    }
    local week_start = now - 7 * DAY
    local month_start = now - 30 * DAY
    for i = 1, 8 do s.weeks[i] = 0 end -- s.weeks[8] = this week, [1] = 7 weeks ago
    local read_days, opened = {}, {}
    for _, e in ipairs(events or {}) do
        if type(e) == "table" and e.t then
            s.first_t = (not s.first_t or e.t < s.first_t) and e.t or s.first_t
            if e.ev == "open" then
                local key = (e.slug or e.title or "") .. "|" .. (e.pub or "")
                if not opened[key] then opened[key] = true s.opened_total = s.opened_total + 1 end
                local h = tonumber(os.date("%H", e.t))
                local slot = (h >= 5 and h < 12) and "morning" or (h >= 12 and h < 17) and "afternoon"
                    or (h >= 17 and h < 22) and "evening" or "night"
                s.hours[slot] = s.hours[slot] + 1
            elseif e.ev == "finish" then
                local words = tonumber(e.words) or 0
                s.read_total = s.read_total + 1
                s.words_total = s.words_total + words
                if e.t >= week_start then
                    s.read_week = s.read_week + 1
                    s.words_week = s.words_week + words
                end
                if e.t >= month_start then s.read_month = s.read_month + 1 end
                local weeks_ago = math.floor((now - e.t) / (7 * DAY))
                if weeks_ago >= 0 and weeks_ago < 8 then s.weeks[8 - weeks_ago] = s.weeks[8 - weeks_ago] + 1 end
                local wd = tonumber(os.date("%w", e.t)) -- 0 = Sunday
                local idx = wd == 0 and 7 or wd           -- Monday = 1 … Sunday = 7
                s.weekdays[idx] = s.weekdays[idx] + 1
                if e.pub then s.pubs[e.pub] = (s.pubs[e.pub] or 0) + 1 end
                if e.author then
                    -- An author value can hold several people ("A, B") and the
                    -- same person twice. Count each person once per article;
                    -- spacing and capitals don't make a different person.
                    local seen = {}
                    local text = tostring(e.author):gsub("\194\160", " ")
                    for part in (text .. ","):gmatch("([^,]*),") do
                        local name = trim(part):gsub("%s+", " ")
                        local key = name:lower()
                        if name ~= "" and not seen[key] then
                            seen[key] = true
                            s.author_names[key] = s.author_names[key] or name
                            s.authors[key] = (s.authors[key] or 0) + 1
                        end
                    end
                end
                if words > 0 then
                    local mins = words / WPM
                    local bucket = mins <= 5 and "short" or mins <= 15 and "medium" or "long"
                    s.lengths[bucket] = s.lengths[bucket] + 1
                    if not s.longest or words > s.longest.words then
                        s.longest = { title = e.title, pub = e.pub, words = words }
                    end
                end
                read_days[dayIndex(e.t)] = true
            end
        end
    end
    -- Streaks: consecutive days with at least one article finished.
    local days = {}
    for d in pairs(read_days) do days[#days + 1] = d end
    table.sort(days)
    local run, prev = 0, nil
    for _, d in ipairs(days) do
        if prev and math.abs(d - prev - DAY) < 3 * 3600 then run = run + 1 else run = 1 end
        if run > s.best_streak then s.best_streak = run end
        prev = d
    end
    local today = dayIndex(now)
    if prev and (math.abs(prev - today) < 3 * 3600 or math.abs(prev - (today - DAY)) < 3 * 3600) then
        s.streak = run -- still alive if the last reading day was today or yesterday
    end
    -- Calendar: finished articles per day for the last 35 days (5 weeks),
    -- starting on a Monday so the grid lines up by weekday.
    local per_day = {}
    for _, e in ipairs(events or {}) do
        if type(e) == "table" and e.ev == "finish" and e.t then
            local d = dayIndex(e.t)
            per_day[d] = (per_day[d] or 0) + 1
        end
    end
    local wd_today = tonumber(os.date("%w", now)); wd_today = wd_today == 0 and 7 or wd_today
    local start = today - (28 + wd_today - 1) * DAY -- Monday, four weeks before this week's Monday
    s.calendar = {}
    for i = 0, 34 do
        local d = dayIndex(start + i * DAY)
        s.calendar[#s.calendar + 1] = { t = d, n = per_day[d] or 0, future = d > today + 3 * 3600,
                                        today = math.abs(d - today) < 3 * 3600 }
    end
    s.minutes_total = math.floor(s.words_total / WPM + 0.5)
    s.minutes_week = math.floor(s.words_week / WPM + 0.5)
    s.completion = s.opened_total > 0 and math.floor(100 * math.min(s.read_total, s.opened_total) / s.opened_total + 0.5) or nil
    return s
end

---------------------------------------------------------------------------
-- Dashboard page
---------------------------------------------------------------------------

local function esc(s)
    return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local WEEKDAYS = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
local WEEKDAY_NAMES = { "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays" }

local function plural(n, one, many)
    return n .. " " .. (n == 1 and one or many)
end

local function hoursText(minutes)
    if minutes < 60 then return minutes .. " min" end
    local h = minutes / 60
    return (h < 10 and string.format("%.1f", h):gsub("%.0$", "") or tostring(math.floor(h + 0.5))) .. " h"
end

--- Ranked list: number, name, count, with hairlines between rows.
-- first = the rank of the first item (the #1 is shown separately).
local function ranked(list, first)
    if #list == 0 then return nil end
    local out = { '<table class="rank">' }
    for i, item in ipairs(list) do
        out[#out + 1] = string.format('<tr><td class="rn">%d</td><td class="rt">%s</td><td class="rc">%d</td></tr>',
            (first or 1) + i - 1, esc(item.name), item.count)
    end
    out[#out + 1] = '</table>'
    return table.concat(out)
end

--- One-line observations from the stats, written for a person.
function M.insights(s, top_pubs)
    local out = {}
    if s.read_total == 0 then
        out[#out + 1] = "Finish a few articles and this page will start telling you about your reading."
        return out
    end
    if top_pubs[1] then
        out[#out + 1] = string.format("Your most-read publication is %s (%s).", top_pubs[1].name,
            plural(top_pubs[1].count, "article", "articles"))
    end
    local best_day, best_n = nil, 0
    for i, n in ipairs(s.weekdays) do if n > best_n then best_day, best_n = i, n end end
    if best_day and s.read_total >= 3 then
        out[#out + 1] = "You finish the most articles on " .. WEEKDAY_NAMES[best_day] .. "."
    end
    local slot, slot_n = nil, 0
    for _, k in ipairs({ "morning", "afternoon", "evening", "night" }) do
        if s.hours[k] > slot_n then slot, slot_n = k, s.hours[k] end
    end
    if slot and slot_n >= 3 then
        local phrase = { morning = "Mornings are", afternoon = "Afternoons are", evening = "Evenings are", night = "Late nights are" }
        out[#out + 1] = phrase[slot] .. " when you usually open articles."
    end
    local L = s.lengths
    local known = L.short + L.medium + L.long
    if known >= 3 then
        if L.short >= L.medium and L.short >= L.long then
            out[#out + 1] = "You mostly finish short reads (5 minutes or less)."
        elseif L.long >= L.medium then
            out[#out + 1] = "You like long reads: most of what you finish is over 15 minutes."
        else
            out[#out + 1] = "Your sweet spot is 5 to 15 minute articles."
        end
    end
    if s.streak >= 2 then
        out[#out + 1] = string.format("You're on a %d-day reading streak. Your best is %d.", s.streak, s.best_streak)
    elseif s.best_streak >= 2 then
        out[#out + 1] = string.format("Your best streak so far is %d days in a row.", s.best_streak)
    end
    return out
end

local CSS = [[
body { margin: 0; line-height: 1.35; }
p { margin: 0.25em 0; text-indent: 0; text-align: left; }
table { border-collapse: collapse; width: 100%; }

/* Hero: the one solid block on the page */
div.hero { background-color: #000; color: #fff; padding: 1.1em 1.1em 1em 1.1em; }
div.hero .kicker { font-size: 0.66em; font-weight: bold; letter-spacing: 0.22em; text-transform: uppercase; color: #fff; }
div.hero .title { font-size: 2.35em; font-weight: bold; line-height: 1.02; margin: 0.18em 0 0.22em 0; color: #fff; }
div.hero .line { font-size: 0.95em; color: #fff; }
table.goal { margin-top: 0.8em; }
table.goal td { height: 0.35em; padding: 0; font-size: 0.4em; }
td.gf { background-color: #fff; }
td.gt { background-color: #555; }
div.goaltext { font-size: 0.75em; margin-top: 0.4em; color: #fff; letter-spacing: 0.12em; }
div.hero .meta { font-size: 0.72em; margin-top: 0.6em; color: #ccc; }

/* Reading type: centred title between fine rules */
div.type { margin: 1.8em 0 0 0; text-align: left; page-break-inside: avoid; }
div.type .k { font-size: 0.72em; font-weight: bold; letter-spacing: 0.22em; text-transform: uppercase; }
div.type .hr { border-top: 1px solid #000; margin: 0.35em 0 0.5em 0; font-size: 0.2em; line-height: 0.2; }
div.type .name { font-size: 1.8em; font-weight: bold; line-height: 1.1; margin: 0; text-align: left; }
div.type .desc { font-size: 0.9em; font-style: italic; margin-top: 0.35em; text-align: left; }

/* Section headings */
div.sec { page-break-after: avoid; page-break-inside: avoid; margin: 1.8em 0 0.7em 0; font-size: 0.72em; font-weight: bold; letter-spacing: 0.22em; text-transform: uppercase; }
div.sec .n { font-weight: bold; color: #777; }
div.rule { border-top: 1px solid #000; margin-top: 0.35em; font-size: 0.2em; line-height: 0.2; }

/* Big numbers in a row, hairline dividers */
table.stats { page-break-inside: avoid; page-break-before: avoid; }
table.stats td { width: 33%; text-align: center; vertical-align: top; padding: 0.3em 0.2em 0.6em 0.2em; border-left: 1px solid #bbb; }
table.stats td.first { border-left: none; }
.fig { font-size: 2em; font-weight: bold; line-height: 1; }
.cap { font-size: 0.78em; margin-top: 0.3em; }

/* Streak panel */
table.panel { background-color: #000; margin: 1.8em 0 0 0; page-break-inside: avoid; }
table.panel td { color: #fff; vertical-align: middle; }
td.pl { width: 34%; padding: 0.9em 0.4em 0.9em 1em; text-align: left; }
.pk { font-size: 0.72em; letter-spacing: 0.25em; text-transform: uppercase; color: #fff; }
.pn { font-size: 3.4em; font-weight: bold; line-height: 1; color: #fff; }
.pc { font-size: 0.85em; color: #fff; }
.pb { font-size: 0.78em; margin-top: 0.6em; color: #ccc; }
td.pr { width: 66%; padding: 0.7em 0.9em 0.6em 0.3em; }
table.dots td { width: 14%; text-align: center; height: 1.5em; padding: 0; color: #fff; }
table.dots td.dw { height: auto; font-size: 0.7em; letter-spacing: 0.08em; color: #aaa; padding-bottom: 0.25em; }
.pyes { font-size: 1.15em; color: #fff; }
.pno { font-size: 1.05em; color: #777; }
.ptoday { font-size: 0.62em; letter-spacing: 0.06em; text-transform: uppercase; color: #fff; line-height: 1; }
.pnote { font-size: 0.7em; text-align: right; color: #ccc; margin-top: 0.9em; }

/* Favourite */
div.spot { page-break-inside: avoid; page-break-before: avoid; border-left: 0.45em solid #000; padding: 0.15em 0 0.2em 0.8em; margin: 0 0 0.8em 0; }
div.spot .k { font-size: 0.7em; letter-spacing: 0.22em; text-transform: uppercase; }
div.spot .name { font-size: 1.7em; font-weight: bold; line-height: 1.1; margin: 0.1em 0; }
div.spot .n { font-size: 0.85em; font-style: italic; }
table.rank td { padding: 0.4em 0.2em; vertical-align: middle; border-bottom: 1px solid #d8d8d8; }
td.rn { width: 9%; font-size: 1.1em; text-align: center; color: #777; }
td.rt { width: 77%; font-size: 0.95em; }
td.rc { width: 14%; text-align: right; font-size: 1em; font-weight: bold; }
p.small { font-size: 0.82em; margin-top: 0.6em; }

/* Library: one typographic line */
p.libline { font-size: 0.9em; line-height: 1.6; text-align: left; }
p.libline b { font-size: 1.35em; }
p.longest { font-size: 0.86em; font-style: italic; text-align: left; margin-top: 0.5em; }
.empty { font-style: italic; font-size: 0.88em; }
div.end { text-align: left; font-size: 0.9em; margin-top: 1.8em; letter-spacing: 0.4em; }
.foot { font-size: 0.72em; margin-top: 0.5em; color: #444; text-align: left; }
]]

local function section(n, title)
    return string.format('<div class="sec"><span class="n">%02d</span>&#160;&#160;&#160;%s<div class="rule">&#160;</div></div>', n, esc(title))
end

--- A light-hearted label for how you read, from length and time of day.
function M.readingType(s)
    local L = s.lengths
    local known = L.short + L.medium + L.long
    local slot, slot_n = nil, 0
    for _, k in ipairs({ "morning", "afternoon", "evening", "night" }) do
        if s.hours[k] > slot_n then slot, slot_n = k, s.hours[k] end
    end
    if s.read_total < 3 or known == 0 then
        return "The Curious Newcomer", "Read a few more articles and your reading type will appear here."
    end
    local when = ({ morning = "Early-Bird", afternoon = "Afternoon", evening = "Evening", night = "Night-Owl" })[slot] or "All-Day"
    local kind, desc
    if L.short >= L.medium and L.short >= L.long then
        kind, desc = "Quick Reader", "You like ideas that get to the point, and you finish what you start."
    elseif L.long >= L.medium then
        kind, desc = "Deep Diver", "Long essays don't scare you. You settle in and read to the end."
    else
        kind, desc = "Steady Reader", "Your sweet spot is a solid 5 to 15 minute read."
    end
    local when_desc = ({
        morning = " Mornings are your reading time.", afternoon = " Afternoons are your reading time.",
        evening = " Evenings are your reading time.", night = " The quiet hours after 10 pm are yours.",
    })[slot] or ""
    return "The " .. when .. " " .. kind, desc .. when_desc
end

--- Black panel: the streak in big type beside a 5-week dot grid in white.
local function streakPanel(s)
    local cal = s.calendar or {}
    local grid = { '<table class="dots"><tr>' }
    for _, d in ipairs(WEEKDAYS) do grid[#grid + 1] = '<td class="dw">' .. d:sub(1, 1) .. '</td>' end
    grid[#grid + 1] = '</tr>'
    for i, c in ipairs(cal) do
        if (i - 1) % 7 == 0 then grid[#grid + 1] = '<tr>' end
        -- Plain yes/no per day: ● read (finished at least one article), ○ didn't.
        local cell
        if c.future then
            cell = ""
        elseif c.n > 0 then
            cell = '<span class="pyes">●</span>'
        else
            cell = '<span class="pno">○</span>'
        end
        if c.today then cell = cell .. '<div class="ptoday">today</div>' end
        grid[#grid + 1] = '<td>' .. cell .. '</td>'
        if i % 7 == 0 then grid[#grid + 1] = '</tr>' end
    end
    grid[#grid + 1] = '</table>'
    return '<table class="panel"><tr><td class="pl">'
        .. '<div class="pk">Streak</div><div class="pn">' .. s.streak .. '</div>'
        .. '<div class="pc">' .. (s.streak == 1 and "day in a row" or "days in a row") .. '</div>'
        .. '<div class="pb">Best: ' .. plural(s.best_streak, "day", "days") .. '</div></td>'
        .. '<td class="pr">' .. table.concat(grid) .. '<div class="pnote">● read that day &#160; ○ no reading &#160;·&#160; last 5 weeks</div></td></tr></table>'
end

local function weekHeadline(s)
    if s.read_week == 0 then return "A fresh week", "Nothing finished in the last 7 days yet. Your Inbox is waiting." end
    local title = s.read_week .. (s.read_week == 1 and " article" or " articles") .. " this week"
    local line = string.format("%s of reading in the last 7 days.", hoursText(s.minutes_week))
    local prev = s.weeks[7] or 0
    if prev > 0 and s.read_week > prev then
        line = line .. " That's " .. (s.read_week - prev) .. " more than the week before."
    elseif prev > 0 and s.read_week == prev then
        line = line .. " Same as the week before."
    end
    return title, line
end

--- The "My reading" page. s = computeStats(); lib = { unread, saved, following,
-- muted, highlights, highlighted_articles, kept, goal, generated }.
function M.dashboardHtml(s, lib)
    lib = lib or {}
    local top_pubs = M.top(s.pubs, 5)
    local top_authors = M.top(s.authors, 3)
    local goal = tonumber(lib.goal) or 5
    local P = {}
    local function add(x) P[#P + 1] = x end
    add('<?xml version="1.0" encoding="UTF-8"?>')
    add('<html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"/><title>My reading</title>')
    add('<style>' .. CSS .. '</style></head><body>')

    -- Hero with weekly goal
    local title, line = weekHeadline(s)
    add('<div class="hero"><div class="kicker">My reading · Substack</div>')
    add('<div class="title">' .. esc(title) .. '</div>')
    add('<div class="line">' .. esc(line) .. '</div>')
    local done = math.min(s.read_week, goal)
    local pct = math.floor(100 * done / goal + 0.5)
    add('<table class="goal"><tr>' .. (pct > 0 and string.format('<td class="gf" style="width: %d%%">&#160;</td>', pct) or "")
        .. (pct < 100 and string.format('<td class="gt" style="width: %d%%">&#160;</td>', 100 - pct) or "") .. '</tr></table>')
    add('<div class="goaltext">WEEKLY GOAL · ' .. s.read_week .. ' OF ' .. goal
        .. (s.read_week >= goal and ' · DONE ✓' or (' · ' .. (goal - s.read_week) .. ' TO GO')) .. '</div>')
    add('<div class="meta">Updated ' .. esc(lib.generated or os.date("%d %b %Y, %H:%M")) .. '</div></div>')

    -- Reading type
    local tname, tdesc = M.readingType(s)
    add('<div class="type"><div class="k">Your reading type</div><div class="hr">&#160;</div>')
    add('<div class="name">' .. esc(tname) .. '</div>')
    add('<div class="desc">' .. esc(tdesc) .. '</div></div>')

    -- Streak panel (calendar)
    add(streakPanel(s))

    -- 01 Numbers
    add(section(1, "By the numbers"))
    local function stat(cls, fig, cap)
        return '<td class="' .. cls .. '"><div class="fig">' .. fig .. '</div><div class="cap">' .. cap .. '</div></td>'
    end
    add('<table class="stats"><tr>')
    add(stat("first", s.read_total, "read in total"))
    add(stat("", hoursText(s.minutes_total), "total reading"))
    add(stat("", s.read_month, "last 30 days"))
    add('</tr><tr>')
    add(stat("first", s.completion and (s.completion .. "%") or "–", "finish rate"))
    add(stat("", s.lengths.short + s.lengths.medium + s.lengths.long > 0 and
        (math.floor(s.words_total / math.max(1, s.read_total) / WPM + 0.5) .. " min") or "–", "average read"))
    add(stat("", s.opened_total, "articles opened"))
    add('</tr></table>')

    -- 03 Favourites
    add(section(2, "Your favourites"))
    if top_pubs[1] then
        add('<div class="spot"><div class="k">Your #1 publication</div><div class="name">' .. esc(top_pubs[1].name)
            .. '</div><div class="n">' .. plural(top_pubs[1].count, "article", "articles") .. ' finished</div></div>')
        local rest = {}
        for i = 2, #top_pubs do rest[#rest + 1] = top_pubs[i] end
        if #rest > 0 then add(ranked(rest, 2)) end
        if top_authors[1] then
            local names = {}
            for i, a in ipairs(top_authors) do
                local shown = (s.author_names and s.author_names[a.name]) or a.name
                shown = shown:gsub("[%.%s]+$", "") -- the sentence adds its own full stop
                names[#names + 1] = i == 1 and ('<b>' .. esc(shown) .. '</b>') or esc(shown)
            end
            add('<p class="small">Writers you return to: ' .. table.concat(names, ", ") .. '.</p>')
        end
    else
        add('<p class="empty">Your favourite publications will appear here.</p>')
    end

    -- 07 Library
    add(section(3, "Your library"))
    add('<p class="libline"><b>' .. (lib.unread or 0) .. '</b> unread &#160;·&#160; <b>' .. (lib.following or 0) .. '</b> publications'
        .. ((lib.muted or 0) > 0 and (' (' .. lib.muted .. ' muted)') or '')
        .. '<br/><b>' .. (lib.highlights or 0) .. '</b> highlights &#160;·&#160; <b>' .. (lib.kept or 0) .. '</b> kept</p>')
    if s.longest then
        add('<p class="longest">Longest read so far: “' .. esc(s.longest.title or "?") .. '”, '
            .. math.floor(s.longest.words / WPM + 0.5) .. ' min' .. (s.longest.pub and (', ' .. esc(s.longest.pub)) or '') .. '</p>')
    end

    add('<div class="end">· · ✦ · ·</div>')
    add('<p class="foot">Counts articles you opened and finished; bulk-marked ones are left out. Reading time is estimated from word counts.'
        .. (s.first_t and (' Tracking since ' .. os.date("%d %b %Y", s.first_t) .. '.') or '') .. ' Lives only on your device.</p>')
    add('</body></html>')
    return table.concat(P, "\n")
end

--- Sorted { name, count } list from a count table, top n.
function M.top(counts, n)
    local list = {}
    for name, c in pairs(counts or {}) do list[#list + 1] = { name = name, count = c } end
    table.sort(list, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name:lower() < b.name:lower()
    end)
    while #list > (n or 5) do table.remove(list) end
    return list
end

return M
