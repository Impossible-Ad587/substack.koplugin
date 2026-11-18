--[[
Minimal ZIP writer/reader (STORE method only, no compression).
Pure Lua + LuaJIT's `bit`, so it works on every KOReader build regardless of
which archive helpers that build ships. EPUB images are already compressed,
so storing is fine.
]]

local bit = require("bit")
local M = {}

local CRC_TABLE
local function crcTable()
    if CRC_TABLE then return CRC_TABLE end
    CRC_TABLE = {}
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if bit.band(c, 1) == 1 then
                c = bit.bxor(bit.rshift(c, 1), 0xEDB88320)
            else
                c = bit.rshift(c, 1)
            end
        end
        CRC_TABLE[i] = c
    end
    return CRC_TABLE
end

function M.crc32(s, crc)
    local t = crcTable()
    local c = bit.bnot(crc or 0)
    for i = 1, #s do
        c = bit.bxor(t[bit.band(bit.bxor(c, s:byte(i)), 0xFF)], bit.rshift(c, 8))
    end
    c = bit.bnot(c)
    if c < 0 then c = c + 4294967296 end
    return c
end

local function u16(n)
    return string.char(n % 256, math.floor(n / 256) % 256)
end

local function u32(n)
    return string.char(n % 256, math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function dosTime(t)
    local d = os.date("*t", t or os.time())
    local time = d.hour * 2048 + d.min * 32 + math.floor(d.sec / 2)
    local date = (math.max(d.year, 1980) - 1980) * 512 + d.month * 32 + d.day
    return time, date
end

local Writer = {}
Writer.__index = Writer

function M.newWriter(path)
    local fh, err = io.open(path, "wb")
    if not fh then return nil, err end
    local time, date = dosTime()
    return setmetatable({ fh = fh, offset = 0, entries = {}, time = time, date = date }, Writer)
end

function Writer:add(name, data)
    local crc = M.crc32(data)
    local size = #data
    local header = table.concat({
        u32(0x04034b50), u16(20), u16(0x0800), u16(0), -- version, flags (UTF-8), method=store
        u16(self.time), u16(self.date),
        u32(crc), u32(size), u32(size),
        u16(#name), u16(0), name,
    })
    self.fh:write(header)
    self.fh:write(data)
    table.insert(self.entries, { name = name, crc = crc, size = size, offset = self.offset })
    self.offset = self.offset + #header + size
end

function Writer:addFile(name, path)
    local fh = io.open(path, "rb")
    if not fh then return false end
    local data = fh:read("*a")
    fh:close()
    self:add(name, data)
    return true
end

function Writer:close()
    local cd_start = self.offset
    local parts = {}
    for _, e in ipairs(self.entries) do
        parts[#parts + 1] = table.concat({
            u32(0x02014b50), u16(20), u16(20), u16(0x0800), u16(0),
            u16(self.time), u16(self.date),
            u32(e.crc), u32(e.size), u32(e.size),
            u16(#e.name), u16(0), u16(0), u16(0), u16(0), u32(0),
            u32(e.offset), e.name,
        })
    end
    local cd = table.concat(parts)
    self.fh:write(cd)
    self.fh:write(table.concat({
        u32(0x06054b50), u16(0), u16(0), u16(#self.entries), u16(#self.entries),
        u32(#cd), u32(cd_start), u16(0),
    }))
    self.fh:close()
    self.fh = nil
    return true
end

local function rd16(s, i) return s:byte(i) + s:byte(i + 1) * 256 end
local function rd32(s, i)
    return s:byte(i) + s:byte(i + 1) * 256 + s:byte(i + 2) * 65536 + s:byte(i + 3) * 16777216
end

--- Reads stored (uncompressed) entries. Returns { {name=, data=}, ... } in order.
-- Entries using other methods are skipped.
function M.read(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local s = fh:read("*a")
    fh:close()
    local out, i = {}, 1
    while i + 30 <= #s and rd32(s, i) == 0x04034b50 do
        local flags = rd16(s, i + 6)
        local method = rd16(s, i + 8)
        local csize = rd32(s, i + 18)
        local nlen = rd16(s, i + 26)
        local xlen = rd16(s, i + 28)
        local name = s:sub(i + 30, i + 29 + nlen)
        local dstart = i + 30 + nlen + xlen
        if bit.band(flags, 8) ~= 0 then break end -- data descriptors: not ours
        if method == 0 then
            out[#out + 1] = { name = name, data = s:sub(dstart, dstart + csize - 1) }
        end
        i = dstart + csize
    end
    return out
end

return M
