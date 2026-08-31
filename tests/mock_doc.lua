-- tests/mock_doc.lua — a fake crengine document for the headless test suite.
--
-- Models a book as a single text node whose xpointers are plain character
-- offsets ("mock/text().<N>", 1-based). Implements the subset of the crengine
-- API the Footcream scanner actually calls:
--
--   findAllText(pattern, dir, nwords, maxhits, simple)
--   getTextFromXPointers(a, b)
--   getPrevVisibleWordStart(xp) / getNextVisibleWordEnd(xp)
--   compareXPointers(a, b)
--   getDocumentProps() / getPageXPointer(n) / getPageCount()
--
-- Word segmentation is whitespace-delimited ("%S+" tokens), which matches
-- crengine closely enough for the scanner's number/idiom logic. Text extraction
-- is exact, so extend_start's text-validation walks behave realistically.

local R = require("regex")

local MockDoc = {}
MockDoc.__index = MockDoc

-- Xpointer offsets are 0-based character indices ("mock/text().<N>"), mirroring
-- crengine's char offsets; a match at 1-based [s,e) uses xp(s-1)..xp(e-1).
local function xp(off)
    return "mock/text()." .. tostring(off)
end

local function off(x)
    if type(x) ~= "string" then return 0 end
    local n = x:match("%.(%d+)$")
    return n and tonumber(n) or 0
end

local function tokenize(text)
    local out = {}
    local pos = 1
    while pos <= #text do
        -- crengine word navigation treats hyphens as word breaks ("three-carat"
        -- is two words), so split on whitespace AND hyphens.
        local s, e = text:find("[^%s%-]+", pos)
        if not s then break end
        out[#out + 1] = { s = s, e = e + 1 }
        pos = e + 1
    end
    return out
end

function MockDoc.new(text, opts)
    opts = opts or {}
    local self = setmetatable({}, MockDoc)
    self.text  = text or ""
    self.words = tokenize(self.text)
    self.file  = opts.file or "/tmp/footcream_test_book.txt"
    self.language = opts.language or "en-US"
    return self
end

-- Return text from xpointer a to b (offsets are 0-based, b exclusive in effect).
function MockDoc:getTextFromXPointers(a, b)
    local oa, ob = off(a), off(b)
    if oa >= #self.text then return "" end
    return self.text:sub(oa + 1, ob)
end

function MockDoc:getPrevVisibleWordStart(x)
    local o = off(x)
    local prev = nil
    for _, w in ipairs(self.words) do
        if w.e <= o then prev = w else break end
    end
    return prev and xp(prev.s - 1) or x
end

function MockDoc:getNextVisibleWordEnd(x)
    local o = off(x)
    for _, w in ipairs(self.words) do
        if w.s - 1 >= o then return xp(w.e - 1) end
    end
    return x
end

function MockDoc:compareXPointers(a, b)
    local oa, ob = off(a), off(b)
    if oa > ob then return 1 end
    if oa < ob then return -1 end
    return 0
end

function MockDoc:getDocumentProps()
    return { language = self.language, title = "Mock book" }
end

function MockDoc:getPageXPointer(n)
    -- crengine: getPageXPointer(1) = start of the book, getPageXPointer(pageCount)
    -- = start of the last page. The scanner reads the whole book via these two,
    -- so model 2 pages: page 1 starts at 0, the last page starts at the end.
    if n and n >= 2 then return xp(#self.text) end
    return xp(0)
end

function MockDoc:getPageCount()
    return 2
end

function MockDoc:findAllText(pattern, _, nwords, _, _)
    nwords = nwords or 5
    local hits = R.findAll(self.text, pattern)
    local out = {}
    for _, h in ipairs(hits) do
        -- previous N words (entire tokens ending before the match start)
        local pt, pcnt = {}, 0
        for i = #self.words, 1, -1 do
            local w = self.words[i]
            if w.e <= h.s then
                pt[#pt + 1] = self.text:sub(w.s, w.e - 1)
                pcnt = pcnt + 1
                if pcnt >= nwords then break end
            end
        end
        local prev = {}
        for i = #pt, 1, -1 do prev[#prev + 1] = pt[i] end
        -- next N words (tokens starting at or after the match end)
        local nt, ncount = {}, 0
        for _, w in ipairs(self.words) do
            if w.s >= h.e then
                nt[#nt + 1] = self.text:sub(w.s, w.e - 1)
                ncount = ncount + 1
                if ncount >= nwords then break end
            end
        end
        out[#out + 1] = {
            start        = xp(h.s - 1),
            ["end"]      = xp(h.e - 1),
            matched_text = self.text:sub(h.s, h.e - 1),
            prev_text    = table.concat(prev, " "),
            next_text    = table.concat(nt, " "),
        }
    end
    return out
end

return MockDoc
