-- Test harness: loads main.lua with stubbed KOReader modules and exposes
-- pure-logic locals for assertions. Run: python3 run_tests.py
local MAIN = _G.FC_MAIN or "main.lua"

-- ── Stubs ────────────────────────────────────────────────────────────────
local function make_extendable()
    local t = {}
    t.extend = function(self, o)
        local r = o or {}
        setmetatable(r, { __index = self })
        return r
    end
    setmetatable(t, { __index = function() return function() return t end end })
    return t
end
local dummy_mod = make_extendable()
local logger_stub = { warn = function() end, info = function() end, dbg = function() end }
local gettext_stub = setmetatable(
    { current_lang = "en", loadMO = function() return true end },
    { __call = function(self, s) return s end })
local ffiutil_stub = {
    template = function(s) return function(...) return s end end,
}

package.preload["ui/widget/container/widgetcontainer"] = function() return dummy_mod end
package.preload["ui/widget/widget"]              = function() return dummy_mod end
package.preload["ui/geometry"]                   = function() return dummy_mod end
package.preload["ffi/blitbuffer"]                = function() return dummy_mod end
package.preload["ui/widget/infomessage"]         = function() return dummy_mod end
package.preload["ui/uimanager"]                    = function() return dummy_mod end
package.preload["datastorage"]                   = function()
    return { getDataDir = function() return "/tmp/fc-test-data" end }
end
package.preload["logger"]                        = function() return logger_stub end
package.preload["ui/widget/notification"]        = function() return dummy_mod end
package.preload["ui/event"]                      = function() return dummy_mod end
package.preload["ui/renderimage"]                = function() return dummy_mod end
package.preload["ffi/util"]                      = function() return ffiutil_stub end
package.preload["gettext"]                       = function() return gettext_stub end
package.preload["libs/libkoreader-lfs"]          = function() error("no lfs in harness") end

_G.G_reader_settings = {
    readSetting = function(self, k) return nil end, -- metric default
}

-- ── Load main.lua with a test hook appended ──────────────────────────────
local fh = assert(io.open(MAIN, "r"))
local src = fh:read("*a")
fh:close()
-- Drop the trailing `return FootFree`; re-add it after the hook.
src = src:gsub("\nreturn FootFree%s*$", "\n")

src = src .. [[

-- TEST HOOK (harness only): expose pure-logic locals. No new `local`s are
-- introduced (200-local ceiling); everything rides on _G.
_G.__T = {
    FootFree        = FootFree,
    UNIT_CONV       = _UNIT_CONV,
    UNIT_SUFFIXES   = _UNIT_SUFFIXES,
    WORD_NUMS       = _WORD_NUMS,
    NUM_UNIT        = _NUM_UNIT,
    NUM_TEN         = _NUM_TEN,
    NUM_SCALE       = _NUM_SCALE,
    NUM_FRAC        = _NUM_FRAC,
    NUM_CONNECTOR   = _NUM_CONNECTOR,
    FRAC_DENOM      = _FRAC_DENOM,
    AREA_CONV       = _AREA_CONV,
    WEIGHT_WORDS    = _WEIGHT_WORDS,
    CURRENCY_HARD   = _CURRENCY_HARD,
    CURRENCY_SOFT   = _CURRENCY_SOFT,
    CURRENCY_PHRASES= _CURRENCY_PHRASES,
    VAGUE_MULTIPLIERS = _VAGUE_MULTIPLIERS,
    identify_unit   = _identify_unit,
    parse_num       = _parse_num,
    compose_spelled = _compose_spelled,
    word_fraction   = _word_fraction,
    prev_num_words  = _prev_num_words,
    detect_vague    = _detect_vague,
    deaccent        = FootFree._deaccent,
    pound_currency_wins = _pound_currency_wins,
    pound_hard_currency = _pound_hard_currency,
    pound_rate_tail = FootFree._pound_rate_tail,
    degrees_temperature_cue = _degrees_temperature_cue,
}
return FootFree
]]

local chunk, err = load(src, "@" .. MAIN)
assert(chunk, "load failed: " .. tostring(err))
local ok, res = pcall(chunk)
assert(ok, "main.lua failed to run under stubs: " .. tostring(res))
print("HARNESS: main.lua loaded OK under stubs")
