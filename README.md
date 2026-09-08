# Footcream

**Read English books in the units you think in.** Footcream scans a book once, finds every measurement, and converts it: imperial to metric, or metric to imperial.

![Footcream](https://github.com/Fank1/foot-cream/releases/download/readme-assets/hero-img.png)

*"six foot four"* → *1.93 m* · *"ninety degrees Fahrenheit"* → *32 °C* · *"1.8 m"* → *5 ft 11 in*

Everything runs on the device. No account, no network, no API. A novel takes 15–30 seconds to scan on a recent Kobo, in the background, while you read.

---

## Three modes

Pick one per book. The mode picker shows the same sentence rendered all three ways, in your own underline style, so you can see the choice before you make it.

| Mode | What you see | Touches the book file? |
| --- | --- | --- |
| **Underline & tap** | *six feet* underlined; tap for a popup | No |
| **Alongside original** | *six feet (1.8 m)* | Yes, reversible |
| **Converted only** | *1.8 m* | Yes, reversible |

Both in-text modes are undone completely by **Remove Footcream data from this book**. In *Converted only*, switch on **Show original units** to underline converted values and tap to see what the book actually said.

---

## Supported units

Set **Convert units to**: Metric, Imperial (US) or Imperial (UK). Every category below works in **both directions**.

| | Converts | To |
| --- | --- | --- |
| 📏 **Length** | inch/inches · foot/feet/ft · yard/yards/yd/yds · fathom/fathoms · furlong/furlongs · mile/miles/mi · nautical mile/nmi · league/leagues · cubit/cubits | cm · m · km |
| ⚖️ **Weight** | ounce/ounces/oz · pound/pounds/lb/lbs · stone | g · kg |
| 🧪 **Volume** | fluid ounce/fl oz · pint/pints/pt · quart/quarts/qt · gallon/gallons/gal | mL · L |
| 🌡️ **Temperature** | °F · degrees Fahrenheit | °C |
| 🚀 **Speed** | mph · miles per hour · miles an hour · knot/knots/kn | km/h |
| 🟩 **Area** | acre/acres · square miles/feet/yards/… | ha · km² · m² · cm² |

**In reverse** (Imperial US/UK) the same categories convert back (km/m/cm/mm, kg/kilos/grams, °C, liters/ml, km/h, hectares, square km/m/cm) as natural compounds: *"1.8 m"* → *5 ft 11 in*, *"2.5 kg"* → *5 lb 8 oz*, *"9 mm"* → *⅜ in*. The UK flavour uses stones and imperial pints and gallons.

Volumes follow the book's own locale, because UK and US gallons and pints differ.

> **Tons are deliberately not converted.** A long ton is 1016 kg, a short ton 907 kg, a metric tonne 1000 kg. Rather than guess wrong, Footcream leaves them alone.

---

## It reads context, not just numbers

Most of the code exists to convert the right things and leave the wrong things alone.

**Pounds: weight or money?** The same word, two meanings, so the surrounding words decide.

- *weighed, heavy, sack, crate, cargo, freight, boulder*, and nearby *stone* or *ounce* → **weight**, converts
- *paid, cost, fortune, coins, salary*, and the **£** symbol → **money**, left alone
- **£**, *sterling*, or a coin denomination always wins, whatever else is nearby
- A bare *1000 pounds or more* with no weight cue reads as money

**It reads these correctly:**

- **Compounds**: *"six foot four"*, *"5 ft 7 in"*, *"six-foot-five-inch"*, *"nine stone four"*, *"seven pounds four ounces"*. Each is one measurement, not two
- **Ranges**: *"four to five feet"*, *"twelve or fifteen miles"*
- **Fractions**: *18½*, *"two thirds of a mile"*, *"one and three-quarter leagues"*, *"two miles and a half"*
- **Vague amounts**: *"a few hundred pounds"* becomes *≈ 90–230 kg*, not fake precision
- **Dimensions**: *"twenty feet by ten"* → *6 × 3 m*
- **Smart rounding**: about two significant figures, finer detail below a metre

**It ignores these:**

- Idioms: *"stand on your own two feet"*, *"a foot in the door"*, *"one inch at a time"*
- *Stone* as rock, *pints* in a pub
- Screen sizes: a *15-inch* laptop stays a laptop
- Latitude and longitude marks
- Chapter titles and headings

---

## Install

1. Download the latest `foot-cream.koplugin` release.
2. Copy the `foot-cream.koplugin` folder into KOReader's `plugins/` directory.
3. Restart KOReader.

Then **Settings** (cogs) → **Footcream** → pick **Convert units to** and a mode, and read. Switch on **Auto-scan** to have new books handled for you; non-English books are detected and left alone.

Update from inside the plugin with **Check for updates**.

---

## Good to know

- **Per-book off switch**: *Enable Footcream in this book* stops it for one book, restores its text, and leaves every other book working.
- **Per-category toggles**: turn length, weight, volume and the rest on or off individually.
- **Styling**: solid or wavy underline, intensity, thickness, tooltip size, optional unit icon, with a live preview. Plugin underlines never look like your own highlights.
- **Self-explaining menu**: long-press any menu item for a plain explanation.
- **Fast on reopen**: results are cached per book in a small sidecar file.
- **30 languages**: the interface follows KOReader's own language setting.

![Styling dialog](https://github.com/Fank1/foot-cream/releases/download/readme-assets/styling.png)

**Limitations:** English-language books only. Tons unsupported, as above.

---

## Help make it better

The single most useful thing you can do is flag a bad conversion while reading.

Switch on **Advanced** → **Long-press units to send errors to the developer**. Flags go to the developer anonymously and feed straight into the scanner. Offline flags are queued and sent later.

<details>
<summary><b>How to flag</b></summary>

**Long-press a measurement** while reading (an underlined one, or converted text in the in-text modes), then pick:

- **⚑ Wrong conversion**: it converted, but the value is off
- **⚑ Wrong text captured**: it grabbed too little or too much
- **⚑ Not a unit**: it marked something that is not a measurement

**Missed a measurement?** Select the text (long-press and drag), tap **⚑ Flag to Footcream**, then **⚑ Missed unit**.

You can also long-press any entry in **Advanced** → **Debug** → **Units in book (list)**.

Each flag records the book title, what was detected, the value, the conversion, the sentence around it, and its location. Nothing else.

**Prefer to send nothing?** Leave the toggle off. Flags from the Units list are still written to `koreader/footcream/flagged_errors.txt` on the device (on a Kobo, `.adds/koreader/...`). Read it via **Debug** → **View flagged errors**, attach it to a GitHub issue, then **Debug** → **Clear flagged errors**.

</details>

<details>
<summary><b>Translations, no programming needed</b></summary>

All 30 languages were drafted by AI and need a real speaker to fix what sounds wrong. Nothing to install:

**https://crowdin.com/project/foot-cream**

Ten corrected lines genuinely help. See [CONTRIBUTING.md](CONTRIBUTING.md).

</details>

<details>
<summary><b>Code contributions</b></summary>

Fork it and do your own thing, or open issues. I improve Footcream over time from them. Pull requests are not really prioritised, sorry.

</details>

<details>
<summary><b>How it works, and licence</b></summary>

Footcream scans the book's full text once and stores the results in a small per-book sidecar, so later opens are instant. The two in-text modes rewrite the book file itself. They are always reversible, but they do modify the stored book.

Licensed under the **GNU Affero General Public License v3.0 or later** (AGPL-3.0-or-later); full text in [LICENSE](LICENSE). Copyright (C) 2026 Erik Fanki.

The plugin runs inside KOReader's own Lua process and uses its internals, and [KOReader is AGPL-3.0](https://github.com/koreader/koreader), so Footcream matches it. Use it, fork it, modify it freely; if you distribute a modified version, ship its source under the same terms.

Crowdin translations are under the same licence, so they ship with the plugin. See [CONTRIBUTING.md](CONTRIBUTING.md).

</details>
