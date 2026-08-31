-- tests/test_new_units.lua — the newly added units: carat (with the gold-
-- fineness guard), ton (with the figurative/tonnage classifier), verst/arshin/
-- pood (Russian), and gill.

local T = require("run")

-- ── Carat ───────────────────────────────────────────────────────────────────
T("two carats -> 0.4 g", function()
    assert_conv("The ring held two carats of diamonds.", "two carats", "= 0.4 g")
end)

T("a three-carat diamond -> 0.6 g", function()
    assert_conv("She wore a three-carat diamond.", "three-carat", "= 0.6 g")
end)

T("24 carat gold is fineness, not weight", function()
    assert_no_match("The chain was 24 carat gold.", "24 carat")
end)

T("karat (with a k) is never a unit", function()
    assert_no_match("It was eighteen-karat gold.", "eighteen-karat")
end)

-- ── Ton ─────────────────────────────────────────────────────────────────────
T("ten tons (US) -> 9 000 kg", function()
    assert_conv("The truck carried ten tons of coal.", "ten tons", "= 9 000 kg")
end)

T("ten tons (UK) -> 10 000 kg", function()
    assert_conv("The truck carried ten tons of coal.", "ten tons", "= 10 000 kg",
        { uk_volumes = true, language = "en-GB" })
end)

T("two tons of fun is figurative (no conversion)", function()
    assert_no_match("We had two tons of fun at the party.", "two tons")
end)

T("a hundred tons of paperwork is figurative (no conversion)", function()
    assert_no_match("There was a hundred tons of paperwork.", "hundred tons")
end)

T("registered tonnage is not a weight (no conversion)", function()
    assert_no_match("The ship had a displacement of forty tons.", "forty tons")
end)

-- ── Russian units ───────────────────────────────────────────────────────────
T("a hundred versts -> 110 km", function()
    assert_conv("They traveled a hundred versts.", "hundred versts", "= 110 km")
end)

T("three arshins -> 2.1 m", function()
    assert_conv("The cloth measured three arshins.", "three arshins", "= 2.1 m")
end)

T("five poods -> 80 kg", function()
    assert_conv("The merchant sold five poods of flour.", "five poods", "= 80 kg")
end)

-- ── Gill ────────────────────────────────────────────────────────────────────
T("two gills (US) -> 0.2 liters", function()
    assert_conv("He drank two gills of ale.", "two gills", "= 0.2 liters")
end)

T("two gills (UK) -> 0.3 liters", function()
    assert_conv("He drank two gills of ale.", "two gills", "= 0.3 liters",
        { uk_volumes = true, language = "en-GB" })
end)

T("green around the gills is a fish idiom, not a volume", function()
    assert_no_match("He looked green around the gills.", "gills")
end)

-- ── Historical/fantasy units (upstream issue #3) ─────────────────────────────
-- Short homographs (span/rod/pole/ell/hand/pace) and the flagged 5-letter ones
-- (perch/chain) only convert with a CLUSTER of ≥2 distinct gated units AND a
-- literal digit — the same rule that guards the Asian transliterations.
T("3 ell and 5 span (cluster) convert", function()
    assert_conv("The cloth was 3 ell and 5 span wide.", "3 ell", "= 3.4 m")
    assert_conv("The cloth was 3 ell and 5 span wide.", "5 span", "= 1.1 m")
end)

T("15 hands and 4 chain (cluster) convert", function()
    assert_conv("The stallion stood 15 hands and the road measured 4 chain.",
                "15 hands", "= 1.5 m")
    assert_conv("The stallion stood 15 hands and the road measured 4 chain.",
                "4 chain", "= 80 m")
end)

T("10 paces and 4 ell (cluster) convert", function()
    assert_conv("He stood 10 paces from the wall and 4 ell from the door.",
                "10 paces", "= 7.6 m")
    assert_conv("He stood 10 paces from the wall and 4 ell from the door.",
                "4 ell", "= 4.6 m")
end)

T("rod and pole are the same measure", function()
    assert_conv("He surveyed 2 rods by 3 poles of land.", "2 rods by 3", "= 10")
end)

-- Single gated unit with no cluster is left alone
T("5 span alone is not a length", function()
    assert_no_match("The cloth was 5 span wide.", "span")
end)

T("4 chain alone is not a length", function()
    assert_no_match("The road measured 4 chain.", "chain")
end)

T("15 hands alone is not a length", function()
    assert_no_match("The stallion stood 15 hands tall.", "hands")
end)

-- Everyday-word idioms never convert
T("life span is an idiom", function()
    assert_no_match("Her life span was remarkable.", "span")
end)

T("fishing rod is an idiom", function()
    assert_no_match("He bought a new fishing rod.", "rod")
end)

T("Ellen is a name, not an ell", function()
    assert_no_match("Ellen lived in the old house.", "ell")
end)

T("two hands of cards is not a length", function()
    assert_no_match("He held two hands of cards.", "hands")
end)

T("keep pace is an idiom", function()
    assert_no_match("She struggled to keep pace.", "pace")
end)

T("chain of events is an idiom", function()
    assert_no_match("It was a chain of events.", "chain")
end)

T("two perch is a fish, not 10 m", function()
    assert_no_match("We caught two perch that day.", "perch")
end)

-- ── Pinyin 時辰 appellations ("Shen Hour") ────────────────────────────────────
-- A named shichen converts to its fixed 2 h (120 min) even without a count.
T("the Shen Hour -> 120 min", function()
    assert_conv("It was the Shen Hour when they left.", "Shen Hour", "= 120 min")
end)

T("the Chou Hour -> 120 min", function()
    assert_conv("The raid began during the Chou Hour.", "Chou Hour", "= 120 min")
end)

T("the Si Hour -> 120 min", function()
    assert_conv("At the Si Hour the temple bells rang.", "Si Hour", "= 120 min")
end)

T("the Ch'en Hour (Wade-Giles) -> 120 min", function()
    assert_conv("The attack came at the Ch'en Hour.", "Ch'en Hour", "= 120 min")
end)

T("a preceding ordinal does not multiply a shichen", function()
    assert_conv("They met at the third Shen Hour.", "Shen Hour", "= 120 min")
end)

T("lowercase clock hour never matches", function()
    assert_no_match("It was the third hour of the day.", "hour")
    assert_no_match("We went for happy hour.", "hour")
end)

-- Capitalized English renderings of 更/點/刻: like the Asian units they need a
-- literal digit AND a book cluster of >=2 distinct gated units.
T("3 Watch and 7 Mark (cluster) convert", function()
    assert_conv("3 Watch passed, then 7 Mark fell.", "3 Watch", "= 432 min")
    assert_conv("3 Watch passed, then 7 Mark fell.", "7 Mark", "= 168 min")
end)

T("2 Hour with 3 Ke (cluster) convert", function()
    assert_conv("The ritual took 2 Hour and 3 Ke.", "2 Hour", "= 240 min")
    assert_conv("The ritual took 2 Hour and 3 Ke.", "3 Ke", "= 45 min")
end)

T("a lone capitalized Watch needs a cluster", function()
    assert_no_match("3 Watch passed.", "Watch")
end)
