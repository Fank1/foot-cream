-- tests/regex.lua — small backtracking regex engine for the crengine pattern
-- subset the Footcream scanner actually passes to doc:findAllText().
--
-- Supported constructs (everything the production patterns use):
--   literals (bytes, incl. UTF-8), . , character classes [a-z] / [^a-z],
--   groups (a|b|c) and non-capturing (?:...), quantifiers * + ? (greedy),
--   \b word boundary, \d/\w/\s, and fixed-width lookbehind (?<=X).
--
-- Public API:
--   M.findAll(text, pattern) -> list of {s=start, e=end} (1-based, e exclusive)
--   M.compile(pattern) -> compiled token list  (for reuse / sanity tests)
--
-- The matcher returns *all* reachable end positions for a start; the caller
-- picks the farthest one (greedy), which mirrors PCRE's longest-match behavior.

local M = {}

local function parse_class(s, i)
    -- s[i] == "[" ; returns (ranges, neg, next_index)
    local neg = false
    local j = i + 1
    if s:sub(j, j) == "^" then neg = true; j = j + 1 end
    local ranges = {}
    while j <= #s do
        local c = s:sub(j, j)
        if c == "]" then return ranges, neg, j + 1 end
        local lo = c:byte()
        j = j + 1
        local d = s:sub(j, j)
        if d == "-" and j < #s and s:sub(j + 1, j + 1) ~= "]" then
            local hi = s:sub(j + 1, j + 1):byte()
            ranges[#ranges + 1] = { lo = lo, hi = hi }
            j = j + 2
        else
            ranges[#ranges + 1] = { lo = lo, hi = lo }
        end
    end
    return ranges, neg, nil
end

-- Parse from i until `stop` (a single byte, e.g. ")" ) or end of string.
-- Returns (arms, next_index): arms is a list of token-lists split on top-level "|".
local function parse_until(s, i, stop)
    local arms = { {} }
    local cur = 1
    while i <= #s do
        local c = s:sub(i, i)
        if stop and c == stop then return arms, i + 1 end
        if c == "|" then
            arms[#arms + 1] = {}
            cur = #arms
            i = i + 1
        elseif c == "(" then
            local j = i + 1
            local head = s:sub(j, j + 2)
            local inner
            if head == "?<=" then
                inner, i = parse_until(s, j + 3, ")")
                local t = { t = "lb", sub = inner }
                if #inner == 1 and #inner[1] == 1 then
                    t = { t = "lb1", sub = inner[1][1] }
                end
                arms[cur][#arms[cur] + 1] = t
            elseif s:sub(j, j + 1) == "?:" then
                inner, i = parse_until(s, j + 2, ")")
                arms[cur][#arms[cur] + 1] = { t = "group", alts = inner }
            else
                inner, i = parse_until(s, j, ")")
                arms[cur][#arms[cur] + 1] = { t = "group", alts = inner }
            end
        elseif c == "[" then
            local ranges, neg, k = parse_class(s, i)
            if not k then return nil end
            arms[cur][#arms[cur] + 1] = { t = "cls", ranges = ranges, neg = neg }
            i = k
        elseif c == "\\" then
            local e = s:sub(i + 1, i + 1)
            if e == "b" then
                arms[cur][#arms[cur] + 1] = { t = "b" }
            elseif e == "B" then
                arms[cur][#arms[cur] + 1] = { t = "notb" }
            elseif e == "d" then
                arms[cur][#arms[cur] + 1] = { t = "cls", ranges = { { lo = 48, hi = 57 } }, neg = false }
            elseif e == "w" then
                arms[cur][#arms[cur] + 1] = { t = "cls",
                    ranges = { { lo = 48, hi = 57 }, { lo = 65, hi = 90 },
                               { lo = 97, hi = 122 }, { lo = 95, hi = 95 } }, neg = false }
            elseif e == "s" then
                arms[cur][#arms[cur] + 1] = { t = "cls",
                    ranges = { { lo = 32, hi = 32 }, { lo = 9, hi = 13 } }, neg = false }
            else
                arms[cur][#arms[cur] + 1] = { t = "lit", c = e:byte() }
            end
            i = i + 2
        elseif c == "*" or c == "+" or c == "?" then
            local prev = arms[cur][#arms[cur]]
            if prev and prev.t ~= "rep" and prev.t ~= "lb" and prev.t ~= "lb1" then
                local min, max = 0, math.huge
                if c == "+" then min = 1 end
                if c == "?" then max = 1 end
                arms[cur][#arms[cur]] = { t = "rep", sub = prev, min = min, max = max }
            end
            i = i + 1
        elseif c == "." then
            arms[cur][#arms[cur] + 1] = { t = "any" }
            i = i + 1
        else
            arms[cur][#arms[cur] + 1] = { t = "lit", c = c:byte() }
            i = i + 1
        end
    end
    return arms, i
end

function M.compile(pattern)
    local arms = parse_until(pattern, 1, nil)
    if not arms then return nil end
    return arms[1]
end

local function word_char(b)
    return b and (b >= 48 and b <= 57 or b >= 65 and b <= 90
                  or b >= 97 and b <= 122 or b == 95)
end

local function cls_match(cls, b)
    if not b then return false end
    for _, r in ipairs(cls.ranges) do
        if b >= r.lo and b <= r.hi then return not cls.neg end
    end
    return cls.neg
end

local function lb1_match(tok, text, pos)
    local k = tok.sub
    local b = text:byte(pos - 1)
    if k.t == "lit" then return b == k.c end
    if k.t == "cls" then return cls_match(k, b) end
    return false
end

-- Returns a list of end positions (may be empty → nil) for matching
-- tokens[idx..] at `pos`. DFS with greedy repetition (fewest first, then more).
local match_at
local function walk_rep(tokens, idx, sub, count, curpos, text, results)
    if count >= tokens[idx].min then
        local more = match_at(tokens, idx + 1, text, curpos)
        if more then
            for _, e in ipairs(more) do results[#results + 1] = e end
        end
    end
    if count < tokens[idx].max then
        local ends = match_at({ sub }, 1, text, curpos)
        if ends then
            for _, e in ipairs(ends) do
                if e > curpos then
                    walk_rep(tokens, idx, sub, count + 1, e, text, results)
                end
            end
        end
    end
end

match_at = function(tokens, idx, text, pos)
    if idx > #tokens then return { pos } end
    local t = tokens[idx]
    if t.t == "lit" then
        if text:byte(pos) == t.c then return match_at(tokens, idx + 1, text, pos + 1) end
        return nil
    elseif t.t == "cls" then
        if cls_match(t, text:byte(pos)) then return match_at(tokens, idx + 1, text, pos + 1) end
        return nil
    elseif t.t == "any" then
        if text:byte(pos) then return match_at(tokens, idx + 1, text, pos + 1) end
        return nil
    elseif t.t == "b" then
        if word_char(text:byte(pos - 1)) ~= word_char(text:byte(pos)) then
            return match_at(tokens, idx + 1, text, pos)
        end
        return nil
    elseif t.t == "notb" then
        if word_char(text:byte(pos - 1)) == word_char(text:byte(pos)) then
            return match_at(tokens, idx + 1, text, pos)
        end
        return nil
    elseif t.t == "lb1" then
        if lb1_match(t, text, pos) then return match_at(tokens, idx + 1, text, pos) end
        return nil
    elseif t.t == "lb" then
        -- General lookbehind: match the arm sequence immediately before pos.
        local sub = t.sub[1]
        if sub then
            local cur = pos
            for k = #sub, 1, -1 do
                local kk = sub[k]
                if kk.t == "lit" then
                    if text:byte(cur - 1) ~= kk.c then return nil end
                    cur = cur - 1
                elseif kk.t == "cls" then
                    if not cls_match(kk, text:byte(cur - 1)) then return nil end
                    cur = cur - 1
                else
                    return nil
                end
            end
            return match_at(tokens, idx + 1, text, pos)
        end
        return match_at(tokens, idx + 1, text, pos)
    elseif t.t == "rep" then
        local results = {}
        walk_rep(tokens, idx, t.sub, 0, pos, text, results)
        return #results > 0 and results or nil
    elseif t.t == "group" then
        local results = {}
        for _, alt in ipairs(t.alts) do
            local ends = match_at(alt, 1, text, pos)
            if ends then
                for _, e in ipairs(ends) do
                    local more = match_at(tokens, idx + 1, text, e)
                    if more then
                        for _, ee in ipairs(more) do results[#results + 1] = ee end
                    end
                end
            end
        end
        return #results > 0 and results or nil
    end
    return nil
end

-- Find matches of `pattern` in `text`. Returns list of {s=, e=} (1-based,
-- e exclusive). Non-overlapping scan, greedy longest match per start.
function M.findAll(text, pattern)
    local toks = M.compile(pattern)
    if not toks then return {} end
    local hits = {}
    local i = 1
    while i <= #text do
        local ends = match_at(toks, 1, text, i)
        if ends then
            local best = i
            for _, e in ipairs(ends) do
                if e > best then best = e end
            end
            hits[#hits + 1] = { s = i, e = best }
            i = best
        else
            i = i + 1
        end
    end
    return hits
end

return M
