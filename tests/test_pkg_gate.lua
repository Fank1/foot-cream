-- tests/test_pkg_gate.lua — opt-in UNIT PACKAGES (see FootFree._PKG_UNITS).
-- Each package (asian, fantasy) is OFF by default on-device; the harness flips
-- them on by default, so these tests drive opts.pkg_enabled to exercise the gate.
-- Even inside a CLUSTER with a literal number, a disabled package must produce
-- zero conversions for its units.

local T = require("run")

-- ── Asian package OFF: units never convert, even in a cluster + literal ───────
T("asian package OFF: 30 li does not convert", function()
    assert_no_match("The farm covered 2 mu, and the caravan went 30 li.",
                     "li", { pkg_enabled = { asian = false } })
end)

T("asian package OFF: jin/zhang cluster does not convert", function()
    assert_no_match("The market sold 5 jin of grain and 3 zhang of cloth.",
                     "jin", { pkg_enabled = { asian = false } })
    assert_no_match("The market sold 5 jin of grain and 3 zhang of cloth.",
                     "zhang", { pkg_enabled = { asian = false } })
end)

T("asian package OFF: pinyin shichen period does not convert", function()
    assert_no_match("Two shichen passed before the dawn.",
                     "shichen", { pkg_enabled = { asian = false } })
end)

-- ── Asian package ON: same inputs convert ─────────────────────────────────────
T("asian package ON: 30 li converts again", function()
    assert_conv("The farm covered 2 mu, and the caravan went 30 li.",
                "30 li", "= 15 000 m", { pkg_enabled = { asian = true } })
end)

T("asian package ON: shichen converts again", function()
    assert_conv("Two shichen passed before the dawn.",
                "Two shichen", "= 240 min", { pkg_enabled = { asian = true } })
end)

-- ── Fantasy package OFF: units never convert, even in a cluster + literal ─────
T("fantasy package OFF: 10 span does not convert", function()
    assert_no_match("The hall measured 10 span from wall to wall.",
                     "span", { pkg_enabled = { fantasy = false } })
end)

T("fantasy package OFF: span/rod cluster does not convert", function()
    assert_no_match("He cut 5 span of rope and 3 rod of timber.",
                     "span", { pkg_enabled = { fantasy = false } })
    assert_no_match("He cut 5 span of rope and 3 rod of timber.",
                     "rod", { pkg_enabled = { fantasy = false } })
end)

-- ── Fantasy package ON: same inputs convert ──────────────────────────────────
-- (A cluster of ≥2 gated units is still required — the package toggle is the
-- outer opt-in; the CLUSTER+DIGIT guard is the inner FP defense, both must pass.)
T("fantasy package ON: span/ell cluster converts again", function()
    assert_conv("The cloth was 3 ell and 5 span wide.",
                "5 span", nil, { pkg_enabled = { fantasy = true } })
end)

-- ── Packages are independent: turning one off must not affect the other ───────
T("asian OFF keeps fantasy ON working", function()
    assert_no_match("The caravan went 30 li down the road.",
                     "li", { pkg_enabled = { asian = false, fantasy = true } })
    assert_conv("The cloth was 3 ell and 5 span wide.",
                "5 span", nil, { pkg_enabled = { asian = false, fantasy = true } })
end)
