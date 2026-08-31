-- tests/test_units.lua — conversion values for the core unit set, both
-- directions. These lock in the scan+convert+format pipeline against real
-- main.lua logic. Expected strings are the plugin's actual smart-rounded
-- output (not naive exact conversions).

local T = require("run")

-- ── Length (imperial → metric) ──────────────────────────────────────────────
T("six feet -> 1.8 m", function()
    assert_conv("He was six feet tall.", "six feet", "= 1.8 m")
end)

T("three inches -> 8 cm", function()
    assert_conv("A three inch nail lay there.", "three inch", "= 8 cm")
end)

T("two miles -> 3.2 km", function()
    assert_conv("They walked two miles.", "two miles", "= 3.2 km")
end)

T("one yard -> 90 cm", function()
    assert_conv("Throw it one yard.", "one yard", "= 90 cm")
end)

T("five feet two inches compound -> 1.57 m", function()
    assert_conv("She was five feet two inches tall.", "five feet", "= 1.57 m")
end)

T("fifty fathoms -> 90 m", function()
    assert_conv("The anchor line ran fifty fathoms.", "fifty fathoms", "= 90 m")
end)

T("one league -> 5 km", function()
    assert_conv("The town was one league away.", "one league", "= 5 km")
end)

T("two hundred cubits -> 90 m", function()
    assert_conv("The wall measured two hundred cubits.", "two hundred cubits", "= 90 m")
end)

-- ── Weight (imperial → metric) ──────────────────────────────────────────────
T("four pounds -> 1.8 kg", function()
    assert_conv("The package weighed four pounds.", "four pounds", "= 1.8 kg")
end)

T("nine stone four -> 59 kg", function()
    assert_conv("The boxer weighed nine stone four.", "nine stone", "= 59 kg")
end)

T("eight ounces -> 230 g", function()
    assert_conv("Add eight ounces of flour.", "eight ounces", "= 230 g")
end)

-- ── Temperature ─────────────────────────────────────────────────────────────
T("98 degrees Fahrenheit -> 37 °C", function()
    assert_conv("The fever read 98 degrees Fahrenheit.", "98 degrees Fahrenheit", "= 37 °C")
end)

T("98°F -> 37 °C", function()
    assert_conv("It hit 98°F outside.", "98°F", "= 37 °C")
end)

T("-10°F -> -23 °C", function()
    assert_conv("The night fell to -10°F.", "-10°F", "= -23 °C")
end)

-- ── Volume ──────────────────────────────────────────────────────────────────
T("US two gallons -> 7.6 liters", function()
    assert_conv("The tank held two gallons.", "two gallons", "= 7.6 liters")
end)

T("UK two gallons -> 9 liters", function()
    assert_conv("The tank held two gallons.", "two gallons", "= 9 liters",
        { uk_volumes = true, language = "en-GB" })
end)

T("one pint -> 0.5 liters", function()
    assert_conv("Pour one pint of milk.", "one pint", "= 0.5 liters")
end)

T("twelve fluid ounces -> 350 mL", function()
    assert_conv("A twelve fluid ounce can.", "twelve fluid ounce", "= 350 mL")
end)

-- ── Speed & area ────────────────────────────────────────────────────────────
T("sixty miles per hour -> 100 km/h", function()
    assert_conv("The car did sixty miles per hour.", "sixty miles per hour", "= 100 km/h")
end)

T("ten knots -> 19 km/h", function()
    assert_conv("The wind blew ten knots.", "ten knots", "= 19 km/h")
end)

T("ten acres -> 4 hectares", function()
    assert_conv("They farmed ten acres.", "ten acres", "= 4 hectares")
end)

T("fifty square feet -> 4.6 m²", function()
    assert_conv("The shed measured fifty square feet.", "fifty square feet", "= 4.6 m²")
end)

-- ── Metric → imperial direction ─────────────────────────────────────────────
T("metric direction: 1.8 m -> 5 ft 11 in", function()
    assert_conv("The room was 1.8 m long.",
        "1.8 m", "= 5 ft 11 in", { imperial = true })
end)

T("metric direction: 75 kg -> 165 lb", function()
    assert_conv("The crate held 75 kg.",
        "75 kg", "= 165 lb", { imperial = true })
end)

T("metric direction: 30 °C -> 86 °F", function()
    assert_conv("It reached 30 °C.",
        "30 °C", "= 86 °F", { imperial = true })
end)
