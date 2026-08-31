-- tests/archiver_stub.lua — fake libarchive (ffi/archiver) for testing
-- metric_epub.lua headlessly. Persists a zip to disk in a simple length-prefixed
-- format: "1" <u32 name-len> <name> <u32 content-len> <content> per entry.
-- Reader/Writer mirror the subset of the real API metric_epub.lua uses.

local M = {}

local function le32(n)
    return string.char(
        n % 256, math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function u32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return a + b * 256 + c * 65536 + d * 16777216, i + 4
end

local function pack(name, content)
    return "1" .. le32(#name) .. name .. le32(#content) .. content
end

local function unpack(data)
    local entries = {}
    local i = 1
    while i <= #data do
        if data:sub(i, i) ~= "1" then break end
        i = i + 1
        local nl; nl, i = u32(data, i)
        local name = data:sub(i, i + nl - 1); i = i + nl
        local cl; cl, i = u32(data, i)
        local content = data:sub(i, i + cl - 1); i = i + cl
        entries[#entries + 1] = { path = name, data = content }
    end
    return entries
end

local Reader = {}
Reader.__index = Reader
function Reader.new()
    return setmetatable({}, Reader)
end
function Reader:open(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local data = f:read("*a")
    f:close()
    if not data or data:sub(1, 1) ~= "1" then return false end
    self._entries = unpack(data)
    return true
end
function Reader:iterate()
    local entries = self._entries
    local i = 0
    return function()
        i = i + 1
        local e = entries and entries[i]
        if not e then return nil end
        return { mode = "file", path = e.path }
    end
end
function Reader:extractToMemory(path)
    for _, e in ipairs(self._entries or {}) do
        if e.path == path then return e.data end
    end
    return nil
end
function Reader:close() end

local Writer = {}
Writer.__index = Writer
function Writer.new()
    return setmetatable({}, Writer)
end
function Writer:open(path)
    self._path  = path
    self._files = {}
    return true
end
function Writer:setZipCompression() end
function Writer:addFileFromMemory(name, data)
    self._files[#self._files + 1] = { path = name, data = data }
end
function Writer:close()
    local out = {}
    for _, f in ipairs(self._files) do
        out[#out + 1] = pack(f.path, f.data)
    end
    local fh = io.open(self._path, "wb")
    fh:write(table.concat(out))
    fh:close()
end

package.loaded["ffi/archiver"] = { Reader = Reader, Writer = Writer }
package.loaded["archiver_stub"] = { Reader = Reader, Writer = Writer }

return { Reader = Reader, Writer = Writer }
