-- tests/test_notation.lua — the "different height notation" forms: fused
-- abbreviations ("6ft"), prime/apostrophe and quote marks (ASCII + typographic
-- U+2019/U+201D), compound heights with decimals/fractions, the bare "6'4"
-- shorthand, and the speech-close guard.

local T = require("run")

local RSQ = "\226\128\153"  -- ' U+2019
local RDQ = "\226\128\157"  -- " U+201D

-- ── Fused abbreviations ─────────────────────────────────────────────────────
T("6ft (fused) -> 1.8 m", function()
    assert_conv("He was 6ft tall.", "6ft", "= 1.8 m")
end)

T("6 ft (spaced) -> 1.8 m", function()
    assert_conv("He was 6 ft tall.", "6 ft", "= 1.8 m")
end)

-- ── Bare prime / quote marks (ASCII) ────────────────────────────────────────
T("6' (feet) -> 1.8 m", function()
    assert_conv("The pole was 6' long.", "6'", "= 1.8 m")
end)

T("6\" (inches) -> 15 cm", function()
    assert_conv("The board was 6\" wide.", "6\"", "= 15 cm")
end)

-- ── Compound heights ────────────────────────────────────────────────────────
T("6'4\" compound -> 1.93 m", function()
    assert_conv("He stood 6'4\" tall.", "6'4\"", "= 1.93 m")
end)

T("6'4 (bare, no closing quote) -> 1.93 m", function()
    assert_conv("He stood 6'4 tall.", "6'4", "= 1.93 m")
end)

T("6' 4\" (spaced compound) -> 1.93 m", function()
    assert_conv("He stood 6' 4\" tall.", "6' 4\"", "= 1.93 m")
end)

T("6'4½\" fractional inches -> 1.94 m", function()
    assert_conv("He stood 6'4½\" tall.", "6'4½\"", "= 1.94 m")
end)

T("6'4.5\" decimal inches -> 1.94 m", function()
    assert_conv("He stood 6'4.5\" tall.", "6'4.5\"", "= 1.94 m")
end)

T("5′9″ unicode primes -> 1.75 m", function()
    assert_conv("She measured 5′9″ tall.", "5′9″", "= 1.75 m")
end)

-- ── Typographic (curly) quotes ──────────────────────────────────────────────
T("6\" curly inches -> 15 cm", function()
    assert_conv("The gap was 6" .. RDQ .. " wide.", "6" .. RDQ, "= 15 cm")
end)

T("6' curly feet -> 1.8 m", function()
    assert_conv("The pole was 6" .. RSQ .. " long.", "6" .. RSQ, "= 1.8 m")
end)

T("6'4\" fully curly compound -> 1.93 m", function()
    assert_conv("He stood 6" .. RSQ .. "4" .. RDQ .. " tall.", "6" .. RSQ, "= 1.93 m")
end)

-- ── Speech-close guard ──────────────────────────────────────────────────────
T("quoted speech \"He's 6,\" is NOT an inch mark", function()
    assert_no_match("He said \"he's only 6,\" and laughed.", "6")
end)

T("a real 6\" followed by a word IS converted", function()
    assert_conv("He was exactly 6\" tall.", "6\"", "= 15 cm")
end)

-- ── Coordinate guard ────────────────────────────────────────────────────────
T("arcminute coordinates 47° 24′ are NOT feet", function()
    assert_no_match("The position was 47° 24′ N 115° 36′ W.", "24")
end)

-- ── Inches must be < 12 in a compound ───────────────────────────────────────
T("6'140 (incredible inches) is not a height", function()
    assert_no_match("The thing was 6'140 in the tally.", "6'140")
end)
