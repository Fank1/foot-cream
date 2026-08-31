-- tests/test_compounds.lua — compound measurements, ranges, fractions and
-- vague quantities.

local T = require("run")

-- ── Word compounds ──────────────────────────────────────────────────────────
T("six foot four -> 1.93 m", function()
    assert_conv("The boxer was six foot four.", "six foot", "= 1.93 m")
end)

T("seven pounds four ounces -> 3.3 kg", function()
    assert_conv("The baby weighed seven pounds four ounces.", "seven pounds", "= 3.3 kg")
end)

T("nine stone four -> 59 kg", function()
    assert_conv("The wrestler was nine stone four.", "nine stone", "= 59 kg")
end)

-- ── Dimensions ──────────────────────────────────────────────────────────────
T("twenty feet by ten -> 6 x 3 m", function()
    assert_conv("The room was twenty feet by ten.", "twenty feet", "6 \195\151 3 m")
end)

T("10x10 feet -> 3 x 3 m", function()
    assert_conv("The mat measured 10x10 feet.", "10x10 feet", "3 \195\151 3 m")
end)

-- ── Ranges ──────────────────────────────────────────────────────────────────
T("four to five feet -> 1.2-1.5 m range", function()
    assert_conv("The fish was four to five feet long.", "four to five feet", "1.2")
end)

T("twelve or fifteen miles -> 20 or 24 km range", function()
    assert_conv("They marched twelve or fifteen miles.", "twelve or fifteen miles", "= 20 or 24 km")
end)

-- ── Fractions ───────────────────────────────────────────────────────────────
T("two miles and a half -> 4 km", function()
    assert_conv("They walked two miles and a half.", "two miles", "= 4 km")
end)

T("a mile and a half -> 2.4 km", function()
    assert_conv("The track was a mile and a half long.", "a mile", "= 2.4 km")
end)

T("half a foot -> 15 cm", function()
    assert_conv("There was half a foot of snow.", "half a foot", "= 15 cm")
end)

-- ── Vague quantities → a band ───────────────────────────────────────────────
T("a few hundred pounds -> approximate band", function()
    assert_conv("He lifted a few hundred pounds.", "few hundred", "\226\137\136")
end)
