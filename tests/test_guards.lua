-- tests/test_guards.lua — the idiom / homonym guards: body-part "feet", the
-- pound-vs-£ classifier, screens, drinks, stone-as-rock, and the metric-
-- direction money guard.

local T = require("run")

-- ── Body-part / idiom feet ──────────────────────────────────────────────────
T("stand on your own two feet is NOT a length", function()
    assert_no_match("She stood on her own two feet.", "two feet")
end)

T("a foot in the door is NOT a length", function()
    assert_no_match("He got a foot in the door.", "a foot")
end)

T("one inch at a time is NOT a length", function()
    assert_no_match("Move the sled one inch at a time.", "one inch")
end)

T("ran a mile relay is NOT a distance", function()
    assert_no_match("He ran a mile relay for the school.", "a mile")
end)

-- ── Pound: weight vs currency ───────────────────────────────────────────────
T("ten pounds sterling is currency (no conversion)", function()
    assert_no_match("The reward was ten pounds sterling.", "ten pounds")
end)

T("twenty thousand pounds is currency (no conversion)", function()
    assert_no_match("Her fortune was twenty thousand pounds.", "twenty thousand pounds")
end)

T("ten pounds of gold IS a weight", function()
    assert_conv("They found ten pounds of gold.", "ten pounds", "= 4.5 kg")
end)

T("the anchor weighed two thousand pounds IS a weight", function()
    assert_conv("The anchor weighed two thousand pounds.", "two thousand pounds", "= 900 kg")
end)

-- ── Screens / TVs stay in inches ────────────────────────────────────────────
T("a 15-inch laptop is NOT converted", function()
    assert_no_match("He bought a 15-inch laptop.", "15-inch")
end)

-- ── Drinks stay in pints ────────────────────────────────────────────────────
T("a pint of beer is NOT converted", function()
    assert_no_match("He ordered a pint of beer.", "a pint")
end)

-- ── Stone: rock, not weight ─────────────────────────────────────────────────
T("twelve stone blocks is rock, not weight", function()
    assert_no_match("The wall was made of twelve stone blocks.", "twelve stone")
end)

-- ── Metric-direction money guard ────────────────────────────────────────────
T("$50 m is millions, not meters", function()
    assert_no_match("The deal was worth $50 m.", "m", { imperial = true })
end)

-- ── Negation rounds to a whole number ───────────────────────────────────────
T("not two miles away -> 3 km", function()
    assert_conv("The town was not two miles away.", "two miles", "= 3 km")
end)

-- ── Upstream v1.7.0 guards (merged) ─────────────────────────────────────────
T("2001's is a year possessive, not 2001 ft", function()
    assert_no_match("2001's Ghosts of Mars.", "2001")
end)

T("the 90's is a decade, not 90 ft", function()
    assert_no_match("He loved the 90's music.", "90")
end)

T("bare degrees converts only with a cold/hot cue", function()
    assert_conv("It was 20 degrees below freezing.", "20 degrees", "= -7")
    assert_no_match("The track banked forty degrees.", "degrees")
end)

T("twenty-three square leagues is area", function()
    assert_conv("It covered twenty-three square leagues.", "twenty-three square leagues", "= 540 km")
end)

T("curly-quote height 6'2\" converts", function()
    local RSQ = "\226\128\153"  -- ' U+2019
    local RDQ = "\226\128\157"  -- " U+201D
    assert_conv("She measured 6" .. RSQ .. "2" .. RDQ .. " tall.", "6", "= 1.88 m")
end)
