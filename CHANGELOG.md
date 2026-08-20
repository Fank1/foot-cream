# Changelog

## v1.8.2

Footcream was mistaking quotation marks for foot marks, so quoted numbers turned into measurements — `'18'` on a label became 5.5 m. That's now fixed in nearly every case, and no real measurements were lost along the way.

Also fixed: `6' 4"` is read as one height instead of two, page numbers in indexes and endnotes are no longer read as sizes, big numbers like "one hundred and eight million" are no longer split in two, and phrases like "one and one-half inches" now get underlined in full.

## v1.8.1

Two fixes, both about Footcream doing things you didn't ask for.

### Leaving a book now stops its scan

Starting a scan and going back to your home screen left the scan running. In the two in-text modes it would then convert the book anyway — rewriting it and reopening it on top of whatever you were looking at, several seconds after you'd walked away.

Leaving a book now cancels its scan, and cancels the conversion queued behind it. Nothing is rewritten, and nothing reopens itself. This works whichever home screen you use, including replacements like the Bookshelf plugin.

### Old conversions are left alone unless you asked for automatic ones

A book converted by an earlier version was interrupted on opening with a question about updating its conversions — a question about an internal version number, asked while you were trying to start reading.

That now only happens with **Auto-convert when opening a new book** switched on, which is the setting that says "rewrite my books without asking". With it off, an already-converted book simply opens, keeping the conversions it has. "Rescan book" still refreshes one whenever you want.

## v1.8.0

Scanning a book is roughly four times faster, and converting one asks its question before it starts rather than after.

### Scanning got much faster

On a Kobo, a 1 MB novel took **87 seconds to scan. It now takes under 10.** The whole scan-and-convert, start to finish, went from about 100 seconds to 23.

Nothing was dropped to get there — the plugin looks for exactly the same measurements as before, and finds exactly the same ones. Three changes did it:

- It no longer reads through the whole book once for every unit name it knows. It first checks which of those 54 names the book actually contains, and only searches for those. On a typical novel that skips about 39 of them outright.
- Where it still has to search, it now starts from the digits rather than from every character in the book, so it can skip from number to number instead of inspecting the spaces between words.
- Several searches that used to make separate passes now share one.

### One action, one question

Choosing a mode that writes into your book used to scan first and ask afterwards — so you waited, then got a question you could still say no to. It now asks up front ("Scan and convert"), and the whole job runs under one progress ring.

New option: **Auto-convert when opening a new book.** With it on, a new English book is converted as you open it without asking. With it off (the default), nothing is converted until you ask.

### Fixed

- **Long books appeared to freeze part-way through a scan.** They weren't frozen — the plugin gave up on any scan that took over a minute and stopped without saying so. Slow books are now given the time they need, and a scan that genuinely fails says so instead of leaving a stalled progress ring on screen.
- **Tapping the screen during a conversion silently cancelled it.** A stray tap — or turning a page — abandoned the whole thing with no message.
- **"Converted N units in book" arrived while the plugin was visibly still working**, sometimes with the progress ring jumping backwards afterwards. The notice now waits until everything has actually finished.
- **Switching a converted book back to underline-only said "Restored original units in book"** — technically true, but it answered a question you hadn't asked. It now tells you what you actually changed: "Underlined N units in book".
- **Rescanning announced that the previous conversion had been restored**, mid-way through redoing it, which read as the plugin undoing its own work.
- Long-press-to-report no longer holds up the end of a conversion. It needs to work out where each converted measurement ended up; that now happens quietly in the background afterwards.

### Translations

Still 30 languages, now including this release's new wording. Hungarian has had its first review by a native speaker — 23 strings improved. If you read one of these languages, corrections are very welcome and take a few minutes; see [CONTRIBUTING.md](CONTRIBUTING.md).

### Scanner

Cache version 64 → 67; already-scanned books rescan themselves once on open.

## v1.7.0

Thank you for all the errors/flags you've sent in! The conversion and filtering is now much improved thanks to that. Please keep doing that. 

### Footcream now speaks 30 languages

The plugin interface — menu entries, dialogs, notifications and the long-press explainers — is translatable, and this release ships with 30 languages: Arabic, Catalan, Chinese (Simplified and Traditional), Czech, Danish, Dutch, Estonian, Finnish, French, German, Greek, Hebrew, Hungarian, Indonesian, Italian, Japanese, Korean, Norwegian Bokmål, Polish, Portuguese (Brazil and Portugal), Romanian, Russian, Slovak, Spanish, Swedish, Turkish, Ukrainian, Vietnamese.

Footcream follows KOReader's own language setting — there is nothing to configure. Anything not yet translated falls back to English.

**Only the interface changes. Your conversions do not.** The scanner, the maths and the output are untouched by any of this: the same measurements are found, the same values come out, and a measurement reads identically in every language — `1.8 m`, `5 ft 11 in`, `°C`, decimal point and all. In the two modes that rewrite the book's text, **not one translated word is written into your book.** Switching KOReader to Japanese changes the menus and nothing else.

**These are machine-assisted drafts awaiting native speakers.** If you read one of these languages, corrections are very welcome and take a few minutes — see [CONTRIBUTING.md](CONTRIBUTING.md).

### Fixed

- **Android: "Check for updates" crashed the reader outright.** KOReader's dismissable-subprocess helper forks, and Android's runtime can't safely fork a live process once network work has started. The update check now runs inline on Android. 
- **"Rescan book" silently did nothing in the two in-text modes.** The scan ran and reported its matches, then never re-applied the conversion — no error, no prompt, indistinguishable from the plugin being broken.
- **Scanning no longer flashes or ghosts the screen.** The corner progress ring repaints only its own small region instead of forcing a full-screen refresh.
- **One rescan could produce up to five separate interruptions**, two of them reporting different counts ("Scan complete: 321 units found" immediately followed by "Converted 304 units in book"). The scan notice is now suppressed when a conversion is queued behind it; the mode that only underlines still always announces, since there the notice is the only feedback there is.

### Scanner

Cache version 59 → 64; already-scanned books rescan themselves once on open.

- **"2001's" and "the 90's" are no longer read as heights** A guard for this shipped in 1.6.0 but could never actually fire.
- **Height notation with curly quotes now works** — `6'2"` as typeset by most commercial EPUBs, not just the straight-quote form. 
- **"ten degrees Celsius" is no longer converted as Fahrenheit** — an already metric figure was coming out as −12 °C.
- Bare **"degrees"** converts as Fahrenheit only when the surrounding sentence is about temperature; angles, proof and headings are left alone. "minus seventy degrees" now negates correctly.
- **"twenty-three square leagues"** and hyphenated compounds like **"250,000-square-foot"** now convert as areas rather than lengths.
- **"three-toed feet"** is no longer read as a distance
