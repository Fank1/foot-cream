-- tests/test_asian_units.lua — the transliteration-unit GATE: short spellings
-- (≤4 letters: go, li, mu, ri, sun, tan, ken, jin, kan, ke …) are ordinary
-- English words, so they only convert with (a) a CLUSTER of ≥2 distinct Asian
-- units in the book AND (b) a literally-written number. Long spellings
-- ("zhang", "shichen", "koku", "tsubo") are unambiguous and convert freely.

local T = require("run")

-- ── Cluster + digit → converts ──────────────────────────────────────────────
T("2 mu + 30 li digits convert", function()
    assert_conv("The farm covered 2 mu, and the caravan went 30 li.",
                "30 li", "= 15 000 m")
    assert_conv("The farm covered 2 mu, and the caravan went 30 li.",
                "2 mu", "= 1 333.3 m²")
end)

T("5 jin + 3 zhang mixed cluster converts", function()
    assert_conv("The market sold 5 jin of grain and 3 zhang of cloth.",
                "5 jin", "= 2.5 kg")
    assert_conv("The market sold 5 jin of grain and 3 zhang of cloth.",
                "3 zhang", "= 10 m")
end)

-- ── Long unambiguous spellings convert freely ───────────────────────────────
T("fifty zhang (long, spelled) converts", function()
    assert_conv("The wall spanned fifty zhang.", "fifty zhang", "= 170 m")
end)

T("two shichen (long) converts", function()
    assert_conv("Two shichen passed before the dawn.", "Two shichen", "= 240 min")
end)

T("2 koku + 3 go cluster converts", function()
    assert_conv("The granary stored 2 koku of rice and 3 go of sake.",
                "2 koku", "= 360 liters")
    assert_conv("The granary stored 2 koku of rice and 3 go of sake.",
                "3 go", "= 0.5 liters")
end)

-- ── Gate: no cluster → short units never convert ────────────────────────────
T("10 go alone is NOT a volume", function()
    assert_no_match("The pot held 10 go of rice.", "go")
end)

T("6 mu alone is NOT an area", function()
    assert_no_match("The farm covered 6 mu of land.", "mu")
end)

T("30 li alone is NOT a distance", function()
    assert_no_match("The caravan went 30 li down the road.", "li")
end)

-- ── Gate: spelled number / article short units never convert ────────────────
T("in one go is an idiom, not 0.18 L", function()
    assert_no_match("He climbed it in one go entirely.", "go")
end)

T("have a go is an idiom, not 0.18 L", function()
    assert_no_match("He had a go at the task.", "go")
end)

T("one li distant is NOT a distance", function()
    assert_no_match("It was one li distant from the camp.", "li")
end)

T("spelled shorts in a cluster still never convert", function()
    assert_no_match("It was one mu of land and one li distant.", "mu")
    assert_no_match("It was one mu of land and one li distant.", "li")
end)

-- ── The English homographs stay inert even beside a number word neighbor ────
T("the sun / a tan are not units", function()
    assert_no_match("He watched the red sun sink slowly.", "sun")
    assert_no_match("She got a deep tan on holiday.", "tan")
end)