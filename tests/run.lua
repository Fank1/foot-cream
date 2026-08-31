-- tests/run.lua — headless Footcream test runner.
--
-- Usage:  lua tests/run.lua          (from the repo root)
--
-- Loads the REAL main.lua behind KOReader module stubs, scans plain-text mock
-- documents through the real scanner (_startScan → _fast_scan_matches →
-- _finishScan), and runs the registered tests. Exits non-zero on failure.
--
-- Test files (tests/test_*.lua) register cases via the returned `T` function:
--   local T = require("run")
--   T("six feet converts", function() ... end)

local src = debug.getinfo(1, "S").source or ""
local this_dir = (src:match("@?(.*)/[^/]*$") or ".")
package.path = this_dir .. "/?.lua;" .. this_dir .. "/../tests/?.lua;" .. package.path

local stub = require("kobo_stub")
stub.install()

local MockDoc = require("mock_doc")

-- ── Settings ────────────────────────────────────────────────────────────────
local function reset_settings()
    local s = stub.settings._t
    for k in pairs(s) do s[k] = nil end
    stub.settings:saveSetting("footcream_preferred_system", "metric")
    -- smart rounding default on
end

local MAIN_LUA
do
    local src = debug.getinfo(1, "S").source or ""
    local dir = (src:match("@?(.*)/[^/]*$") or ".")
    MAIN_LUA = dir .. "/../main.lua"
end

local FootFree = dofile(MAIN_LUA)

-- Scan a plain-text "book" through the real scanner. Returns the applied
-- matches (each: matched_text, _converted, prev_text, next_text, ...).
local function scan(text, opts)
    opts = opts or {}
    reset_settings()
    if opts.imperial then
        stub.settings:saveSetting("footcream_preferred_system", "us")
    end
    local doc = MockDoc.new(text, {
        file     = opts.file or "/tmp/footcream_test_book.txt",
        language = opts.language or "en-US",
    })
    FootFree._cat_enabled = {}
    for _, c in ipairs({ "length", "weight", "temperature", "volume", "speed", "area", "time", "energy", "pressure" }) do
        local v = opts.cat_enabled and opts.cat_enabled[c]
        FootFree._cat_enabled[c] = (v ~= false)
    end
    -- Opt-in unit packages default ON in the harness so the existing unit tests
    -- (which expect Asian/fantasy units to convert) keep passing. Individual
    -- tests opt a package OUT via opts.pkg_enabled to exercise the gate.
    FootFree._pkg_enabled = {}
    for _, p in ipairs({ "asian", "fantasy" }) do
        local v = opts.pkg_enabled and opts.pkg_enabled[p]
        FootFree._pkg_enabled[p] = (v ~= false)
    end
    FootFree._debug_report     = false
    FootFree._tap_mode         = opts.tap_mode or 1
    FootFree._scanned          = false
    FootFree._all_matches      = nil
    FootFree._current_boxes    = {}
    FootFree._after_scan       = nil
    FootFree._distinguish_pounds = opts.distinguish_pounds ~= false
    FootFree._uk_volumes       = opts.uk_volumes or false
    FootFree._doc_unsupported  = false
    FootFree.ui = { document = doc }
    FootFree:_startScan(doc)
    -- Production scans run in a subprocess that saves the sidecar; completion
    -- then re-loads the raw matches and applies settings (UK volumes, pounds
    -- classifier). The harness's synchronous fallback skips that reload, so
    -- reproduce it here to exercise the same code path (and get UK volumes).
    local raw = FootFree._TEST.load_sidecar(doc.file)
    if raw then
        local use_uk = FootFree._uk_volumes and FootFree._TEST.is_uk_book(doc)
        local applied = FootFree._TEST.apply_settings(raw, FootFree._distinguish_pounds, use_uk)
        FootFree._all_matches = applied
        return applied
    end
    return FootFree._all_matches or {}
end

-- ── Assertions ──────────────────────────────────────────────────────────────
local T

-- Compute a match's conversion through the real pipeline (matches are stored
-- with _converted computed lazily by the plugin's _convert).
local function conv_of(r)
    return FootFree._TEST.convert(r) or (r._converted or "")
end

local function fmt_matches(matches)
    local out = {}
    for i, r in ipairs(matches) do
        out[#out + 1] = string.format("    [%d] %q  ->  %s",
            i, r.matched_text, conv_of(r))
    end
    return #out > 0 and table.concat(out, "\n") or "    (no matches)"
end

local function scan_for(text, opts)
    opts = opts or {}
    local matches = scan(text, opts)
    return matches, text, opts
end

-- Find the first match whose matched_text (displayed, lowercased) contains `phrase`.
local function find_match(matches, phrase)
    local p = phrase:lower()
    for _, r in ipairs(matches) do
        local mt = (r.matched_text or ""):lower()
        if mt:find(p, 1, true) then return r end
    end
    return nil
end

local function assert_eq(a, b, label)
    if a ~= b then
        error(string.format("%s: expected %q, got %q", label or "eq", tostring(b), tostring(a)), 2)
    end
end

local function assert_conv(text, phrase, expect_contains, opts)
    local matches = scan(text, opts)
    local r = find_match(matches, phrase)
    if not r then
        error(string.format("no match for %q in %q\n%s",
            phrase, text, fmt_matches(matches)), 2)
    end
    local conv = conv_of(r)
    if expect_contains and not conv:find(expect_contains, 1, true) then
        error(string.format("conversion %q for %q missing %q\n%s",
            conv, phrase, expect_contains, fmt_matches(matches)), 2)
    end
    return r
end

local function assert_no_match(text, phrase, opts)
    local matches = scan(text, opts)
    local r = find_match(matches, phrase)
    if r then
        error(string.format("should NOT match %q in %q, but got conversion: %s\n%s",
            phrase, text, conv_of(r), fmt_matches(matches)), 2)
    end
end

-- ── Runner ──────────────────────────────────────────────────────────────────
local cases = {}
local order = {}
local failures = {}

T = function(name, fn)
    cases[name] = fn
    order[#order + 1] = name
end

local function run_all()
    local passed = 0
    for _, name in ipairs(order) do
        local fn = cases[name]
        local okk, err = pcall(fn)
        if okk then
            passed = passed + 1
            io.write("  ok  " .. name .. "\n")
        else
            failures[#failures + 1] = name
            io.write("  FAIL " .. name .. "\n    " .. tostring(err):gsub("\n", "\n    ") .. "\n")
        end
    end
    return passed, #order - passed
end

-- Discover and load test files.
local function discover()
    local dir = this_dir
    local p = io.popen('ls "' .. dir .. '" | grep -E "^test_.+\\.lua$"')
    local files = {}
    if p then
        for f in p:lines() do files[#files + 1] = f end
        p:close()
    end
    table.sort(files)
    for _, f in ipairs(files) do
        local chunk = assert(loadfile(dir .. "/" .. f))
        chunk()
    end
end

-- Allow test files to call us. The helper globals plus a pre-cached
-- package.loaded["run"] mean test files' `require("run")` resolves to THIS
-- chunk's T and registers into these very `cases`/`order` tables (not a
-- re-executed copy).
_G.T               = T
_G.scan            = scan
_G.assert_conv     = assert_conv
_G.assert_no_match = assert_no_match
_G.assert_eq       = assert_eq
_G.find_match      = find_match
_G.fmt_matches     = fmt_matches
package.loaded["run"] = T

local is_main = (arg and arg[0]) and arg[0]:find("run%.lua") ~= nil
if is_main and not _G._footcream_running then
    -- Sentinel set BEFORE discover(): test files require("run") while the
    -- entry chunk is still executing, and the re-entrant load must not
    -- re-discover/re-run (infinite recursion).
    _G._footcream_running = true
    discover()
    local passed, failed = run_all()
    io.write(string.format("\n%d passed, %d failed\n", passed, failed))
    os.exit(failed == 0 and 0 or 1)
end

return T
