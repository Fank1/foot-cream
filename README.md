## What is Footcream?

![Footcream](https://github.com/Fank1/foot-cream/releases/download/readme-assets/hero-img.png)

Are you tired of mentally trying to convert "six foot four" or "ninety degrees Fahrenheit" while reading English books? The Footcream plugin for KOReader scans your book once, finds every measurement and converts it to the unit system **you** think in. Imperial books become metric, and metric books become imperial: *"1.8 m"* → *"5 ft 11 in"*, *"30 °C"* → *"86 °F"*. You can choose to **underline** each one so you can **tap for the conversion**, or choose to **rewrite the text in place** so the converted value is just *there* as you read.

It's built to be smart about context. It knows the difference between pounds (the money) and pounds (the weight), between a six-foot man and a six-foot-by-eight-foot room, and it leaves idioms like *"stand on your own two feet"* alone.

It runs totally on-device (no API:s or Wifi needed). A novel takes about 15–30 seconds to scan (on an newer Kobo). The scan runs in the background, so you can read while it does it's magic.

NOTE: Although Claude Code helped a lot in the writing of Lua, I have QA:ed this plugin extensively with a large variety of content – so please don't judge it as bare slop before you tested it. Please give it a try - would love to hear the feedback!

***

## Features

- **Both directions**: set **Convert units to** Metric, Imperial (US) or Imperial (UK). Metric books get natural imperial compounds, like *"75 kg"* → *"165 lb"* (UK: *"11 st 11 lb"*) and *"500 ml"* → *"17 fl oz"*, and imperial books get metric, in every mode.
- **3 reading modes**
  - **Underline & tap**: non-destructive. Measurements get a distinct underline; tap one for a popup with the conversion.
  - **Alongside original (in text)**: inserts the conversion as a parenthetical gloss (e.g. *"six feet (1.8 m)"*), keeping the original text. Fully reversible.
  - **Converted only (in text)**: rewrites the book's text in place (e.g. *"six feet"* → *"1.8 m"*). Fully reversible.
- **Per-book off switch**: *"Enable Footcream in this book"* turns it off for one book (restores its text, stops prompts) while every other book keeps working.
- **Self-explaining menu**: long-press any menu item for a plain-language explanation of what it does.
- **Distinct highlight style**: plugin underlines never get confused with your own highlights.
- **Customisable styling**: solid or wavy underline, intensity, thickness, tooltip size (S / M / L), optional unit icon. The styling dialog is draggable.
- **Per-category toggles**: turn whole groups (length, weight, volume, …) on or off.
- **UK / US aware**: uses imperial or US gallons & pints based on the book's language.
- **Smart Rounding** toggle clean, human-readable values instead of cluttery precision.
- **"Show original units"** option for the *Converted only (in text)* mode: underlines the converted values and lets you tap to see the original text.
- **Opt-in error reporting**: long-press a unit (or select text Footcream missed) to flag a bad conversion straight to the developer. Anonymous, works offline, and directly improves future versions.
- **Fast on reopen**: results are cached in a per-book sidecar; new books are scanned automatically.
- **Updateable**: check for and install updates from inside the plugin.
- **Reversible & per-book**: *"Remove Footcream data from this book"* undoes everything cleanly.

***

## Supported units

| Category        | Imperial                             | Metric         |
| --------------- | ------------------------------------ | -------------- |
| 📏 Length       | inch / inches                        | cm             |
| 📏 Length       | foot / feet / ft                     | m              |
| 📏 Length       | yard / yards / yd / yds              | m              |
| 📏 Length       | fathom / fathoms                     | m              |
| 📏 Length       | furlong / furlongs                   | m              |
| 📏 Length       | mile / miles / mi                    | km             |
| 📏 Length       | nautical mile / nmi                  | km             |
| 📏 Length       | league / leagues                     | km             |
| 📏 Length       | cubit / cubits                       | m              |
| 📏 Length       | span / spans / hand / hands          | m              |
| 📏 Length       | rod / rods / pole / poles / perch / perches | m        |
| 📏 Length       | chain / chains                       | m              |
| 📏 Length       | ell / ells / pace / paces            | m              |
| 📏 Length       | verst / versts                       | km             |
| 📏 Length       | arshin / arshins                     | m              |
| ⚖️ Weight       | ounce / ounces / oz                  | g              |
| ⚖️ Weight       | pound / pounds / lb / lbs            | kg             |
| ⚖️ Weight       | stone                                | kg             |
| ⚖️ Weight       | ton / tons                           | kg             |
| ⚖️ Weight       | pood / poods                         | kg             |
| ⚖️ Weight       | carat / carats                       | g              |
| 🧪 Volume       | fluid ounce / fl oz                  | mL             |
| 🧪 Volume       | pint / pints / pt                    | L              |
| 🧪 Volume       | quart / quarts / qt                  | L              |
| 🧪 Volume       | gallon / gallons / gal               | L              |
| 🧪 Volume       | gill / gills                         | mL             |
| 🌡️ Temperature | °F / degrees Fahrenheit              | °C             |
| 🚀 Speed        | mph / miles per hour / miles an hour | km/h           |
| 🚀 Speed        | knot / knots / kn                    | km/h           |
| 🟩 Area         | acre / acres                         | ha             |
| 🟩 Area         | square miles / feet / yards / …      | km² / m² / cm² |
| ⚡ Energy       | hp / horsepower                      | kW             |
| ⚡ Energy       | BTU / British thermal unit(s)        | kJ             |
| ⚡ Energy       | calorie / calories                   | kJ             |
| 🔧 Pressure    | psi / pounds per square inch         | kPa            |
| 🔧 Pressure    | atmosphere / atmospheres / atm       | kPa            |
| 🔧 Pressure    | mmHg / millimeters of mercury        | kPa            |
| 📏 Length       | li / zhang / chi / cun / ri / cho / ken / shaku / sun / jang / cheok / chon (*) | m / km |
| ⚖️ Weight       | jin / liang / qian / kan (*)          | kg             |
| 🧪 Volume       | shō / gō / koku                      | L              |
| 🟩 Area         | mu / tan / tsubo / pyeong (*)        | m²             |
| ⏱ Time         | shichen / geng / dian / ke           | min            |
| ⏱ Time         | the Shen/Chou/…/Hai Hour (12 時辰)    | min            |
| ⏱ Time         | Hour / Watch / Mark / Ke             | min            |

*Volumes follow the book's locale: UK imperial vs. US measures. Energy and pressure categories work in both directions (imperial↔metric).*

**In the imperial direction** (Convert units to: Imperial US/UK) the same categories work in reverse: km/m/cm/mm, kg/kilos/grams, °C, liters/ml, km/h, hectares and square km/m/cm all convert, as natural compounds (*"1.8 m"* → *"5 ft 11 in"*, *"2.5 kg"* → *"5 lb 8 oz"*), with stones and imperial pints/gallons in the UK flavor and eighth-inch fractions for small lengths (*"9 mm"* → *"⅜ in"*). Kilowatts, kilojoules and kilopascals convert to hp, BTU and psi respectively.

**Height notation**: curly-quote primes (*6′4″*) and bare compound notation (*6'4*) are detected and converted to metric (*1.93 m*). Fractional inches (*5 ft 9½ in*) are supported. A speech-close guard prevents false positives on dialogue markers like *6'4" she said*.

> **A note on tons:** Footcream converts *tons* using a context classifier. Standing weights (*"weighed ten tons"*) convert to kilograms (*≈ 9 000 kg*), while register tonnage (*"displacement of 50 000 tons"*) and figurative uses (*"tons of trouble"*) are left untouched. Carat is similarly guarded: *"18 carat gold"* (fineness) is preserved, while *"a 2-carat diamond"* (weight) converts to grams.

> **A note on Asian/transliteration units (\*) and other short spellings:** these stage in historical-CJK fiction (wuxia etc.), but several spell like English words (*"go"*, *"sun"*, *"tan"*, *"ken"*, *"mu"*, *"li"*). So the short ones (≤ 4 letters) only convert when the **book** clearly uses them — at least two distinct transliteration units somewhere in it — **and** the number is written as digits (*"30 li"*). That keeps *"in one go"* (an idiom, not 0.18 litres) and *"she got a tan"* from ever converting, while *"the caravan went 30 li, the farm covered 2 mu"* converts normally. Longer spellings (*"zhang"*, *"shichen"*, *"koku"*) are unambiguous and convert freely.

> **A note on 時辰 (traditional Chinese time):** besides the pinyin forms *shichen / geng / dian / ke*, Footcream recognises the English renderings of the twelve named two-hour periods — *"the Shen Hour"*, *"the Chou Hour"*, … *"the Hai Hour"* (broad pinyin/Wade-Giles romanizations) — each converting to its fixed 2 h (*120 min*), even without a count. The capitalized generic *Hour / Watch / Mark / Ke* (→ *shichen / geng / dian / ke*) convert like the other short homographs: they need a literal number and a book cluster, so ordinary *"happy hour"* and clock *"hour"* are never touched.

***

## Smart handling

Footcream isn't a dumb find-and-replace. A lot of the code goes into matching the right things and leaving the wrong things alone.

### Pounds: weight or money?

*"£"* and *"pounds"* are the same word for two different things, so Footcream weighs the surrounding context:

- **Weight cues**: *weighed, heavy, sack, crate, cargo, freight, boulder, overweight,* and nearby weight units (*stone, ounce*) push toward **weight** → converts to kg.
- **Currency cues**: *paid, cost, fortune, coins, salary,* and the **£** symbol push toward **money** → left alone.
- **Hard cues always win**: a *£* symbol, the word *sterling*, or coin denominations mark it as money no matter what else is around.
- **Magnitude prior**: a bare amount of *1000 pounds or more* with no weight cue is treated as currency (people rarely casually carry half a ton).

### Other smartness

- **Height notation**: curly-quote primes (*6′4″*), bare compound notation (*6'4*), and fractional inches (*5 ft 9½ in*) are detected and converted to metric. A speech-close guard prevents false positives on dialogue markers.
- **UK vs. US volumes**: gallons and pints differ between the two; Footcream picks the right factor from the book's language.
- **Compound measurements**: heights like *"six foot four"*, *"5 ft 7 in"*, *"six-foot-five-inch"*, *"five-foot, seven inches"*, and *"six feet, one and a half inches"* are read as a single value. Same for weights: *"nine stone four"*, *"seven pounds four ounces"*.
- **Ranges**: *"four to five feet"*, *"twelve or fifteen miles"* convert to a metric range.
- **Fractions**: fractions *18½*), spelled-out fractions (*"two thirds of a mile"*, *"one and three-quarter leagues"*), and additive tails (*"two miles and a half"*).
- **Vague quantities**: *"a few hundred pounds"* becomes a range (*≈ 90–230 kg*) rather than a fake-precise number. Open for suggestions on how to improve this further.
- **Dimensions**: *"twenty feet by ten"* → *6 × 3 m*.
- **Smart rounding**: about two significant number, finer detail below a metre, whole numbers for vague distances.
- **Knows what to ignore**
  - *"stand on your own two feet"*, *"one inch at a time"*, *"a foot in the door"*
  - *Stone* as rock, *pints* in a pub when they're not a measurement
  - Screen sizes (a *15-inch* laptop stays a laptop)
  - Latitude/longitude coordinate marks
  - Chapter titles and headings are never converted

***

## The three modes

Tap **Mode** in the menu to open the picker: it shows one sample sentence rendered in each of the three modes (with a live underline in your own styling), so you can see exactly what you're choosing. The mode names follow your **Convert units to** setting: under an imperial preference they read *"tap for imperial"*, *"Imperial alongside original"*, and so on.

### Underline units, tap for the conversion

Measurements are underlined in your chosen style. Tap one to see a popup with the converted value and a unit icon. Your book's text is never changed.

### Alongside original (in text)

Footcream inserts each conversion right after the original measurement, in parentheses: *"six feet"* becomes *"six feet (1.8 m)"*, or *"1.8 m"* becomes *"1.8 m (5 ft 11 in)"* under an imperial preference. Nothing is hidden or replaced, and no tapping is required. The book is fully reversible via *"Remove Footcream data from this book"* (Advanced).

### Converted only (in text)

Footcream rewrites the measurements in the book's text itself. *"six feet"* becomes *"1.8 m"* as you read, no tapping required. Turn on **"Show original units"** (Advanced) to underline the converted values and tap any of them to see the original text. This helps if you are worried something is not converted correctly. The book is fully reversible via *"Remove Footcream data from this book"* (Advanced).

***

## Styling

Open the styling dialog to customise how underlines and tooltips look, with a live preview.

![Styling dialog](https://github.com/Fank1/foot-cream/releases/download/readme-assets/styling.png)

***

## Installation

1. Download the latest `foot-cream.koplugin` release.
2. Copy the `foot-cream.koplugin` folder into your KOReader `plugins/` directory.
3. Restart KOReader.

You can check for updates via **Check for updates** in the plugin menu.

***

## Usage

1. Open a book in KOReader and go to **Settings** (Cogs) → **Footcream**. Either scan book-for-book or toggle the **Auto-scan** feature. It checks if the book is in English. It will leave other languages alone.
2. Pick your system under **Convert units to** (Metric / Imperial US / Imperial UK) and a conversion mode; adjust styling and unit categories (Advanced) to taste.
3. Start reading! 

***

## How it works

Footcream scans the book's whole text once and stores the results in a small per-book sidecar file, so subsequent opens are instant. The two *(in text)* modes rewrite the book file's text. They're always reversible, but they *do* modify the stored book.

***

## Limitations

- Coverage supports English-language books only

***

## Contribution

- Fork and do your own thing with it or submit issues and I will update Footcream to become better over time.
- PRs will not really be prioritized, sorry.

### Flagging bad conversions

The best way to help is to flag conversions that come out wrong while you read. The easiest path: turn on **Advanced** → **"Long-press units to send errors to the developer"**. With it on, flags are sent anonymously to the developer and feed directly into improving the scanner, no manual steps. Flags made while offline are queued and sent automatically once you're connected again.

**How to flag (with the toggle on):**

- **Long-press a unit while reading**: an underlined measurement, or converted text in the two *(in text)* modes. Pick the issue that fits:
  - **⚑ Wrong conversion**: it converted, but the value is off.
  - **⚑ Wrong text captured**: it grabbed too little or too much of the measurement.
  - **⚑ Not a unit**: it marked something that isn't a measurement at all.
- **Footcream missed a measurement entirely?** Select the text (long-press + drag) and tap **⚑ Flag to Footcream** in the selection menu, then **⚑ Missed unit**.
- You can also long-press any entry in **Advanced** → **Debug** → **Units in book (list)**.

Each flag records the book title, what was detected, the value, the conversion, the surrounding sentence, and its location. Nothing else.

**Prefer not to send anything?** Leave the toggle off. Flags made from the Units list are still saved to a plain-text log on the device at `koreader/footcream/flagged_errors.txt` (e.g. on a Kobo, `.adds/koreader/footcream/flagged_errors.txt`). You can review it via **Debug** → **View flagged errors**, attach it to a GitHub issue in this repo, then tidy up with **Debug** → **Clear flagged errors**.

### Translations

Footcream's menus come in 30 languages, but every one of them was first
drafted by AI — so they need a real speaker to read them and fix what sounds
wrong. That happens here, with nothing to install and no programming:

**https://crowdin.com/project/foot-cream**

Even ten corrected lines genuinely help. See
[CONTRIBUTING.md](CONTRIBUTING.md) for where to start.

***

## License

Footcream is free software, licensed under the **GNU Affero General Public
License v3.0 or later** (AGPL-3.0-or-later). The full text is in
[LICENSE](LICENSE).

Copyright (C) 2026 Erik Fanki

The plugin runs inside KOReader's own Lua process and uses its internals, and
[KOReader is AGPL-3.0](https://github.com/koreader/koreader) — so Footcream
matches it. In practice: use it, fork it, modify it freely; if you distribute a
modified version, ship its source under the same terms.

Community translations contributed through Crowdin are under the same licence,
so they can be shipped as part of the plugin — see
[CONTRIBUTING.md](CONTRIBUTING.md).
