-- tests/test_new_energy_pressure.lua — energy/pressure category tests.
-- Locks in the new imperial↔metric conversions for energy and pressure units.

local T = require("run")

-- ══════════════════════════════════════════════════════════════════════════════
-- Energy: imperial → metric
-- ══════════════════════════════════════════════════════════════════════════════
T("150 hp → kW", function()
    assert_conv("The engine produced 150 hp.", "hp", "= 110 kW")
end)

T("1000 BTU → kJ", function()
    assert_conv("The furnace output 1000 BTU.", "BTU", "= 1 060 kJ")
end)

T("calories → kJ (dietary)", function()
    assert_conv("She ate 200 calories.", "calories", "= 840 kJ")
end)

T("one horsepower → kW", function()
    assert_conv("The machine used one horsepower.", "horsepower", "= 0.8 kW")
end)

-- ══════════════════════════════════════════════════════════════════════════════
-- Pressure: imperial → metric
-- ══════════════════════════════════════════════════════════════════════════════
T("30 psi → kPa", function()
    assert_conv("Tire pressure was 30 psi.", "psi", "= 200 kPa")
end)

T("1 atmosphere → kPa", function()
    assert_conv("The sample sat at 1 atmosphere.", "atmosphere", "= 100 kPa")
end)

T("760 mmHg → kPa", function()
    assert_conv("The pressure was 760 mmHg.", "mmHg", "= 100 kPa")
end)

-- ══════════════════════════════════════════════════════════════════════════════
-- Energy: metric → imperial (needs imperial=true to set preferred=us)
-- ══════════════════════════════════════════════════════════════════════════════
T("100 kW → hp (imperial pref)", function()
    assert_conv("The motor ran at 100 kW.", "kW", "= 134 hp", {imperial = true})
end)

T("500 kJ → BTU (imperial pref)", function()
    assert_conv("The heater output 500 kJ.", "kJ", "= 474 BTU", {imperial = true})
end)

-- ══════════════════════════════════════════════════════════════════════════════
-- Pressure: metric → imperial (needs imperial=true)
-- ══════════════════════════════════════════════════════════════════════════════
T("100 kPa → psi (imperial pref)", function()
    assert_conv("The gauge read 100 kPa.", "kPa", "= 15 psi", {imperial = true})
end)

T("200 kPa → psi (imperial pref)", function()
    assert_conv("The pressure reached 200 kPa.", "kPa", "= 29 psi", {imperial = true})
end)

-- ══════════════════════════════════════════════════════════════════════════════
-- Guard: carat gold (existing guard suppresses conversion)
-- ══════════════════════════════════════════════════════════════════════════════
T("18 carat gold — no conversion", function()
    assert_no_match("The ring was 18 carat gold.", "carat")
end)

T("24 carat — no conversion", function()
    assert_no_match("24 carat gold is pure.", "carat")
end)

-- ══════════════════════════════════════════════════════════════════════════════
-- Guard: "atmosphere" is only a pressure with a NUMBER ("1 atmosphere"), not
-- the figurative mood sense ("an atmosphere of dread") that an article would
-- otherwise feed into.
-- ══════════════════════════════════════════════════════════════════════════════
T("an atmosphere of suspense is NOT a pressure", function()
    assert_no_match("There was an atmosphere of suspense in the room.", "atmosphere")
end)

T("an atmosphere of dread is NOT a pressure", function()
    assert_no_match("An atmosphere of dread hung over the hall.", "atmosphere")
end)
