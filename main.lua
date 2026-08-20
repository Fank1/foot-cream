local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Widget          = require("ui/widget/widget")
local Geom            = require("ui/geometry")
local Blitbuffer      = require("ffi/blitbuffer")
local InfoMessage     = require("ui/widget/infomessage")
local UIManager       = require("ui/uimanager")
local DataStorage     = require("datastorage")
local logger          = require("logger")
local Notification    = require("ui/widget/notification")
local Event           = require("ui/event")
local RenderImage     = require("ui/renderimage")
local ok_lfs, lfs     = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
if not ok_lfs then lfs = nil end
-- ffi/util provides runInSubProcess / isSubProcessDone for background work
local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local _  = require("gettext")
local T  = ffiutil.template

-- Out-of-tree plugins aren't part of KOReader's own l10n project (the core
-- GetText textdomain is hardcoded to "koreader", one .mo per language), so
-- Footcream ships its own compiled translations and merges them into the
-- SAME lookup table gettext() reads from — loadMO() only adds entries, it
-- doesn't clear what's already loaded (only changeLang() does that), so this
-- is safe to run after core's own translations are in place. Must happen
-- before any module-level table literal below calls _(), so it runs here
-- rather than in FootFree:init() (which only runs once a book is opened).
do
    local plugin_dir = (debug.getinfo(1, "S").source or ""):match("@?(.*)/[^/]*$") or "."
    _.loadMO(plugin_dir .. "/l10n/" .. tostring(_.current_lang) .. "/foot-cream.mo")
end

local FootFree = WidgetContainer:extend{
    name     = "foot-cream",
    _enabled = true,
    -- Books whose Footcream data the user removed THIS SESSION (keyed by file
    -- path). Auto-scan skips them so the rescan/convert prompt doesn't pop right
    -- back up after "Remove Footcream data from this book" (the removal reloads
    -- the document, which re-runs onReaderReady). Lives on the CLASS table —
    -- reloadDocument recreates the plugin instance, so an instance field would
    -- be lost. Not persisted: reopening the book in a later session auto-scans
    -- again as normal. A manual "Scan book" clears the entry.
    _removed_this_session = {},
}

-- ── Unicode constants (decimal-escaped UTF-8) ─────────────────────────────────
local _PRIME  = "\226\128\178"   -- ′  U+2032
local _DPRIME = "\226\128\179"   -- ″  U+2033
-- Curly/smart-quote twins of the ASCII apostrophe/quote — most commercial
-- EPUBs are typeset with these, not straight ASCII, for shorthand height
-- notation ("6’2”"). Recognized everywhere the straight forms are (issue #2).
-- Class attributes, not `local`s — see the 200-local ceiling note in
-- references/gotchas.md.
FootFree._CAPOS  = "\226\128\153"   -- '  U+2019 curly right single quote (apostrophe)
FootFree._CDQ    = "\226\128\157"   -- "  U+201D curly right double quote
-- The OPENING twin. Not a measurement glyph — it is how we tell a closing
-- quotation mark apart from an inches mark when a digit sits before it
-- (“Reach 18” is a call sign, 18” is a measurement; see the quotation guard).
FootFree._CLDQ   = "\226\128\156"   -- "  U+201C curly left double quote
-- Its single-quote twin. British typesetting quotes speech and quoted strings
-- with '…', so a quoted NUMBER ends in the same glyph as a feet mark: Wool's
-- socket labels ("the jack labelled '18'") produced 32 false 5.5 m readings.
-- U+2018 is unambiguous — it is never an apostrophe — so counting it against
-- U+2019 can only ever UNDER-report an open quotation, never invent one.
FootFree._CLSQ   = "\226\128\152"   -- '  U+2018 curly left single quote
local _ENDASH = "\226\128\147"   -- –  U+2013
local _TIMES  = "\195\151"       -- ×  U+00D7
local _SUP2   = "\194\178"       -- ²  U+00B2 (superscript two)

local CACHE_VERSION = 68  -- bumped: the bare-prime audit (2026-08-20). The full 187-book English corpus scan made 91 prime-notation detections; every one was read by hand against the book text. The COMPOUND form ("6'2\"") was a real measurement 19 times out of 19. The bare INCH mark was right 4 times in 9. The bare FEET mark was right ONCE in 63 — and that once was half of a spaced "6' 4\"" that the compound pattern should have claimed whole. Everything else was a closing quotation mark, a call number, an apostrophe or a coordinate; Wool alone contributed 32, because British typesetting quotes strings in '…' and the book is full of numbered floors, sockets and channels. THREE changes. (1) FootFree._prime_fp_reason — ten tells that the glyph CLOSES something rather than measuring it: a quote immediately before the digits (42 of the 72 bare false positives, and the cheapest test there is), an unmatched U+2018/U+201C earlier in the paragraph, a dash before the number (a year span in a citation title), a Victorian middle-dot decimal, a clock time, "No."/"#", a year after a month name, digits continuing straight after the mark (Dewey/LC call numbers — no need to guess where front matter ends), any letter after a bare FEET mark ("86'd", and this subsumes the old possessive-s guard, which is now DELETED rather than duplicated), and a zero-length measurement. Every rule was measured against all 91 corpus hits before it went in: together they suppress 62 of the 72 bare hits and cost ZERO of the genuine ones. A positive measurement cue after the mark (tall/wide/deep/long/across/by/square/×) short-circuits all ten, which is what keeps a height spoken inside single-quoted dialogue converting — no corpus hit carries such a cue, so this costs nothing today and is the insurance against the guards over-reaching later. The guard runs in the prime PASS, sharing its paragraph read with the coordinate check: crengine's prev_text is five words (~45 chars), far too short to see the opening quote of "'around 50,000'", and its next_text starts at the following WORD, so "86'd" and "823'.92" arrive with the evidence already swallowed — only a document read sees them. (2) _is_coordinate learned U+00BA (Two Years Before the Mast sets "33º 30' S." throughout, so the ° test missed every coordinate in the book) and the PLURAL abbreviation "degs."/"degs" (the Beagle's "57 degs. 23' south"). (3) Two pattern gaps that were losing real measurements: the compound now allows ONE SPACE between the figures ("6' 4\"" = 1.93 m, was two bare hits), and a new inches-BY-inches dimension entry converts both figures of "10\" × 8\"" (the feet×inches form existed; DBL×DBL fell through, so the 8" stayed imperial beside a metric 10"). classify indices renumbered 4→5 entries. Covered by smoketest5 CH52 and 28 new headless cases in lua_helper_tests; EXPECTED_TOTAL 329 -> 332. VM-VERIFIED, and the verification earned its keep: the cue exemption above SHIPPED INERT. It read crengine's next_text, and next_text SKIPS THE ADJACENT WORD — for "The shelf was 6' wide" it begins " and hard to reach", with the cue already swallowed. So the test could never fire, and the only reason the corpus measurement still looked right is that no corpus cue-carrying hit sat inside a quotation. A probe book with "'He was 6' tall,' she said" showed it in one scan: the height was dropped. Both context arguments are now document reads (widths tried 24/12/4/2, because the match can sit near the end of its node), and the headless cases were rewritten against real book text rather than an invented next_text. This is the THIRD guard in this file to ship compiled, green and doing nothing — see cache 64's possessive-s test and cache 65's shy-book gate — and all three failed the same way: a suppression that silently stops working is indistinguishable from one that works, so nothing short of reading a real match list catches it. Two harness faults surfaced with it, both now fixed: verify_scan.py checked must-not rules against DISPLAY-SUPPRESSED matches the reader never sees (a correctly suppressed currency case read as a regression), and sidecar_to_json.lua's classifier mirror still called _pound_currency_wins with two arguments after it grew a third, so the rate-tail rule looked dead from the outside — it now extracts FootFree._pound_rate_tail too and shouts on stderr instead of silently reporting nothing suppressed. Scan evidence, all on smoketest5 unless noted: 337 matches, 0 must-not violations; smoketest5shy 13; smoketest6 39 under "us". Corpus book diffs — Wool 76 -> 44 visible (32 quoted numbers gone, its one real 8" becomes the dimension 8" x 2"), Written In Bone 29 -> 22 (7 index entries gone, all 8 genuine 5ft/6ft heights kept), I Heard You Paint Houses 60 -> 57 (6' + 4" merged into 6' 4" = 1.93 m, two call numbers gone), Lee Miller 34 -> 33 (two bare 10" become 10" x 8" dimensions), Orbital 39 -> 39 with four range renderings corrected ("160 and 13 000 000 km" -> "170 000 000 km"), Manhunt 21/2 inches 53 cm -> 6 cm, 20,000 Leagues span widened to "one and three-quarter leagues", Two Years Before the Mast 143 -> 141, Voyage of the Beagle 642 -> 641 with its 40+ "and" ranges untouched, Moby Dick 161 -> 160, SPQR 42 -> 40. FULL CORPUS RE-SCAN, 226 books, every change accounted for: 9,467 -> 9,372 reader-visible matches. 98 suppressed outright (69 prime, 25 index/endnote, 1 runaway span, 3 by sense — Gulliver's "thirty pounds a year" and the two walking idioms), 66 CORRECTED IN PLACE, 3 newly appearing (the inches-by-inches dimensions), and NOTHING unexplained. Prime detections 91 -> 25, of which 23 are compound/dimension and all correct; the 2 residual bare false positives ("EC1’", "IG XI.4.756’") are both the documented under-fire direction of the quote-balance rule, where an apostrophe earlier in the paragraph balances the count. The in-place corrections are mostly ONE THING: 57 spans widened with the value unchanged, and 53 of those are the cookbook's "one and one-half inches" being underlined as "one-half inches" — the same extend_start fault as Verne and Darwin, and in Add/Convert mode it was writing "one and 4 cm" into the text 53 times in one book. The 7 value changes are the scaled-and ranges (Orbital x4, Gulliver, The Lost City of Z 500-and-180 000 km2 -> 700 000 km2, The Last Devil To Die) plus Manhunt's 21/2 inches. The income-rate rule earns exactly ONE correction: 9 of its 10 corpus hits were ALREADY suppressed by the existing cue table (usually "annum" or "income" in the same window), so its smoketest case had to be scrubbed of every other cue word — heading included, since crengine feeds heading text into prev_text — before it tested anything at all. (One book, The Bell Jar, reported "not-english" in the batch run and scanned identically to before in isolation: a known race in the sweep harness's language probe, not a plugin change.) SECOND BATCH, same audit, same cache: the 21 non-prime confirmed bugs. (a) INDEX AND ENDNOTE ENTRIES — the number-walk collects words backwards from the unit, and in an index the words behind it are page numbers ("amputation tattoos 279; foot" = 85 m). Four rules, one principle (the number must be ADJACENT to the unit), each measured corpus-wide with ZERO legitimate matches caught: a semicolon between them (6 hits), a BLOCK BREAK immediately before the unit word (13) — anchored at the unit so a <br/> inside a spelled compound, which is legitimate and is smoketest5 CH26 case E, cannot trip it — a sentence-ending period crossed on the way back (9, "30. Fathom" from a table of contents), and a non-alias word GLUED to the number ("8Katzmarzyk PT" = 3.8 litres; 28 corpus hits carry a glued letter run and exactly the 3 non-alias ones are wrong, the rest spelling lb/mph/ft/QT or the "x" of "10x10 feet"). (b) RUNAWAY SPANS — the compound "N feet M inches" walk glued numbers thousands of characters apart, producing a single 9,331-character "match" across most of a Moby Dick chapter and a 6,847 one in Two Years Before the Mast. Corpus median span is 11 characters and the 99.9th percentile is 41, so an 80-character cap is a backstop nothing real approaches: exactly 2 of 9,763 hits exceed it, and both are those runaways. (c) A COMPOUND NUMBER READ AS A RANGE — "one hundred and eight million miles" came out of Orbital as "160 and 13 000 000 km". The existing guard only recognised a SMALL second operand (n2 < 100); these carry a scale word of their own, so the test is now that n2's multiplier exceeds n1 ("two hundred and fifty thousand" = (200+50) x 1000, n1 200 < scale 1000), which leaves a genuine shared-scale range like "between one hundred and two hundred feet" alone. 7 corpus hits, all wrong, none of the 91 real "and" ranges near them. (d) AN ADDITIVE SPAN THAT STOPPED SHORT — extend_start validates a candidate with _parse_num, which is STRUCTURALLY unable to confirm the additive form: "one and three-quarter leagues" is 1.75 but _parse_num prefix-reads it as 1, which is exactly why _prev_num_words computes that value itself. So the test could never become true, the loop ran out, and the span fell back short — correct 8.4 km attached to two thirds of the phrase. Harmless in Underline mode; in Add/Convert it writes "one and 8.4 km" into the book. A second validator mirrors the additive branch (whole + fraction, exact hit only). Darwin's "thirteen and three-quarters British miles" is the same shape. (e) THE WALKING IDIOM — "one foot carefully placed in front of the other" (Fourth Wing) and "putting one foot steadily in front of the other" (Evicted): the "in front" cue is anchored at the start of next_text and could not see past the wedged-in adverb, so the whole phrase "in front of the other/next" is now matched unanchored, still inside the <=2 body-scale gate. (f) AN INCOME RATE — "thirty pounds a year", "twenty pounds per annum" read as weights. ADJACENCY is the whole rule and the reason this is its own list rather than three more _CURRENCY_PHRASES: 25 corpus pound matches have a rate phrase somewhere in their window and 8 of those are genuine weights ("ballooning up fifteen pounds in a month", "T. rex put on about 1,700 pounds per year"), and every one of them either separates the phrase from the unit or uses a DAILY/WEEKLY rate — so those two forms are absent and the phrase must open next_text. 10 hits then, all money. Worth one vote, so a genuine weight cue still ties and keeps. (The reader also suggested "got"; measured and REJECTED — of 16 pound matches with "got" nearby most are plain weights: lifted eighty pounds, dropped about ten pounds, went about 350 pounds, sixteen pounds of marijuana.) (g) AN ASCII TYPESET HALF — "21/2 inches above the clavicle" (Manhunt) read as 53 cm. The tight-U+2044 improper-numerator rule from cache 51 now also accepts a plain "/", but ONLY the improper form and only for denominators a fraction actually uses (2/3/4/8/16), so "12/25" and "10/12" stay dates. Together with the prime work above this corrects ~43 corpus detections. Covered by smoketest5 CH53 and 21 more headless cases; EXPECTED_TOTAL 332 -> 335. (67 was: two reader-flagged fixes. (1) Report #37 — "29,028 feet" (Everest) converted to "9 000 m". The conversion was right (8 847.7 m); smart rounding then flattened it, because plain metres at distance scale round within a 4% band REGARDLESS of source precision and 9 000 is only 1.72% away, so one significant figure swallowed a five-figure surveyed number. Distance targets (m/km) now floor the collapse at the source's own significant digits via _sig_digits, gated on `not _is_approx_num(n)` so an admittedly-round source still rounds hard: 29,028 ft -> 8 848 m and 511 ft -> 156 m (which the comment at the top of that section always CLAIMED happened), while 1,700 ft -> 500 m and 3,000 ft -> 900 m are unchanged. Ranges keep rounding coarse (force=true). (2) Reports #40/#41 — a closing curly quote after a digit read as inches: the call sign "Reach 18" came out as 46 cm. The existing guard only catches a quote after PUNCTUATION ("1836."); here a digit genuinely precedes the glyph, so the tell is an unmatched OPENING curly quote earlier in the context. Bare inches only — a spoken height ("5'10\"") carries a feet mark and is matched by the compound pattern, which never reaches this guard. Corpus-checked over 45 books before adding: 4 matches sit inside an open quotation, ALL FOUR citations or call signs, zero genuine measurements (one, "1913-1914\" -> -5 000 cm, was a live FP nobody had reported). (3) Reports #35/#36 — a foot as a BODY PART read as a distance. "had done so on two feet, and operated the door" = 60 cm: the "on/with <n> feet" idiom guard only covered the literal word "one", so it is now the whole ≤2 body scale (the "of" exception still protects a real "on two feet of packed snow"). "one foot is wrapped around the calf of her other leg" = 30 cm: every body-verb cue is anchored at the START of the following text and a copula sat in front of them all, so a leading is/was/were/are is now stripped before the cues run, and wrapp/hook/tuck/curl/propp/cross joined them (≤2-gated — "fifty feet wrapped around the post" is rope). Both were VM-confirmed STILL LIVE on a probe book before fixing, not assumed from the v59 report. Covered by smoketest5 CH50 and CH41; EXPECTED_TOTAL 321 -> 329. (66 was: the scan is now ONE PLAIN findAllText per unit alias for every book. It was a single 54-branch regex alternation, justified by "the cost is the per-call document walk, not the matching" — profiling says the opposite (2026-08-17, Lonesome Dove 366k words): plain search for "miles" 0.03s, regex \bmiles\b 0.52s for the IDENTICAL 177 hits, and the alternation grew ~0.08s per branch to 4.82s of a 5.0s scan. Its (?:\b|(?<=[0-9])) left anchor alone was 2.34s. 54 plain passes cost ~1.6s, so doing it 54 times is ~3x cheaper; plain search also needs no \b anchor, which is what let cache 65's bug exist (\b cannot see a soft hyphen where a letter would be). Equivalence was PROVEN before the switch, not assumed: 12 books both ways, both directions, every match set identical — smoketest5 321, smoketest6 39, smoketest5shy 13, Lonesome Dove 261. Measured end to end: Lonesome Dove 5.13s -> 2.43s, The End of Men 1.91s -> 0.69s, SPQR 16.6s -> 12.2s; tiny books pay slightly more (smoketest5 0.24s -> 0.28s) because each pass has a fixed cost. The regex path is DELETED rather than kept as a fallback: two paths that were supposed to agree and silently did not is exactly what produced cache 65, and only the unprofiled one had the hole. Shy books also stopped running the prime/°F regex passes unconditionally: they now answer "does this book contain 6'2\" or °F at all?" from the RAW FILE via metric_epub.probe_notation (tags stripped, entities decoded, any failure answers yes-to-everything) instead of from the 160s crengine read. 73% of a 45-book corpus contain neither, so most shy books now skip all 7. Controlled pair, same prose: lonesome-dove-shy 16.99s -> 2.74s against lonesome-dove 2.39s, both 261 matches; smoketest5shy still 13 with 0 passes, smoketest5 still 321 with 7 passes run (it does contain the notation). Shy-book ETA multiplier corrected 55x -> 8x. (65 was: soft-hyphen books. TWO fixes, both surfaced by profiling one novel against an 82k-soft-hyphen twin of itself (2026-08-17). (1) The shy path's adjacent-character boundary probe read exactly ONE character, and in these books that character is frequently the soft hyphen itself — not %a, so the guard passed and the "mi" alias matched inside longer words: "losing five mi|nutes" converted as "five mi" = 8 km, 48 times in one book. The probe now reads 4 characters and strips U+00AD before testing. (2) The whole-book getTextFromXPointers gate that decides whether to run the prime/°F literal passes cost 0.02s on the ordinary book and 159.95s on the shy twin — 98% of the entire scan, and it gated nothing: zero passes ran after it. Shy books now skip the gate and take the same branch as a failed gate read (run the passes unconditionally), the conservative direction: a wrong "skip" is silent lost prime/°F coverage, a wrong "run" is a few extra passes. (64 was: the year/decade possessive guard for a bare feet-mark ("2001's", "the 90's") ACTUALLY WORKS now. It shipped in 63 but was inert: it tested next_text for a leading "s", and crengine builds context word-by-word — "2001’s" is one token, so the possessive "s" is swallowed and next_text starts at " Ghosts of Mars". The test could never fire, so reports #11-13 (2001’ = 600 m) were still live; VM-verified 2026-08-07, 5 false positives in smoketest5 CH49. Now reads the actual next character from the document via _xpointer_offset, the same one-char xpointer read the mid-word guard below already uses (a genuine height reads a space there: "6’ wide"). (63 was: "square <unit>" now recognizes "league"/"leagues" (was missing from _AREA_CONV entirely — the "square" cue had nothing to convert with, so "twenty-three square leagues" was a total miss, report #10). "<count>-toed/-legged/-clawed/-pawed/etc. feet/foot" no longer reads as a distance — anatomy, not a measurement (report #9: "three-toed feet" was reading as 91 cm; the shared _parse_num word-number fallback treats a hyphen right after a number word as an ordinary compound-number boundary, the same mechanism that composes "twenty-three", so it doesn't distinguish "three-toed" from "twenty-three"). (62 was: shorthand height notation (issue #2) now recognizes curly/smart quotes ("6’2”"), not just straight ASCII/true-prime — most commercial EPUBs are typeset this way, which is why it looked entirely broken to the reporter. A digit-adjacent bare feet-mark ('/′/’) immediately followed by "s" is now read as a year/decade possessive or plural ("2001's", "the 90's"), not a height — closes the false positive in reports #11-13 ("2001's Ghosts of Mars" was reading as 2001 ft = 600 m). (61 was: bare "degrees" (no F/Fahrenheit qualifier) now converts as a Fahrenheit temperature when a nearby word suggests one (cold/hot/warm/chill/freez.../temperature/weather/humid/...); default is still to leave it alone (angle, rotation, proof, heading, latitude). Spelled "minus" before a number now negates it ("minus seventy degrees" = -70), matching the existing symbolic-dash handling. "N degrees below zero" is suppressed rather than mis-signed (residual — reports #14-33). (60 was: hyphenated adjectival "square <unit>" compounds ("a 250,000-square-foot room", "a three-million-square-foot cave") now detect as area — the "square" cue check missed the hyphen glue and fell through to the linear-foot factor, badly wrong and missing the ² (reports #22-24). (59 was: metric→imperial direction ("Preferred units": metric/us/uk; sidecars carry a direction field, matches can now target imperial compound formats). (58 was: hyphen-glued attributive fractions parse — "<ordinal>-of-a-<unit>-thick/long" reads as 1/denominator ("a third-of-a-mile-thick" = 540 m; "quarter-of-a" worked already via _WORD_NUMS, ordinals like "third" were nil because bare ordinals are ambiguous — the glued "-of-a" tail disambiguates). (57 was: bare-article "a million miles" (incl. "an hour"/"away" forms) suppressed as hyperbole — user-approved 2026-07-06, all 7 corpus hits figurative; digits and real multiples ("two million miles", "half a million miles") still convert. (56 was: URL path fragments never convert (digit/letter slash in matched_text — "178650/League" was 860 000 km); "N-foot-by-M-foot" dimension adjectives convert both sides ("twenty-foot-by-hundred-foot" = 6 × 30 m, was a bare 6 m). (55 was: shy-book plain passes enforce true \\b via adjacent-char probes on BOTH sides (plain-path contexts are word-based, so "15 mi|nutes"/"one kn|ows" looked clean and inflated matches 3-6x). (54 was: soft-hyphen books (U+00AD in the text) scan via per-alias PLAIN findAllText passes — the regex path returns span-shifted/missing hits in such books (The Rise and Fall of the Dinosaurs: "1,700 miles" never hit, "seven-ton" garbled). (53 was: new-test-books sweep fixes — em-dash/ellipsis glued to the number no longer defeats _prev_num_words ("too far—eleven feet six inches", "off course by…sixty miles", "park—four acres"); fused digit+unit forms hit via a digit lookbehind in _FAST_UNIT_PAT ("260lbs", "6ft"); banking vocabulary (bank/account/bills/untraceable) added to the soft-currency cues. (52 was: "for a mile" article cue (user-approved) + attributive-tail guard ("ran a mile RELAY" is a compound noun — the batch-2 motion-verb cues were wrongly converting it). (51 was: tight U+2044 fractions from sup/sub-span markup ("21⁄2-inch" = 2½, "13⁄16-inch" = 13/16 — improper-looking numerator reads as a mixed number, proper as a plain fraction). 50 was: corpus-sweep batch 2 follow-ups — prime matches re-check the coordinate/astronomy vocab on the tail of their own paragraph (the 5-word hit window missed "ABERRATION … is established 20″"); spaced U+2044 mixed fractions parse ("2 1 ⁄ 2 -inch plank" = 2.5); _prev_num_words' article-fraction tail requires both words ("half LONG" no longer reads 0.5, which spawned a bogus 0.5–1000 range eating "…a mile and a half long and 1000 ft. deep"). (49 was: batch 2 — FP guards for closing-quote/middle-dot/arcsecond; enumeration lists; ASCII mixed fractions; million; article-mile directional/motion cues; at-a-time ≤ 2; "<digit> of a mile" fraction guard. 48 was: foot-idiom positional cues gated ≤ 2.)))))
local _REVERSE_VERSION = 2  -- v2: ordered originals per converted string (position-aware reverse lookup)

-- ── Number prefixes ───────────────────────────────────────────────────────────

-- [^0-9,] before the digit prevents mid-number matches (e.g. "0 lbs" from "140 lbs").
-- A number, anchored on its first DIGIT.
--
-- This used to be "[^0-9,][0-9][0-9,.]*" — a mandatory non-digit, non-comma
-- boundary character, consumed as part of the match, to stop "1950" also
-- matching as "950"/"50"/"0". It worked, and it was almost the entire cost of
-- the pass: [^0-9,] matches nearly every character in a book, so the engine had
-- to attempt a match at every single position instead of skipping from digit to
-- digit. Measured on one novel, same alternation, only this atom changed:
-- 1.56s -> 0.24s, SIX TIMES faster (2026-08-18).
--
-- The boundary rule is not gone, it moved — see `needs_left_char` in
-- run_passes. Two halves of it, and neither costs a document read:
--   * a digit/comma to the left  -> already handled, for free, by seen_end:
--     "950'" and "1950'" share an END xpointer, and document order delivers the
--     longer one first, so the sub-match is dropped as a tail sub-match.
--   * no character at all to the left (the match starts a text node) -> the old
--     pattern could not match there, so those hits are dropped explicitly.
local _ND  = "[0-9][0-9,.]*"

-- ── Word → number lookup ──────────────────────────────────────────────────────
-- Longest-first so sub(1,#word) finds the right entry before shorter prefixes.

local _WORD_NUMS = {
    { "a hundred thousand", 100000 }, { "one hundred thousand", 100000 },
    { "ninety thousand",  90000 }, { "eighty thousand",  80000 },
    { "seventy thousand", 70000 }, { "sixty thousand",   60000 },
    { "fifty thousand",  50000 }, { "forty thousand",  40000 },
    { "thirty thousand", 30000 }, { "twenty thousand", 20000 },
    { "nineteen thousand",19000 }, { "eighteen thousand",18000 },
    { "seventeen thousand",17000 }, { "sixteen thousand",16000 },
    { "fifteen thousand",15000 }, { "fourteen thousand",14000 },
    { "thirteen thousand",13000 }, { "twelve thousand", 12000 },
    { "eleven thousand", 11000 }, { "ten thousand",    10000 },
    { "nine thousand",    9000 }, { "eight thousand",   8000 },
    { "seven thousand",   7000 }, { "six thousand",     6000 },
    { "five thousand",    5000 }, { "four thousand",    4000 },
    { "three thousand",   3000 }, { "two thousand",     2000 },
    { "one thousand",     1000 }, { "a thousand",       1000 },
    -- Hyphenated N-thousand forms for compound adjectives ("twenty-thousand-foot peaks").
    -- Must precede plain "twenty" etc. in this prefix-match table.
    { "ninety-thousand",  90000 }, { "eighty-thousand",  80000 },
    { "seventy-thousand", 70000 }, { "sixty-thousand",   60000 },
    { "fifty-thousand",  50000 }, { "forty-thousand",  40000 },
    { "thirty-thousand", 30000 }, { "twenty-thousand", 20000 },
    { "nineteen-thousand",19000 }, { "eighteen-thousand",18000 },
    { "seventeen-thousand",17000 }, { "sixteen-thousand",16000 },
    { "fifteen-thousand",15000 }, { "fourteen-thousand",14000 },
    { "thirteen-thousand",13000 }, { "twelve-thousand", 12000 },
    { "eleven-thousand", 11000 }, { "ten-thousand",    10000 },
    { "nine-thousand",    9000 }, { "eight-thousand",   8000 },
    { "seven-thousand",   7000 }, { "six-thousand",     6000 },
    { "five-thousand",    5000 }, { "four-thousand",    4000 },
    { "three-thousand",   3000 }, { "two-thousand",     2000 },
    { "one-thousand",     1000 },
    -- Broader fractions (fourths/fifths/sixths/eighths/tenths). Bare forms —
    -- the fast scan strips "of a/an" and prefix-matches just the fraction
    -- ("two fifths of a mile" → "two fifths" = 0.4). Placed before the plain
    -- numbers further down so e.g. "one quarter" beats a bare "one".
    { "seven eighths", 0.875 }, { "five eighths", 0.625 }, { "three eighths", 0.375 },
    { "one eighth",   0.125 }, { "an eighth",    0.125 },
    { "four fifths",    0.8 }, { "three fifths",  0.6 }, { "two fifths",    0.4 },
    { "one fifth",      0.2 }, { "a fifth",       0.2 },
    { "five sixths",    5/6 }, { "one sixth",     1/6 }, { "a sixth",       1/6 },
    { "nine tenths",    0.9 }, { "seven tenths",  0.7 }, { "three tenths",  0.3 },
    { "one tenth",      0.1 }, { "a tenth",       0.1 },
    { "three fourths", 3/4 }, { "one quarter",   0.25 }, { "one fourth",   0.25 },
    { "a fourth",      0.25 }, { "one half",       0.5 },
    { "six sevenths",  6/7 }, { "five sevenths", 5/7 }, { "four sevenths", 4/7 },
    { "three sevenths",3/7 }, { "two sevenths",  2/7 }, { "one seventh",   1/7 },
    { "a seventh",     1/7 },
    { "eight ninths",  8/9 }, { "seven ninths",  7/9 }, { "six ninths",    6/9 },
    { "five ninths",   5/9 }, { "four ninths",   4/9 }, { "three ninths",  3/9 },
    { "two ninths",    2/9 }, { "one ninth",     1/9 }, { "a ninth",       1/9 },
    { "two thirds of a", 2/3 }, { "one third of a", 1/3 },
    { "three quarters", 3/4 }, { "a third of a",  1/3 },
    { "two thirds",     2/3 }, { "one third",     1/3 }, { "a third",      1/3 },
    { "a hundred",     100 }, { "one hundred",   100 }, { "two hundred",   200 },
    { "three hundred", 300 }, { "four hundred",  400 }, { "five hundred",  500 },
    { "six hundred",   600 }, { "seven hundred", 700 }, { "eight hundred", 800 },
    { "nine hundred",  900 },
    -- Hyphenated N-hundred forms for compound adjectives ("two-hundred-foot drop").
    -- Must precede plain "two", "three" etc.
    { "two-hundred",   200 }, { "three-hundred",  300 }, { "four-hundred",  400 },
    { "five-hundred",  500 }, { "six-hundred",    600 }, { "seven-hundred", 700 },
    { "eight-hundred", 800 }, { "nine-hundred",   900 },
    -- Hyphenated N-hundred (1100–1900) forms ("twelve-hundred-mile voyage")
    { "nineteen-hundred", 1900 }, { "eighteen-hundred", 1800 },
    { "seventeen-hundred",1700 }, { "sixteen-hundred",  1600 },
    { "fifteen-hundred",  1500 }, { "fourteen-hundred", 1400 },
    { "thirteen-hundred", 1300 }, { "twelve-hundred",   1200 },
    { "eleven-hundred",   1100 },
    -- Bare "million" mirrors bare "hundred"/"thousand": needed so the
    -- back-walk's _is_number_word("million") accepts it and compounds like
    -- "fifty-seven million gallons" compose (corpus-sweep miss, Lost City of Z).
    { "million",   1000000 },
    { "thousand",     1000 }, { "hundred",      100 },
    { "half an",       0.5 }, { "half a",        0.5 }, { "a quarter",    0.25 },
    { "a dozen",        12 }, { "a half",        0.5 }, { "a third",      1/3  },
    -- N-hundreds (1100–1900): must precede plain 11–19 entries
    { "nineteen hundred", 1900 }, { "eighteen hundred", 1800 },
    { "seventeen hundred",1700 }, { "sixteen hundred",  1600 },
    { "fifteen hundred",  1500 }, { "fourteen hundred", 1400 },
    { "thirteen hundred", 1300 }, { "twelve hundred",   1200 },
    { "eleven hundred",   1100 },
    { "nineteen",  19 }, { "eighteen",   18 }, { "seventeen", 17 },
    { "sixteen",   16 }, { "fifteen",    15 }, { "fourteen",  14 },
    { "thirteen",  13 }, { "twelve",     12 }, { "eleven",    11 },
    -- Compound tens (must precede plain tens in the lookup table)
    { "twenty-one", 21 }, { "twenty-two", 22 }, { "twenty-three", 23 },
    { "twenty-four", 24 }, { "twenty-five", 25 }, { "twenty-six", 26 },
    { "twenty-seven", 27 }, { "twenty-eight", 28 }, { "twenty-nine", 29 },
    { "thirty-one", 31 }, { "thirty-two", 32 }, { "thirty-three", 33 },
    { "thirty-four", 34 }, { "thirty-five", 35 }, { "thirty-six", 36 },
    { "thirty-seven", 37 }, { "thirty-eight", 38 }, { "thirty-nine", 39 },
    { "forty-one", 41 }, { "forty-two", 42 }, { "forty-three", 43 },
    { "forty-four", 44 }, { "forty-five", 45 }, { "forty-six", 46 },
    { "forty-seven", 47 }, { "forty-eight", 48 }, { "forty-nine", 49 },
    { "fifty-one", 51 }, { "fifty-two", 52 }, { "fifty-three", 53 },
    { "fifty-four", 54 }, { "fifty-five", 55 }, { "fifty-six", 56 },
    { "fifty-seven", 57 }, { "fifty-eight", 58 }, { "fifty-nine", 59 },
    { "sixty-one", 61 }, { "sixty-two", 62 }, { "sixty-three", 63 },
    { "sixty-four", 64 }, { "sixty-five", 65 }, { "sixty-six", 66 },
    { "sixty-seven", 67 }, { "sixty-eight", 68 }, { "sixty-nine", 69 },
    { "seventy-one", 71 }, { "seventy-two", 72 }, { "seventy-three", 73 },
    { "seventy-four", 74 }, { "seventy-five", 75 }, { "seventy-six", 76 },
    { "seventy-seven", 77 }, { "seventy-eight", 78 }, { "seventy-nine", 79 },
    { "eighty-one", 81 }, { "eighty-two", 82 }, { "eighty-three", 83 },
    { "eighty-four", 84 }, { "eighty-five", 85 }, { "eighty-six", 86 },
    { "eighty-seven", 87 }, { "eighty-eight", 88 }, { "eighty-nine", 89 },
    { "ninety-one", 91 }, { "ninety-two", 92 }, { "ninety-three", 93 },
    { "ninety-four", 94 }, { "ninety-five", 95 }, { "ninety-six", 96 },
    { "ninety-seven", 97 }, { "ninety-eight", 98 }, { "ninety-nine", 99 },
    { "ninety",    90 }, { "eighty",     80 }, { "seventy",   70 },
    { "sixty",     60 }, { "fifty",      50 }, { "forty",     40 },
    { "thirty",    30 }, { "quarter",   0.25 }, { "twenty",    20 },
    { "dozen",     12 }, { "ten",        10 }, { "nine",        9 },
    { "eight",      8 }, { "seven",       7 }, { "six",         6 },
    { "five",       5 }, { "four",        4 }, { "three",       3 },
    { "two",        2 }, { "half",       0.5 }, { "one",         1 },
}

-- ── Core helpers ─────────────────────────────────────────────────────────────

-- Strip the leading boundary character that _ND captures.
-- If matched_text starts with a non-digit then a digit, the first char is the
-- boundary (e.g. " 6ft" → "6ft"). Word patterns start letter+letter, not stripped.
-- UTF-8 bytes of U+2212 (−), the "real" minus sign some books use instead of
-- an ASCII hyphen. Treated as a leading minus everywhere a hyphen would be.
local _UMINUS = "\226\136\146"
-- Other dashes books use as a leading minus before a number ("–10°F", "—10°F").
local _ENDASH = "\226\128\147"   -- – U+2013
local _EMDASH = "\226\128\148"   -- — U+2014
local _APPROX = "\226\137\136"   -- ≈ U+2248 (prefix for vague-quantifier bands)
-- All four dash forms, longest-byte-safe, treated as a leading minus sign.
local _NEG_SIGNS = { ["-"] = true, [_UMINUS] = true, [_ENDASH] = true, [_EMDASH] = true }

local function _display(text)
    -- Strip the single leading boundary char the digit patterns require
    -- ([^0-9,]) — but keep a leading minus sign so negatives read correctly
    -- (e.g. "-10°F" must not display as "10°F"). U+2212 is multi-byte so it
    -- never matched the single-byte strip below anyway.
    local first = text:match("^([^0-9])[0-9]")
    if first and first ~= "-" then return text:sub(2) end
    return text
end

-- Spelled-out cardinal composition. _parse_num's _WORD_NUMS table is a flat
-- prefix-match, so a multi-part number like "five thousand five hundred" matched
-- only its first chunk (→ 5000) and "six and a half" lost the half. This composes
-- the number properly from the START of the text, stopping at the first
-- non-number token (prefix semantics). Hyphen/dash-joined forms ("six-and-a-half",
-- "five-thousand-five-hundred") work via normalising the joiners to spaces; a
-- comma ends the number (a measurement boundary, e.g. "…nine, two hundred thirty
-- pounds"). Returns value, value-token-count, had_fraction — or nil. Multiplicative
-- fractions ("two fifths", "three quarters") bail so the _WORD_NUMS table (which
-- knows them) handles them. Callers engage this only for ≥2 value tokens or an
-- additive fraction, so single words keep their exact _WORD_NUMS values.
local _NUM_UNIT = {
    zero=0, one=1, two=2, three=3, four=4, five=5, six=6, seven=7, eight=8, nine=9,
    ten=10, eleven=11, twelve=12, thirteen=13, fourteen=14, fifteen=15,
    sixteen=16, seventeen=17, eighteen=18, nineteen=19,
}
local _NUM_TEN = {
    twenty=20, thirty=30, forty=40, fifty=50, sixty=60, seventy=70, eighty=80, ninety=90,
}
local _NUM_SCALE = { thousand=1000, million=1000000, billion=1000000000 }
local _NUM_FRAC  = { half=0.5, quarter=0.25, third=1/3 }
-- Unicode "vulgar fraction" glyphs (their UTF-8 bytes) → decimal value, so
-- "18½ miles" reads 18.5 and "½ mile" reads 0.5. The ½/¼/¾ live in Latin-1
-- (2 bytes); the ⅓-family in U+215x (3 bytes).
local _VULGAR_FRAC = {
    ["\194\189"]     = 0.5,    -- ½
    ["\194\188"]     = 0.25,   -- ¼
    ["\194\190"]     = 0.75,   -- ¾
    ["\226\133\147"] = 1/3,    -- ⅓
    ["\226\133\148"] = 2/3,    -- ⅔
    ["\226\133\149"] = 0.2,    -- ⅕
    ["\226\133\155"] = 0.125,  -- ⅛
    ["\226\133\156"] = 0.375,  -- ⅜
    ["\226\133\157"] = 0.625,  -- ⅝
    ["\226\133\158"] = 0.875,  -- ⅞
}

-- Spelled multiplicative fractions: "three quarters" = 0.75, "three tenths" = 0.3,
-- "two thirds" ≈ 0.667, "a quarter" = 0.25. The denominator word maps to its
-- divisor; the numerator must be a small number word strictly below it (so
-- "three quarters" but not "five quarters", and not unrelated "<n> <noun>" pairs).
local _FRAC_DENOM = {
    half=2, halves=2, third=3, thirds=3, quarter=4, quarters=4,
    fourth=4, fourths=4, fifth=5, fifths=5, sixth=6, sixths=6,
    seventh=7, sevenths=7, eighth=8, eighths=8, ninth=9, ninths=9,
    tenth=10, tenths=10, twelfth=12, twelfths=12, sixteenth=16, sixteenths=16,
}
local function _word_fraction(text)
    local s = (text or ""):lower():gsub("%-", " "):gsub("^%s+", "")
    local nw, dw = s:match("^(%a+)%s+(%a+)")
    if not nw then return nil end
    local denom = _FRAC_DENOM[dw]
    if not denom then return nil end
    local numer = (nw == "a" or nw == "an") and 1 or _NUM_UNIT[nw]
    if not numer or numer < 1 or numer >= denom then return nil end
    return numer / denom
end

local function _compose_spelled(text)
    -- Only the ASCII hyphen joins parts of ONE number ("twenty-three",
    -- "six-and-a-half"). En/em dashes separate two numbers (a range, "five–six"),
    -- so they are NOT normalised here — otherwise "five–six" would compose to 11.
    local s = text:lower():gsub("%-", " ")
    local total, cur, frac = 0, 0, 0
    local ntok, started, await_frac, used = 0, false, false, 0
    -- Within one sub-hundred group there is at most one tens word and one units
    -- word ("eighty-five"). A second tens or units word means a NEW number, not a
    -- continuation — "eighty-five and ninety" is 85 then 90 (a range/list), NOT
    -- 175. These flags reset on hundred / dozen / a scale word (which open a fresh
    -- group), so "one hundred and twelve" still composes 100 + 12 = 112.
    local have_ten, have_unit = false, false
    for raw in s:gmatch("%S+") do
        local hard_stop = raw:find(",", 1, true) ~= nil   -- comma = number boundary
        local w = raw:gsub("[^%a]", "")
        if w == "and" then
            -- connector, ignore
        elseif w == "a" or w == "an" then
            await_frac = true                              -- "a half" vs "a hundred"
        elseif _NUM_UNIT[w] then
            if have_unit then break end                    -- "five six" → two numbers
            cur = cur + _NUM_UNIT[w]; have_unit = true
            ntok = ntok + 1; started = true; await_frac = false
        elseif _NUM_TEN[w] then
            if have_ten or have_unit then break end        -- "eighty-five and ninety" → 85, then stop
            cur = cur + _NUM_TEN[w]; have_ten = true
            ntok = ntok + 1; started = true; await_frac = false
        elseif w == "hundred" then
            cur = (cur == 0 and 1 or cur) * 100; have_ten, have_unit = false, false
            ntok = ntok + 1; started = true; await_frac = false
        elseif w == "dozen" then
            -- "two dozen" = 24, "a dozen" = 12. Without this branch the composer
            -- stopped at "dozen", mis-reading "two dozen" as 2 and leaving the
            -- Units-list value blank ("?") even though _WORD_NUMS knew dozen=12.
            cur = (cur == 0 and 1 or cur) * 12; have_ten, have_unit = false, false
            ntok = ntok + 1; started = true; await_frac = false
        elseif _NUM_SCALE[w] then
            total = total + (cur == 0 and 1 or cur) * _NUM_SCALE[w]
            cur = 0; have_ten, have_unit = false, false
            ntok = ntok + 1; started = true; await_frac = false
        elseif _NUM_FRAC[w] then
            -- additive fraction only ("six and a half"); a multiplicative form
            -- ("two fifths") has a number right before with no "a" → bail.
            if not started or not await_frac then return nil end
            frac = frac + _NUM_FRAC[w]; await_frac = false
        else
            break                                          -- non-number token: stop
        end
        used = used + 1                                    -- words consumed by this number
        if hard_stop then break end
    end
    if not started then return nil end
    -- 4th result: words consumed (lets a caller walk multiple numbers in a phrase).
    return total + cur + frac, ntok, frac > 0, used
end

local function _parse_num(text)
    -- ASCII mixed fraction "19-3/10" / "1-3/8" / "2 1/2" (also U+2044 ⁄): the
    -- plain digit path below would read just the integer (or, worse, stop at
    -- the hyphen). ASCII slash is TIGHT only — no spaces around it — so the
    -- OCR-mangled "1 /10" form (CH18) keeps its deliberate suppression. The
    -- U+2044 fraction slash is unambiguous, so spaces around it are just
    -- typography and allowed ("2 1 ⁄ 2 -inch plank", Sailor's Word-Book).
    -- p<q keeps this to genuine fractions ("3/10"), never date-ish "10/12".
    do
        local w, p, q = text:match("^%s*(%d+)[%-%s](%d+)/(%d+)%f[%D]")
        if not w then
            w, p, q = text:match("^%s*(%d+)[%-%s](%d+)%s*\226\129\132%s*(%d+)%f[%D]")
        end
        if w then
            local wn, pn, qn = tonumber(w), tonumber(p), tonumber(q)
            if wn and pn and qn and qn > 0 and pn < qn then
                return wn + pn / qn
            end
        end
        -- TIGHT U+2044 with no separator ("21⁄2-inch" — superscript/subscript
        -- spans render with no space): a proper-looking numerator is a plain
        -- fraction ("13⁄16" = 13/16), an improper-looking one is a MIXED
        -- number whose last digit is the numerator ("21⁄2" = 2½ — nobody
        -- typesets 21/2 with a fraction slash).
        --
        -- The ASCII slash gets the IMPROPER half of that rule and nothing else,
        -- because the same typesetting reaches print with a plain "/" too:
        -- Manhunt writes "the ball entering just behind the sterno-cleido
        -- muscle—21/2 inches above the clavicle", which read as 53 cm. A date
        -- or a division is the reason this was left alone before, so the
        -- denominator must be one a fraction actually uses — 2, 3, 4, 8, 16 —
        -- which excludes "12/25" and "10/12" outright. The proper-looking form
        -- ("13/16 inch") is untouched and still takes the path below.
        local n0, q0 = text:match("^%s*(%d+)\226\129\132(%d+)%f[%D]")
        if not n0 then
            local a, b = text:match("^%s*(%d%d+)/(%d+)%f[%D]")
            if a and (b == "2" or b == "3" or b == "4" or b == "8" or b == "16")
               and tonumber(a) > tonumber(b) then
                n0, q0 = a, b
            end
        end
        if n0 then
            local nn, qn = tonumber(n0), tonumber(q0)
            if nn and qn and qn > 0 then
                if nn < qn then return nn / qn end
                local whole, p1 = n0:sub(1, -2), tonumber(n0:sub(-1))
                if #whole > 0 and p1 and p1 >= 1 and p1 < qn then
                    return tonumber(whole) + p1 / qn
                end
            end
        end
    end
    local s_start, s_end, s = text:find("([0-9][0-9,.]*)")
    if s then
        local n = tonumber((s:gsub(",", "")))
        if n then
            -- A vulgar-fraction glyph fused to the digits ("18½") adds its value.
            local tail = text:sub(s_end + 1, s_end + 3)
            local vf = _VULGAR_FRAC[tail:sub(1, 2)] or _VULGAR_FRAC[tail:sub(1, 3)]
            if vf then n = n + vf end
            -- Honor a minus sign immediately before the digits — ASCII hyphen
            -- OR any of the Unicode dashes books use (U+2212 −, U+2013 –,
            -- U+2014 —) — so "−10°F"/"–10°F"/"—10°F" parse as -10, not 10.
            local before = text:sub(1, s_start - 1)
            if _NEG_SIGNS[before:sub(-1)] or _NEG_SIGNS[before:sub(-3)] then
                n = -n
            end
            return n
        end
    end
    -- A standalone vulgar-fraction glyph ("½ mile" → 0.5), after any leading space.
    local lead = text:gsub("^%s+", "")
    local vf0 = _VULGAR_FRAC[lead:sub(1, 2)] or _VULGAR_FRAC[lead:sub(1, 3)]
    if vf0 then return vf0 end
    -- Compose multi-word / additive-fraction spelled numbers ("five thousand five
    -- hundred" = 5500, "six and a half" = 6.5) the flat table below can't. Gated
    -- to ≥2 number tokens or a fraction, so single words and multiplicative
    -- fractions ("two fifths") still resolve via _WORD_NUMS.
    local cval, ctok, cfrac = _compose_spelled(text)
    if cval and (ctok >= 2 or cfrac) then return cval end
    -- Spelled multiplicative fraction ("three quarters" = 0.75, "three tenths" =
    -- 0.3) — before the flat _WORD_NUMS lookup, which would prefix-match just the
    -- numerator ("three" → 3).
    local wf = _word_fraction(text)
    if wf then return wf end
    -- Strip leading punctuation/space so a paren- or quote-attached word number
    -- still prefix-matches ("(three" → "three", "  ten" → "ten").
    local lower = text:lower():gsub("^[^%w]+", "")
    -- Hyphen-glued attributive fraction ("third-of-a-mile-thick rock"): the
    -- "-of-a" tail disambiguates the ordinal completely — "the third of May"
    -- is never hyphenated — so <denominator>-of-a reads as 1/denom. Singular
    -- only: a plural here would be the tail of a numerator form the composer
    -- already handles as one token ("two-thirds-of-a" = 2/3).
    do
        local dw = lower:match("^(%a+)%-of%-an?%f[%A]")
        local dd = dw and dw:sub(-1) ~= "s" and _FRAC_DENOM[dw]
        if dd and dd > 1 then return 1 / dd end
    end
    for _, entry in ipairs(_WORD_NUMS) do
        local word = entry[1]
        if lower:sub(1, #word) == word then
            -- Require a word boundary after the match so "tentacles" isn't read as
            -- "ten", "only" as "one", etc. A following letter means it's a longer,
            -- non-number word; digits/spaces/punctuation are fine.
            local nextc = lower:sub(#word + 1, #word + 1)
            if nextc == "" or not nextc:match("%a") then return entry[2] end
        end
    end
    return nil
end

-- Group the integer part with thin spaces as the thousands separator (SI style:
-- "160000" -> "160 000"), never a comma. Operates on a formatted number string,
-- preserving a leading sign and any decimal tail.
local function _group_thousands(s)
    local sign, intp, rest = s:match("^(%-?)(%d+)(.*)$")
    if not intp then return s end
    local g = intp:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^%s+", "")
    return sign .. g .. rest
end

local function _fmt(v)
    local s
    if v == math.floor(v) then
        s = string.format("%.0f", v)
    else
        -- One decimal, but drop a trailing ".0" so e.g. 0.9922 reads "1" not "1.0".
        s = string.format("%.1f", v):gsub("%.0$", "")
    end
    return _group_thousands(s)
end

-- A readable view of the source number(s) a match detected, for the debug Units
-- list: "three feet" → "3", "four hundred feet" → "400", "five to six miles" →
-- "5–6", "six foot four" → "6, 4", "5'6\"" → "5, 6". Digit forms are read
-- directly; spelled forms are composed left to right, one maximal number at a
-- time, so ranges and compounds both surface all their numbers.
local function _detected_value_str(text)
    local s = _display(text or "")
    local low = s:lower()
    -- Range separators join two DISTINCT numbers, unlike an intra-number hyphen
    -- ("twenty-three", "six-and-a-half"). Split on them first so each endpoint is
    -- parsed on its own — otherwise "five–six" composes to 11.
    local is_range = low:find(" to ", 1, true) or low:find(" or ", 1, true)
        or s:find(_ENDASH, 1, true) or s:find(_EMDASH, 1, true) or s:find(", ", 1, true)
    local split = s:gsub(_ENDASH, "\1"):gsub(_EMDASH, "\1")
        :gsub(" to ", "\1"):gsub(" or ", "\1"):gsub(", ", "\1")
    local vals = {}
    for seg in (split .. "\1"):gmatch("(.-)\1") do
        if seg:match("%S") then
            local had = false
            for d in seg:gmatch("%d[%d.,]*") do
                local n = tonumber((d:gsub(",", "")))
                if n then vals[#vals + 1] = _fmt(n); had = true end
            end
            if not had then  -- spelled: compose each maximal number run (hyphens = joiners)
                local words = {}
                for w in seg:lower():gmatch("%S+") do words[#words + 1] = w end
                local i = 1
                while i <= #words do
                    local val, _, _, consumed = _compose_spelled(table.concat(words, " ", i))
                    if val and consumed and consumed >= 1 then
                        vals[#vals + 1] = _fmt(val); i = i + consumed
                    else
                        -- The composer can't start on a leading fraction word
                        -- ("half a gallon", "three quarters of a mile"), but
                        -- _parse_num knows these via _WORD_NUMS — so the Units
                        -- list shows "0.5"/"0.75" instead of "?".
                        local pv = _parse_num(table.concat(words, " ", i))
                        if pv then vals[#vals + 1] = _fmt(pv) end
                        i = i + 1
                    end
                end
            end
        end
    end
    if #vals == 0 then return "?" end
    if #vals == 1 then return vals[1] end
    return table.concat(vals, is_range and _ENDASH or ", ")
end

-- ── Decimal mark: always ".", deliberately ──────────────────────────────────
-- Footcream formatted the decimal mark from the UI language for one release
-- cycle ("1,8 m" for the 41 comma languages) and it was reverted before
-- shipping. The reason is the in-text modes: the converted number is written
-- into the reader's own book file, so a German UI put "1,8 m" into a
-- paragraph where the author wrote "1.8" — visibly inconsistent WITHIN ONE
-- PARAGRAPH, which reads as a typo rather than a courtesy. Inferring a number
-- format from someone's interface language is a guess about what they want;
-- if this comes back it should be an explicit "format preference" setting.
-- The thousands separator is a space everywhere (SI, unambiguous) and predates
-- all of this.

-- For compound feet+inches heights, _fmt's 1-decimal rounding loses too much
-- (6'4" -> "1.9 m" hides a ~3cm range). Always show centimeter precision.
local function _fmt_height(v)
    return string.format("%.2f", v)
end

-- Pick a friendlier sub-unit when the value is below a whole one: km->m,
-- m->cm, kg->g. Returns the scaled value and the new unit. ("0.4 km" -> "400 m",
-- "0.1 m" -> "10 cm", "0.3 kg" -> "300 g".)
local function _downscale(v, unit)
    if v < 1 then
        if unit == "km" then return v * 1000, "m"  end
        if unit == "m"  then return v * 100,  "cm" end
        if unit == "kg" then return v * 1000, "g"  end
    end
    return v, unit
end

local function _fmt_dist(v, unit)
    -- Imperial target tag (metric→imperial direction): compound formatting
    -- lives in FootFree._IMPERIAL (defined below; resolved at call time).
    if unit and FootFree._IMPERIAL.tags[unit] then
        return FootFree._IMPERIAL.fmt(v, unit)
    end
    local sv, su = _downscale(v, unit)
    return _fmt(sv) .. " " .. su
end

-- Range version of _fmt_dist: downscales both ends based on the (larger) upper
-- bound, so both endpoints stay in the same unit. `conn` is the original
-- connector (" and "/" or "/" to ", spaces included) so the converted range
-- reads as prose ("1.2 and 1.5 m") instead of range notation ("1.2–1.5 m") —
-- this matters most in Convert-in-text mode, where it lands in the sentence.
local function _fmt_dist_range(r1, r2, unit, conn)
    if unit and FootFree._IMPERIAL.tags[unit] then
        return FootFree._IMPERIAL.fmt_range(r1, r2, unit, conn)
    end
    local sr2, su = _downscale(r2, unit)
    local scale = (su == unit or r2 == 0) and 1 or (sr2 / r2)
    return _fmt(r1 * scale) .. (conn or _ENDASH) .. _fmt(sr2) .. " " .. su
end

-- ── Smart Rounding of Converted Units ────────────────────────────────────────
-- When on (default), a converted value gets rounded to a "nice" 1-2-5×10^n
-- step — but only when the SOURCE number looks like an approximation
-- (a round number: "ten thousand", "a hundred", "two hundred and fifty", ...).
-- Precise source numbers ("27 feet", "65 pounds", "5.5 miles", "511 feet")
-- are left exactly as today. The step is chosen as coarse as possible while
-- staying within _SMART_ROUND_TOLERANCE of the true value.
local _SMART_ROUND_TOLERANCE = 0.02  -- 2%

local function _smart_rounding_enabled()
    return G_reader_settings:readSetting("footcream_smart_rounding") ~= false
end

-- A whole number >= 10 with at least one trailing zero "looks approximate"
-- (10, 100, 140, 250, 10000, ...). Numbers with a fractional part, or small/
-- non-round integers (9, 27, 65, 511), are treated as deliberately precise.
local function _is_approx_num(n)
    if not n then return false end
    -- Fractions of a single unit ("a third of a mile", "half a pound", "two
    -- thirds of a foot") are colloquial approximations, not precise measurements,
    -- so a value below 1 is rounded too (536.4 m -> 540 m). Precise sub-unit
    -- decimals like "0.25 inches" are unaffected: _nice_round only rounds when a
    -- coarser value stays within tolerance, which it can't for those.
    if n > 0 and n < 1 then return true end
    if n ~= math.floor(n) then return false end
    if n < 10 then return false end
    return n % 10 == 0
end

-- How many significant digits the SOURCE number carries. Trailing zeros in a
-- whole number are not significant — "a hundred feet" is one figure, "29,028
-- feet" is five. Same signal _is_approx_num reads, at finer resolution: it
-- answers "is this round?", this answers "how precise is it?".
local function _sig_digits(n)
    if not n or n == 0 then return 1 end
    if n < 0 then n = -n end
    local s
    if n ~= math.floor(n) then
        s = (string.format("%.10f", n):gsub("0+$", ""):gsub("%.", ""):gsub("^0+", ""))
    else
        s = (string.format("%.0f", n):gsub("0+$", ""))
    end
    return math.max(1, #s)
end

-- Round v to the coarsest 1-2-5×10^n step whose relative error stays within
-- _SMART_ROUND_TOLERANCE. Returns v unchanged if even the smallest such step
-- would overshoot the tolerance. `min_sig` sets a floor on how few significant
-- figures the result may collapse to, so a precise source can't be flattened
-- (see the distance branch of _smart_round).
local function _nice_round(v, tol, min_sig)
    if v == 0 then return v end
    tol = tol or _SMART_ROUND_TOLERANCE
    -- Round the magnitude and reapply the sign, so negative values (sub-zero °C
    -- temperatures, negative range endpoints) round the same way positives do.
    local sign = 1
    if v < 0 then sign, v = -1, -v end
    -- Round to the FEWEST significant figures that stays within tolerance —
    -- i.e. the nearest value at each precision level, coarsest first. Because
    -- each candidate is a *nearest* rounding, the result never lands further
    -- from the true value than necessary (the old coarsest-1-2-5-step rule could
    -- overshoot, e.g. 6705.6 → 6800 instead of the closer 6700).
    local digits = math.floor(math.log(v) / math.log(10))  -- 10^digits <= v < 10^(digits+1)
    for sig = math.max(1, min_sig or 1), 8 do
        local pow = 10 ^ (digits - sig + 1)
        local rounded = math.floor(v / pow + 0.5) * pow
        if rounded > 0 and math.abs(rounded - v) / v <= tol then
            return sign * rounded
        end
    end
    return sign * v
end

-- "Round harder" units (user-selected): a wider tolerance AND rounding even when
-- the source number looks deliberately precise. Temperature is special-cased to
-- whole degrees. Plain metres ("m") are deliberately absent here and gated by
-- magnitude in _smart_round instead, so heights/short lengths stay untouched.
local _HARSH_TOLERANCE = 0.04   -- 4%
local _HARSH_TARGETS = {
    cm = true, kg = true, g = true,
    ["km/h"] = true, km = true, liters = true, mL = true,
}

local function _round_to_int(v)
    if v < 0 then return -math.floor(-v + 0.5) end
    return math.floor(v + 0.5)
end

-- Apply smart rounding to a converted value `v`, given the source number `n`
-- it was converted from and (optionally) the metric `target` unit. Pass
-- force=true for ranges, which are inherently approximate regardless of how the
-- endpoints happen to be written.
local function _smart_round(v, n, force, target)
    -- Imperial target tags own their rounding inside FootFree._IMPERIAL.fmt
    -- (compound output rounds inherently) — pass the value through untouched.
    if target and FootFree._IMPERIAL.tags[target] then return v end
    if not _smart_rounding_enabled() then return v end
    -- Temperature: always whole degrees (72°F → 22 °C, not 22.2 °C).
    if target == "°C" then return _round_to_int(v) end
    -- Centimetres: collapse to fewest sig-figs within the band first (30.5 → 30,
    -- 91.4 → 90), then ensure a whole-cm result for anything ≥3 cm (7.6 → 8),
    -- which the band alone wouldn't reach. Sub-3 cm keeps its decimal so a
    -- deliberate "0.5 inches → 1.3 cm" isn't flattened to a wrong whole number.
    if target == "cm" then
        local r = _nice_round(v, _HARSH_TOLERANCE)
        if r ~= math.floor(r) and math.abs(r) >= 3 then r = _round_to_int(r) end
        return r
    end
    -- Harsh units: wider band, and round regardless of source precision. Plain
    -- metres only qualify at distance scale (≥10 m), sparing heights/short lengths.
    if target and (_HARSH_TARGETS[target]
                   or (target == "m" and (v >= 10 or v <= -10))) then
        -- ...except that DISTANCE must not flatten a precise source. A reader
        -- reported "29,028 feet" (Everest) coming out as "9 000 m": the true
        -- 8 847.7 m is only 1.72% from 9 000, inside the 4% band, so one
        -- significant figure was allowed to swallow a five-figure surveyed
        -- number. Approximate sources still round hard — "1,700 feet" -> 500 m
        -- is unchanged, because _is_approx_num already says that number is
        -- rough. This only bites when the source is BOTH precise and long:
        -- 29,028 ft -> 8 848 m, 511 ft -> 156 m (which is what the comment at
        -- the top of this section always claimed happened), 333 ft -> 101 m.
        -- Ranges keep rounding hard: force means "inherently approximate".
        local floor_sig
        if (target == "m" or target == "km")
           and not force and not _is_approx_num(n) then
            floor_sig = _sig_digits(n)
        end
        local r = _nice_round(v, _HARSH_TOLERANCE, floor_sig)
        -- A precision floor can leave a decimal at distance scale ("8 847.7 m"
        -- reads as false precision); whole units are the honest rendering.
        if floor_sig and r ~= math.floor(r) and math.abs(r) >= 10 then
            r = _round_to_int(r)
        end
        return r
    end
    -- Sub-metre lengths display as centimetres (via _downscale at format time),
    -- so round them on the cm scale to ~2 sig figs — otherwise the metre value's
    -- 1-decimal format leaks odd precision once downscaled ("three feet" →
    -- 0.9144 m → "91.4 cm"; now → 0.90 m → "90 cm"). Mirrors the cm branch above.
    if target == "m" and v > -1 and v < 1 then
        local cm = _nice_round(v * 100, _HARSH_TOLERANCE)
        if cm ~= math.floor(cm) and math.abs(cm) >= 3 then cm = _round_to_int(cm) end
        return cm / 100
    end
    if not force and not _is_approx_num(n) then return v end
    return _nice_round(v)
end

-- Whole-number distance for "not <n> <unit>" — the negation signals a vague,
-- approximate distance, so a round number reads more honestly ("not two miles" →
-- "3 km", not "3.2 km"). Smart-round first (nice 1-2-5 value, e.g. half a mile →
-- 0.8 km → 800 m), THEN drop any remaining decimal in the display unit, so "not"
-- never reads LESS round than the plain conversion would.
local function _round_whole_dist(v, n, target)
    if FootFree._IMPERIAL.tags[target] then
        return FootFree._IMPERIAL.fmt(_round_to_int(v), target)
    end
    local rv = _smart_round(v, n, true, target)
    local sv, su = _downscale(rv, target)
    return _fmt(_round_to_int(sv)) .. " " .. su
end

-- ── Metric → imperial direction ("Convert units to") ─────────────────────────
-- Data + formatters for the REVERSE direction: scanning metric units and
-- showing imperial conversions, for readers whose preferred system is
-- imperial ("us"/"uk"; "metric" is the classic direction and the default).
-- One class-attached block of pure data/functions (not chunk locals: the main
-- chunk sits near LuaJIT's 200-locals ceiling, and the headless test
-- extractor lifts dotted blocks — same convention as FootFree._REPORTING).
FootFree._IMPERIAL = {
    -- Imperial TARGET TAGS mark a conversion entry as metric-direction.
    -- _smart_round passes tagged values through untouched and _fmt_dist /
    -- _fmt_dist_range dispatch to fmt/fmt_range below, so the generic
    -- pipeline (single values, ranges, sidecar, popups) needs no other
    -- changes. Each tag's BASE unit (what `factor` converts into):
    -- ftin=feet, in=inches, mi=miles, lboz=pounds, oz=ounces, °F=degrees F,
    -- vol=LITERS (flavor picks fl oz / pints / quarts / gallons at format
    -- time), mph=mph, acres=acres.
    tags = { ftin=true, ["in"]=true, mi=true, lboz=true, oz=true,
             ["°F"]=true, vol=true, mph=true, acres=true,
             sqft=true, sqmi=true, sqin=true },

    -- The user's preferred system: "metric" (default) | "us" | "uk".
    preferred = function()
        local v = G_reader_settings:readSetting("footcream_preferred_system")
        if v == "us" or v == "uk" then return v end
        return "metric"
    end,

    -- Metric-source unit → conversion entry (mirror of _UNIT_CONV). Bare
    -- one-letter "m"/"g" are identified from matched text but deliberately
    -- get special anchoring in the scan pattern (digit-adjacent only);
    -- tonnes are deliberately absent (register-tonnage ambiguity — standing
    -- decision); °C degree-symbol forms run as literal passes like °F.
    conv = {
        ["kilometers"]           = { factor=0.621371,  offset=0,  target="mi",    cat="length" },
        ["kilometres"]           = { factor=0.621371,  offset=0,  target="mi",    cat="length" },
        ["kilometer"]            = { factor=0.621371,  offset=0,  target="mi",    cat="length" },
        ["kilometre"]            = { factor=0.621371,  offset=0,  target="mi",    cat="length" },
        ["km"]                   = { factor=0.621371,  offset=0,  target="mi",    cat="length" },
        ["klicks"]               = { factor=0.621371,  offset=0,  target="mi",    cat="length" },
        ["klick"]                = { factor=0.621371,  offset=0,  target="mi",    cat="length" },
        ["meters"]               = { factor=3.28084,   offset=0,  target="ftin",  cat="length" },
        ["metres"]               = { factor=3.28084,   offset=0,  target="ftin",  cat="length" },
        ["meter"]                = { factor=3.28084,   offset=0,  target="ftin",  cat="length" },
        ["metre"]                = { factor=3.28084,   offset=0,  target="ftin",  cat="length" },
        ["m"]                    = { factor=3.28084,   offset=0,  target="ftin",  cat="length" },
        ["centimeters"]          = { factor=0.393701,  offset=0,  target="in",    cat="length" },
        ["centimetres"]          = { factor=0.393701,  offset=0,  target="in",    cat="length" },
        ["centimeter"]           = { factor=0.393701,  offset=0,  target="in",    cat="length" },
        ["centimetre"]           = { factor=0.393701,  offset=0,  target="in",    cat="length" },
        ["cm"]                   = { factor=0.393701,  offset=0,  target="in",    cat="length" },
        ["millimeters"]          = { factor=0.0393701, offset=0,  target="in",    cat="length" },
        ["millimetres"]          = { factor=0.0393701, offset=0,  target="in",    cat="length" },
        ["millimeter"]           = { factor=0.0393701, offset=0,  target="in",    cat="length" },
        ["millimetre"]           = { factor=0.0393701, offset=0,  target="in",    cat="length" },
        ["mm"]                   = { factor=0.0393701, offset=0,  target="in",    cat="length" },
        ["kilograms"]            = { factor=2.20462,   offset=0,  target="lboz",  cat="weight" },
        ["kilogram"]             = { factor=2.20462,   offset=0,  target="lboz",  cat="weight" },
        ["kilos"]                = { factor=2.20462,   offset=0,  target="lboz",  cat="weight" },
        ["kilo"]                 = { factor=2.20462,   offset=0,  target="lboz",  cat="weight" },
        ["kg"]                   = { factor=2.20462,   offset=0,  target="lboz",  cat="weight" },
        ["grams"]                = { factor=0.0352740, offset=0,  target="oz",    cat="weight" },
        ["gram"]                 = { factor=0.0352740, offset=0,  target="oz",    cat="weight" },
        ["g"]                    = { factor=0.0352740, offset=0,  target="oz",    cat="weight" },
        ["degrees Celsius"]      = { factor=9/5,       offset=32, target="°F",    cat="temperature" },
        ["degrees centigrade"]   = { factor=9/5,       offset=32, target="°F",    cat="temperature" },
        ["centigrade"]           = { factor=9/5,       offset=32, target="°F",    cat="temperature" },
        ["Celsius"]              = { factor=9/5,       offset=32, target="°F",    cat="temperature" },
        ["liters"]               = { factor=1,         offset=0,  target="vol",   cat="volume" },
        ["litres"]               = { factor=1,         offset=0,  target="vol",   cat="volume" },
        ["liter"]                = { factor=1,         offset=0,  target="vol",   cat="volume" },
        ["litre"]                = { factor=1,         offset=0,  target="vol",   cat="volume" },
        ["milliliters"]          = { factor=0.001,     offset=0,  target="vol",   cat="volume" },
        ["millilitres"]          = { factor=0.001,     offset=0,  target="vol",   cat="volume" },
        ["milliliter"]           = { factor=0.001,     offset=0,  target="vol",   cat="volume" },
        ["millilitre"]           = { factor=0.001,     offset=0,  target="vol",   cat="volume" },
        ["ml"]                   = { factor=0.001,     offset=0,  target="vol",   cat="volume" },
        ["hectares"]             = { factor=2.47105,   offset=0,  target="acres", cat="area" },
        ["hectare"]              = { factor=2.47105,   offset=0,  target="acres", cat="area" },
        -- Square metric ("an eleven-square-metre cell" converted as LINEAR
        -- 36 ft before these — Nesbø sweep). Hyphen twins cover the
        -- adjectival form; conv keys must mirror the suffix strings exactly.
        ["square kilometers"]    = { factor=0.386102,  offset=0,  target="sqmi",  cat="area" },
        ["square kilometres"]    = { factor=0.386102,  offset=0,  target="sqmi",  cat="area" },
        ["square kilometer"]     = { factor=0.386102,  offset=0,  target="sqmi",  cat="area" },
        ["square kilometre"]     = { factor=0.386102,  offset=0,  target="sqmi",  cat="area" },
        ["square-kilometer"]     = { factor=0.386102,  offset=0,  target="sqmi",  cat="area" },
        ["square-kilometre"]     = { factor=0.386102,  offset=0,  target="sqmi",  cat="area" },
        ["square meters"]        = { factor=10.7639,   offset=0,  target="sqft",  cat="area" },
        ["square metres"]        = { factor=10.7639,   offset=0,  target="sqft",  cat="area" },
        ["square meter"]         = { factor=10.7639,   offset=0,  target="sqft",  cat="area" },
        ["square metre"]         = { factor=10.7639,   offset=0,  target="sqft",  cat="area" },
        ["square-meter"]         = { factor=10.7639,   offset=0,  target="sqft",  cat="area" },
        ["square-metre"]         = { factor=10.7639,   offset=0,  target="sqft",  cat="area" },
        ["square centimeters"]   = { factor=0.155,     offset=0,  target="sqin",  cat="area" },
        ["square centimetres"]   = { factor=0.155,     offset=0,  target="sqin",  cat="area" },
        ["square centimeter"]    = { factor=0.155,     offset=0,  target="sqin",  cat="area" },
        ["square centimetre"]    = { factor=0.155,     offset=0,  target="sqin",  cat="area" },
        ["square-centimeter"]    = { factor=0.155,     offset=0,  target="sqin",  cat="area" },
        ["square-centimetre"]    = { factor=0.155,     offset=0,  target="sqin",  cat="area" },
        ["kilometers per hour"]  = { factor=0.621371,  offset=0,  target="mph",   cat="speed" },
        ["kilometres per hour"]  = { factor=0.621371,  offset=0,  target="mph",   cat="speed" },
        ["kilometers an hour"]   = { factor=0.621371,  offset=0,  target="mph",   cat="speed" },
        ["kilometres an hour"]   = { factor=0.621371,  offset=0,  target="mph",   cat="speed" },
        ["km/h"]                 = { factor=0.621371,  offset=0,  target="mph",   cat="speed" },
        ["kph"]                  = { factor=0.621371,  offset=0,  target="mph",   cat="speed" },
        ["meters per second"]    = { factor=2.23694,   offset=0,  target="mph",   cat="speed" },
        ["metres per second"]    = { factor=2.23694,   offset=0,  target="mph",   cat="speed" },
    },

    -- Longest-first, like _UNIT_SUFFIXES (suffix identification + shy-book
    -- plain passes; "m"/"g" are identified here but anchored digit-adjacent
    -- in the pattern, and skipped by the shy plain passes entirely — a plain
    -- search for a single letter matches every occurrence of the letter).
    suffixes = {
        -- Square units FIRST: "…square kilometres" must not tail-match the
        -- linear "kilometres". Hyphen twins catch "eleven-square-metre".
        "square kilometers", "square kilometres", "square kilometer",
        "square kilometre", "square-kilometer", "square-kilometre",
        "square centimeters", "square centimetres", "square centimeter",
        "square centimetre", "square-centimeter", "square-centimetre",
        "square meters", "square metres", "square meter", "square metre",
        "square-meter", "square-metre",
        "kilometers per hour", "kilometres per hour",
        "kilometers an hour", "kilometres an hour",
        "meters per second", "metres per second",
        "degrees Celsius", "degrees centigrade", "centigrade", "Celsius",
        "millimeters", "millimetres", "millimeter", "millimetre",
        "centimeters", "centimetres", "centimeter", "centimetre",
        "kilometers", "kilometres", "kilometer", "kilometre",
        "milliliters", "millilitres", "milliliter", "millilitre",
        "kilograms", "kilogram", "hectares", "hectare",
        "klicks", "klick", "liters", "litres", "liter", "litre",
        "kilos", "kilo", "grams", "gram",
        -- AFTER kilometers/centimeters/millimeters: "meters" is a tail of all
        -- three, and _identify_unit takes the first tail match.
        "meters", "metres", "meter", "metre",
        "km/h", "kph", "ml", "km", "cm", "mm", "kg", "m", "g",
    },

    -- Eighth-inch fraction display for small lengths ("⅜ in", "1¼ in").
    -- Eighths, not quarters: quarter resolution mangled gun calibers ("9mm"
    -- = 0.354 in showed ¼ instead of ⅜ — Nesbø sweep), and eighths are the
    -- everyday US carpentry fractions anyway.
    frac_in = function(iv)
        local e = math.floor(iv * 8 + 0.5)
        if e == 0 then e = 1 end
        local whole, eighth = math.floor(e / 8), e % 8
        local glyph = ({ [1] = "⅛", [2] = "¼", [3] = "⅜", [4] = "½",
                         [5] = "⅝", [6] = "¾", [7] = "⅞" })[eighth] or ""
        if whole == 0 then return glyph .. " in" end
        return whole .. glyph .. " in"
    end,

    -- Natural-compound imperial formatting. `v` is in the tag's base unit;
    -- `flavor` defaults to the live preference (tests pass it explicitly).
    -- Owns its own rounding (compounds round inherently), which is why
    -- _smart_round passes tagged values through. With the Smart Rounding
    -- toggle OFF, falls back to decimal single units ("5.9 ft").
    fmt = function(v, target, flavor)
        local IMP = FootFree._IMPERIAL
        flavor = flavor or IMP.preferred()
        local uk = flavor == "uk"
        if not _smart_rounding_enabled() then
            local plain = { ftin = "ft", ["in"] = "in", mi = "mi", lboz = "lb",
                            oz = "oz", ["°F"] = "°F", mph = "mph", acres = "acres",
                            sqft = "sq ft", sqmi = "sq mi", sqin = "sq in" }
            if target == "vol" then
                return _fmt(v * (uk and 0.219969 or 0.264172)) .. " gal"
            end
            return _fmt(v) .. " " .. plain[target]
        end
        local neg = v < 0
        local a = neg and -v or v
        local out
        if target == "in" then
            if a >= 12 then return IMP.fmt(v / 12, "ftin", flavor) end
            out = a < 2 and IMP.frac_in(a) or _fmt(a) .. " in"
        elseif target == "ftin" then
            if a >= 2000 then return IMP.fmt(v / 5280, "mi", flavor) end
            if a < 2 then
                -- Inches, formatted DIRECTLY: routing through the "in" branch
                -- ping-pongs (its >=12-inch promotion sends 1–2 ft straight
                -- back here — stack overflow on any 0.3–0.6 m length; found
                -- by the Nesbø metric sweep).
                local iv = a * 12
                out = iv < 2 and IMP.frac_in(iv) or _fmt(iv) .. " in"
            elseif a < 20 then
                local ft = math.floor(a)
                local inch = _round_to_int((a - ft) * 12)
                if inch >= 12 then ft, inch = ft + 1, 0 end
                out = inch == 0 and (ft .. " ft") or (ft .. " ft " .. inch .. " in")
            else
                out = _fmt(_round_to_int(_nice_round(a, _SMART_ROUND_TOLERANCE))) .. " ft"
            end
        elseif target == "mi" then
            if a < 0.25 then return IMP.fmt(v * 5280, "ftin", flavor) end
            local r = _nice_round(a, _SMART_ROUND_TOLERANCE)
            out = (r >= 10 and _fmt(_round_to_int(r)) or _fmt(r)) .. " mi"
        elseif target == "lboz" then
            if a < 1 then return IMP.fmt(v * 16, "oz", flavor) end
            if uk and a >= 66 and a <= 441 then
                local st = math.floor(a / 14)
                local lb = _round_to_int(a - st * 14)
                if lb >= 14 then st, lb = st + 1, 0 end
                out = lb == 0 and (st .. " st") or (st .. " st " .. lb .. " lb")
            elseif a < 20 then
                local lb = math.floor(a)
                local ozv = _round_to_int((a - lb) * 16)
                if ozv >= 16 then lb, ozv = lb + 1, 0 end
                out = ozv == 0 and (lb .. " lb") or (lb .. " lb " .. ozv .. " oz")
            else
                out = _fmt(_round_to_int(a)) .. " lb"
            end
        elseif target == "oz" then
            if a >= 16 then return IMP.fmt(v / 16, "lboz", flavor) end
            -- Sub-tenth values need two decimals — _fmt's single decimal
            -- printed "one gram = 0 oz" (Nesbø sweep). Never show 0 for a
            -- real amount.
            if a < 0.095 then
                local s = string.format("%.2f", a)
                if s == "0.00" then s = "0.01" end
                out = s .. " oz"
            else
                out = _fmt(a) .. " oz"
            end
        elseif target == "°F" then
            out = _fmt(_round_to_int(a)) .. " °F"
        elseif target == "vol" then
            -- fl oz below one pint (UK) / one quart (US) — "17 fl oz" reads
            -- better than "0.5 qt". Whole fl oz from 2 up; decimals only for
            -- tiny amounts ("0.5 fl oz" for 15 ml).
            if uk then
                if a < 0.569 then
                    local floz = a * 35.1951
                    out = _fmt(floz < 2 and floz or _round_to_int(floz)) .. " fl oz"
                elseif a < 3.5 then
                    local p = _fmt(a * 1.75975)
                    out = p .. (p == "1" and " pint" or " pints")
                else out = _fmt(a * 0.219969) .. " gal" end
            else
                if a < 0.947 then
                    local floz = a * 33.814
                    out = _fmt(floz < 2 and floz or _round_to_int(floz)) .. " fl oz"
                elseif a < 4 then out = _fmt(a * 1.05669) .. " qt"
                else out = _fmt(a * 0.264172) .. " gal" end
            end
        elseif target == "mph" then
            out = _fmt(_round_to_int(a)) .. " mph"
        elseif target == "acres" then
            out = (a >= 10 and _fmt(_round_to_int(_nice_round(a, _HARSH_TOLERANCE)))
                            or _fmt(a)) .. " acres"
        elseif target == "sqft" then
            out = (a >= 10 and _fmt(_round_to_int(_nice_round(a, _HARSH_TOLERANCE)))
                            or _fmt(a)) .. " sq ft"
        elseif target == "sqmi" then
            local r = _nice_round(a, _SMART_ROUND_TOLERANCE)
            out = (r >= 10 and _fmt(_round_to_int(r)) or _fmt(r)) .. " sq mi"
        elseif target == "sqin" then
            out = _fmt(a) .. " sq in"
        else
            out = _fmt(a) .. " " .. tostring(target)
        end
        return (neg and _UMINUS or "") .. out
    end,

    -- Range twin: format both endpoints; when both come out as simple
    -- "<number> <same unit>" strings, drop the first unit ("3.1–6.2 mi").
    -- Compound endpoints stay whole ("5 ft 11 in to 6 ft 2 in").
    fmt_range = function(r1, r2, target, conn)
        local IMP = FootFree._IMPERIAL
        local a, b = IMP.fmt(r1, target), IMP.fmt(r2, target)
        local u1 = a:match("^[%d.,]+ ([%a °]+)$")
        local u2 = b:match("^[%d.,]+ ([%a °]+)$")
        if u1 and u1 == u2 then a = a:match("^([%d.,]+)") end
        return a .. (conn or _ENDASH) .. b
    end,
}

-- ── Compound converters ───────────────────────────────────────────────────────

-- "six foot two" / "6 foot 4" / "5 feet 3 inches" / "six-foot-four" → metres
local function _conv_foot_inch_to_m(text)
    local s = _display(text):lower()
    local before, after = s:match("^(.-)[ %-]+foot[ %-]+(.+)$")
    if not before then
        before, after = s:match("^(.-)[ %-]+feet[ %-]+(.+)$")
    end
    if before and after then
        local ft = _parse_num(before)
        local in_ = _parse_num(after)
        if ft then return _fmt_height(ft * 0.3048 + (in_ or 0) * 0.0254) .. " m" end
    end
    return nil
end

-- "6′9″" / "6'8"" / "6’9”" (curly, most commercial EPUBs) → metres.
-- The feet and inches figures may be separated by a single space: "I was 6' 4"."
-- is how I Heard You Paint Houses sets every height in the book, and without the
-- optional space it split into a bare 6' and a bare 4" — two matches, neither of
-- them the height, and both of them landing in the bare-prime guards below.
local function _conv_prime_to_m(text)
    local clean = _display(text)
    local f, i = clean:match("^([0-9]+)" .. _PRIME .. "%s?([0-9]+)")
    if not f then f, i = clean:match("^([0-9]+)'%s?([0-9]+)") end
    if not f then f, i = clean:match("^([0-9]+)" .. FootFree._CAPOS .. "%s?([0-9]+)") end
    if f and i then
        return _fmt_height(tonumber(f) * 0.3048 + tonumber(i) * 0.0254) .. " m"
    end
    return nil
end

-- "nine stone four" / "ten stone two" → kg  (stone + extra lbs)
local function _conv_stone_lbs_to_kg(text)
    local s = _display(text):lower()
    local before, after = s:match("^(.-)%s+stone%s+(.+)$")
    if before and after then
        local st = _parse_num(before)
        local lb = _parse_num(after)
        if st then return _fmt(st * 6.35029 + (lb or 0) * 0.453592) .. " kg" end
    end
    return nil
end

-- "seven pounds four ounces" / "two pounds, four ounces" / "1-lb 4-oz" → kg
local function _conv_lbs_oz_to_kg(text)
    local s = _display(text):lower():gsub("%s+and%s+", " "):gsub("[,%-]%s*", " ")
    local before, after = s:match("^(.-)%s+pounds?%s+(.-)%s+ounces?$")
    if not before then before, after = s:match("^(.-)%s+lbs?%s+(.-)%s+oz$") end
    if before and after then
        local lb = _parse_num(before)
        local oz = _parse_num(after)
        if lb then return _fmt(lb * 0.453592 + (oz or 0) * 0.0283495) .. " kg" end
    end
    return nil
end

-- "four feet by two inches" / "6 ft by 3 in" → "1.8 m by 7.6 cm"
local function _conv_ft_by_in(text)
    local s = _display(text):lower()
    -- f[eo]?[eo]?t matches feet / foot / ft (vowels optional → also "ft").
    local before, after = s:match("^(.-)%s+f[eo]?[eo]?t%s+by%s+(.+)$")
    if before and after then
        local ft  = _parse_num(before)
        local in_ = _parse_num(after)
        if ft and in_ then
            return _fmt(ft * 0.3048) .. " m by " .. _fmt(in_ * 2.54) .. " cm"
        end
    end
    return nil
end

-- "4′ × 2″" / "4' × 2"" dimension → "1.2 m by 5.1 cm"
local function _conv_dim_to_m_cm(text)
    local clean = _display(text)
    local f = clean:match("^([0-9]+)")
    local i = clean:match(".*[^0-9]([0-9]+)")
    if f and i then
        return _fmt(tonumber(f) * 0.3048) .. " m by " .. _fmt(tonumber(i) * 2.54) .. " cm"
    end
    return nil
end

-- The inches-by-inches twin of the form above ("10" × 8"", "8” × 2”") → cm by cm.
-- It was missing, so a plate or print size converted its FIRST figure only: the
-- 8" of '10" × 8" plates' stayed imperial beside a metric 10", which reads as a
-- mistake even though the 25 cm itself is right.
local function _conv_dim_cm_cm(text)
    local clean = _display(text)
    local a = clean:match("^([0-9]+)")
    local b = clean:match(".*[^0-9]([0-9]+)")
    if a and b then
        return _fmt(tonumber(a) * 2.54) .. " cm by " .. _fmt(tonumber(b) * 2.54) .. " cm"
    end
    return nil
end

-- "10x10 feet" / "10×10 ft" → "3 × 3 m": two same-unit dimensions joined by
-- x/X/× (no spaces — the spaced form "10 x 10 feet" only spans "10 feet"). Both
-- numbers convert with the unit's own factor/target; nil if it isn't this shape.
local function _conv_nxn(text, factor, target)
    local clean = _display(text)
    local a, b = clean:match("^%s*(%d+%.?%d*)%s*[xX\195\151]%s*(%d+%.?%d*)")
    if not (a and b) then return nil end
    local na, nb = tonumber(a), tonumber(b)
    if not (na and nb) then return nil end
    local ra = _smart_round(na * factor, na, false, target)
    local rb = _smart_round(nb * factor, nb, false, target)
    return _fmt(ra) .. " \195\151 " .. _fmt_dist(rb, target)
end

-- Range factory: "twenty or thirty feet" → "6.1 or 9.1 m" (keeps the connector)
local function _range_conv(factor, offset, target)
    return function(text)
        local s = _display(text):lower()
        for _, sep in ipairs({" and ", " or ", " to "}) do
            local p = s:find(sep, 1, true)
            if p then
                local n1 = _parse_num(s:sub(1, p - 1))
                local n2 = _parse_num(s:sub(p + #sep))
                if n1 and n2 then
                    local r1 = n1 * factor + offset
                    local r2 = n2 * factor + offset
                    if r1 > r2 then r1, r2 = r2, r1 end
                    return _fmt_dist_range(_smart_round(r1, nil, true, target),
                                            _smart_round(r2, nil, true, target), target, sep)
                end
            end
        end
        return nil
    end
end

-- "twelve acres" / "200 acres" → "4.9 hectares" / "80 hectares"
local function _conv_acres_to_ha(text)
    local num = _parse_num(text)
    if not num then return nil end
    local disp = _fmt(_smart_round(num * 0.404686, num, false, "ha"))
    return disp .. (disp == "1" and " hectare" or " hectares")
end

-- ── Convert a match to display string ────────────────────────────────────────

local function _convert(r)
    if r._converted then return r._converted end
    -- Unit-first match: number in r._num, unit word in r.matched_text
    if r._num ~= nil and r._search then
        local unit_disp = _display(r.matched_text)
        -- Compound height: "6 foot 4" detected via r._num2
        if r._num2 then
            local m = r._num * 0.3048 + r._num2 * 0.0254
            return string.format("%s foot %s = %s m", _fmt(r._num), _fmt(r._num2), _fmt_height(m))
        end
        -- Compound stone: "nine stone four" via r._num2
        if r._num_stone2 then
            local kg = r._num * 6.35029 + r._num_stone2 * 0.453592
            return string.format("%s stone %s = %s kg", _fmt(r._num), _fmt(r._num_stone2), _fmt(kg))
        end
        -- Compound lbs+oz: "seven pounds four ounces" via r._num_oz
        if r._num_oz then
            local kg = r._num * 0.453592 + r._num_oz * 0.0283495
            return string.format("%s lbs %s oz = %s kg", _fmt(r._num), _fmt(r._num_oz), _fmt(kg))
        end
        -- Custom converter (e.g. acres → hectares)
        if r._search.converter then
            local fake   = _fmt(r._num) .. " " .. unit_disp
            local result = r._search.converter(fake)
            if result then return string.format("%s %s = %s", _fmt(r._num), unit_disp, result) end
        end
        -- Standard factor/offset conversion
        if r._search.factor then
            local result = r._num * r._search.factor + r._search.offset
            return string.format("%s %s = %s", _fmt(r._num), unit_disp,
                                  _fmt_dist(_smart_round(result, r._num, false, r._search.target), r._search.target))
        end
        return unit_disp
    end
    -- Standard (non-unit-first) match
    if not r._search then return r.matched_text end
    local disp = _display(r.matched_text)
    if r._search.converter then
        local result = r._search.converter(r.matched_text)
        if result then return string.format("%s = %s", disp, result) end
    end
    if not r._search.factor then return disp end
    local num = _parse_num(r.matched_text)
    if not num then return disp end
    local result = num * r._search.factor + r._search.offset
    return string.format("%s = %s", disp, _fmt_dist(_smart_round(result, num, false, r._search.target), r._search.target))
end

-- ── UK Imperial volume overrides ─────────────────────────────────────────────
-- Applied when the book's dc:language starts with "en-GB" (UK volumes are always
-- on now). UK volumes are ~20% larger than US equivalents.
local _UNIT_CONV_UK = {
    ["gallons"]      = { factor=4.54609,  offset=0, target="liters",  cat="volume" },
    ["gallon"]       = { factor=4.54609,  offset=0, target="liters",  cat="volume" },
    ["gal"]          = { factor=4.54609,  offset=0, target="liters",  cat="volume" },
    ["pints"]        = { factor=0.568261, offset=0, target="liters",  cat="volume" },
    ["pint"]         = { factor=0.568261, offset=0, target="liters",  cat="volume" },
    ["pt"]           = { factor=0.568261, offset=0, target="liters",  cat="volume" },
    ["quarts"]       = { factor=1.13652,  offset=0, target="liters",  cat="volume" },
    ["quart"]        = { factor=1.13652,  offset=0, target="liters",  cat="volume" },
    ["qt"]           = { factor=1.13652,  offset=0, target="liters",  cat="volume" },
    ["fluid ounces"] = { factor=28.4131,  offset=0, target="mL", cat="volume" },
    ["fluid ounce"]  = { factor=28.4131,  offset=0, target="mL", cat="volume" },
    ["fl oz"]        = { factor=28.4131,  offset=0, target="mL", cat="volume" },
}

-- ── Pounds context classifier (weight vs. £ currency) ────────────────────────
-- Always on now. Checks the prev/next context words that findAllText already
-- returns — no extra document scan needed.
-- Pound disambiguation (spelled "pound(s)" only — "lb"/"lbs" is unambiguously
-- weight). Two tiers feed ONE weighted decision (see _pound_* helpers below):
--   _CURRENCY_HARD — words with NO plausible weight reading (coin denominations,
--                    "sterling"). Their presence suppresses the match outright,
--                    at scan time, like the £ symbol.
--   _CURRENCY_SOFT — money cues that CAN sit beside a real weight ("the crate,
--                    worth a fortune, weighed two hundred pounds"). These only
--                    *vote*: currency suppresses only when its cues outnumber the
--                    weight cues, so a weighty context rescues the match.
-- gold/silver are deliberately in NEITHER list — "ten pounds of gold/silver" is a
-- real weight (see the Around-the-World "in gold" flag); treating them as money
-- would suppress genuine weights.
local _CURRENCY_HARD = {
    shilling=true, shillings=true, pence=true, penny=true, pennies=true,
    farthing=true, farthings=true, guinea=true, guineas=true, sixpence=true,
    threepence=true, fourpence=true, florin=true, florins=true,
    halfpenny=true, halfpence=true, groat=true, groats=true, quid=true,
    sovereign=true, sovereigns=true, sterling=true,
}
local _CURRENCY_SOFT = {
    -- transaction verbs
    paid=true, pay=true, paying=true, pays=true, repaid=true,
    cost=true, costs=true, costing=true,
    worth=true, valued=true,
    earned=true, earn=true, earns=true, earning=true,
    owed=true, owe=true, owes=true, owing=true,
    spent=true, spend=true, spends=true, spending=true,
    charged=true, charge=true, charges=true, charging=true,
    bought=true, buy=true, buys=true, buying=true,
    sold=true, sell=true, sells=true, selling=true,
    lent=true, lend=true, lends=true, lending=true,
    borrowed=true, borrow=true, borrows=true, borrowing=true,
    won=true, win=true, wins=true, winning=true,
    bet=true, bets=true, betting=true, wager=true, wagers=true, wagered=true,
    offered=true, offer=true, offers=true, offering=true,
    purchase=true, purchased=true, purchases=true,
    stole=true, steal=true, steals=true, stolen=true, stealing=true,
    robbed=true, robbery=true, robber=true, robbers=true,
    deposit=true, deposited=true, deposits=true,
    saved=true, save=true, saves=true, saving=true,
    fetch=true, fetched=true, fetches=true,
    pocketed=true, pocket=true, pockets=true,
    -- money nouns
    price=true, priced=true, prices=true,
    fee=true, fees=true, fine=true, fined=true, fines=true,
    salary=true, wage=true, wages=true,
    debt=true, debts=true, sum=true, sums=true,
    rent=true, rents=true, fortune=true, money=true, monies=true,
    income=true, payment=true, payments=true, advance=true, advanced=true,
    ransom=true, dowry=true, bribe=true, bribed=true, allowance=true,
    pension=true, legacy=true, bequest=true, annuity=true, inheritance=true,
    reward=true, rewards=true, rewarded=true,
    cheque=true, cheques=true, receipt=true, receipts=true,
    banker=true, bankers=true, banknote=true, banknotes=true,
    notes=true, cash=true, coin=true, coins=true,
    bargain=true, bargained=true,
    -- financial nouns surfaced by the Gutenberg-corpus measurement (P&P/Verne):
    -- "to the amount of", "interest of", "per annum", "per cent", a marriage
    -- "settlement", "inherited", "expenses". Each has no weight sense.
    inherited=true, inherits=true, inheriting=true,
    amount=true, amounts=true, interest=true,
    annum=true, cent=true, cents=true, percent=true,
    settlement=true, settlements=true, settled=true,
    expenses=true, expense=true,
    -- inheritance / estate vocabulary (P&P "a legacy of …", "his estate",
    -- "bequeathed"): money words with no weight sense.
    estate=true, estates=true, bequeathed=true, bequeath=true, bequeaths=true,
    acquisition=true, acquisitions=true,
    -- banking vocabulary (We Solve Murders corpus sweep: "a million pounds in
    -- untraceable bills" → 450 000 kg; "the NatWest account his grandad
    -- started for him with five pounds"). NOT "balance" — that's also a
    -- weighing instrument ("placed ten pounds on the balance"). A genuine
    -- weight near these words still ties and keeps.
    bank=true, banks=true, account=true, accounts=true,
    bills=true, untraceable=true,
}
-- Currency PHRASES (multi-word; checked as bounded substrings). "in gold" /
-- "in silver" mark money ("twenty thousand pounds in gold"), while the weight
-- reading uses "of gold" ("ten pounds of gold") — so the phrase disambiguates
-- without the bare word "gold"/"silver" wrongly suppressing genuine weights.
-- "left <pron> <sum>" is the inheritance/will idiom ("her father … had left her
-- four thousand pounds"). A bounded phrase keeps it from firing on "left" alone
-- (turn left / left behind). If a real weight sits nearby ("left her ten pounds
-- lighter") the weight cue ties and keeps it.
local _CURRENCY_PHRASES = {
    "in gold", "in silver",
    "left her", "left him", "left them", "left me", "left us",
}
-- An income rate written IMMEDIATELY after the unit — "thirty pounds a year",
-- "twenty pounds per annum". A sum quoted at a yearly or monthly rate is a
-- salary, an allowance or a rent; nothing is ever weighed per annum.
--
-- Adjacency is the whole rule, and it is why this is a separate list rather
-- than three more entries in _CURRENCY_PHRASES (which search the whole window).
-- Measured over the corpus: 25 pound matches have a rate phrase somewhere in
-- their window and 8 of those are genuine weights — "ballooning up fifteen
-- pounds in a month", "T. rex put on about 1,700 pounds per year", "we require
-- more than one pound a day". Every one of them puts something between the unit
-- and the rate, or uses a DAILY/WEEKLY rate. Anchor at the unit and drop the day
-- and week forms, and the same corpus yields 10 hits, all of them money.
--
-- ("got" was measured as a cue too, on the reader's suggestion, and rejected:
-- of 16 pound matches with "got" nearby, most are plain weights — lifted eighty
-- pounds, dropped about ten pounds, went about 350 pounds, sixteen pounds of
-- marijuana. It would cost more than it earns.)
--
-- A class attribute, not a local: main.lua is at Lua's 200-local ceiling (see
-- references/gotchas.md), and this form is also what the headless harness
-- extracts by name.
function FootFree._pound_rate_tail(nxt)
    local n = (nxt or ""):lower():gsub("^%s+", "")
    for _, t in ipairs({ "a year", "per year", "a month", "per month",
                         "per annum", "an annum" }) do
        if n:sub(1, #t) == t and not n:sub(#t + 1, #t + 1):match("%a") then
            return true
        end
    end
    return false
end
local _WEIGHT_WORDS = {
    weighed=true, weighs=true, weigh=true, weighing=true,
    weight=true, weights=true,
    heavy=true, heavier=true, heaviest=true,
    lighter=true, lightest=true,
    massive=true, bulky=true, hefty=true, ponderous=true,
    lifted=true, lift=true, lifts=true, lifting=true,
    carried=true, carry=true, carries=true, carrying=true,
    hauled=true, haul=true, hauls=true, hauling=true,
    hoisted=true, hoist=true, hoists=true, hoisting=true,
    heaved=true, heave=true, heaves=true, heaving=true,
    load=true, loaded=true, loads=true, loading=true,
    bag=true, bags=true, sack=true, sacks=true,
    crate=true, crates=true, barrel=true, barrels=true,
    keg=true, kegs=true, cask=true, casks=true,
    bale=true, bales=true, bundle=true, bundles=true,
    cargo=true, freight=true, ballast=true,
    boulder=true, anvil=true,
    gained=true, gain=true, gains=true, gaining=true,
    muscle=true, overweight=true,
    stone=true, ounce=true, ounces=true, ton=true, tons=true,
    tonne=true, tonnes=true, kilogram=true, kilograms=true, kilo=true, kilos=true,
}
-- Pound classifier helpers (pure; unit-tested in builder/lua_helper_tests.lua).
-- `window` is the lowercased prev+next context around a spelled-"pound(s)" match.
-- A hard currency cue (coin denomination / "sterling") means money, full stop.
local function _pound_hard_currency(window)
    for word in window:gmatch("%a+") do
        if _CURRENCY_HARD[word] then return true end
    end
    return false
end
-- Soft decision: currency "wins" (suppress) only when its cues OUTNUMBER the
-- weight cues, so a genuinely weighty context keeps the match even with a money
-- word nearby. Ties keep (lean toward converting). `num` (optional) is the
-- pound amount, used for the magnitude prior below.
local function _pound_currency_wins(window, num, rate_tail)
    local cscore, wscore = 0, 0
    -- An income rate right after the unit is worth one currency vote, like a
    -- phrase cue — so a genuine weight cue still ties and keeps the conversion.
    if rate_tail then cscore = cscore + 1 end
    for word in window:gmatch("%a+") do
        if _CURRENCY_SOFT[word] then cscore = cscore + 1 end
        if _WEIGHT_WORDS[word]  then wscore = wscore + 1 end
    end
    -- Phrase cues vote on the currency side. %f[%a]…%f[%A] frontiers keep them
    -- whole-word ("in gold", not "thin gold" / "in golden").
    for _, ph in ipairs(_CURRENCY_PHRASES) do
        if window:find("%f[%a]" .. ph .. "%f[%A]") then cscore = cscore + 1 end
    end
    -- Magnitude prior: in prose, amounts of a thousand pounds or more are almost
    -- always money — a person or object weighing ≥1000 lb (450 kg) is absurd
    -- (Pride & Prejudice: "twenty thousand pounds", "her fortune of thirty
    -- thousand pounds"…). Worth ONE currency vote — not more — so a single
    -- genuine weight cue ("the anchor weighed two thousand pounds") still ties
    -- and keeps the conversion. Hundreds are NOT boosted: 200–800 lb are real
    -- weights for people/loads (the CH30 "two/three hundred pounds" cases rely
    -- on this).
    if num and num >= 1000 then cscore = cscore + 1 end
    return cscore > wscore
end

-- ── Bare "degrees" temperature cue classifier ───────────────────────────────
-- Bare "degrees" (no °F/°C, no "Fahrenheit"/"Celsius") is genuinely ambiguous
-- in prose — angle ("banked forty degrees"), rotation, alcohol proof, compass
-- heading, latitude, oven gas marks. Unlike the pounds classifier above
-- (default keep, suppress on strong currency evidence), this GATES: the
-- default is suppress, and a nearby cue word is required to opt a match IN.
-- Reports #14/17/18/19/26/30/31/32/33 (Frostbite, The Postmortal) are all
-- genuine Fahrenheit temperatures with a temperature word nearby.
-- Class attributes (not `local`s) — see the 200-local ceiling note in
-- references/gotchas.md; FootFree._IMPERIAL/._RadioDot use the same trick.
FootFree._TEMP_CUE_WORDS = {
    cold=true, colder=true, coldest=true, coldness=true,
    hot=true, hotter=true, hottest=true, hotness=true,
    warm=true, warmer=true, warmest=true, warmth=true, warmed=true, warming=true,
    cool=true, cooler=true, coolest=true, cooled=true, cooling=true, cools=true,
    freeze=true, freezes=true, freezing=true, froze=true, frozen=true,
    frost=true, frosty=true, frostbite=true, frostbitten=true,
    chill=true, chilly=true, chilled=true, chilling=true, chills=true,
    thaw=true, thawed=true, thawing=true, thaws=true,
    temperature=true, temperatures=true,
    weather=true, climate=true, forecast=true,
    heat=true, heated=true, heating=true, heats=true,
    humid=true, humidity=true, muggy=true,
    sweltering=true, balmy=true, sultry=true, tropical=true,
    frigid=true, icy=true, ice=true, snow=true, snowy=true, snowing=true,
    thermometer=true, thermostat=true,
    refrigerator=true, refrigerated=true, refrigeration=true, refrigerate=true,
    fridge=true, freezer=true, icebox=true,
    fever=true, feverish=true,
    boiling=true, simmer=true, simmering=true,
}
FootFree._TEMP_CUE_PHRASES = {
    "below zero", "sub zero", "below freezing", "wind chill", "heat index",
}
local function _degrees_temperature_cue(window)
    for word in window:gmatch("%a+") do
        if FootFree._TEMP_CUE_WORDS[word] then return true end
    end
    for _, ph in ipairs(FootFree._TEMP_CUE_PHRASES) do
        if window:find(ph, 1, true) then return true end
    end
    return false
end

-- Window-truncation helpers. The scan stores 15 context words each side (the
-- pound currency classifier needs the wide view), but the number/range/idiom
-- logic and the legacy filters are tuned for 8 — these trim back to the 8 words
-- nearest the match so that behaviour is unchanged for everything but pounds.
local function _last_words(s, n)
    if not s then return s end
    local w = {}
    for tok in s:gmatch("%S+") do w[#w + 1] = tok end
    if #w <= n then return s end
    return table.concat(w, " ", #w - n + 1)
end
local function _first_words(s, n)
    if not s then return s end
    local w = {}
    for tok in s:gmatch("%S+") do
        w[#w + 1] = tok
        if #w >= n then break end
    end
    return table.concat(w, " ")
end

-- ── Metric edition helpers ───────────────────────────────────────────────────

-- Directory containing main.lua (and metric_epub.lua).
local _PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("@?(.*)/[^/]*$") or "."

-- Pure-Lua EPUB rewriter (libarchive) — replaces the old python3 metric_epub.py
-- so "Convert directly in the text" works on-device (Kobo etc., no Python).
-- Loaded lazily and cached; the subprocess fork inherits the loaded module.
local _metric_mod
local function _metric_module()
    if _metric_mod == nil then
        local ok, mod = pcall(dofile, _PLUGIN_DIR .. "/metric_epub.lua")
        _metric_mod = (ok and mod) or false
    end
    return _metric_mod or nil
end

-- Return just the converted value (no "original = " prefix).
-- e.g. "1.8 m" from a match for "six feet".
local function _metric_only(r)
    if r._converted then
        return r._converted:match("= (.+)$") or r._converted
    end
    -- Compound matches carry pre-parsed numbers; mirror _convert's compound
    -- branches so the value is correct even before a _converted string is
    -- cached (e.g. a fresh fast-scan record shown in the tap popup).
    if r._num ~= nil then
        if r._num2 then
            return _fmt_height(r._num * 0.3048 + r._num2 * 0.0254) .. " m"
        end
        if r._num_stone2 then
            return _fmt(r._num * 6.35029 + r._num_stone2 * 0.453592) .. " kg"
        end
        if r._num_oz then
            return _fmt(r._num * 0.453592 + r._num_oz * 0.0283495) .. " kg"
        end
    end
    if not r._search then return nil end
    if r._search.converter then
        return r._search.converter(r.matched_text)
    end
    if r._search.factor then
        local num = r._num or _parse_num(r.matched_text)
        if num then
            local result = num * r._search.factor + r._search.offset
            return _fmt_dist(_smart_round(result, num, false, r._search.target), r._search.target)
        end
    end
    return nil
end

-- NOTE: _patches_path and _is_metric_mode are defined after _SIDECAR_DIR below.

-- ── Sidecar cache ────────────────────────────────────────────────────────────
-- Stored in KOReader's own data dir to avoid permission/space issues on
-- external mounts. Key is the sanitised book path so it survives book moves
-- only if the path is identical on next open.

local _CAT_ICONS = {
    length      = "length",
    weight      = "weight",
    temperature = "temp",
    volume      = "volume",
    speed       = "speed",
    area        = "length",   -- no separate area icon; length is the closest
}

local _SIDECAR_DIR         = DataStorage:getDataDir() .. "/footcream"
local _SCAN_PROGRESS_FILE  = _SIDECAR_DIR .. "/scan_progress"
local _PARTIAL_SIDECAR     = _SIDECAR_DIR .. "/scan_partial.lua"
-- Append-only log of conversions the reader flags as wrong (Debug › Units in
-- book › long-press › Flag). Kept as plain text so it can be pulled off the
-- device over USB and discussed/fixed on a computer.
local _FLAG_FILE           = _SIDECAR_DIR .. "/flagged_errors.txt"
os.execute("mkdir -p " .. _SIDECAR_DIR)

-- Error reporting to the developer's collector (report-server/, a Cloudflare
-- Worker + D1). Flags queue locally as JSON lines (_FLAG_FILE's sibling
-- "report_queue.jsonl") and flush in a subprocess when a POST succeeds —
-- e-readers are offline most of the time, so the queue IS the design. Upload
-- happens only when the user turns on "Long-press units to send errors to
-- the developer" (Advanced; default off). Pure helpers only in this table (no
-- side effects at load) so the headless test extractor can pick it up.
FootFree._REPORTING = {
    -- The deployed worker URL INCLUDING the /report path (see
    -- report-server/README.md). Empty = reporting disabled regardless of the
    -- user toggle. Can be overridden at runtime via the
    -- "footcream_report_url" reader setting.
    endpoint = "https://footcream-reports.erikfanki.workers.dev/report",
    -- Minimal JSON string escaper for the hand-built report lines: escapes
    -- backslash, double quote, and all control characters (\n in sentence
    -- context being the common one).
    json_escape = function(s)
        s = tostring(s or "")
        s = s:gsub('[\\"]', "\\%0"):gsub("%c", function(c)
            return string.format("\\u%04x", c:byte())
        end)
        return s
    end,
    -- Blocking HTTPS POST (called from a subprocess only). True on HTTP 200.
    post = function(url, body)
        local ltn12      = require("ltn12")
        local socketutil = require("socketutil")
        local requester  = url:match("^https:") and require("ssl.https")
                                                 or require("socket.http")
        local resp = {}
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local ok, code = requester.request{
            url     = url,
            method  = "POST",
            headers = {
                ["Content-Type"]   = "application/json",
                ["Content-Length"] = tostring(#body),
                ["User-Agent"]     = "foot-cream-reporter",
            },
            source = ltn12.source.string(body),
            sink   = ltn12.sink.table(resp),
        }
        socketutil:reset_timeout()
        return ok ~= nil and code == 200
    end,
}

-- Icon-less replacement for ConfirmBox (which hard-codes a notice-question
-- icon with no way to disable it): left-aligned prompt text over a
-- Cancel/OK button row. Tap outside dismisses, like ConfirmBox. A class
-- attribute rather than a chunk local — the main chunk sits near LuaJIT's
-- 200-locals ceiling.
-- cancel_callback (optional) runs when the user declines — via the Cancel
-- button OR by dismissing the dialog with a tap outside. Used by the convert
-- question to undo a picker-originated mode change.
function FootFree._confirm(text, ok_text, ok_callback, cancel_text, cancel_callback)
    -- Headless test driver: accept every confirmation without showing the
    -- dialog. Set only by the VM verification runs (like KO_MULTIUSER, the
    -- variable never exists on a device).
    if os.getenv("FOOTCREAM_AUTOCONFIRM") == "1" then
        logger.info("FootFree: auto-confirmed — " .. (ok_text or "?"))
        ok_callback()
        return
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title       = text,
        title_align = "left",
        tap_close_callback = cancel_callback,
        buttons = {{
            {
                -- TRANSLATORS: Right-hand button of every Footcream confirmation dialog; dismisses
                -- it without doing anything. Used as the default when a caller doesn't pass its
                -- own wording.
                text = cancel_text or _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                    if cancel_callback then cancel_callback() end
                end,
            },
            {
                text = ok_text,
                callback = function()
                    UIManager:close(dialog)
                    ok_callback()
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

-- Developer marker: if this file exists, dev-only features turn on (currently the
-- scan report). It lives in the same Mac↔VM shared debug folder that the report
-- and other diagnostics already write to (/mnt/macos/debug = <repo>/debug on the
-- Mac), so dev mode is flipped from the Mac side and never exists on a user's
-- device. Enable:  touch <repo>/debug/.dev     Disable:  rm <repo>/debug/.dev
-- Class attribute, not a local: this file is at the 200-local ceiling.
FootFree._DEV_FLAG_FILE = "/mnt/macos/debug/.dev"

-- True when the developer marker file is present.
local function _dev_mode_enabled()
    local fh = io.open(FootFree._DEV_FLAG_FILE)
    if fh then fh:close(); return true end
    return false
end

-- TEMP DIAGNOSTIC: append a timestamped step to a trace file in the (writable)
-- data dir so we can localize a UI freeze. Remove once the freeze is found.
-- Monotonic-ish wall clock in fractional seconds, for profiling scan phases.
local function _now()
    if ok_ffiutil and ffiutil.gettime then
        local ok, s, us = pcall(ffiutil.gettime)
        if ok and s then return s + (us or 0) / 1e6 end
    end
    return os.time()
end

-- Drop the calling process's CPU priority to the minimum. Called inside the
-- forked scan child so a single-core e-reader keeps cycles for the parent UI
-- (page turns stay responsive) while the heavy whole-book findAllText runs.
-- All failure modes are swallowed — niceing is best-effort, never required.
-- Byte size of a file (cheap: seek to end, no read). Used as a stable proxy for
-- a book's text volume when estimating scan duration for the progress bar —
-- stable across font/layout changes, unlike page count.
local function _file_size(path)
    local f = path and io.open(path, "rb")
    if not f then return nil end
    local sz = f:seek("end")
    f:close()
    return sz
end

-- Seconds of scan time per epub byte, used to estimate the progress-bar ETA.
-- Self-calibrated after every scan (footcream_scan_rate); this is just the
-- first-ever-scan fallback, tuned for a slow single-core e-reader. Over-/under-
-- estimates self-correct on the next book.
-- Class attribute, not a local: this file is at the 200-local ceiling.
FootFree._DEFAULT_SCAN_RATE = 5.0e-5

local _ffi_ok, _ffi = pcall(require, "ffi")
local function _nice_self()
    if not _ffi_ok then return end
    pcall(function()
        pcall(_ffi.cdef, "int setpriority(int, int, int);")
        _ffi.C.setpriority(0, 0, 19)  -- PRIO_PROCESS, self, lowest niceness
    end)
end

-- Set to a doc path when "Rescan book" is run on a converted book: after the
-- revert reloads the document, onReaderReady picks this up and does the rescan +
-- re-convert. Module-level so it survives the reloadDocument UI teardown that a
-- scheduled callback on the old instance does not.
local _pending_rescan = nil

-- ── GitHub auto-update ────────────────────────────────────────────────────────
local _GITHUB_REPO = "Fank1/foot-cream"

-- Installed version, read from this plugin folder's _meta.lua (single source).
local function _installed_version()
    local ok, meta = pcall(dofile, _PLUGIN_DIR .. "/_meta.lua")
    if ok and type(meta) == "table" and meta.version then return tostring(meta.version) end
    return "0"
end

-- "v1.2" / "1.2.0" → {1,2,(0)}; numeric, dot-separated, leading v optional.
local function _parse_ver(s)
    local t = {}
    for n in tostring(s):gsub("^[vV]", ""):gmatch("%d+") do t[#t + 1] = tonumber(n) end
    return t
end
local function _ver_gt(a, b)  -- is version a strictly newer than b?
    local va, vb = _parse_ver(a), _parse_ver(b)
    for i = 1, math.max(#va, #vb) do
        local x, y = va[i] or 0, vb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

local function _json_decode(s)
    local ok, rj = pcall(require, "rapidjson")
    if ok and rj and rj.decode then
        local ok2, t = pcall(rj.decode, s)
        if ok2 then return t end
    end
    local ok3, J = pcall(require, "json")  -- fallback if rapidjson is unavailable
    if ok3 and J and J.decode then
        local ok4, t = pcall(J.decode, s)
        if ok4 then return t end
    end
    return nil
end

-- HTTPS GET. With dest_path, streams the body to that file (for the zip);
-- otherwise returns the body string. Follows redirects manually (GitHub asset
-- URLs 302 to a CDN host, which luasec won't re-handshake automatically).
local function _http_fetch(url, dest_path, depth)
    depth = depth or 0
    if depth > 6 then return nil, "too many redirects" end
    local ltn12      = require("ltn12")
    local socketutil = require("socketutil")
    local socket_url = require("socket.url")
    local requester  = url:match("^https:") and require("ssl.https") or require("socket.http")

    local body, fh, sink = {}, nil, nil
    if dest_path then
        fh = io.open(dest_path, "wb")
        if not fh then return nil, "cannot write " .. dest_path end
        sink = ltn12.sink.file(fh)
    else
        sink = ltn12.sink.table(body)
    end

    -- KOReader's standard short timeouts (10s/op, 30s total) — socketutil has
    -- globally overridden socket.tcp, so these bound connect/read. Our old 120s
    -- total could leave the network task hanging for two minutes on a bad
    -- connection. (DNS getaddrinfo still isn't bounded by these — it's a
    -- pre-socket system call — so a momentary DNS hiccup can still briefly
    -- block; that's a device/network state issue, not ours.)
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code, headers = requester.request{
        url     = url,
        method  = "GET",
        headers = { ["User-Agent"] = "foot-cream-updater" },
        sink    = sink,
        redirect = false,  -- handled below
    }
    socketutil:reset_timeout()

    if not ok then
        -- DNS/host-resolution failures surface as "host or service not provided"
        -- — make that actionable rather than cryptic.
        local msg = tostring(code)
        if msg:find("host or service", 1, true) or msg:find("not known", 1, true) then
            msg = "couldn't reach GitHub (network/DNS) — check WiFi and try again"
        end
        return nil, "network error: " .. msg
    end
    code = tonumber(code)
    if code and code >= 300 and code < 400 then
        local loc = headers and (headers.location or headers.Location)
        if not loc then return nil, "redirect without Location" end
        return _http_fetch(socket_url.absolute(url, loc), dest_path, depth + 1)
    end
    if not code or code >= 400 then return nil, "HTTP " .. tostring(code) end
    if dest_path then return true end
    return table.concat(body)
end

-- After unzipping, find the directory that holds both main.lua and _meta.lua,
-- wherever it sits in the archive (asset-zip root, "<name>.koplugin/", or the
-- source zip's "<repo>-<tag>/plugin/"). Returns that path or nil.
local function _find_plugin_root(dir)
    local p = io.popen('find "' .. dir .. '" -name main.lua 2>/dev/null')
    if not p then return nil end
    for line in p:lines() do
        local d = line:match("^(.*)/[^/]*$")
        local mf = d and io.open(d .. "/_meta.lua")
        if mf then mf:close(); p:close(); return d end
    end
    p:close()
    return nil
end

local function _file_exists(path)
    local f = io.open(path)
    if f then f:close(); return true end
    return false
end

-- Shared by the subprocess and Android-synchronous update-install paths:
-- download -> unzip -> swap the plugin dir in place. Returns "OK" or
-- "ERR:<reason>". No UIManager use inside — the subprocess path can't.
-- (Class attribute, not a local: this file is at the 200-local ceiling.)
function FootFree._do_install_update(asset_url, tag)
    local tmp_zip   = _SIDECAR_DIR .. "/update.zip"
    local tmp_dir   = _SIDECAR_DIR .. "/update"
    local plugin_dir = _PLUGIN_DIR
    local backup    = plugin_dir .. ".bak"
    os.execute('rm -rf "' .. tmp_dir .. '" "' .. tmp_zip .. '" "' .. backup .. '"')
    local ok, err = _http_fetch(asset_url, tmp_zip)
    -- TRANSLATORS: Error after 'Menu > Footcream > Check for updates' when downloading
    -- the release package fails. %1 is the network error, untranslated.
    if not ok then return "ERR:" .. T(_("Download failed: %1"), tostring(err)) end
    os.execute('mkdir -p "' .. tmp_dir .. '"')
    os.execute('unzip -o "' .. tmp_zip .. '" -d "' .. tmp_dir .. '" >/dev/null 2>&1')
    local src = _find_plugin_root(tmp_dir)
    -- TRANSLATORS: Error after 'Menu > Footcream > Check for updates': the downloaded
    -- ZIP didn't contain a plugin, so nothing was installed.
    if not src then return "ERR:" .. _("Update package didn't contain the plugin files.") end
    os.execute('cp -rf "' .. plugin_dir .. '" "' .. backup .. '"')
    os.execute('cp -rf "' .. src .. '/." "' .. plugin_dir .. '/"')
    if not _file_exists(plugin_dir .. "/main.lua") then
        os.execute('rm -rf "' .. plugin_dir .. '" && mv "' .. backup .. '" "' .. plugin_dir .. '"')
        os.execute('rm -rf "' .. tmp_dir .. '" "' .. tmp_zip .. '"')
        -- TRANSLATORS: Error after 'Menu > Footcream > Check for updates': copying the new
        -- version in failed and the old one was put back. Nothing is broken.
        return "ERR:" .. _("Install failed — restored the previous version.")
    end
    os.execute('rm -rf "' .. backup .. '" "' .. tmp_dir .. '" "' .. tmp_zip .. '"')
    return "OK"
end

-- Shared: interpret _do_install_update's result, offering a restart on
-- success or surfacing the error otherwise.
function FootFree._report_install_result(result, tag)
    local InfoMessage = require("ui/widget/infomessage")
    if result == "OK" then
        FootFree._confirm(
            -- TRANSLATORS: Confirmation after a successful self-update. %1 is the version tag
            -- (e.g. 'v1.6.0'). The new code only runs after a restart.
            T(_("Updated to %1.\nRestart KOReader now to load it?"), tag),
            -- TRANSLATORS: Left button on the 'Updated to ...' dialog; restarts KOReader
            -- immediately so the new version loads.
            _("Restart"), function() UIManager:restartKOReader() end,
            -- TRANSLATORS: Right button on the 'Updated to ...' dialog; closes it and keeps
            -- reading. The update loads at the next restart either way.
            _("Later"))
    else
        UIManager:show(InfoMessage:new{
            -- TRANSLATORS: Fallback error when a self-update fails without a specific reason
            -- ('Menu > Footcream > Check for updates').
            text = (type(result) == "string" and result:gsub("^ERR:", "")) or _("Update failed.") })
    end
end

-- Path of the patch record for a given book (defined here so _SIDECAR_DIR is set).
local function _patches_path(doc_path)
    local key = doc_path:gsub("[/\\]", "_"):gsub("[^%w%-%._]", "_")
    if #key > 180 then key = key:sub(-180) end
    return _SIDECAR_DIR .. "/patches_" .. key .. ".json"
end

local function _is_metric_mode(doc_path)
    local fh = io.open(_patches_path(doc_path))
    if fh then fh:close(); return true end
    return false
end

-- Path of the converted->original reverse-lookup sidecar for a given book.
local function _reverse_path(doc_path)
    local key = doc_path:gsub("[/\\]", "_"):gsub("[^%w%-%._]", "_")
    if #key > 180 then key = key:sub(-180) end
    return _SIDECAR_DIR .. "/reverse_" .. key .. ".lua"
end

-- Path of the tiny file recording which scanner (CACHE_VERSION) produced a
-- book's in-text conversion. On open, a converted book compares this with the
-- current CACHE_VERSION; if the scanner has since improved, it can revert +
-- rescan + reconvert so the conversion isn't stuck on stale logic.
local function _metric_ver_path(doc_path)
    local key = doc_path:gsub("[/\\]", "_"):gsub("[^%w%-%._]", "_")
    if #key > 180 then key = key:sub(-180) end
    return _SIDECAR_DIR .. "/metric_ver_" .. key
end

-- `total` (optional) is the book's hint count at conversion time. A converted
-- book's _all_matches holds only the rewrite's leftovers, but the menu status
-- line must keep reporting the full unit count in every mode (user-specified),
-- so the pre-conversion count is stamped here alongside the version.
-- `mode` (optional) is the tap mode the conversion was applied in (2 = the
-- conversion appended alongside the original, 3 = replaced) so open/mode-
-- switch flows know whether the on-disk text matches the active mode.
-- `direction` is the preferred-units setting the conversion was made under
-- ("metric"/"us"/"uk") — a converted book must revert when the preference
-- changes, since the baked-in text is for the other system (us vs uk also
-- differ: stones, imperial pints).
local function _write_metric_version(doc_path, total, mode, direction)
    local f = io.open(_metric_ver_path(doc_path), "w")
    if f then
        f:write(tostring(CACHE_VERSION)
            .. (total and (" " .. tostring(total)) or "")
            .. (total and mode and (" " .. tostring(mode)) or "")
            .. (total and mode and direction and (" " .. direction) or ""))
        f:close()
    end
end

-- The scanner version a converted book was made with, or nil if unknown (an
-- older conversion predating this record — treated as stale so it updates
-- once). Second return: the conversion-time hint count; third: the tap mode
-- it was applied in (nil for conversions predating the stamp — those were
-- mode 3, the only convert mode at the time); fourth: the conversion's
-- direction (nil for stamps predating it — those were always "metric", the
-- only in-text direction at the time).
local function _read_metric_version(doc_path)
    local f = io.open(_metric_ver_path(doc_path))
    if not f then return nil end
    local s = f:read("*a") or ""
    f:close()
    local v, applied, amode, adir = s:match("(%d+)%s+(%d+)%s+(%d+)%s+(%a+)")
    if not v then v, applied, amode = s:match("(%d+)%s+(%d+)%s+(%d+)") end
    if not v then v, applied = s:match("(%d+)%s+(%d+)") end
    if not v then v = s:match("%d+") end
    return tonumber(v), tonumber(applied), tonumber(amode), adir
end

-- xpointers look like ".../text().162" — split into the node path and the
-- trailing character offset so overlapping matches on the same text node
-- can be compared numerically.
local function _xpointer_offset(xp)
    local prefix, num = xp:match("^(.*%.)(%d+)$")
    if not prefix then return xp, 0 end
    return prefix, tonumber(num)
end

-- A match whose xpointer path runs through a heading element (h1–h6) lives in a
-- chapter title or the book title, never body prose. crengine renders headings
-- as "/h2/span/text()" etc., so the path contains "/hN" followed by "/" or "[".
-- Such matches are dropped at scan time → never underlined, never rewritten.
-- (Inlined at the two scan chokepoints as `(xp or ""):find("/h[1-6][%[/]")` to
-- stay under Lua's 200-locals-per-chunk limit — no top-level helper slot.)

-- Numeric document-order key for an xpointer: the sequence of integers it
-- contains (DocFragment index, element indices, char offset). Comparing these
-- numerically orders e.g. DocFragment[7] before DocFragment[10] — a plain
-- string compare would wrongly put "[10]" first.
local function _xp_numkey(xp)
    local t = {}
    for n in tostring(xp):gmatch("%d+") do t[#t + 1] = tonumber(n) end
    return t
end
local function _xp_key_less(ka, kb)
    for i = 1, math.max(#ka, #kb) do
        local va, vb = ka[i] or -1, kb[i] or -1
        if va ~= vb then return va < vb end
    end
    return false
end

-- Drop matches that overlap an already-kept match on the same text node,
-- preferring the longer match (e.g. "9.30 m" over the substring "30 m").
-- Needed because findAllText's alternation can return overlapping hits when
-- one converted value is itself a substring of another.
local function _filter_overlapping_matches(matches)
    local indexed = {}
    for i, m in ipairs(matches) do
        local prefix, s = _xpointer_offset(m.start)
        local _, e = _xpointer_offset(m["end"])
        indexed[i] = { m = m, prefix = prefix, s = s, e = e, key = _xp_numkey(m.start) }
    end
    table.sort(indexed, function(a, b)
        if a.prefix ~= b.prefix then return _xp_key_less(a.key, b.key) end
        if a.s ~= b.s then return a.s < b.s end
        return a.e > b.e
    end)
    local result, last_prefix, last_end = {}, nil, -1
    for _, it in ipairs(indexed) do
        if it.prefix ~= last_prefix or it.s >= last_end then
            table.insert(result, it.m)
            last_prefix, last_end = it.prefix, it.e
        end
    end
    return result
end

-- ── Donut progress indicator ──────────────────────────────────────────────────
-- Pre-computed ring pixel list (built once, reused every frame).
local _donut_pixels = nil

local function _build_donut(r_outer, r_inner)
    local pixels = {}
    for dy = -r_outer, r_outer do
        for dx = -r_outer, r_outer do
            local d = math.sqrt(dx*dx + dy*dy)
            if d >= r_inner and d <= r_outer then
                -- Angle from top, clockwise: 0 at top, 2π at top again
                local angle = math.atan2(dx, -dy)
                if angle < 0 then angle = angle + 2 * math.pi end
                table.insert(pixels, { dx=dx, dy=dy, angle=angle })
            end
        end
    end
    return pixels
end

local function _draw_donut(bb, cx, cy, progress)
    local R_OUT = 11
    local R_IN  =  7
    if not _donut_pixels then
        _donut_pixels = _build_donut(R_OUT, R_IN)
    end
    -- Clear the circle area with white so we paint over page content cleanly
    bb:paintCircle(cx, cy, R_OUT, Blitbuffer.Color8(0xFF))
    -- Draw ring: filled arc = black, unfilled arc = light grey
    local threshold = progress * 2 * math.pi
    local black = Blitbuffer.Color8(0x00)
    local grey  = Blitbuffer.Color8(0xBB)
    for _, p in ipairs(_donut_pixels) do
        bb:paintRect(cx + p.dx, cy + p.dy, 1, 1,
                     p.angle <= threshold and black or grey)
    end
end

-- ── SVG scan-progress loader ──────────────────────────────────────────────────
-- Custom artwork in assets/loader/<pct>%.svg (0..100 in 5% steps) replaces the
-- hand-drawn donut. Each bucket's tile is rendered once and cached.
-- Class attribute, not a local: this file is at the 200-local ceiling.
FootFree._LOADER_DIR = _PLUGIN_DIR .. "/assets/loader"
local _LOADER_PX  = 28            -- on-screen size before DPI scaling
-- How long our corner ring yields to KOReader's own re-render bar before
-- drawing beside it again. Long enough to cover a full-book re-render after an
-- in-text convert; short enough that a stuck rendering_state can't hide our
-- progress for a whole session.
local _RENDER_YIELD_S = 60
-- How a scan-and-convert divides the ONE ring the reader sees. Each leg gets a
-- slice and only the last is allowed to close the circle, so the ring never
-- appears to finish and restart. Grouped in a table rather than as three
-- top-level locals because main.lua is at Lua's 200-locals-per-chunk ceiling.
--
--   0 → tail_from        the scan (its own 0→0.97 sweep, compressed)
--   tail_from → relocate  the in-place rewrite
--   relocate → 1.0        the post-reload re-locate of converted positions
--
-- Before this split each leg ran its own 0→100%: the scan filled the circle,
-- the convert restarted it at 75%, and the re-locate did it again — "it
-- finished, then went backwards" (on-device report, 2026-08-17).
--
-- notice_wait_s bounds how long a queued toast waits for the ring and
-- KOReader's re-render bar to clear. A bound, not a timeout we expect to hit:
-- the rendering flag is KOReader's, and a notice that can be swallowed forever
-- is worse than one that arrives late.
local _RING = {
    tail_from     = 0.70,
    relocate_from = 0.88,
    notice_wait_s = 60,
}
local _loader_tile_cache = {}

-- Map a 0..1 progress fraction to the nearest available 5% bucket (0,5,..,100).
local function _loader_pct(progress)
    local pct = math.floor((progress or 0) * 20 + 0.5) * 5
    if pct < 0 then return 0 elseif pct > 100 then return 100 end
    return pct
end

-- Rendered Blitbuffer for a bucket, or false if it couldn't render (cached
-- either way so we don't retry every repaint).
local function _loader_tile(pct)
    local cached = _loader_tile_cache[pct]
    if cached ~= nil then return cached end
    local Screen = require("device").screen
    local size = Screen:scaleBySize(_LOADER_PX)
    local ok, tile = pcall(function()
        return RenderImage:renderSVGImageFile(
            FootFree._LOADER_DIR .. "/" .. pct .. "%.svg", size, size)
    end)
    if not ok or not tile then
        _loader_tile_cache[pct] = false
        return false
    end
    _loader_tile_cache[pct] = tile
    return tile
end

-- Paint the loader at top-left (x, y). Falls back to the donut if the SVG
-- can't be rendered. progress is 0..1.
local function _draw_loader(bb, x, y, progress)
    local tile = _loader_tile(_loader_pct(progress))
    if not tile then
        _draw_donut(bb, x + 11, y + 11, progress)
        return
    end
    local tw, th = tile:getWidth(), tile:getHeight()
    -- White disc behind the ring so it paints cleanly over page text.
    bb:paintCircle(x + math.floor(tw / 2), y + math.floor(th / 2),
                   math.floor(tw / 2) + 1, Blitbuffer.Color8(0xFF))
    bb:alphablitFrom(tile, x, y, 0, 0, tw, th)
end

-- ── Underline styling ────────────────────────────────────────────────────────
-- The underline is drawn 10% darker than the chosen intensity, for more contrast
-- across the board (the menu still shows 10/20/30/40%, but 10% renders like 20%,
-- … 40% like 50%). Applied in both the solid and wavy render paths.
local _UNDERLINE_CONTRAST_BOOST = 10
local function _underline_grey(pct)
    local eff = math.min(100, pct + _UNDERLINE_CONTRAST_BOOST)
    return math.floor(255 * (1 - eff / 100) + 0.5)
end

-- Greyscale underline color from a percent intensity: higher percent = darker
-- line. 0% would be white, 100% would be black.
local function _underline_color(pct)
    return Blitbuffer.Color8(_underline_grey(pct))
end

-- The wavy underline tiles plugin/assets/wiggly-line.svg horizontally. The
-- raw SVG (stroke="black", with or without a stroke-width attribute) is
-- recolored and restroked per (raw underline-width, color %) combination,
-- rendered once, and cached.
local _WAVY_SVG_PATH = _PLUGIN_DIR .. "/assets/wiggly-line.svg"
local _wavy_svg_template
local _wavy_tile_cache = {}

local function _load_wavy_template()
    if _wavy_svg_template then return _wavy_svg_template end
    local fh = io.open(_WAVY_SVG_PATH, "r")
    if not fh then return nil end
    _wavy_svg_template = fh:read("*a")
    fh:close()
    return _wavy_svg_template
end

-- Returns a rendered Blitbuffer tile, or false if rendering failed (cached
-- either way so we don't retry every repaint).
local function _wavy_tile(raw_width, color_pct)
    local key = raw_width .. "_" .. color_pct
    local cached = _wavy_tile_cache[key]
    if cached ~= nil then return cached end

    local template = _load_wavy_template()
    if not template then
        _wavy_tile_cache[key] = false
        return false
    end

    local grey = _underline_grey(color_pct)
    local hex  = string.format("#%02x%02x%02x", grey, grey, grey)
    local svg  = template:gsub('stroke="black"', 'stroke="' .. hex .. '"')
    if template:find('stroke%-width="[%d%.]+"') then
        svg = svg:gsub('stroke%-width="[%d%.]+"', 'stroke-width="' .. raw_width .. '"')
    else
        -- Template has no stroke-width attribute (defaults to 1) — add one.
        svg = svg:gsub('stroke="' .. hex .. '"', 'stroke="' .. hex .. '" stroke-width="' .. raw_width .. '"')
    end

    local svg_path = _SIDECAR_DIR .. "/wavy_" .. key .. ".svg"
    local fh = io.open(svg_path, "w")
    if fh then fh:write(svg); fh:close() end

    -- Render at the SVG's own aspect ratio (read from its root <svg width=.. height=..>),
    -- so a landscape tile isn't stretched/cropped into a square.
    local svg_w = tonumber(template:match('<svg[^>]-width="([%d%.]+)"')) or 12
    local svg_h = tonumber(template:match('<svg[^>]-height="([%d%.]+)"')) or 12
    local Screen = require("device").screen
    -- 1 SVG unit = 1 scaled pixel, so stroke-width="raw_width" renders as
    -- raw_width actual pixels rather than being stretched by tile_w/svg_w.
    local tile_w = Screen:scaleBySize(svg_w)
    local tile_h = math.max(1, math.floor(tile_w * svg_h / svg_w + 0.5))
    local ok, tile = pcall(function()
        return RenderImage:renderSVGImageFile(svg_path, tile_w, tile_h)
    end)
    if not ok or not tile then
        _wavy_tile_cache[key] = false
        return false
    end
    _wavy_tile_cache[key] = tile
    return tile
end

-- Draw a styled underline beneath `box` (screen coordinates).
-- style: "solid" | "wavy"; width is in (already-scaled) pixels.
-- raw_width/color_pct are the unscaled settings (1/2 Thin/Thick, 10-20-30-40), used to
-- build the wavy SVG tile.
local function _draw_underline(bb, box, style, color, width, raw_width, color_pct)
    local y  = box.y + box.h - width
    local x0 = box.x
    local x1 = box.x + box.w
    if style == "wavy" then
        local tile = _wavy_tile(raw_width, color_pct)
        if tile then
            local tw, th = tile:getWidth(), tile:getHeight()
            -- Centre the tile's stroke on the same line as the solid
            -- underline's centre (box.h - width/2), not flush with the
            -- bottom of the box.
            local ypos = box.y + box.h - math.floor((th + width) / 2 + 0.5)
            local x = x0
            while x < x1 do
                local w = math.min(tw, x1 - x)
                bb:alphablitFrom(tile, x, ypos, 0, 0, w, th)
                x = x + tw
            end
            return
        end
        -- Fall through to solid if the tile failed to render.
    end
    bb:paintRect(x0, y, box.w, width, color)
end

-- ── Popup pointer arrow ─────────────────────────────────────────────────────
-- A small triangular "speech bubble" pointer drawn row-by-row. The two
-- slanted edges get a border stripe; the base (which overlaps the popup
-- card) is left border-free so it visually merges into the card.
local _PointerArrow = Widget:extend{
    width        = 0,
    height       = 0,
    direction    = "up",   -- "up": apex on top, base on bottom; "down": reverse
    apex_offset  = 0,      -- apex x position, relative to the widget's left edge
    border_size  = 1,
    border_color = Blitbuffer.COLOR_BLACK,
    fill_color   = Blitbuffer.COLOR_WHITE,
}

function _PointerArrow:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function _PointerArrow:paintTo(bb, x, y)
    local w, h  = self.width, self.height
    local apex  = self.apex_offset
    local bw    = self.border_size
    for row = 0, h - 1 do
        local frac = (self.direction == "up") and ((row + 1) / h) or ((h - row) / h)
        local half  = (w * frac) / 2
        local left  = math.floor(apex - half + 0.5)
        local right = math.ceil(apex + half - 0.5)
        bb:paintRect(x + left, y + row, math.max(1, right - left + 1), 1, self.border_color)

        local inner_half = half - bw
        if inner_half > 0 then
            local ileft  = math.floor(apex - inner_half + 0.5)
            local iright = math.ceil(apex + inner_half - 0.5)
            if iright >= ileft then
                bb:paintRect(x + ileft, y + row, iright - ileft + 1, 1, self.fill_color)
            end
        end
    end
end

-- ── Underline preview widget ────────────────────────────────────────────────
-- Renders just the underline (via _draw_underline) inside a widget the size
-- of the sample word, so the Styling dialog can show a live preview.
local _UnderlinePreview = Widget:extend{
    width = 0, height = 0,
    style = "solid", color = nil, line_width = 0, raw_width = 2, color_pct = 25,
}

function _UnderlinePreview:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function _UnderlinePreview:paintTo(bb, x, y)
    _draw_underline(bb, { x = x, y = y, w = self.width, h = self.height },
        self.style, self.color, self.line_width, self.raw_width, self.color_pct)
end

-- Radio marker, drawn (not a font glyph) so the fills and dark-mode behaviour
-- are exact. Selected: a big filled-black disc with a smaller solid-white disc
-- inside. Unselected: a thin black ring (empty). Drawn black-on-white always;
-- KOReader's global night-mode inversion flips it to white-on-black for free.
-- A class attribute (not a chunk local — the 200-locals ceiling), shared by
-- the Styling dialog and the Mode picker. Edges are anti-aliased by per-pixel
-- coverage (paintCircle is hard-edged and looked jagged at this size):
-- coverage ≈ how far the pixel is inside the relevant radius, blended over
-- the white background as a grey value.
FootFree._RadioDot = Widget:extend{ size = 0, selected = false }
function FootFree._RadioDot:getSize() return Geom:new{ w = self.size, h = self.size } end
function FootFree._RadioDot:paintTo(bb, x, y)
    local sz   = self.size
    local ro   = sz / 2                              -- outer radius
    local cx   = x + ro - 0.5                         -- centre on the pixel grid
    local cy   = y + ro - 0.5
    local ri   = self.selected and (ro * 0.5) or nil  -- inner white radius
    local rh   = ro - math.max(1.3, ro * 0.26)        -- ring inner edge (unselected)
    local function cover(d, edge) -- 1 inside, 0 outside, linear across the edge
        local c = edge + 0.5 - d
        if c < 0 then return 0 elseif c > 1 then return 1 else return c end
    end
    for py = 0, sz - 1 do
        for px = 0, sz - 1 do
            local dx, dy = (x + px) - cx, (y + py) - cy
            local d = math.sqrt(dx * dx + dy * dy)
            local v   -- final grey 0..255; nil = leave background untouched
            if self.selected then
                local co = cover(d, ro)               -- black-disc coverage
                if co > 0 then
                    local cin = cover(d, ri)          -- white-inner coverage
                    v = 255 * (1 - co)                -- white bg → black disc
                    v = v * (1 - cin) + 255 * cin     -- white inner over the disc
                end
            else
                local c = cover(d, ro) - cover(d, rh) -- ring = outer minus hole
                if c > 0 then v = 255 * (1 - c) end
            end
            if v then
                bb:paintRect(x + px, y + py, 1, 1, Blitbuffer.Color8(math.floor(v + 0.5)))
            end
        end
    end
end

local function _sidecar_path(doc_path)
    local key = doc_path:gsub("[/\\]", "_"):gsub("[^%w%-%._]", "_")
    if #key > 180 then key = key:sub(-180) end
    return _SIDECAR_DIR .. "/" .. key .. ".lua"
end

local function _save_sidecar(doc_path, matches)
    local sidecar = _sidecar_path(doc_path)
    local fh, err = io.open(sidecar, "w")
    if not fh then
        logger.warn("FootFree: sidecar save failed: " .. tostring(err) .. " — " .. sidecar)
        return
    end
    -- Record the epub's mtime AS THE SIDECAR SEES IT, so staleness can be
    -- judged by equality against a later reading of the same value. Comparing
    -- epub mtime > sidecar mtime is broken on the VM/e-reader whenever the
    -- book lives on a network/shared mount whose clock differs from the
    -- device's: a freshly saved sidecar can look "older" than an epub stamped
    -- by the other clock, and gets discarded in an endless rescan loop.
    local epub_mtime = lfs and lfs.attributes(doc_path, "modification")
    fh:write("return {\n  version = " .. CACHE_VERSION .. ",\n"
        .. "  epub_mtime = " .. tostring(epub_mtime or "nil") .. ",\n")
    -- A scan of a CONVERTED (mode-3) book records only the leftovers the
    -- rewrite skipped — valid while the book stays converted, but poison
    -- after a revert: the revert's no-rescan optimization would resurrect it
    -- against the restored ORIGINAL text ("loaded 32 match(es)" on an
    -- imperial book, at converted-text positions). Mark it so the revert
    -- knows to delete rather than revalidate.
    if _is_metric_mode(doc_path) then fh:write("  metric_scan = true,\n") end
    -- Scan direction: an imperial-preference scan found METRIC units; its
    -- matches are meaningless under another preference (absent = "metric",
    -- the classic direction — backward compatible).
    local dir_now = FootFree._IMPERIAL.preferred()
    if dir_now ~= "metric" then
        fh:write("  direction = \"" .. dir_now .. "\",\n")
    end
    fh:write("  matches = {\n")
    for _, r in ipairs(matches) do
        -- Core fields always written
        fh:write(string.format(
            "    { start=%q, [\"end\"]=%q, matched_text=%q, converted=%q, cat=%q," ..
            " prev_text=%q, next_text=%q",
            r.start, r["end"], r.matched_text, _convert(r), r._cat or "",
            r.prev_text or "", r.next_text or ""))
        -- Vague-quantifier band ("a few hundred pounds"): flag it so Mode 3
        -- knows to skip it after a reload (the band can't be rewritten inline).
        if r._vague then fh:write(", vague=true") end
        -- For simple factor/offset matches: store raw unit+num+factor so
        -- UK volume recalculation can happen without a rescan.
        if r._unit and r._search and r._search.factor and not r._search.converter then
            local num = _parse_num(r.matched_text)
            if num then
                fh:write(string.format(", unit=%q, num=%s, factor=%s, offset=%s",
                    r._unit, tostring(num),
                    tostring(r._search.factor), tostring(r._search.offset or 0)))
            end
        end
        fh:write(" },\n")
    end
    fh:write("  },\n}\n")
    fh:close()
end

-- Load raw matches from sidecar — no settings applied yet.
-- Call _apply_settings_to_matches() after this.
local function _load_sidecar_raw(doc_path)
    local sidecar = _sidecar_path(doc_path)
    local ok, data = pcall(dofile, sidecar)
    if not ok or type(data) ~= "table" or data.version ~= CACHE_VERSION then return nil end
    -- Direction mismatch (preference flipped since the scan): the matches are
    -- for the other system entirely — rescan. Keep the file on a CONVERTED
    -- book (it's the preserved pre-conversion scan; the revert path needs it,
    -- and the post-revert load lands here again and deletes it then).
    if (data.direction or "metric") ~= FootFree._IMPERIAL.preferred() then
        logger.info("FootFree: sidecar is for the other unit direction — rescan needed")
        if not _is_metric_mode(doc_path) then os.remove(sidecar) end
        return nil
    end
    -- Discard the sidecar if the epub has been modified since it was saved —
    -- its xpointers would point into text that no longer exists. The sidecar
    -- records the epub mtime it was scanned against; staleness is INEQUALITY
    -- between that and the current mtime (two readings of the same clock).
    -- Never compare epub mtime against the sidecar file's own mtime: when the
    -- book lives on a shared/network mount, its timestamps come from a
    -- different clock than the device's, and a mere few seconds of skew makes
    -- every freshly saved sidecar look "older" than the epub — an endless
    -- discard-and-rescan loop.
    -- While the book is CONVERTED, the sidecar on disk is the ORIGINAL-text
    -- scan: stale against the rewritten epub (mtime mismatch), but exactly
    -- what a future revert needs — the revert restores byte-identical text
    -- and re-stamps the recorded mtime, making this sidecar valid again with
    -- no rescan. So in metric mode a stale sidecar is unusable but must be
    -- KEPT on disk; only unconverted books delete stale caches (that removal
    -- is what forces the legitimate rescan after external file changes).
    local keep_stale = _is_metric_mode(doc_path)
    local epub_attr = lfs and lfs.attributes(doc_path, "modification")
    if data.epub_mtime then
        if epub_attr and epub_attr ~= data.epub_mtime then
            if keep_stale then
                logger.info("FootFree: sidecar is the preserved pre-conversion scan — keeping")
            else
                logger.info("FootFree: epub modified since scan — discarding stale cache")
                os.remove(sidecar)
            end
            return nil
        end
    else
        -- Legacy sidecar without the recorded mtime: fall back to the old
        -- cross-clock comparison (better than accepting stale xpointers).
        local sidecar_attr = lfs and lfs.attributes(sidecar, "modification")
        if epub_attr and sidecar_attr and epub_attr > sidecar_attr then
            if keep_stale then
                logger.info("FootFree: sidecar is the preserved pre-conversion scan — keeping")
            else
                logger.info("FootFree: epub newer than sidecar — discarding stale cache")
                os.remove(sidecar)
            end
            return nil
        end
    end
    local matches = {}
    for _, m in ipairs(data.matches or {}) do
        table.insert(matches, {
            start        = m.start,
            ["end"]      = m["end"],
            matched_text = m.matched_text,
            _converted   = m.converted,
            _cat         = m.cat,
            prev_text    = m.prev_text,   -- for pounds classifier
            next_text    = m.next_text,   -- for pounds classifier
            _unit        = m.unit,        -- for UK volume recalculation
            _num         = m.num,         -- numeric value (nil for compound matches)
            _factor      = m.factor,      -- US/default factor (nil for compound)
            _offset      = m.offset,      -- offset (nil for compound)
            _vague       = m.vague,       -- vague-quantifier band → Mode 3 skips it
        })
    end
    return matches
end

-- Write the converted->original map immediately after a metric edition is applied.
-- Write the `map` block: each converted string maps to its category and an
-- ordered list of the original phrases that produced it, one entry per
-- occurrence in document order. Keeping the list (rather than a single
-- "first writer wins" original) lets two different originals that round to the
-- same converted string each recover their own text by position (6.2).
local function _write_reverse_map(fh, map, doc_path)
    -- Same recorded-mtime staleness model as _save_sidecar: equality against
    -- a later reading of the epub's own mtime, never a cross-clock comparison
    -- (see _load_sidecar_raw).
    local epub_mtime = lfs and doc_path and lfs.attributes(doc_path, "modification")
    fh:write("return {\n  version = " .. _REVERSE_VERSION .. ",\n"
        .. "  epub_mtime = " .. tostring(epub_mtime or "nil") .. ",\n  map = {\n")
    for to, info in pairs(map) do
        fh:write(string.format("    [%q] = { cat=%q, originals={", to, info.cat or ""))
        for _, o in ipairs(info.originals or {}) do
            fh:write(string.format("%q,", o))
        end
        fh:write("} },\n")
    end
    fh:write("  },\n")
end

local function _save_reverse_map(doc_path, map)
    local fh = io.open(_reverse_path(doc_path), "w")
    if not fh then return end
    _write_reverse_map(fh, map, doc_path)
    fh:write("}\n")
    fh:close()
end

-- Load the reverse map (and cached position scan, if present). Discards if
-- the epub has been modified since the reverse sidecar was written.
local function _load_reverse_data(doc_path)
    local path = _reverse_path(doc_path)
    local ok, data = pcall(dofile, path)
    if not ok or type(data) ~= "table" or data.version ~= _REVERSE_VERSION then return nil end
    local epub_attr = lfs and lfs.attributes(doc_path, "modification")
    if data.epub_mtime then
        -- Recorded-mtime equality — see _load_sidecar_raw for why the old
        -- "epub newer than file" comparison is wrong across mount clocks.
        if epub_attr and epub_attr ~= data.epub_mtime then
            os.remove(path)
            return nil
        end
    else
        local rev_attr = lfs and lfs.attributes(path, "modification")
        if epub_attr and rev_attr and epub_attr > rev_attr then
            os.remove(path)
            return nil
        end
    end
    return data
end

-- Rewrite the reverse sidecar with cached, fully-resolved match positions
-- added, so future opens skip the one-time findAllText scan. Each cached entry
-- already carries the specific original text for that position (resolved via
-- document order), so the load path needs no further map lookup.
local function _save_reverse_matches(doc_path, map, matches)
    local fh = io.open(_reverse_path(doc_path), "w")
    if not fh then return end
    _write_reverse_map(fh, map, doc_path)
    fh:write("  matches = {\n")
    for _, m in ipairs(matches) do
        fh:write(string.format("    { start=%q, [\"end\"]=%q, original=%q, cat=%q },\n",
            m.start, m["end"], m.original, m.cat or ""))
    end
    fh:write("  },\n}\n")
    fh:close()
end

-- Read the book's declared language tag (lowercased), empty string if unknown.
local function _get_book_lang(doc)
    local ok, props = pcall(function() return doc:getDocumentProps() end)
    if ok and type(props) == "table" then
        return (props.language or props.lang or ""):lower()
    end
    return ""
end

-- True for en-*, or when language is unknown — empty or the ISO
-- "undetermined" tag ("und", e.g. The Bell Jar's OPF) → don't block.
local function _is_english(doc)
    local lang = _get_book_lang(doc)
    return lang == "" or lang == "und" or lang:match("^en") ~= nil
end

-- True specifically for en-GB / en-UK (UK Imperial volumes).
local function _is_uk_book(doc)
    local lang = _get_book_lang(doc)
    return lang:match("^en%-gb") ~= nil or lang:match("^en%-uk") ~= nil
end

-- Human-readable label for the book's English-language variant, e.g.
-- "UK English" / "US English". Returns nil for unknown/non-regional "en".
local _LANG_LABELS = {
    -- TRANSLATORS: Name of the English variant detected from the book's metadata,
    -- shown inside the hint-count menu line: '12 hints found in this US English book'.
    -- Keep it short; it must read naturally inside that sentence.
    ["en-us"] = _("US English"),
    -- TRANSLATORS: Name of the English variant detected from the book's metadata,
    -- shown inside the hint-count menu line: '12 hints found in this UK English book'.
    -- Keep it short; it must read naturally inside that sentence.
    ["en-gb"] = _("UK English"),
    -- TRANSLATORS: Name of the English variant detected from the book's metadata,
    -- shown inside the hint-count menu line: '12 hints found in this UK English book'.
    -- Keep it short; it must read naturally inside that sentence.
    ["en-uk"] = _("UK English"),
    -- TRANSLATORS: Name of the English variant detected from the book's metadata,
    -- shown inside the hint-count menu line: '12 hints found in this Canadian English
    -- book'. Keep it short; it must read naturally inside that sentence.
    ["en-ca"] = _("Canadian English"),
    -- TRANSLATORS: Name of the English variant detected from the book's metadata,
    -- shown inside the hint-count menu line: '12 hints found in this Australian
    -- English book'. Keep it short; it must read naturally inside that sentence.
    ["en-au"] = _("Australian English"),
    -- TRANSLATORS: Name of the English variant detected from the book's metadata,
    -- shown inside the hint-count menu line: '12 hints found in this New Zealand
    -- English book'. Keep it short; it must read naturally inside that sentence.
    ["en-nz"] = _("New Zealand English"),
    -- TRANSLATORS: Name of the English variant detected from the book's metadata,
    -- shown inside the hint-count menu line: '12 hints found in this Irish English
    -- book'. Keep it short; it must read naturally inside that sentence.
    ["en-ie"] = _("Irish English"),
    -- TRANSLATORS: Name of the English variant detected from the book's metadata,
    -- shown inside the hint-count menu line: '12 hints found in this South African
    -- English book'. Keep it short; it must read naturally inside that sentence.
    ["en-za"] = _("South African English"),
    -- TRANSLATORS: Name of the English variant detected from the book's metadata,
    -- shown inside the hint-count menu line: '12 hints found in this Indian English
    -- book'. Keep it short; it must read naturally inside that sentence.
    ["en-in"] = _("Indian English"),
}

local function _lang_label(doc)
    local lang = _get_book_lang(doc):match("^(en%-%a%a)")
    return lang and _LANG_LABELS[lang]
end

-- Apply current settings to a raw match list (no findAllText needed).
-- Returns a new filtered+adjusted list. Safe to call multiple times.
local function _apply_settings_to_matches(matches, distinguish_pounds, use_uk_volumes)
    local result = {}
    for _, r in ipairs(matches) do
        local keep = true

        -- UK volume recalculation: if unit+num+factor stored, recompute with UK factor
        if use_uk_volumes and r._unit and r._num and r._factor then
            local uk = _UNIT_CONV_UK[r._unit]
            if uk then
                local disp = _display(r.matched_text)
                local val  = r._num * uk.factor + uk.offset
                r._converted = string.format("%s = %s %s", disp,
                                              _fmt(_smart_round(val, r._num, false, uk.target)), uk.target)
            end
        end

        -- Pounds classifier: suppress when currency context clearly wins.
        -- Only the spelled-out "pound(s)" is ambiguous with £ sterling — the
        -- "lbs"/"lb" abbreviation is unambiguously weight (currency is never
        -- abbreviated "lbs"), so it must never be suppressed by money context
        -- (e.g. "one hundred lbs ... a month's wages" is still a weight).
        if distinguish_pounds and r._cat == "weight" then
            local mt = (r.matched_text or ""):lower()
            if mt:find("pound") then
                local window = ((r.prev_text or "") .. " " .. (r.next_text or "")):lower()
                if _pound_currency_wins(window, r._num,
                                        FootFree._pound_rate_tail(r.next_text)) then
                    keep = false
                end
            end
        end

        if keep then table.insert(result, r) end
    end
    return result
end

-- ── Unit conversion table ────────────────────────────────────────────────────
-- Unit string → conversion data ({factor, offset, target, cat} or {converter,…}).
-- The fast scan looks units up here after anchoring on the unit word.
local _UNIT_CONV = {
    ["feet"]              = { factor=0.3048,   offset=0,       target="m",    cat="length"      },
    ["foot"]              = { factor=0.3048,   offset=0,       target="m",    cat="length"      },
    ["ft"]                = { factor=0.3048,   offset=0,       target="m",    cat="length"      },
    ["inches"]            = { factor=2.54,     offset=0,       target="cm",   cat="length"      },
    ["inch"]              = { factor=2.54,     offset=0,       target="cm",   cat="length"      },
    ["miles"]             = { factor=1.60934,  offset=0,       target="km",   cat="length"      },
    ["mile"]              = { factor=1.60934,  offset=0,       target="km",   cat="length"      },
    ["mi"]                = { factor=1.60934,  offset=0,       target="km",   cat="length"      },
    ["nautical miles"]    = { factor=1.852,    offset=0,       target="km",   cat="length"      },
    ["nautical mile"]     = { factor=1.852,    offset=0,       target="km",   cat="length"      },
    ["nmi"]               = { factor=1.852,    offset=0,       target="km",   cat="length"      },
    ["yards"]             = { factor=0.9144,   offset=0,       target="m",    cat="length"      },
    ["yard"]              = { factor=0.9144,   offset=0,       target="m",    cat="length"      },
    ["yds"]               = { factor=0.9144,   offset=0,       target="m",    cat="length"      },
    ["yd"]                = { factor=0.9144,   offset=0,       target="m",    cat="length"      },
    ["fathoms"]           = { factor=1.8288,   offset=0,       target="m",    cat="length"      },
    ["fathom"]            = { factor=1.8288,   offset=0,       target="m",    cat="length"      },
    ["furlongs"]          = { factor=201.168,  offset=0,       target="m",    cat="length"      },
    ["furlong"]           = { factor=201.168,  offset=0,       target="m",    cat="length"      },
    -- Land league = 3 statute miles (4.828 km). Common in 19th-c. prose
    -- (Frankenstein, Verne). The nautical league (5.556 km) is rarer; land is
    -- the safe default for general fiction.
    ["leagues"]           = { factor=4.82803,  offset=0,       target="km",   cat="length"      },
    ["league"]            = { factor=4.82803,  offset=0,       target="km",   cat="length"      },
    -- Ancient/biblical length: 1 cubit = 18 in = 45.72 cm. Appears in scripture,
    -- historical and fantasy prose ("three hundred cubits").
    ["cubits"]            = { factor=0.4572,   offset=0,       target="m",    cat="length"      },
    ["cubit"]             = { factor=0.4572,   offset=0,       target="m",    cat="length"      },
    ["pounds"]            = { factor=0.453592, offset=0,       target="kg",   cat="weight"      },
    ["pound"]             = { factor=0.453592, offset=0,       target="kg",   cat="weight"      },
    ["lbs"]               = { factor=0.453592, offset=0,       target="kg",   cat="weight"      },
    ["lb"]                = { factor=0.453592, offset=0,       target="kg",   cat="weight"      },
    ["ounces"]            = { factor=28.3495,  offset=0,       target="g",    cat="weight"      },
    ["ounce"]             = { factor=28.3495,  offset=0,       target="g",    cat="weight"      },
    ["oz"]                = { factor=28.3495,  offset=0,       target="g",    cat="weight"      },
    ["stone"]             = { factor=6.35029,  offset=0,       target="kg",   cat="weight"      },
    ["°F"]                = { factor=5/9,      offset=-32*5/9, target="°C",   cat="temperature" },
    ["degrees Fahrenheit"]= { factor=5/9,      offset=-32*5/9, target="°C",   cat="temperature" },
    ["degrees F"]         = { factor=5/9,      offset=-32*5/9, target="°C",   cat="temperature" },
    -- Bare "degrees" (no F/Fahrenheit qualifier): ambiguous unit, gated by
    -- _degrees_temperature_cue at scan-finish (bare_degrees marks it so the
    -- gate can tell it apart from the unambiguous "degrees F"/"Fahrenheit"
    -- entries above, which never need the cue check).
    ["degrees"]            = { factor=5/9,      offset=-32*5/9, target="°C",   cat="temperature", bare_degrees=true },
    ["gallons"]           = { factor=3.78541,  offset=0,       target="liters",    cat="volume"      },
    ["gallon"]            = { factor=3.78541,  offset=0,       target="liters",    cat="volume"      },
    ["gal"]               = { factor=3.78541,  offset=0,       target="liters",    cat="volume"      },
    ["pints"]             = { factor=0.473176, offset=0,       target="liters",    cat="volume"      },
    ["pint"]              = { factor=0.473176, offset=0,       target="liters",    cat="volume"      },
    ["pt"]                = { factor=0.473176, offset=0,       target="liters",    cat="volume"      },
    ["quarts"]            = { factor=0.946353, offset=0,       target="liters",    cat="volume"      },
    ["quart"]             = { factor=0.946353, offset=0,       target="liters",    cat="volume"      },
    ["qt"]                = { factor=0.946353, offset=0,       target="liters",    cat="volume"      },
    ["fluid ounces"]      = { factor=29.5735,  offset=0,       target="mL",   cat="volume"      },
    ["fluid ounce"]       = { factor=29.5735,  offset=0,       target="mL",   cat="volume"      },
    ["fl oz"]             = { factor=29.5735,  offset=0,       target="mL",   cat="volume"      },
    ["mph"]               = { factor=1.60934,  offset=0,       target="km/h", cat="speed"       },
    ["miles per hour"]    = { factor=1.60934,  offset=0,       target="km/h", cat="speed"       },
    ["miles an hour"]     = { factor=1.60934,  offset=0,       target="km/h", cat="speed"       },
    ["knots"]             = { factor=1.852,    offset=0,       target="km/h", cat="speed"       },
    ["knot"]              = { factor=1.852,    offset=0,       target="km/h", cat="speed"       },
    ["kn"]                = { factor=1.852,    offset=0,       target="km/h", cat="speed"       },
    ["acres"]             = { converter=_conv_acres_to_ha,     target="ha",   cat="area"        },
    ["acre"]              = { converter=_conv_acres_to_ha,     target="ha",   cat="area"        },
}

-- Longest-first so "miles per hour" matches before "miles", etc.
local _UNIT_SUFFIXES = {
    "degrees Fahrenheit", "degrees F", "degrees",
    "nautical miles", "nautical mile",
    "fluid ounces", "fluid ounce",
    "miles per hour", "miles an hour",
    "fl oz", "fathoms", "fathom", "furlongs", "furlong",
    "leagues", "league",
    "gallons", "gallon", "quarts", "quart",
    "cubits", "cubit",
    "knots", "knot", "pounds", "pound",
    "ounces", "ounce", "pints", "pint",
    "acres", "acre", "stone", "yards", "yard",
    "miles", "mile", "feet", "foot", "inches", "inch",
    "yds", "yd", "lbs", "lb", "nmi", "gal",
    "mph", "kn", "ft", "mi", "oz", "pt", "qt", "°F",
}

local function _identify_unit(text, list)
    local s = text:lower()
    -- Active direction picks the suffix set: imperial preference scans
    -- METRIC units (tests pass `list` explicitly).
    list = list or (FootFree._IMPERIAL.preferred() ~= "metric"
                    and FootFree._IMPERIAL.suffixes or _UNIT_SUFFIXES)
    for _, u in ipairs(list) do
        if s:sub(-#u) == u:lower() then return u end
    end
end

-- Extract measurement number from the tail of prev_text.
-- Tries the last 1-4 words as a phrase to handle "three hundred", "a dozen", etc.
local function _parse_prev_num(prev)
    if not prev or prev == "" then return nil end
    local s = prev:lower():gsub("%-+%s*$", ""):match("^(.-)%s*$") or ""
    if s == "" then return nil end
    local words = {}
    for w in s:gmatch("%S+") do table.insert(words, w) end
    if #words == 0 then return nil end
    for i = #words, math.max(1, #words - 3), -1 do
        local n = _parse_num(table.concat(words, " ", i))
        if n then return n end
    end
    return nil
end

-- Range converter: identifies unit from matched_text tail, splits on and/or/to.
local function _range_conv_unit(text)
    local unit = _identify_unit(text)
    local conv_tbl = FootFree._IMPERIAL.preferred() ~= "metric"
        and FootFree._IMPERIAL.conv or _UNIT_CONV
    local info = unit and conv_tbl[unit]
    if not info or not info.factor then return nil end
    local s = _display(text):lower()
    -- En/em dashes and a comma+space are range separators too ("five–six miles",
    -- "seven, eight feet"); see _detect_back_range. They're displayed as " to "
    -- (matching the word-range output) rather than echoed back verbatim.
    for _, sep in ipairs({" and ", " or ", " to ", _ENDASH, _EMDASH, ", "}) do
        local p = s:find(sep, 1, true)
        if p then
            local n1 = _parse_num(s:sub(1, p - 1))
            local n2 = _parse_num(s:sub(p + #sep))
            if n1 and n2 then
                -- "four and a half feet" — separator is "and", second number is a
                -- fraction (0 < n2 < 1): treat as addition, not a range.
                -- "four and five feet" still has n2 ≥ 1 → handled as range below.
                if sep == " and " and n1 >= 1 and n2 > 0 and n2 < 1 then
                    local total  = n1 + n2
                    local result = total * info.factor + info.offset
                    return _fmt_dist(_smart_round(result, total, false, info.target), info.target)
                end
                -- Compound number addition: "a hundred and fifty" = 150.
                -- When n1 is a round hundred/thousand and n2 < n1, it's addition.
                if sep == " and " and n2 > 0 and n2 < n1 then
                    if (n1 >= 100 and n1 % 100 == 0) or (n1 >= 1000 and n1 % 1000 == 0) then
                        local total = n1 + n2
                        local result = total * info.factor + info.offset
                        return _fmt_dist(_smart_round(result, total, false, info.target), info.target)
                    end
                end
                -- Shared-scale correction: "two or three hundred yards" means
                -- 200–300 not 2–300. When n1 is a small integer and n2 is a
                -- round hundred/thousand whose leading digit exceeds n1, scale up.
                if n1 >= 1 and n1 < 10 then
                    if n2 >= 1000 and n2 % 1000 == 0 and n1 < math.floor(n2/1000) then
                        n1 = n1 * 1000
                    elseif n2 >= 100 and n2 % 100 == 0 and n1 < math.floor(n2/100) then
                        n1 = n1 * 100
                    end
                end
                local r1 = n1 * info.factor + info.offset
                local r2 = n2 * info.factor + info.offset
                if r1 > r2 then r1, r2 = r2, r1 end
                local out_conn = (sep == _ENDASH or sep == _EMDASH or sep == ", ") and " to " or sep
                return _fmt_dist_range(_smart_round(r1, nil, true, info.target),
                                        _smart_round(r2, nil, true, info.target), info.target, out_conn)
            end
        end
    end
    return nil
end

-- ~24 patterns. Compound entries first (win start-position dedup).
-- broad=true / range_broad=true: unit identified from matched_text at scan time.
-- kw = plain strings: ANY must appear in book text or pattern is skipped.
-- kw_pat = Lua pattern: checked in addition to kw (OR logic).
-- Safety guarantee: if a keyword is absent, the pattern CANNOT match.
-- "five-hundred-and-eleven-foot" → 511 feet → metric.
-- Defined here (after _UNIT_CONV) so the table lookup is in scope.
local function _conv_hundred_and(text)
    local s = _display(text):lower()
    local h_word, rem_and_unit = s:match("^(%a+)%-hundred%-and%-(.+)$")
    if not h_word or not rem_and_unit then return nil end
    local hundreds = _parse_num(h_word)
    if not hundreds then return nil end
    local rem_part, unit_word = rem_and_unit:match("^(.-)%-(%a+)$")
    if not rem_part or not unit_word then return nil end
    local remainder = _parse_num(rem_part)
    if not remainder then return nil end
    local total = hundreds * 100 + remainder
    local info = (FootFree._IMPERIAL.preferred() ~= "metric"
                  and FootFree._IMPERIAL.conv or _UNIT_CONV)[unit_word]
    if not info or not info.factor then return nil end
    local result = total * info.factor + (info.offset or 0)
    return _fmt_dist(_smart_round(result, total, false, info.target), info.target)
end

-- ── Scan ──────────────────────────────────────────────────────────────────────
-- The scan does ONE PLAIN findAllText per unit alias, then classifies each hit
-- in Lua from the number that precedes it. Compounds (feet+inches,
-- pounds+ounces, "6 foot 4", "nine stone four"), ranges, fractions, and prime/°F
-- notation are all handled (the last two via dedicated literal passes below).
-- Aliases come from the FULL unit list, searched longest-first so a longer alias
-- claims a position before a shorter one can ("nautical mile" before "mile").
-- The pass loop and the measurements that chose it are at the top of
-- _fast_scan_matches. "°F" is handled separately (a word boundary around "°F"
-- doesn't behave); bare "in" is intentionally not in _UNIT_SUFFIXES — too easily
-- the English preposition.
--
-- HISTORY, because the removed code keeps getting reinvented: this was a single
-- 54-branch regex alternation until 2026-08-17, on the stated grounds that "the
-- cost is the per-call document walk, not the matching". Measurement says the
-- opposite — the walk is ~0.03s and the alternation was ~4.8s of a 5s scan. The
-- alternation carried a `(?:\b|(?<=[0-9]))` left anchor, because regex \b never
-- fires between a digit and a letter and fused forms ("260lbs", "6ft") produced
-- no hit at all; that anchor alone cost 2.34s of the 4.82s. Plain search needs
-- no anchor — the boundary is enforced by reading the adjacent characters
-- instead (shy_boundary_ok), which is both cheaper and, unlike \b, able to see
-- a soft hyphen sitting where a letter would be.
--
-- One thing from that design still stands and must not be re-litigated: "m" and
-- "g" cannot ride in a shared alternation at all —
--   * a plain \b anchor lets "I'm" hit "m" via the apostrophe boundary,
--     blowing the 2000-hit budget on every novel;
--   * a branch-leading lookbehind ((?<=[0-9])[ ]?m) makes crengine return a
--     CORRUPT START for its first match (smoketest6 caught a "match" running
--     from a chapter heading to the first "1.8m");
--   * a branch-leading digit class ([0-9][0-9.,]*[ ]?m) comes back with the
--     start off by a character ("1.8m" reported as "8m", "500g" as "00g"),
--     which the glued-number fallback then "fixes" into a truncated value
--     (1.8 m read as 1 m, 500 g as 5 g).
-- Nor can they ride a PLAIN pass, which would match every letter m in the book.
-- They run as dedicated number-anchored literal passes instead (unit_pats
-- below) — the standalone digit-leading shape is the proven _TEMP_PATS one.

-- Single-letter metric aliases as literal passes (see above). The number is
-- part of the match, so the value comes from _parse_num(matched_text) like
-- the °F/°C passes. "m" takes an optional space ("1.8 m", "180m"); "g" only
-- glued tight ("500g" — a spaced "5 g" is usually g-force, deliberately not
-- matched). money=true arms the run_passes currency veto ("$50 m" = fifty
-- million dollars; the symbol can share the word with the digits, so the
-- veto raw-reads the characters just before the hit).
FootFree._IMPERIAL.unit_pats = {
    pre = "\\b[0-9][0-9.,]*",
    { suf = "[ ]?m\\b", cat = "length",
      factor = 3.28084, offset = 0, target = "ftin", money = true },
    { suf = "g\\b", cat = "weight",
      factor = 0.0352740, offset = 0, target = "oz", money = true },
    -- One alternation, one walk (see _PRIME_PATS). The trailing letter is the
    -- whole distinction here.
    classify = function(s)
        if s:sub(-1) == "m" then return 1 end
        if s:sub(-1) == "g" then return 2 end
        return nil
    end,
}

-- Is this token part of a number phrase? (digit, number-word, or connector word
-- like "a"/"and" that glue multi-word numbers such as "a hundred and fifty").
local _NUM_CONNECTOR = { a = true, an = true, ["and"] = true, half = true, quarter = true }
local function _is_number_word(w)
    w = w:lower():gsub("[%.,;:%)]+$", ""):gsub("^[%(]+", "")
    if w == "" then return false end
    if w:match("%d") then return true end
    if _NUM_CONNECTOR[w] then return true end
    return _parse_num(w) ~= nil
end

-- A match's prev_text is the context before the UNIT, so it ends with the
-- measurement's own number ("…his own two" for "two feet"). To test the word
-- BEFORE the number — for idioms like "own two feet" / "with one foot" — strip
-- the trailing number word(s) first, then return the last remaining word.
local function _word_before_number(prev)
    local p = (prev or ""):gsub("%s+$", "")
    while true do
        local w = p:match("([%w]+)%s*$")
        if w and _is_number_word(w) then
            p = p:gsub("[%w]+%s*$", ""):gsub("%s+$", "")
        else
            break
        end
    end
    return p:match("([%a]+)%s*$")
end

-- The number phrase immediately before the unit, and how many words it spans.
-- Walks back ONLY over consecutive number words, so "stood 5 feet 3" yields just
-- "3" (1 word) — not "5 feet 3" — and "a hundred" yields 2 words.
local function _prev_num_words(prev)
    if not prev or prev == "" then return nil end
    local s = prev:gsub("[%-%s]+$", ""):match("^(.-)%s*$") or ""
    -- Spaced U+2044 fraction slash ("2 1 ⁄ 2 -inch plank", Sailor's Word-Book):
    -- collapse "N ⁄ M" to "N⁄M" so the word-walk below doesn't stall on the
    -- bare "⁄" token (it's not a number word). Digit-bounded, so ordinary
    -- prose is untouched; _parse_num accepts the spaced form directly.
    s = s:gsub("(%d)%s*\226\129\132%s*(%d)", "%1\226\129\132%2")
    -- An em-dash or ellipsis glued to the number ("too far—eleven feet",
    -- "off course by…sixty miles", "park—four acres") fuses it into one
    -- non-number token and the walk bails. Both glyphs are pure separators
    -- here — neither joins compound numbers, and _detect_back_range matches
    -- its em-dash range connector on the RAW prev before this ever runs.
    -- (The en-dash is left alone: it IS a range connector glyph.)
    s = s:gsub("\226\128\148", " "):gsub("\226\128\166", " "):gsub("%s+$", "")
    -- Fractional "<frac> of a/an [unit]" form ("two thirds of a mile"): the
    -- word-walk below can't cross "of", so handle it up front. The fraction is
    -- the word(s) just before "of a/an"; _parse_num knows these (e.g. prefix
    -- "two thirds of a" = 2/3). Span includes the trailing "of a" (2 words).
    local before_of = s:match("^(.-)%s+of%s+an?$")
    if before_of and before_of ~= "" then
        -- Nested multiplicative fraction: "half a quarter of a mile" = ½ × ¼ = ⅛.
        -- The "<f1> a/an <f2>" shape means f1 OF a f2, so the values multiply
        -- (½ of ¼ mile, not ½ + ¼). Both parts must be sub-1 fractions.
        local f1w, f2w = before_of:match("([%w%-]+)%s+an?%s+([%w%-]+)%s*$")
        if f1w then
            local f1, f2 = _parse_num(f1w), _parse_num(f2w)
            if f1 and f2 and f1 > 0 and f1 < 1 and f2 > 0 and f2 < 1 then
                -- span covers "<f1> a <f2> of a" = 5 words.
                return f1 * f2, 5
            end
        end
        local fwords = {}
        for w in before_of:gmatch("%S+") do fwords[#fwords + 1] = w end
        for span = math.min(3, #fwords), 1, -1 do
            local n = _parse_num(table.concat(fwords, " ", #fwords - span + 1))
            if n and n < 1 then return n, span + 2 end
        end
    end
    -- Additive "N and a/<frac> [unit]" form ("four and a half feet",
    -- "one and three-quarter leagues"): value = whole N + fraction. The fraction
    -- must sit at the END of prev (adjacent to the unit) and be only 1–2 words —
    -- otherwise a distant "…seven and a half yards … thirty-five" would wrongly
    -- bind "thirty-five" to that far-off fraction. Greedy `(.*)` takes the "and"
    -- closest to the unit. Returned with a third result `true` so the caller pins
    -- the conversion (matched_text's own _parse_num would prefix-match just N).
    local pre, frac_part = s:match("^(.*)%s+and%s+(.+)$")
    if pre and frac_part then
        local fw = 0
        for _ in frac_part:gmatch("%S+") do fw = fw + 1 end
        local int_part = pre:match("([%w%-]+)%s*$")
        if int_part and fw <= 2 then
            local iv, fv = _parse_num(int_part), _parse_num(frac_part)
            if iv and fv and iv >= 1 and iv == math.floor(iv) and fv > 0 and fv < 1 then
                return iv + fv, 2 + fw, true   -- span: <int> and <frac words>
            end
        end
    end
    -- Leading-article fraction adjacent to the unit ("half a foot", "half an
    -- inch", "a quarter mile"): the trailing article ("a"/"an") breaks the
    -- number-word walk below, which needs the LAST word to be a number word, so
    -- it would bail. Parse the 2-word tail directly. Only a genuine sub-1
    -- fraction counts (½, ¼, ⅓), so the bare "a foot"/"an inch" idiom (value 1)
    -- is untouched, and "two and a half feet" still takes the additive path
    -- above first. This is what lets foot/inch (absent from _ART_DIST_UNITS)
    -- convert "half a foot" = ~15 cm, matching the "six inches" it equals.
    local frac2 = s:match("([%a]+%s+[%a]+)%s*$")
    if frac2 then
        -- Both words must carry the fraction ("half a", "half an", "a
        -- quarter") — _parse_num prefix-reads, so "half long" (from "a mile
        -- and a half LONG and 1000 ft") would otherwise return 0.5 here and
        -- spawn a bogus 0.5–1000 back-range that eats the "1000 ft" match.
        local w2 = frac2:match("%s(%a+)$"):lower()
        local w2v = _parse_num(w2)
        if w2 == "a" or w2 == "an" or (w2v and w2v > 0 and w2v < 1) then
            local fv = _parse_num(frac2)
            if fv and fv > 0 and fv < 1 then return fv, 2 end
        end
    end
    local words = {}
    for w in s:gmatch("%S+") do words[#words + 1] = w end
    if #words == 0 or not _is_number_word(words[#words]) then return nil end
    local first = #words
    -- Stop at a comma-terminated word: it belongs to a previous measurement, not
    -- this one ("five feet nine, two hundred thirty pounds" — the weight's number
    -- is "two hundred thirty", not "nine, two hundred thirty"). The window is
    -- wide enough for a long spelled compound ("seven thousand five hundred and
    -- twenty-four" = 6 words); the comma guard still bounds runaway reads.
    while first > 1 and (#words - first) < 7 and _is_number_word(words[first - 1])
          and not words[first - 1]:find(",", 1, true) do
        first = first - 1
    end
    -- A clause-joining "and" must not START the span: "…feet long and four
    -- hundred and fifty feet" — the leading "and" connects two measurements, it
    -- is not part of this number. (Internal "and", as in "four hundred AND
    -- fifty", is kept — the walk merely stopped here, it didn't start here.)
    while first < #words and words[first]:lower() == "and" do
        first = first + 1
    end
    -- "a hundred" / "a thousand" / "a dozen": the article scales the following
    -- multiplier but isn't a number word on its own, so the walk above stops at
    -- "hundred". Pull "a"/"an" into the span when it forms a known "a <mult>"
    -- number (value is unchanged — "a hundred" == "hundred" == 100 — so this
    -- only widens the match to cover the article, no false positives).
    if first > 1 then
        local art = words[first - 1]:lower()
        if (art == "a" or art == "an")
           and _parse_num(art .. " " .. table.concat(words, " ", first)) then
            first = first - 1
        end
    end
    -- A digit mixed fraction ("2 1⁄2" / "2 1/2") is ONE number, not two
    -- adjacent numbers — the spelled composer below can't fold digit tokens,
    -- so the uncombinable-numbers advance would wrongly strand just the
    -- fraction ("1⁄2" → 1). Parse it whole and return early.
    do
        local wt = table.concat(words, " ", first)
        if wt:match("^%d+%s+%d+\226\129\132%d+$") or wt:match("^%d+%s+%d+/%d+$") then
            local nf = _parse_num(wt)
            if nf then return nf, #words - first + 1 end
        end
    end
    -- Two adjacent but uncombinable numbers ("one fifteen feet" — "one [shark],
    -- fifteen feet") leave a leading number the composer can't fold in. Keep the
    -- UNIT-ADJACENT (rightmost) number: advance until the span composes whole.
    while first < #words do
        local _, _, _, used = _compose_spelled(table.concat(words, " ", first))
        if used and used >= (#words - first + 1) then break end
        first = first + 1
    end
    -- A spelled "minus" immediately before the number phrase negates it
    -- ("minus seventy degrees" = -70), the word form of the ASCII/Unicode
    -- dash signs _parse_num already honors before bare digits.
    local n = _parse_num(table.concat(words, " ", first))
    if n then
        if first > 1 and words[first - 1]:lower() == "minus" then
            return -n, #words - first + 2
        end
        return n, #words - first + 1
    end
    n = _parse_num(words[#words])
    if n then
        if #words > 1 and words[#words - 1]:lower() == "minus" then
            return -n, 2
        end
        return n, 1
    end
    return nil
end

-- Parse a leading "<number> [inches|ounces]" or bare "<number>" from next_text
-- (the tail of a compound). Returns (value, "inch"|"oz"|"bare") or nil.
local function _lead_compound(next_text)
    -- A sentence boundary is NOT a compound separator. "Ten feet. Five." is a
    -- countdown, not "ten feet five inches" — reading the next number as inches
    -- produced "3.17 m". A period followed by whitespace + a capital letter is a
    -- new sentence; an abbreviation dot ("5 ft. 4 in") is followed by a digit,
    -- so it is still read as a compound.
    if (next_text or ""):match("^%s*%.%s+%u") then return nil end
    -- Strip leading spaces/commas/hyphens AND a stray period (from an abbreviated
    -- "ft." before the inches number), so the second number is found.
    local s = (next_text or ""):gsub("^[%s,%.%-]+", "")
    local tok = s:match("^([%w][%w%.,]*)")
    if not tok then return nil end
    local n = _parse_num((tok:gsub("[%.,]+$", "")))
    if not n then return nil end
    local rest = s:sub(#tok + 1):gsub("^[%s%-]+", "")
    -- A spelled-out "inch(es)"/"ounce(s)" marks a compound tail handled by the
    -- backward merge. The bare "in"/"in." abbreviation is reported separately
    -- ("in_abbr") so the caller can accept it ONLY right after a feet/ft unit —
    -- the one context where "in" reliably means inches, not the preposition.
    if rest:match("^inch") then return n, "inch" end
    if rest:match("^ounce") then return n, "oz" end
    if rest:match("^in%f[%A]") or rest == "in" then
        -- "clear" = "in" is the final token ("in." / "in," / "in"<end>), so it's
        -- safe to draw under the highlight. "in <word>" (a preposition like "in
        -- his socks") still counts as inches but its "in" is NOT highlighted.
        local clear = rest:match("^in[%.,]") ~= nil or rest:match("^in%s*$") ~= nil
        return n, "in_abbr", clear
    end
    return n, "bare"
end

-- Words a number immediately after "or"/"to" belongs to — so it is NOT a second
-- inches value. "five foot four or five minutes" must stay a single height, not
-- become a 5'4"–5'5" range. Length units (feet/miles/yards/pounds) are included
-- because "or six feet" is a separate measurement; "inch(es)" is deliberately
-- absent ("five foot five or six inches" reinforces the height reading).
local _RANGE_TAIL_NOUNS = {
    minute=true, minutes=true, second=true, seconds=true, hour=true, hours=true,
    day=true, days=true, week=true, weeks=true, month=true, months=true,
    year=true, years=true, time=true, times=true, people=true, men=true,
    women=true, mile=true, miles=true, foot=true, feet=true, yard=true,
    yards=true, pound=true, pounds=true, ["o'clock"]=true, percent=true,
    dozen=true, hundred=true, thousand=true, million=true,
}

-- After a feet+inches compound ("five foot five"), detect an "or/to K" tail that
-- is a second inches value → a height RANGE ("five foot five or six" = 5'5"–5'6").
-- `first_inch` is the already-parsed inches number; `next_text` is the text after
-- the foot unit. Returns (K, connector) — K an integer 1..11, connector "or"/"to"
-- — or nil. Guarded against a trailing noun the number really belongs to.
local function _inch_range_tail(next_text, first_inch)
    if not next_text or not first_inch then return nil end
    if next_text:match("^%s*%.%s+%u") then return nil end  -- new sentence, not a range tail
    local s = next_text:gsub("^[%s,%.%-]+", "")
    local tok = s:match("^([%w][%w%.,]*)")           -- the first inch token
    if not tok then return nil end
    local rest = s:sub(#tok + 1):gsub("^[%s%-]+", "")
    local conn, after = rest:match("^(%a+)%s+(.+)$")  -- connector + remainder
    if conn ~= "or" and conn ~= "to" then return nil end
    local ktok = after:match("^([%w][%w%-]*)")
    if not ktok then return nil end
    local k = _parse_num((ktok:gsub("[%.,]+$", "")))
    if not k or k ~= math.floor(k) or k < 1 or k > 11 then return nil end
    local nextword = after:sub(#ktok + 1):gsub("^[%s%-]+", ""):match("^([%a']+)")
    if nextword and _RANGE_TAIL_NOUNS[nextword:lower()] then return nil end
    return k, conn
end

-- Forward "or/to M" range tail with NO repeated unit: "a mile or two",
-- "one mile or two". The second operand must be a bare number NOT followed by a
-- unit/noun it belongs to (so "three miles, or four miles" stays two separate
-- matches, and "a mile or so" — _parse_num fails on "so" — is left as a single).
-- Returns (M, connector "or"/"to") or nil.
local function _distance_or_tail(next_text)
    if not next_text then return nil end
    if next_text:match("^%s*%.%s+%u") then return nil end   -- new sentence
    local s = next_text:gsub("^[%s,%.]+", "")
    local conn, mtok = s:match("^(%a+)%s+([%w][%w%-]*)")
    if conn ~= "or" and conn ~= "to" then return nil end
    -- A thousands-separated continuation ("…miles, or 5,250 French leagues") is a
    -- restatement in another unit, NOT an "or two"-style range endpoint. The comma
    -- truncates mtok to "5", so detect the ",<digit>" right after it and bail.
    if s:match("^%a+%s+[%w][%w%-]*,%d") then return nil end
    local m = _parse_num((mtok:gsub("[%.,]+$", "")))
    if not m then return nil end
    local after = s:gsub("^%a+%s+[%w%-]+", "", 1):gsub("^[%s%-]+", "")
    local nextword = after:match("^([%a']+)")
    if nextword and _RANGE_TAIL_NOUNS[nextword:lower()] then return nil end
    return m, conn
end

-- Forward "by M" dimension tail: "twenty feet by ten" → a 20×10 two-axis
-- measurement in the SAME unit (the second number is bare). Rejected when the
-- second number carries an inch/foot/yard unit of its own ("feet by ten inches"
-- is the feet-by-inches path) or a noun it belongs to. Returns (M, phrase) or nil.
local function _dim_by_tail(next_text)
    if not next_text then return nil end
    local s = next_text:lower():gsub("^[%s,]+", "")
    local mtok = s:match("^by%s+([%w%-]+)")
    if not mtok then return nil end
    local m = _parse_num((mtok:gsub("[%.,]+$", "")))
    if not m then return nil end
    local after = s:gsub("^by%s+[%w%-]+", "", 1):gsub("^[%s%-]+", "")
    local nextword = after:match("^([%a']+)")
    local unit_after = {
        inch=true, inches=true, foot=true, feet=true, ft=true,
        yard=true, yards=true, yd=true, yds=true,
    }
    if nextword and (unit_after[nextword] or _RANGE_TAIL_NOUNS[nextword]) then return nil end
    return m, "by " .. mtok
end

-- Build a "phrase = converted" string for a known numeric value `val`. Used
-- when matched_text's own _parse_num would disagree (e.g. additive "four and a
-- half" prefix-parses as just 4), so the cached _converted carries the right value.
local function _value_converted(disp, val, conv, unit)
    local rstr
    if conv.converter then
        rstr = conv.converter(_fmt(val) .. " " .. unit)
    elseif conv.factor then
        rstr = _fmt_dist(_smart_round(val * conv.factor + (conv.offset or 0), val, false, conv.target), conv.target)
    end
    return rstr and (disp .. " = " .. rstr) or nil
end

-- Post-unit fractional tail: "two miles and a half" → +0.5, "ten feet and a
-- quarter" → +0.25, "... and three quarters" → +0.75. This is the variant where
-- the fraction trails the unit; the pre-unit additive form ("four and a half
-- feet") is handled on the back side in _prev_num_words. Hyphens are normalised
-- to spaces so "and three-quarters" matches. Returns (fraction, phrase) or nil;
-- `phrase` is the space-normalised tail used to walk the match end forward.
local _FRAC_TAILS = {
    ["and a half"] = 0.5,
    ["and one half"] = 0.5,
    ["and a quarter"] = 0.25,
    ["and one quarter"] = 0.25,
    ["and three quarters"] = 0.75,
    ["and a third"] = 1/3,
    ["and two thirds"] = 2/3,
}
local function _frac_tail(next_text)
    if not next_text then return nil end
    local s = next_text:lower():gsub("%-", " "):gsub("^[%s,]+", "")
    for phrase, frac in pairs(_FRAC_TAILS) do
        if s:sub(1, #phrase) == phrase then
            -- Require a word boundary after the phrase so "and a halfpenny" or
            -- "and a quartermaster" don't read as a fraction.
            local after = s:sub(#phrase + 1, #phrase + 1)
            if after == "" or not after:match("%a") then
                return frac, phrase
            end
        end
    end
    -- Dynamic "and <numerator> <denominator>" tail not in the table above
    -- ("and three tenths" = 0.3, "and five eighths" = 0.625).
    local nw, dw = s:match("^and%s+(%a+)%s+(%a+)")
    if nw and dw then
        local v = _word_fraction(nw .. " " .. dw)
        if v then return v, "and " .. nw .. " " .. dw end
    end
    return nil
end

-- ── Area ("square <unit>") ────────────────────────────────────────────────────
-- "two or three square miles" reads as miles (length) without this — the cue
-- word "square" between number and unit flips it to an area. Factors are the
-- imperial area units in square metres.
local _AREA_CONV = {
    mile = 2589988.11, miles = 2589988.11,
    yard = 0.83612736, yards = 0.83612736,
    foot = 0.09290304, feet  = 0.09290304,
    inch = 0.00064516, inches = 0.00064516,
    -- League already converts as a length (_UNIT_CONV, 4.82803 km); square of
    -- that same land-league factor (report #10: "twenty-three square leagues"
    -- was a straight miss — "square" ate the cue but no area factor existed,
    -- so the number-before-"square" word-walk had nothing to land on).
    league = 23309873.68, leagues = 23309873.68,
}

-- Format a square-metre value with an auto-picked unit (km² / m² / cm²) and a
-- ~2-sig-fig "nice" rounding (areas are inherently approximate).
local function _fmt_area_one(m2)
    if m2 >= 1e6 then
        return _fmt(_nice_round(m2 / 1e6, _HARSH_TOLERANCE)) .. " km²"
    elseif m2 >= 1 then
        return _fmt(_nice_round(m2, _HARSH_TOLERANCE)) .. " m²"
    else
        return _fmt(_nice_round(m2 * 1e4, _HARSH_TOLERANCE)) .. " cm²"
    end
end

-- Area string for a single value or a range. `conn` (e.g. " or ", " to ") is the
-- original connector so a range reads as prose. Both endpoints share the unit
-- chosen for the larger one.
local function _area_str(n1, n2, factor, conn)
    local a1 = n1 * factor
    if not n2 then return _fmt_area_one(a1) end
    local a2 = n2 * factor
    if a1 > a2 then a1, a2 = a2, a1 end
    -- Pick scale from the larger endpoint, scale both the same way.
    local div, suf
    if a2 >= 1e6 then div, suf = 1e6, " km²"
    elseif a2 >= 1 then div, suf = 1, " m²"
    else div, suf = 1 / 1e4, " cm²" end
    return _fmt(_nice_round(a1 / div, _HARSH_TOLERANCE))
        .. (conn or _ENDASH)
        .. _fmt(_nice_round(a2 / div, _HARSH_TOLERANCE)) .. suf
end

-- Range "N <conn> M [unit]" (unit appears once, e.g. "five to ten miles",
-- "1 to 30 miles", "twenty or thirty miles"): detect from the lowercased
-- prev_text. Returns (n1, n2, span-from-N-to-unit) or nil. "and" only ranges
-- when M >= 1 — "N and a half" is the additive form handled in _prev_num_words.
-- Multi-endpoint chain: "eight or ten to twelve and fifteen inches" — three or
-- more numbers strung together by range/additive connectors. The author's intent
-- is genuinely ambiguous, so we collapse to the OUTER endpoints (8–15) and let
-- _range_conv_unit render the span from the full matched text. Only fires for 3+
-- distinct numbers; a plain two-number range falls through to the pairwise logic
-- below. Returns (min, max, span) or nil. Additive compounds ("one hundred and
-- twelve") merge to a single value and so report <2 endpoints → nil.
local function _detect_chain_range(prev, unit)
    local s = (prev or ""):lower():gsub(_ENDASH, " to "):gsub(_EMDASH, " to ")
    if unit and unit ~= "" then
        local ue = unit:gsub("[%-%.%(%)%[%]%+%*%?%^%$%%]", "%%%0")
        s = s:gsub("%s+" .. ue .. "%s*$", " ")
    end
    local toks = {}
    for w in s:gmatch("[%w%-]+") do toks[#toks + 1] = w end
    if #toks < 5 then return nil end  -- need ≥3 numbers + ≥2 connectors
    local CONN = { to = true, ["or"] = true, ["and"] = true }
    -- Longest suffix run of number-words / connectors only.
    local lo = #toks + 1
    for i = #toks, 1, -1 do
        local w = toks[i]
        if _is_number_word(w) or CONN[w] then lo = i else break end
    end
    -- Trim leading/trailing connectors off the run.
    while lo <= #toks and CONN[toks[lo]] do lo = lo + 1 end
    local hi = #toks
    while hi >= lo and CONN[toks[hi]] do hi = hi - 1 end
    if hi - lo + 1 < 3 then return nil end
    -- Split the run into number segments on connector tokens; remember the
    -- connector that introduced each segment so additive "X hundred and Y" merges.
    local segs = {}
    local cur, pend = {}, nil
    for i = lo, hi do
        local w = toks[i]
        if CONN[w] then
            if #cur > 0 then
                segs[#segs + 1] = { v = _parse_num(table.concat(cur, " ")), conn = pend }
                cur = {}
            end
            pend = w
        else
            cur[#cur + 1] = w
        end
    end
    if #cur > 0 then segs[#segs + 1] = { v = _parse_num(table.concat(cur, " ")), conn = pend } end
    -- Merge additive "<round hundred/thousand> and <small>" pairs into one value.
    local vals = {}
    for _, seg in ipairs(segs) do
        if not seg.v then return nil end  -- a non-number snuck in → not a pure chain
        local prevv = vals[#vals]
        if seg.conn == "and" and prevv and prevv > 0 and seg.v < prevv
           and ((prevv >= 100 and prevv % 100 == 0) or (prevv >= 1000 and prevv % 1000 == 0)) then
            vals[#vals] = prevv + seg.v
        else
            vals[#vals + 1] = seg.v
        end
    end
    if #vals < 3 then return nil end
    local mn, mx = vals[1], vals[1]
    for _, v in ipairs(vals) do
        if v < mn then mn = v end
        if v > mx then mx = v end
    end
    if mn == mx then return nil end
    return mn, mx, 1
end

local function _detect_back_range(prev, unit)
    local cmn, cmx, csp = _detect_chain_range(prev, unit)
    if cmn then return cmn, cmx, csp end
    -- Word connectors, typographic range dashes (en/em), and a comma (the
    -- colloquial "seven, eight feet" = 7–8). A connector forms a range only
    -- between two numbers — the `n1 and n2` check below enforces that, so
    -- "five-foot" / "the giant, eight feet" can't become ranges. The ASCII hyphen
    -- is deliberately NOT a connector: it collides with spelled compound numbers
    -- ("twenty-five" → 20 and 5). The comma form requires a trailing SPACE (", ")
    -- so a thousands separator ("5,000 feet") isn't read as "5 to 000".
    for _, conn in ipairs({" to ", " or ", " and ", _ENDASH, _EMDASH, ", "}) do
        -- The second operand is the rest after the connector (not just one token)
        -- so a scaled endpoint like "three–four hundred" (→ "four hundred") is
        -- captured; _parse_num prefix-reads its leading number. _range_conv_unit
        -- re-parses matched_text and decides range vs additive ("a hundred and
        -- fifty") and applies the shared-scale fix ("two or three hundred").
        -- EXCEPTION: the comma is the colloquial "seven, eight feet" form, which
        -- takes a SINGLE second number — a multi-word second operand there would
        -- read a height+weight ("five feet nine, two hundred thirty pounds") as a
        -- 9–230 range instead of two separate measurements.
        local before, mtok
        if conn == ", " then
            before, mtok = prev:match("^(.-), ([%w%-][%w%-%.,°]*)%s*$")
            -- A foot/feet word right before the comma marks a feet+inches height
            -- ("five-foot, seven inches"), NOT a "5 to 7" range — leave it for the
            -- compound-tail merge so it reads 5'7" rather than a 5–7 inch range.
            if before and (before:match("foot$") or before:match("feet$")) then
                before = nil
            end
        else
            -- Greedy `(.+)` matches the connector CLOSEST to the unit (rightmost),
            -- so an earlier same-word connector elsewhere in the window doesn't
            -- swallow the real range: "…can live, twelve or fifteen miles" must
            -- read "twelve or fifteen", not the "or" back in "can live, or …".
            before, mtok = prev:match("^(.+)" .. conn .. "(%S.*)$")
        end
        if before and mtok then
            local n2 = _parse_num(mtok)
            local n1, n1span = _prev_num_words(before)
            local extra = 0
            -- "N unit <conn> M unit" form: N is followed by the unit word, so
            -- strip it before reading the first number ("5 miles to 10 miles").
            if not n1 and unit and unit ~= "" then
                local ue = unit:gsub("[%-%.%(%)%[%]%+%*%?%^%$%%]", "%%%0")
                local stripped = before:gsub("%s+" .. ue .. "%s*$", "")
                if stripped ~= before then
                    n1, n1span = _prev_num_words(stripped)
                    extra = 1
                end
            end
            -- The second operand must sit RIGHT BEFORE the unit: after its
            -- number words, only the unit (or nothing) may remain. Otherwise a
            -- number far from the unit forms a bogus range — "four or five
            -- laborers on the foot[-path]" prefix-read "five …" as the endpoint
            -- and attached it to a unit five words away. (Comma form already
            -- captures a single trailing token, so it's exempt.)
            -- Enumeration guard: "gave 95, 128, and 103 fathoms" — when the
            -- word right before the first endpoint is itself a comma-terminated
            -- NUMBER ("95,"), the connector joins items of a LIST, not the two
            -- ends of a range. Bail entirely: the normal single path then
            -- converts the unit-adjacent value ("103 fathoms"). Genuine ranges
            -- ("between fifty and a hundred", "…can live, twelve or fifteen
            -- miles") have a non-number word there and are unaffected.
            if n1 and conn ~= ", " then
                local src = (extra == 1)
                    and before:gsub("%s+" .. unit:gsub("[%-%.%(%)%[%]%+%*%?%^%$%%]", "%%%0") .. "%s*$", "")
                    or before
                local ws = {}
                for w in src:gmatch("%S+") do ws[#ws + 1] = w end
                local pw = ws[#ws - (n1span or 1)]
                if pw and pw:find(",$") and _is_number_word(pw) then
                    return nil
                end
            end
            if n1 and n2 and conn ~= ", " then
                local rest2 = mtok:lower()
                if unit and unit ~= "" then
                    rest2 = rest2:gsub(unit:gsub("[%-%.%(%)%[%]%+%*%?%^%$%%]", "%%%0"), " ")
                end
                for word in rest2:gmatch("%a+") do
                    -- "a"/"an" are accepted: they article a multiplier ("…and a
                    -- hundred fathoms" → 50–100). Everything else must be a number.
                    if word ~= "a" and word ~= "an" and not _is_number_word(word) then
                        n2 = nil; break
                    end
                end
            end
            -- Any numbers qualify (incl. 0 / negative, e.g. "−10°F and 0°F").
            -- The additive "N and a half" form is excluded structurally: its
            -- connector is followed by two tokens ("a half"), not the single
            -- token mtok matches. _range_conv_unit sorts out range vs additive.
            if n1 and n2 then
                -- The comma form is a colloquial consecutive estimate ("seven,
                -- eight feet") — the two values are always close. A large gap
                -- means it isn't a range at all, e.g. "aged about forty-four, six
                -- feet" (age, then height). Cap the comma range at a 3× ratio.
                if conn == ", " then
                    local hi = math.max(math.abs(n1), math.abs(n2))
                    local lo = math.min(math.abs(n1), math.abs(n2))
                    if lo == 0 or hi / lo > 3 then return nil end
                end
                -- "N and <fraction>" is the ADDITIVE form, not a range: "one and
                -- three-quarter leagues" = 1.75, "four and a half feet" = 4.5.
                -- Bail so _prev_num_words composes the whole value.
                if conn == " and " and n2 > 0 and n2 < 1 then return nil end
                -- "<scale> and <small>" is one ADDITIVE number, not a range:
                -- "one hundred and twelve" = 112, "eight thousand and ninety-two"
                -- = 8092, "thirteen hundred and eighty-two" = 1382. The "and"
                -- joins parts of a single number, so bail and let the normal
                -- single-number path read the whole compound (correct value AND
                -- span). A true range keeps n1 off a round hundred ("ten and
                -- twenty") or n2 ≥ 100 ("between one hundred and two hundred").
                if conn == " and " and n1 % 100 == 0 and n2 > 0 then
                    if n2 < 100 then return nil end
                    -- Same thing one scale up, which the < 100 test above cannot
                    -- see: "one hundred and eight million" = 108 million and
                    -- "two hundred and fifty thousand" = 250,000. Both came out
                    -- of Orbital as two-ended ranges ("160 and 13 000 000 km"),
                    -- and the shape occurs 7 times across the corpus — every one
                    -- of them wrong, none of the 91 genuine "and" ranges near it.
                    --
                    -- The tell is that n2 carries a SCALE WORD whose multiplier
                    -- is larger than n1 itself: "two hundred and fifty thousand"
                    -- reads (200 + 50) x 1000, so n1 (200) sits below n2's scale
                    -- (1000). A genuine range like "between one hundred and two
                    -- hundred feet" shares its scale — n1 (100) is NOT below
                    -- n2's scale (100) — and is left alone.
                    local lead = mtok:match("^%s*([%w%-]+)")
                    local lv = lead and _parse_num(lead)
                    if lv and lv > 0 and lv < 100 then
                        local scale = n2 / lv
                        if scale >= 10 and n1 < scale then return nil end
                    end
                end
                return n1, n2, (n1span or 1) + 2 + extra
            end
        end
    end
    return nil
end

-- Vague quantified amounts: "a few hundred pounds", "some dozen feet". The
-- WRITTEN number is just the multiplier (hundred/thousand/dozen), so a single
-- point conversion is false precision — the real quantity is the multiplier
-- scaled by an indefinite band ("a few" ≈ 2–5×). We convert it as a metric band
-- instead. Multiplier words whose bare value (and nothing more) carries the
-- amount; "score"/archaic forms deliberately omitted.
local _VAGUE_MULTIPLIERS = { dozen = 12, hundred = 100, thousand = 1000, million = 1000000 }
-- Quantifier → {low, high} multiplier band. low==high renders as a single "≈ X".
local _VAGUE_BANDS = {
    ["a couple of"] = {2, 2}, ["a couple"] = {2, 2}, ["couple of"] = {2, 2},
    ["couple"] = {2, 2}, ["a few"] = {2, 5}, ["several"] = {3, 7},
    ["some"] = {1, 1}, ["few"] = {2, 5},
}
-- Longest-first so "a couple of" beats "couple", "a few" beats "few".
local _VAGUE_ORDER = {
    "a couple of", "a couple", "couple of", "several", "a few", "couple", "some", "few",
}

-- Given the lowercased prev_text (which ends with the multiplier word, the
-- written number for these matches), return {qlow, qhigh, qword, mult} when it
-- is a vague-quantified amount, else nil. Engages ONLY when the written number
-- is a BARE multiplier ("a few hundred", not "a few two hundred") preceded by a
-- vague quantifier — so precise amounts ("two hundred pounds") are untouched.
local function _detect_vague(prev)
    local p = (prev or ""):lower():gsub("%s+$", "")
    local mword = p:match("([%a]+)$")
    local mult = mword and _VAGUE_MULTIPLIERS[mword]
    if not mult then return nil end
    p = p:sub(1, #p - #mword):gsub("%s+$", "")     -- drop the multiplier word itself
    for _, q in ipairs(_VAGUE_ORDER) do
        if #p >= #q and p:sub(-#q) == q then
            local bch = p:sub(-#q - 1, -#q - 1)     -- char before the quantifier
            if bch == "" or bch:match("%s") then
                local band = _VAGUE_BANDS[q]
                return band[1], band[2], q, mult
            end
        end
    end
    return nil
end

-- Is this unit hit the FIRST unit of an "N unit <conn> M unit" range? (Detected
-- from next_text starting "<conn> M <same-unit>".) If so it's skipped — the
-- second unit hit emits the whole range, avoiding a duplicate "15°F"/"5 miles".
local function _is_range_start(nx, unit)
    if not unit or unit == "" then return false end
    local rest = nx:match("^%s*to%s+(.+)$") or nx:match("^%s*and%s+(.+)$")
              or nx:match("^%s*or%s+(.+)$")
    if not rest then return false end
    local mtok = rest:match("^([%w%-%.,°]+)")
    if not mtok or not _parse_num((mtok:gsub("[%.,]+$", ""))) then return false end
    if unit:find("°", 1, true) then        -- °F: unit fused into the number
        return mtok:find("°", 1, true) ~= nil
    end
    local after = rest:sub(#mtok + 1):gsub("^%s+", "")
    local u = after:match("^(%a+)")
    return u ~= nil and _identify_unit(u) == unit
end

-- Latitude/longitude coordinates ("47° 24′", "69° 50′ 72″") use the arcminute
-- (′) and arcsecond (″) marks — the SAME glyphs as feet/inches — so a prime pass
-- would mis-convert "24′" to 7.3 m. Detect the coordinate context and skip.
local _DEGREE  = "\194\176"   -- ° U+00B0
-- U+00BA MASCULINE ORDINAL, which older typesetting uses where a modern text
-- would set °. Two Years Before the Mast writes "33º 30' S." throughout, so the
-- ° test above walked straight past every coordinate in the book.
local _DEGORD  = "\194\186"   -- º U+00BA
-- crengine drops the ° byte that sits immediately before the matched prime (its
-- own degrees mark), so we can't rely on it being in prev_text. Instead scan the
-- whole prev+next window for coordinate signals — in a "<n>° <n>′ … <n>° <n>′"
-- run the OTHER component's ° (and the lat/long vocabulary) survives. All signals
-- are abbreviation-safe: a real feet/inch prime ("the room was 12′ long",
-- "6′ tall") carries none of them.
local function _is_coordinate(prev, nxt)
    local w = ((prev or "") .. " " .. (nxt or "")):lower()
    -- A degree symbol anywhere in the window (the paired component's °).
    if w:find(_DEGREE, 1, true) or w:find(_DEGORD, 1, true) then return true end
    -- Coordinate vocabulary — full words and the safe abbreviations only.
    if w:find("latitude") or w:find("longitude") then return true end
    if w:find("%f[%a]lat%f[%A]") then return true end        -- "lat" / "lat." (not "flat"/"later")
    -- "deg"/"deg."/"degs"/"degs." — Darwin's Beagle logs abbreviate the plural
    -- ("we drifted to 57 degs. 23' south"), which the singular frontier missed.
    if w:find("%f[%a]deg%f[%A]") or w:find("%f[%a]deg%.")
       or w:find("%f[%a]degs%f[%A]") or w:find("%f[%a]degs%.") then return true end
    if w:find("meridian") then return true end
    -- "W. long" / "E. long" — a directional letter guards the otherwise-risky
    -- "long" (so the adjective in "12′ long" is NOT matched).
    if w:find("[nsew]%.%s*long") then return true end
    -- Astronomy: arc-minutes/-seconds of celestial measurements ("the
    -- acceleration of the moon is 56″", "the constant of aberration … 20″")
    -- use the same glyphs as feet/inches. These nouns have no plausible
    -- co-occurrence with a real feet/inches prime measurement.
    if w:find("aberration") or w:find("parallax") or w:find("precession")
       or w:find("revolution") or w:find("equinox") or w:find("celestial")
       or w:find("%f[%a]arc%f[%A]") then return true end
    return false
end

-- Prime/apostrophe notation (6′8″, 3″, 5'11", 4′ × 2″) isn't anchored on a unit
-- word, so these run as literal findAllText passes rather than riding the
-- alias search. Ordered longest-first so the feet+inches form claims "6′8″"
-- before the bare feet/inches forms.
--
-- `pre` is the shared leading number and `suf` the part that differs, because
-- the whole GROUP runs as ONE findAllText alternation (`pre(suf1|suf2|…)`)
-- rather than one pass per entry — see run_passes. Alternation here is
-- leftmost-first, so keeping the entries longest-first preserves exactly the
-- precedence the separate passes had.
local _PRIME_PATS = {
    pre = _ND,
    needs_left_char = true,
    -- 4′ × 2″  (feet × inches)
    { suf = "(".._PRIME.."|'|"..FootFree._CAPOS..")[ ]*".._TIMES.."[ ]*[0-9]+(".._DPRIME.."|\"|"..FootFree._CDQ..")",
      converter = _conv_dim_to_m_cm, target = "m×cm", cat = "length" },
    -- 10″ × 8″  (inches × inches)
    { suf = "(".._DPRIME.."|\"|"..FootFree._CDQ..")[ ]*".._TIMES.."[ ]*[0-9]+(".._DPRIME.."|\"|"..FootFree._CDQ..")",
      converter = _conv_dim_cm_cm, target = "cm×cm", cat = "length" },
    -- 6′8″ and the spaced 6′ 8″
    { suf = "(".._PRIME.."|'|"..FootFree._CAPOS..")[ ]?[0-9]+(".._DPRIME.."|\"|"..FootFree._CDQ..")",
      converter = _conv_prime_to_m, target = "m", cat = "length" },
    { suf = "(".._PRIME.."|'|"..FootFree._CAPOS..")",   factor = 0.3048, offset = 0, target = "m",  cat = "length" },
    { suf = "(".._DPRIME.."|\"|"..FootFree._CDQ..")", factor = 2.54,   offset = 0, target = "cm", cat = "length" },
}

-- Map a combined-pass hit back to the entry that would have produced it when
-- each pattern ran its own pass. Tested in order, so the first fit wins — the
-- same longest-first precedence as the pattern list. Returns nil for a hit that
-- fits nothing, which run_passes drops rather than guessing at.
--
-- A class-attached function, not a local: main.lua is at Lua's ceiling of 200
-- locals per chunk, and this form is also what the headless harness can extract
-- by name. These classifiers decide which conversion factor a match gets, so
-- they are exactly the kind of pure string logic that should be unit-tested
-- rather than only exercised through a full device scan.
function FootFree._classify_prime(s)
    local SGL = { _PRIME, "'", FootFree._CAPOS }    -- feet marks  ′ ' ’
    local DBL = { _DPRIME, "\"", FootFree._CDQ }    -- inch marks  ″ " ”
    local function ends_any(t, marks)
        for _, m in ipairs(marks) do
            if #t >= #m and t:sub(-#m) == m then return true end
        end
        return false
    end
    local function has_any(t, marks)
        for _, m in ipairs(marks) do
            if t:find(m, 1, true) then return true end
        end
        return false
    end
    -- Classify on what follows the NUMBER, not on the whole match. `_ND`
    -- consumes one boundary character before the digits and that character can
    -- itself be a quote — in "'12\"" the leading apostrophe would otherwise
    -- read as a feet mark and turn a plain inches hit into a feet+inches one.
    local tail = s:match("^.-[0-9][0-9,.]*(.*)$") or s
    local dbl = ends_any(tail, DBL)
    -- Both × forms end in an inch mark, so they are told apart by which mark
    -- sits on the LEFT figure — the part of the tail before the ×.
    if tail:find(_TIMES, 1, true) then
        local head = tail:sub(1, (tail:find(_TIMES, 1, true) or 1) - 1)
        if has_any(head, SGL) then return 1 end       -- 4′ × 2″
        return 2                                     -- 10″ × 8″
    end
    if dbl and has_any(tail, SGL) then return 3 end   -- 6′8″ / 6′ 8″
    if ends_any(tail, SGL) then return 4 end          -- 6′
    if dbl then return 5 end                          -- 3″
    return nil
end
_PRIME_PATS.classify = FootFree._classify_prime

-- A bare feet/inch mark — one glyph, nothing on the other side of the number —
-- is by far the weakest signal this plugin acts on. Measured across the 187
-- English books of the corpus (2026-08-20, full device scan, every hit read by
-- hand): the compound form "6'2"" was a real measurement 19 times out of 19,
-- the bare INCH mark 4 times out of 9, and the bare FEET mark ONCE out of 63 —
-- and that once was half of a spaced "6' 4"" which the compound pattern now
-- claims whole. Every other bare-feet hit in the corpus was a closing quotation
-- mark: Wool alone contributed 32, because British typesetting quotes strings
-- in '…' and the book is full of numbered floors, sockets and channels.
--
-- Hence these guards. Each is a tell that the glyph CLOSES something rather
-- than measuring something. Each was checked against all 91 corpus prime hits
-- before being added: together they suppress 62 of the 72 bare hits and cost
-- zero of the genuine ones.
--
--   mt     the matched text
--   left   the match's own paragraph up to the number (the same wide read the
--          coordinate check does — crengine's prev_text is only ~45 characters,
--          far too short to see the opening quote of "'around 50,000'")
--   after  the REAL characters following the mark, read from the document
--
-- Both context arguments are document reads rather than crengine's prev_text /
-- next_text, and neither is a nicety. next_text SKIPS THE ADJACENT WORD: for
-- "The shelf was 6' wide" it begins " and hard to reach", with "wide" already
-- swallowed. So a cue test written against next_text can never fire — which is
-- how the first version of the exemption below shipped inert, and it is the
-- same shape as the year-possessive guard of cache 64 and the shy-book gate of
-- cache 65. VM-verified on a probe book before this note was written, not
-- assumed. prev_text has the mirror problem plus a five-word ceiling.
--
-- Returns a short reason string, or nil to keep the match. The compound and ×
-- forms never reach here: they carry both marks, which is exactly the evidence
-- the bare forms lack.
function FootFree._prime_fp_reason(mt, left, after)
    mt, left, after = mt or "", left or "", after or ""
    local SGL = { _PRIME, "'", FootFree._CAPOS }
    local DBL = { _DPRIME, "\"", FootFree._CDQ }
    local function ends_any(t, marks)
        for _, m in ipairs(marks) do
            if #t >= #m and t:sub(-#m) == m then return true end
        end
        return false
    end
    local feet = ends_any(mt, SGL)
    if not (feet or ends_any(mt, DBL)) then return nil end   -- not a prime hit
    -- Both marks present = compound/dimension. Those forms are trustworthy and
    -- are never second-guessed here.
    do
        local body = mt:sub(1, -2)
        for _, m in ipairs(feet and DBL or SGL) do
            if body:find(m, 1, true) then return nil end
        end
    end

    -- POSITIVE CUE WINS. A measurement word right after the mark outranks every
    -- guard below, so a genuine height inside quoted dialogue — "'He was 6'
    -- tall,' she said", which the quotation guards would otherwise kill — still
    -- converts. No corpus hit carries one of these, so this costs nothing today
    -- and is the insurance against the guards ever over-reaching.
    do
        local w = after:lower():match("^[%s%p]*(%a+)")
        local CUES = { tall = true, high = true, wide = true, long = true,
                       deep = true, thick = true, across = true, by = true,
                       square = true, height = true, length = true,
                       width = true, diameter = true, apart = true }
        if w and CUES[w] then return nil end
        if after:find(_TIMES, 1, true) then return nil end
    end

    local lt = left:gsub("[ \t]+$", "")            -- keep the last real char
    local last = lt:sub(-1)
    local last3 = lt:sub(-3)

    -- 1. The number is WRAPPED in quotes: '18', '40', '2'. 42 of the 72 corpus
    --    false positives, and the cheapest test there is — look at the one
    --    character before the digits. A measurement never has a quote there.
    if last == "'" or last == '"' or last3 == FootFree._CLSQ
       or last3 == FootFree._CAPOS or last3 == FootFree._CLDQ
       or last3 == FootFree._CDQ or last3 == _PRIME or last3 == _DPRIME then
        return "quoted number"
    end

    -- 2. The number sits INSIDE an open quotation whose opening mark is further
    --    back: "'around 50,000'", "'£4.99 for a roll of 60'". U+2018 and U+201C
    --    are unambiguous opening glyphs — neither is ever an apostrophe — so an
    --    apostrophe-heavy paragraph inflates the CLOSING count and the test
    --    quietly fails to fire. It can under-report an open quotation; it can
    --    never invent one. Straight ASCII quotes are not counted at all: ' is
    --    both apostrophe and quote, so the count means nothing.
    if select(2, lt:gsub(FootFree._CLSQ, "")) > select(2, lt:gsub(FootFree._CAPOS, "")) then
        return "inside a quotation"
    end
    if select(2, lt:gsub(FootFree._CLDQ, "")) > select(2, lt:gsub(FootFree._CDQ, "")) then
        return "inside a quotation"
    end

    -- 3. A dash immediately before the number makes it the far end of a range,
    --    and the mark closes the title it sits in: "…Species Theory, 1838-1859""
    --    read as 4 700 cm, "Anson's Circumnavigation, 1740-44"" as 110 cm.
    if last == "-" or last3 == _ENDASH or last3 == _EMDASH then
        return "range endpoint"
    end

    -- 4. Victorian British decimal point (U+00B7): "0·485"" is 0.485 arcseconds,
    --    not 485 inches. The existing middle-dot guard only fires when the dot
    --    is inside matched_text; here it sits just before it.
    if last3:sub(-2) == "\194\183" then return "middle-dot decimal" end

    -- 5. Clock time: "'2030-08-27 20:31'" — the minutes read as 9.4 m.
    if lt:match("%d:$") then return "clock time" end

    -- 6. An item number rather than a size: "whole-number coefficients, No. 11"",
    --    "'#39' for the one who never says anything except the number".
    if lt:match("[Nn]os?%.$") or last == "#" then return "item number" end

    -- 7. A year after a month name is a date, whatever glyph follows it:
    --    "said '18 October 1919'" read as 585 m.
    do
        local n = tonumber((mt:gsub("[^%d]", "")))
        if n and n >= 1000 and n <= 2999 then
            local w = lt:lower():match("(%a+)%s*$")
            local MONTHS = { january = true, february = true, march = true,
                             april = true, may = true, june = true, july = true,
                             august = true, september = true, october = true,
                             november = true, december = true }
            if w and MONTHS[w] then return "date" end
        end
    end

    -- 8. Library of Congress / Dewey call numbers on the copyright page:
    --    "823'.92-dc22", "364.1'06'0973-dc22", "895.6'36-dc22". The prime is a
    --    field separator, so DIGITS CONTINUE straight after it — which a real
    --    "6' tall" never does. One test, every such number in the corpus, and
    --    no need to guess at where the front matter ends.
    if after:match("^%d") or after:match("^%.%d") then
        return "call number"
    end

    -- 9. A letter straight after a bare FEET mark makes it an apostrophe:
    --    "86'd", "2001's Ghosts of Mars", "o'clock". (This subsumes the
    --    narrower possessive-s test that used to live in the match filter.)
    --    Inches are exempt — "3" in diameter" legitimately precedes a letter.
    if feet and after:match("^%a") then return "apostrophe" end

    -- 10. A zero-length measurement says nothing worth saying, and in practice
    --     it is dialect: Tehanu's "'0' course he did" is "of course".
    do
        local n = tonumber((mt:gsub("[^%d%.]", "")))
        if n == 0 then return "zero" end
    end

    return nil
end

-- All °F (degree-symbol form) handling runs as dedicated literal passes, like
-- the prime passes — the unit-anchored stage can't reliably read a leading dash
-- from prev_text (it would drop the sign, or emit the two endpoints as separate
-- singles), so °F is intentionally absent from the alias list. Longest-first:
-- both-°F range, then trailing-°F range, then the bare value. Each number takes
-- an optional dash prefix covering "−10°F"/"–10°F"/"—10°F"/"-10°F".
local _DEGF = "\194\176F"   -- °F  (U+00B0 'F')
local _TEMP_SIGN = "(-|" .. _ENDASH .. "|" .. _EMDASH .. "|" .. _UMINUS .. ")?"
local _TNUM = _TEMP_SIGN .. "[0-9][0-9.,]*"
local _TEMP_CONV = _range_conv(5/9, -32*5/9, "°C")
-- `pre`/`suf`/`classify`: the group runs as one alternation, see _PRIME_PATS.
local _TEMP_PATS = {
    pre = _TNUM,
    -- "−10°F and 0°F" / "15°F to 75°F"
    { suf = "[ ]*" .. _DEGF .. "[ ]+(to|and|or)[ ]+" .. _TNUM .. "[ ]*" .. _DEGF,
      converter = _TEMP_CONV, target = "°C", cat = "temperature" },
    -- "15 to 75°F" (only the trailing endpoint carries the symbol)
    { suf = "[ ]+(to|and|or)[ ]+" .. _TNUM .. "[ ]*" .. _DEGF,
      converter = _TEMP_CONV, target = "°C", cat = "temperature" },
    -- "98°F" / "−10°F"
    { suf = "[ ]*" .. _DEGF,
      factor = 5/9, offset = -32*5/9, target = "°C", cat = "temperature" },
}

-- Metric-direction twin: °C literal passes (imperial preference only). Same
-- degree-symbol anchoring problem as °F; same longest-first structure.
FootFree._IMPERIAL.degc = "\194\176C"   -- °C
FootFree._IMPERIAL.temp_pats = {
    pre = _TNUM,
    { suf = "[ ]*" .. "\194\176C" .. "[ ]+(to|and|or)[ ]+" .. _TNUM .. "[ ]*" .. "\194\176C",
      converter = _range_conv(9/5, 32, "°F"), target = "°F", cat = "temperature" },
    { suf = "[ ]+(to|and|or)[ ]+" .. _TNUM .. "[ ]*" .. "\194\176C",
      converter = _range_conv(9/5, 32, "°F"), target = "°F", cat = "temperature" },
    { suf = "[ ]*" .. "\194\176C",
      factor = 9/5, offset = 32, target = "°F", cat = "temperature" },
}

-- Both temperature groups classify the same way: count the degree symbols. Two
-- means the both-endpoints range; one plus a range word means the trailing-only
-- range ("15 to 75°F"); one alone is the bare value. Class-attached and
-- symbol-parameterised for the same reasons as _classify_prime.
function FootFree._classify_temp(s, sym)
    local stripped, n = s:gsub(sym, "")
    if stripped and n >= 2 then return 1 end
    -- The range words are the pattern's own (to|and|or), always spaced.
    if s:find("[ ]to[ ]") or s:find("[ ]and[ ]") or s:find("[ ]or[ ]") then
        return 2
    end
    if n >= 1 then return 3 end
    return nil
end
_TEMP_PATS.classify = function(s) return FootFree._classify_temp(s, _DEGF) end
FootFree._IMPERIAL.temp_pats.classify = function(s)
    return FootFree._classify_temp(s, FootFree._IMPERIAL.degc)
end

-- Does prev_text end with "<unit> [,/and] <number>"? Confirms a compound tail
-- even with a comma or "and" connector ("two pounds, four ounces",
-- "5 feet and 3 inches"), not just a plain space.
local function _compound_tail(p, u1, u2)
    -- Separator after the foot/pound word may be a space, comma OR hyphen — the
    -- last covers fully-hyphenated compounds like "six-foot-five-inch", whose
    -- prev_text ends "...six-foot-five-" (no space/comma before the inches).
    return p:match(u1 .. "[,%s%-]+%S+%s*$")        or p:match(u2 .. "[,%s%-]+%S+%s*$")
        or p:match(u1 .. "[,%s%-]+and%s+%S+%s*$")  or p:match(u2 .. "[,%s%-]+and%s+%S+%s*$")
end

local _INCH_UNITS  = { inches = true, inch = true, ["in"] = true }
local _OZ_UNITS    = { ounces = true, ounce = true, oz = true }

-- "a/an <unit>" read as the number 1 — but ONLY for distance units that rarely
-- read figuratively, AND only when a spatial cue sits right beside it. This
-- catches "a league from the city" / "a mile distant" / "a league in width"
-- while leaving the homonyms alone ("a league of nations", "go the extra mile",
-- "a foot in the door" — foot isn't even in the set). Article = 1 is otherwise
-- not honoured (parse_num("a") is nil); "a hundred miles" already works via the
-- multiplier path.
local _ART_DIST_UNITS = {
    league=true, leagues=true, mile=true, miles=true, yard=true, yards=true,
    fathom=true, fathoms=true, furlong=true, furlongs=true,
}
local _SPATIAL_NEXT = {   -- first word AFTER the unit
    from=true, away=true, off=true, distant=true, long=true, wide=true,
    deep=true, high=true, tall=true, broad=true, thick=true, apart=true,
    ahead=true, behind=true, beyond=true, further=true, farther=true,
    square=true, ["or"]=true,   -- "a mile or two" (range, still a distance)
    -- Directional continuations: "a mile down the road", "a league up the
    -- coast", "a mile out". (Corpus-sweep misses: Bury Our Bones' dialogue
    ---initial "A mile down the road".)
    down=true, up=true, along=true, across=true, out=true, back=true,
    -- FALSE entries are attributive compound tails: "ran a mile RELAY" /
    -- "a mile RACE" — the unit modifies the following noun ("a [mile relay]",
    -- not a distance), so no prev cue may force a conversion. (CH31 spec:
    -- "ran a mile relay" must NOT match — the motion-verb prev cues would
    -- otherwise fire on "ran".) Kept in this table to respect the Lua
    -- 200-locals ceiling; _article_distance_one checks == false explicitly.
    relay=false, relays=false, race=false, races=false, marker=false,
    markers=false, post=false, posts=false, record=false, records=false,
    time=false, trial=false, trials=false, pace=false,
}
local _SPATIAL_DIM = {    -- "<unit> in <dim>"
    width=true, length=true, height=true, breadth=true, diameter=true,
    circumference=true, radius=true,
}
local _SPATIAL_PREV = {   -- phrase ending right before the article
    "distance of", "within", "more than", "less than", "about", "nearly",
    "almost", "scarcely", "barely", "fully", "quite",
    -- "for a mile" — extent of an action ("carried for a mile", "stretched
    -- for a mile"): practically always a genuine distance (Tainted Cup
    -- corpus-sweep miss; user-approved 2026-07-06).
    "for",
    -- Motion verbs: "go a mile", "walked a league", "rode a mile" — a motion
    -- verb directly before "a <distance-unit>" always reads as distance (KJV
    -- corpus-sweep miss: "compel thee to go a mile"). Matched with a word
    -- frontier below, so "ago" can never satisfy "go".
    "go", "goes", "went", "gone", "walk", "walked", "ran", "run",
    "rode", "ride", "sail", "sailed", "march", "marched",
    "travel", "traveled", "travelled", "drove", "drive", "swam", "crawled",
}
-- Returns true if `unit` is "a/an <distance-unit>" with an adjacent spatial cue.
local function _article_distance_one(unit, prev, nxt)
    if not _ART_DIST_UNITS[unit] then return false end
    prev = (prev or ""):lower(); nxt = (nxt or ""):lower()
    local art = prev:match("(%a+)%s*$")
    if art ~= "a" and art ~= "an" then return false end   -- bare article only
    -- "<digit-token> of a <unit>" is a FRACTION of the unit — the OCR-mangled
    -- "3 4's of a mile" (= ¾ of a mile) or "1⁄120 of a mile" — not the
    -- article-as-one shape; "a mile = 1.6 km" would overstate the distance.
    -- Spelled fractions ("three quarters of a mile") parse upstream and never
    -- reach this path, so only digit-bearing tokens need rejecting.
    local ofw = prev:match("(%S+)%s+of%s+an?%s*$")
    if ofw and ofw:find("%d") then return false end
    -- spatial cue FOLLOWING the unit (== false marks an attributive tail —
    -- "a mile relay" — which blocks the prev cues too)
    local nf = nxt:match("^%s*(%a+)")
    if nf and _SPATIAL_NEXT[nf] == false then return false end
    if nf and _SPATIAL_NEXT[nf] then return true end
    local dim = nxt:match("^%s*in%s+(%a+)")
    if dim and _SPATIAL_DIM[dim] then return true end
    -- spatial cue PRECEDING the article ("distance of a", "more than a", …).
    -- %f[%a] frontier: the cue must start a word ("ago" must not satisfy "go").
    local before = (prev:gsub("%s*an?%s*$", " "))
    for _, cue in ipairs(_SPATIAL_PREV) do
        if before:find("%f[%a]" .. cue .. "%s*$") then return true end
    end
    return false
end

local function _fast_scan_matches(doc, cat_enabled)
    -- 15 context words each side (was 8): the pound currency classifier reads
    -- the full width to catch £ cues that sit beyond 8 words. Everything else
    -- (number/range/span logic, the legacy filters) trims back to 8 via
    -- _last_words/_first_words so its behaviour is unchanged. (Corpus measure:
    -- 15 is the sweet spot — recovers ~10 out-of-window currency cases with no
    -- genuine-weight loss; wider starts crossing sentence boundaries.)
    local _t0 = _now()
    -- Phase timings for the dev-mode scan report. Written here, read by
    -- _finishScan (same process — the fork happens above this call, so a
    -- module-level table carries across without an IPC channel). The old
    -- per-pattern `t_per_pat` breakdown died with the single-alternation
    -- rewrite (both call sites pass {}), and total-only can't tell a slow
    -- document walk from a slow per-hit loop — which is the ONLY question
    -- worth asking before optimizing either. Cost is a handful of _now()
    -- calls per scan; the fields are consumed only when dev mode is on.
    FootFree._scan_t = { walk = 0, loop = 0, lit = 0, gate = 0, litn = 0,
                         hits = 0, passes = 1, shy = false,
                         probe = 0, skipped = 0 }
    -- Active direction: imperial preference scans METRIC units (metric →
    -- imperial); the default scans imperial as always. Read once per scan —
    -- the subprocess inherits the parent's settings snapshot.
    local dir_imperial = FootFree._IMPERIAL.preferred() ~= "metric"
    local ACTIVE_CONV = dir_imperial and FootFree._IMPERIAL.conv or _UNIT_CONV
    local ACTIVE_SUFS = dir_imperial and FootFree._IMPERIAL.suffixes or _UNIT_SUFFIXES
    -- Soft-hyphen books break the REGEX findAllText path: hits near U+00AD
    -- words come back span-shifted or go missing entirely (probe-confirmed on
    -- The Rise and Fall of the Dinosaurs: "Indianapolis is 1,700 miles"
    -- produced NO hit; "seven-ton" surfaced as the garbled "en-t"; a bare
    -- alternation without \b is equally broken, so it's the regex engine
    -- itself, not the anchors). The PLAIN (non-regex) search path handles the
    -- same text correctly, so such books scan with one plain pass per unit
    -- alias instead. ("Slower, but correct" is what this comment used to say;
    -- it is wrong. Measured 2026-08-17 on one book and its soft-hyphen twin:
    -- all 54 plain passes = 2.63s, the single regex alternation = 4.84s. Plain
    -- search is ~100x cheaper PER PASS, so 54 of them still beat one regex
    -- pass. Whether the plain path should therefore be the default for ALL
    -- books is an open question, not a settled one — the two paths do not
    -- currently agree on what they find.) Detection: file-level, via
    -- metric_epub's libarchive reader — no crengine text API exposes the
    -- character (context extraction strips it; the plain search path skips it
    -- for matching, so it can't even be searched for). (Known limitation: the
    -- prime/°F literal passes below stay regex, so prime notation adjacent to
    -- soft-hyphenated words can still skew in such books — not seen in
    -- practice.)
    local shy_book = false
    do
        local mod = _metric_module()
        local f = doc.file or ""
        if mod and mod.has_soft_hyphens and f:lower():match("%.epub$") then
            local oks, res = pcall(mod.has_soft_hyphens, f)
            shy_book = (oks and res) or false
        end
    end
    -- ── The only scan path: one PLAIN search per unit alias ──────────────────
    -- This used to be the soft-hyphen fallback, with a single 54-branch regex
    -- alternation as the path every other book took. Profiling inverted that
    -- (2026-08-17, Lonesome Dove, 366k words):
    --
    --     plain search for "miles"           0.03s   177 hits
    --     regex \bmiles\b — same result      0.52s   177 hits
    --     regex, 8 branches                  1.56s
    --     regex, 27 branches                 2.98s
    --     regex, 54 branches (what shipped)  4.82s
    --
    -- The document walk is nearly free; the alternation was the entire bill,
    -- growing ~0.08s per branch. 54 plain passes cost ~1.6s against 4.82s for
    -- one regex pass, so doing it 54 times is still ~3x cheaper. (Factoring the
    -- alternation — mile|miles -> miles? — was tried and is WORSE: optional
    -- groups cost more than extra alternatives. 17 factored branches = 3.59s
    -- against 2.98s for 27 plain ones.)
    --
    -- Equivalence was established before the switch, not assumed: 12 books
    -- scanned both ways, both directions, every match set IDENTICAL — including
    -- smoketest5's 321 and smoketest6's 39. Consolidating to ONE path also
    -- removes the failure mode that produced cache 65: two paths that were
    -- supposed to agree, silently didn't, and only a soft-hyphen book ran the
    -- one nobody profiled.
    --
    -- The win scales with book length — each pass has a small fixed cost, so a
    -- tiny book pays slightly more (smoketest5: 0.24s -> 0.27s) while a novel
    -- saves seconds (Lonesome Dove: 5.13s -> 2.43s).
    local ok, hits
    do
        hits = {}
        local claimed = {}   -- start xpointer -> true (longest alias wins)
        local aliases = {}
        for _, u in ipairs(ACTIVE_SUFS) do
            -- One-letter metric aliases can't ride a plain search: "m"/"g"
            -- would match every occurrence of the letter. They are covered by
            -- their own number-anchored literal passes instead (unit_pats),
            -- which is why the metric direction is unaffected by this path.
            if u ~= "°F" and u ~= "m" and u ~= "g" then aliases[#aliases + 1] = u end
        end
        table.sort(aliases, function(a, b) return #a > #b end)
        FootFree._scan_t.shy, FootFree._scan_t.passes = shy_book, #aliases
        -- True \b on BOTH sides, by reading the adjacent character in the
        -- node: plain-path prev_text/next_text are WORD-based (they stop at
        -- word boundaries), so a mid-word hit ("15 mi|nutes", "one kn|ows",
        -- "s|mile|s") looks clean in its contexts and would sail through
        -- every string guard. A digit on the left stays allowed ("260lbs" —
        -- mirrors the regex path's digit lookbehind).
        -- Read up to `n` characters outward from `xp` and strip soft hyphens
        -- before the caller tests them. A ONE-character probe is not enough in
        -- exactly the books this path exists for: the character adjacent to the
        -- alias is frequently the soft hyphen itself, which is not %a, so the
        -- guard passed and "losing five mi|nutes" converted as "five mi" = 8 km
        -- (measured 2026-08-17: 48 such false positives in one novel, every one
        -- of them the "mi" alias inside a longer word). Widening the read and
        -- discarding U+00AD tests the character a reader actually sees. Falls
        -- back to a single character if the wide read runs past the node.
        local _SHY_CH = "\194\173"
        local function _probe(a, b, fallback_a, fallback_b)
            local okp, s = pcall(function()
                return doc:getTextFromXPointers(a, b)
            end)
            if not (okp and s) then
                okp, s = pcall(function()
                    return doc:getTextFromXPointers(fallback_a, fallback_b)
                end)
            end
            if not (okp and s) then return nil end
            return (s:gsub(_SHY_CH, ""))
        end
        local function shy_boundary_ok(h)
            local pfx, off = _xpointer_offset(h.start)
            if pfx ~= h.start and off and off > 0 then
                local c = _probe(pfx .. tostring(math.max(0, off - 4)), h.start,
                                 pfx .. tostring(off - 1), h.start)
                -- Left side: the character immediately BEFORE the alias is the
                -- last one of the probe, so test the tail.
                if c and c:match("%a$") then return false end
            end
            local pfx2, off2 = _xpointer_offset(h["end"])
            if pfx2 ~= h["end"] and off2 then
                local c = _probe(h["end"], pfx2 .. tostring(off2 + 4),
                                 h["end"], pfx2 .. tostring(off2 + 1))
                if c and c:match("^%a") then return false end
            end
            return true
        end
        -- Skip the pass entirely for an alias this book never contains. A pass
        -- costs a full walk of the document regardless of what it finds, and
        -- roughly half of the 54 aliases are absent from a typical novel
        -- (measured over 20 books: 27 of 55 present on average). `present` is
        -- nil whenever the probe could not answer confidently, and nil means
        -- run everything — the asymmetry matters, since a wrongly skipped pass
        -- loses conversions silently for the life of the book.
        local _tPR = _now()
        local present
        do
            local mod = _metric_module()
            local f = doc.file or ""
            if mod and mod.probe_aliases and f:lower():match("%.epub$") then
                local okpr, res = pcall(mod.probe_aliases, f, aliases)
                present = (okpr and res) or nil
            end
        end
        FootFree._scan_t.probe = _now() - _tPR
        FootFree._scan_t.skipped = 0
        for _, u in ipairs(aliases) do
            if present and not present[u] then
                FootFree._scan_t.skipped = FootFree._scan_t.skipped + 1
                goto next_alias
            end
            do
            local okp, res = pcall(function()
                return doc:findAllText(u, true, 15, 20000, false)
            end)
            if okp and res then
                for _, h in ipairs(res) do
                    if not claimed[h.start] and shy_boundary_ok(h) then
                        claimed[h.start] = true
                        hits[#hits + 1] = h
                    end
                end
            end
            end
            ::next_alias::
        end
        -- Per-alias passes lose document order; the compound-merge logic
        -- (feet+inches etc.) depends on it. Restore it.
        table.sort(hits, function(a, b)
            return doc:compareXPointers(a.start, b.start) == 1
        end)
        ok = true
    end
    if not ok or not hits then return {} end
    local _tA1 = _now() - _t0
    FootFree._scan_t.walk, FootFree._scan_t.hits = _tA1, #hits


    -- Real scan progress (read by the parent's _pollFastScan over
    -- _SCAN_PROGRESS_FILE). findAllText above is one opaque pass, but the per-hit
    -- loop below is the dominant cost and its length (#hits) is known now, so we
    -- report i/#hits as genuine progress. _tA1 (the findAllText duration) is sent
    -- alongside so the parent can size the pre-loop band proportionally. Writes
    -- are atomic (tmp + rename) so a torn read can never mis-parse; every failure
    -- is ignored (the parent just falls back to its time-based estimate).
    local _prog_total = #hits
    local _prog_every = math.max(1, math.floor(_prog_total / 100))
    local function _report(frac)
        local fh = io.open(_SCAN_PROGRESS_FILE .. ".tmp", "w")
        if fh then
            fh:write(string.format("%.4f %.5f", _tA1, frac))
            fh:close()
            os.rename(_SCAN_PROGRESS_FILE .. ".tmp", _SCAN_PROGRESS_FILE)
        end
    end
    _report(0)

    local function text_of(a, b)
        local okt, mt = pcall(function() return doc:getTextFromXPointers(a, b) end)
        if okt and mt then return (mt:gsub("^%s+", ""):gsub("%s+$", "")) end
        return nil
    end
    -- crengine word-navigation wrappers: pcall-guarded, return nil on failure.
    local function _prevword(xp)
        local okx, nx = pcall(function() return doc:getPrevVisibleWordStart(xp) end)
        return okx and nx or nil
    end
    local function _nextword(xp)
        local okx, nx = pcall(function() return doc:getNextVisibleWordEnd(xp) end)
        return okx and nx or nil
    end
    -- Extend a start xpointer back over the number, validating by text so it
    -- crosses hyphens (which getPrevVisibleWordStart treats as word breaks, so
    -- "six-foot-four" would otherwise stop the underline at "-foot-"). Returns
    -- the position where the text begins with `num`; falls back to the plain
    -- word-count position if no exact text match is found.
    local function extend_start(unit_start, num, span, prev_text)
        local cand, fallback = unit_start, nil
        for i = 1, 8 do
            local nxt = _prevword(cand)
            if not nxt or nxt == cand then break end
            cand = nxt
            if i == span then fallback = cand end
            local t = text_of(cand, unit_start)
            -- Never extend the number across a sentence boundary: in "…not one
            -- hundred miles from Shanghai. A hundred miles" the earlier "hundred"
            -- (=100) belongs to the previous sentence, so without this the span
            -- merged both. A boundary is [.!?] + space + a capital (an "ft. 4"
            -- abbreviation is followed by a digit, so it doesn't trip this).
            if t and t:find("[.!?]%s+%u") then break end
            -- Validate by parsing the WHOLE span text, not just the first token:
            -- a space-separated spelled compound ("seven thousand five hundred and
            -- twenty-four") only equals `num` once the entire phrase is covered,
            -- and getPrevVisibleWordStart splits hyphenated parts ("twenty-four"
            -- → "twenty" + "four"), so the old first-token + step-count check
            -- stalled mid-number. _parse_num reads the leading number of `t` and
            -- stops at the unit, so it grows 524 → 1524 → 7524 as we step back and
            -- matches only at the true start. The i >= span gate still defers a
            -- match whose last word alone equals num ("one hundred" → stop at
            -- "one", not "hundred"; "a hundred" → include the "a").
            if t and _parse_num(t) == num and i >= (span or 1) then return cand end
            -- The ADDITIVE form needs its own validator, because _parse_num is
            -- structurally unable to confirm it: "one and three-quarter leagues"
            -- is 1.75, but _parse_num prefix-reads it as 1 — which is exactly why
            -- _prev_num_words computes the value itself for this shape. So the
            -- test above can never become true, the loop runs out, and the span
            -- falls back short: the book read "one and three-quarter leagues" and
            -- the underline covered "three-quarter leagues", with the correct
            -- 8.4 km attached to two thirds of the phrase. Harmless in Underline
            -- mode; in Add/Convert mode it writes "one and 8.4 km" into the text.
            -- Mirror the additive branch of _prev_num_words: whole + fraction,
            -- both re-parsed from the candidate text, accepted only on an exact
            -- hit. (Corpus: Darwin's "thirteen and three-quarters British miles"
            -- and Verne's "one and three-quarter leagues".)
            if t then
                local ipart, fpart = t:match("^([%w%-]+)%s+and%s+(.+)$")
                if ipart and fpart then
                    local iv, fv = _parse_num(ipart), _parse_num(fpart)
                    if iv and fv and iv >= 1 and iv == math.floor(iv)
                       and fv > 0 and fv < 1 and math.abs(iv + fv - num) < 1e-9 then
                        return cand
                    end
                end
            end
            -- Range lower-endpoint rescue: a range like "fifty and a hundred
            -- fathoms" has its two numbers glued by "and", so _parse_num(t)
            -- composes the whole span multiplicatively ("fifty … hundred" =
            -- 5000) and never equals the range's first number (50). Accept the
            -- candidate when the text UP TO THE FIRST range connector parses to
            -- num — that's the start of the lower endpoint. ("or"/"to" ranges
            -- already match at line above because _parse_num stops at those.)
            if t and i >= (span or 1) then
                local head = t:match("^(.-)%s+and%s") or t:match("^(.-)%s+or%s")
                    or t:match("^(.-)%s+to%s")
                if head and head ~= "" and _parse_num(head) == num then return cand end
            end
        end
        -- Offset fallback: when the unit was matched as a SUBSTRING of a
        -- hyphen-fused token ("five-thousand-five-hundred-mile"), the unit's
        -- start is mid-word and getPrevVisibleWordStart can't step back through
        -- it, so the loop above gives up at "-mile". The number and unit share one
        -- text node, so jump straight back by the length of the trailing number
        -- text in prev_text and confirm by re-reading the text (a wrong guess
        -- simply isn't accepted). Tries a couple of connector widths ("-"/none).
        if prev_text then
            local numtext = prev_text:match("([%w][%w%.,%-]*)%s*$")
            if numtext and _parse_num(numtext) == num then
                local prefix, off = _xpointer_offset(unit_start)
                if prefix ~= unit_start then
                    for gap = 0, 2 do
                        local cand2 = prefix .. tostring(off - #numtext - gap)
                        local t = text_of(cand2, unit_start)
                        local lead = t and t:match("^([%w][%w%.,%-]*)")
                        if lead and _parse_num(lead) == num then return cand2 end
                    end
                end
                -- Cross-node fallback: the number lives in one or more text nodes
                -- BEFORE the unit's node — the unit was wrapped in an inline
                -- element (<span>/<i>), or a <br/>/soft-break split the compound
                -- across nodes. Same-node offset math (above) can't reach a prior
                -- node, and the word walker stalls at the first hyphen. So step
                -- back NODE by NODE: at each earlier node, read its text up to the
                -- unit and look for the known number surface (numtext). Accept the
                -- LAST occurrence (the one adjacent to the unit), re-validated by
                -- text — a wrong guess is simply not returned.
                -- The number's first token ("five" of "five-thousand-…", "four"
                -- of "four-and-a-half"). Searched literally; the FULL value is
                -- then confirmed by parsing the text from that point to the unit,
                -- which tolerates an internal break char a <br/> may inject (a
                -- newline splits the tokens but _parse_num composes them anyway).
                local head = numtext:match("^([%w]+)") or numtext
                local probe, seen = unit_start, {}
                for _ = 1, 10 do
                    local pfx, poff = _xpointer_offset(probe)
                    if pfx == probe or not poff then break end
                    if seen[pfx] then break end
                    seen[pfx] = true
                    local nodestart = pfx .. "0"
                    local okf, full = pcall(function()
                        return doc:getTextFromXPointers(nodestart, unit_start)
                    end)
                    if okf and full then
                        -- All start offsets of `head` in this node, latest first
                        -- (the occurrence adjacent to the unit is the right one;
                        -- "five-thousand-five-hundred" has two — the earlier
                        -- validates, the later "five-hundred" doesn't).
                        local positions, p = {}, full:find(head, 1, true)
                        while p do positions[#positions + 1] = p; p = full:find(head, p + 1, true) end
                        for i = #positions, 1, -1 do
                            local k = positions[i] - 1
                            if k >= 0 then
                                local cand2 = pfx .. tostring(k)
                                local t = text_of(cand2, unit_start)
                                if t and _parse_num(t) == num then return cand2 end
                            end
                        end
                    end
                    -- Step into the previous node: one visible-word step back from
                    -- this node's start crosses the boundary.
                    local okx, ws = pcall(function()
                        return doc:getPrevVisibleWordStart(nodestart)
                    end)
                    if not okx or not ws or ws == nodestart or ws == probe then break end
                    probe = ws
                end
            end
        end
        return fallback or cand
    end
    -- Extend an end xpointer forward to include the second number of a compound
    -- ("six-foot-|four", "6 foot |4"). With include_in, also pull a trailing
    -- "in"/"in." inch abbreviation under the highlight ("five ft. seven |in.").
    -- Returns the original end if the second number isn't found.
    local function extend_end(unit_end, second, include_in)
        local cand = unit_end
        for _ = 1, 4 do
            local okx, nxt = pcall(function() return doc:getNextVisibleWordEnd(cand) end)
            if not okx or not nxt or nxt == cand then break end
            cand = nxt
            local t = text_of(unit_end, cand)
            local tail = t and t:gsub("[%s%-]+$", ""):match("([%w][%w%.,]*)$")
            if tail and _parse_num(tail) == second then
                if include_in then
                    local okn, after = pcall(function() return doc:getNextVisibleWordEnd(cand) end)
                    if okn and after and after ~= cand then
                        local w = text_of(cand, after)
                        if w and w:match("(%a+)") and w:match("(%a+)"):lower() == "in" then
                            return after
                        end
                    end
                end
                return cand
            end
        end
        return unit_end
    end
    -- The second number of a compound — read from the text BETWEEN the first
    -- match's end and the unit hit (exactly the inches/ounces number, robust to
    -- a fused "4-oz" token that a prev_text word-walk mis-reads as "1-lb 4"→1).
    -- Falls back to the single word just before the unit.
    local function tail_num(prev_end, unit_start)
        local between = text_of(prev_end, unit_start)
        if between then
            local n = _parse_num((between:gsub("^[%s,]+", "")))
            if n then return n end
        end
        local okps, ps = pcall(function() return doc:getPrevVisibleWordStart(unit_start) end)
        if okps and ps then
            local bt = text_of(ps, unit_start)
            if bt then return _parse_num(bt) end
        end
        return nil
    end

    local out, seen_end = {}, {}
    local _tL0 = _now()
    for i, h in ipairs(hits) do
        if i % _prog_every == 0 then _report(i / _prog_total) end
        local unit = _identify_unit(h.matched_text, ACTIVE_SUFS)
        local conv = unit and ACTIVE_CONV[unit]
        -- Metric-direction money guard: "$50 m" / "£3m" / "€2 m" is a money
        -- abbreviation (millions), not meters/grams — the currency symbol
        -- glued to the number gives it away. The number is usually INSIDE
        -- matched_text (the m/g pattern branches include it), leaving
        -- prev_text ending on the bare symbol — hence the optional digits.
        if conv and dir_imperial and (unit == "m" or unit == "g")
           and ((h.prev_text or ""):match("%$%s*[%d.,]*%s*$")
                or (h.prev_text or ""):match("£%s*[%d.,]*%s*$")
                or (h.prev_text or ""):match("€%s*[%d.,]*%s*$")) then
            conv = nil
        end
        if conv and cat_enabled[conv.cat] ~= false and not seen_end[h["end"]]
           and not (h.start or ""):find("/h[1-6][%[/]")  -- skip heading/title text
           -- A fraction DENOMINATOR right before the unit is not the measurement
           -- value — e.g. the OCR-mangled "not over 1 /10; inch" (= one-tenth inch)
           -- ends its context "...1 /10; " and would otherwise read "10 inch" =
           -- 25 cm. The "<num> / <num>" shape (optionally trailing ";") can't be
           -- reliably recovered, so suppress rather than emit a wrong value (cf.
           -- CH18 mangled fractions).
           -- (space REQUIRED before the slash: that's the OCR-mangled signature
           -- "1 /10; inch". A tight "19-3/10 miles" / "1-3/8 inches" is a clean
           -- ASCII mixed fraction and must convert — sweep batch 2.)
           and not (h.prev_text or ""):match("%d%s+/%s*%d+%s*;?%s*$")
           and not _is_range_start((h.next_text or ""):lower(), (unit or ""):lower()) then
            local p = (h.prev_text or ""):lower()
            local ulow = (unit or ""):lower()

            -- Range "N <conn> M unit" — reuse the classic _range_conv_unit for
            -- the actual conversion. No _unit/_num is set, so the sidecar keeps
            -- the range string verbatim (UK-volume recalc would otherwise
            -- collapse it to a single value).
            local range_done = false

            -- Area: "two or three square miles" / "fifty square feet" — the cue
            -- word "square" sits between the number and the unit, so the length
            -- path would mis-read it as miles/feet. Convert to metric area
            -- (km²/m²/cm², auto). Sets range_done so the length branches skip.
            -- Hyphenated adjectival compounds ("a three-million-square-foot
            -- cave", "a 250,000-square-foot room") glue "square" to the unit
            -- with a hyphen, not a space, so the cue check needs the same
            -- hyphen-to-space normalization _prev_num_words/_compose_spelled
            -- already do internally — otherwise this falls through to the
            -- plain length path with the LINEAR foot factor, badly wrong and
            -- missing the ² (report #22-24: 250,000-square-foot → 76 000 m
            -- instead of ~23 000 m²).
            local area_factor = _AREA_CONV[ulow]
            local lw8 = _last_words(p, 8):gsub("%-", " ")
            if area_factor and lw8:match("square%s*$") then
                local pbefore = lw8:gsub("%s*square%s*$", "")
                local an1, an2 = _detect_back_range(pbefore, "")
                local single = (not an1) and _prev_num_words(pbefore) or nil
                local lonum = an1 or single
                if lonum then
                    -- Original connector for prose ("two or three" → " or ").
                    local conn = " to "
                    for _, c in ipairs({" or ", " and ", " to " }) do
                        if pbefore:find(c, 1, true) then conn = c end
                    end
                    local astart = extend_start(h.start, lonum, 1)
                    local mt = text_of(astart, h["end"])
                    if mt then
                        out[#out + 1] = {
                            start = astart, ["end"] = h["end"],
                            matched_text = mt, prev_text = h.prev_text, next_text = h.next_text,
                            _search = conv, _cat = "area",
                            _converted = _display(mt) .. " = "
                                .. _area_str(lonum, an2, area_factor, an1 and conn or nil),
                        }
                        seen_end[h["end"]] = true
                        range_done = true
                    end
                end
            end

            -- Range detection reads breadth of prev_text, so feed it the legacy
            -- 8-word slice (the wider window is for the pound classifier only).
            local rn1 = not range_done and _detect_back_range(_last_words(p, 8), ulow)
            if rn1 then
                -- Extend back to the FIRST position whose text parses to rn1
                -- (span = 1). A fixed span miscounts when the connector isn't a
                -- word: "seven, eight feet" puts "seven" one step nearer than
                -- "five to ten" does, and the old span overshot past it, so the
                -- range collapsed to just "eight feet".
                local rstart = extend_start(h.start, rn1, 1)
                local mt = text_of(rstart, h["end"])
                -- Restore a dropped leading minus: extend_start can land AFTER a
                -- U+2212/"−" it couldn't text-validate, so mt would read "10°F"
                -- and _range_conv_unit would flip the negative first endpoint.
                if mt and rn1 < 0 then
                    local lead = mt:gsub("^%s+", "")
                    if lead:sub(1, 1) ~= "-" and lead:sub(1, #_UMINUS) ~= _UMINUS then
                        mt = _UMINUS .. lead
                    end
                end
                local rconv = mt and _range_conv_unit(mt)
                if rconv then
                    out[#out + 1] = {
                        start = rstart, ["end"] = h["end"],
                        matched_text = mt, prev_text = h.prev_text, next_text = h.next_text,
                        _search = conv, _cat = conv.cat,
                        _converted = _display(mt) .. " = " .. rconv,
                    }
                    seen_end[h["end"]] = true
                    range_done = true
                end
            end

            local prevm = out[#out]
            local merged = false

            -- Compound TAIL: inches/ounces right after a feet/pounds match —
            -- merge into the previously emitted match instead of standing alone.
            if not range_done and _INCH_UNITS[unit] and prevm and not prevm._num2
               and _compound_tail(p, "feet", "foot") then
                local m = tail_num(prevm["end"], h.start) or _prev_num_words(h.prev_text)
                if m then
                    prevm._num    = prevm._num or _parse_num(prevm.matched_text)
                    prevm._num2   = m
                    prevm._search = _UNIT_CONV["feet"]
                    prevm["end"]  = h["end"]
                    prevm.matched_text = text_of(prevm.start, h["end"]) or prevm.matched_text
                    prevm.next_text = h.next_text
                    merged = true
                end
            elseif not range_done and _OZ_UNITS[unit] and prevm and not prevm._num_oz
               and _compound_tail(p, "pounds?", "lbs?") then
                local m = tail_num(prevm["end"], h.start) or _prev_num_words(h.prev_text)
                if m then
                    prevm._num    = prevm._num or _parse_num(prevm.matched_text)
                    prevm._num_oz = m
                    prevm._search = _UNIT_CONV["pounds"]
                    prevm["end"]  = h["end"]
                    prevm.matched_text = text_of(prevm.start, h["end"]) or prevm.matched_text
                    prevm.next_text = h.next_text
                    merged = true
                end
            -- Dimension "feet by inches": "four feet by two inches" → ONE unit
            -- ("1.2 m by 5.1 cm"). Unlike a feet+inches height (summed), this is
            -- two independent measurements, so pin _converted via _conv_ft_by_in
            -- rather than the _num/_num2 height path.
            elseif not range_done and _INCH_UNITS[unit] and prevm
               and (prevm._unit == "feet" or prevm._unit == "foot")
               and not prevm._num2 and not prevm._converted
               and p:match("f[eo]?[eo]?t%s+by%s+%S+%s*$") then
                local mt = text_of(prevm.start, h["end"])
                local conv_str = mt and _conv_ft_by_in(mt)
                if conv_str then
                    prevm["end"]       = h["end"]
                    prevm.matched_text = mt
                    prevm.next_text    = h.next_text
                    prevm._converted   = _display(mt) .. " = " .. conv_str
                    prevm._unit        = nil  -- block single-unit recompute
                    prevm._search      = conv
                    merged = true
                end
            end
            if merged then seen_end[h["end"]] = true end

            if not range_done and not merged then
                -- Fused digit+unit ("260lbs", "9mm"): the digits share the
                -- hit's own WORD, so crengine's word-based prev_text ends
                -- before them ("…must weigh upwards of "). Read the raw
                -- characters just before the hit and take a glued trailing
                -- number. Probed FIRST — a glued digit IS the measurement,
                -- and a spelled number further back is a count: "It takes
                -- two 9mm…" used to read as 2 mm (Nesbø sweep). The span is
                -- extended by exact offset (validated by re-reading the
                -- text), not by word-walking.
                local num, span, glued_start
                do
                    local pfx, off = _xpointer_offset(h.start)
                    if pfx ~= h.start and off and off > 0 then
                        local pre_xp = pfx .. tostring(math.max(0, off - 12))
                        local okp, pre = pcall(function()
                            return doc:getTextFromXPointers(pre_xp, h.start)
                        end)
                        local numtext = okp and pre and pre:match("(%d[%d,%.]*)$")
                        if numtext then
                            local n = _parse_num(numtext)
                            if n then
                                local cand = pfx .. tostring(off - #numtext)
                                local t = text_of(cand, h["end"])
                                if t and t:sub(1, #numtext) == numtext then
                                    num, span, glued_start = n, 0, cand
                                end
                            end
                        end
                    end
                end
                if not num then
                    num, span = _prev_num_words(h.prev_text)
                end
                -- Bare-article "a million miles" is hyperbole, not measurement
                -- ("walked a million miles to get a coffee", "a million miles
                -- an hour/away") — user-approved suppression, 2026-07-06 sweep:
                -- all 7 corpus occurrences were figurative. Only the bare form:
                -- digits ("1,000,000 miles") and real multiples ("two million
                -- miles", "ninety-three million miles") still convert. "half a
                -- million miles" is DELIBERATELY caught too: the composer reads
                -- it as bare million (1e6, 2x the real value), so suppressing
                -- beats emitting a wrong number.
                -- (miles-family covers the speed aliases too: "miles an hour"/
                -- "miles per hour"/"mph" are their own unit hits, not "miles".)
                if num == 1000000
                   and (ulow:match("^miles?%f[%A]") ~= nil or ulow == "mph")
                   and p:match("%f[%a]a%s+million%s*$") then
                    num = nil
                end
                local vlo, vhi, vword, vmult = _detect_vague(h.prev_text)
                -- Vague bands are metric-direction-deferred ("a few hundred
                -- meters" → band) — stage 2 of the imperial direction.
                if num and vlo and vmult == num and conv.factor
                   and not dir_imperial then
                    -- Vague quantified amount ("a few hundred pounds") → convert
                    -- as a metric BAND ("≈ 90–230 kg") rather than a false-precise
                    -- point. Always rounded (vagueness demands it, regardless of
                    -- the Smart Rounding toggle). Flagged _vague so Mode 3 skips it
                    -- — "a few hundred pounds" can't be cleanly rewritten in place.
                    local qstart = extend_start(h.start, num, span, h.prev_text)
                    local qwc = select(2, vword:gsub("%S+", ""))
                    for _ = 1, qwc do
                        local okx, nx = pcall(function() return doc:getPrevVisibleWordStart(qstart) end)
                        if okx and nx and nx ~= qstart then qstart = nx else break end
                    end
                    local full = text_of(qstart, h["end"])
                    if not (full and full:lower():find(vword, 1, true)) then
                        qstart = extend_start(h.start, num, span, h.prev_text)
                        full = text_of(qstart, h["end"]) or (vword .. " " .. h.matched_text)
                    end
                    local lo_m = _nice_round(vlo * num * conv.factor + (conv.offset or 0), _HARSH_TOLERANCE)
                    local hi_m = _nice_round(vhi * num * conv.factor + (conv.offset or 0), _HARSH_TOLERANCE)
                    local band
                    if vlo == vhi then
                        band = _APPROX .. " " .. _fmt_dist(lo_m, conv.target)
                    else
                        if lo_m > hi_m then lo_m, hi_m = hi_m, lo_m end
                        band = _APPROX .. " " .. _fmt_dist_range(lo_m, hi_m, conv.target, _ENDASH)
                    end
                    out[#out + 1] = {
                        start = qstart, ["end"] = h["end"],
                        matched_text = full, prev_text = h.prev_text, next_text = h.next_text,
                        _search = conv, _cat = conv.cat, _vague = true,
                        _converted = _display(full) .. " = " .. band,
                    }
                    seen_end[h["end"]] = true
                elseif num then
                    local rec = {
                        start = glued_start or extend_start(h.start, num, span, h.prev_text),
                        ["end"] = h["end"],
                        prev_text = h.prev_text, next_text = h.next_text,
                        _search = conv, _cat = conv.cat, _unit = unit,
                    }
                    -- Forward compound: "6 foot 4" (height) / "nine stone four".
                    local second, kind, clear_in = _lead_compound(h.next_text)
                    -- An inches component is always < 12 (12+ would be another
                    -- foot). Capping it stops a bare trailing number that isn't
                    -- really inches from being absorbed — e.g. "ten feet, twenty"
                    -- (a metaphor) was read as 10 ft 20 in = 3.56 m; now it stays
                    -- "ten feet". Legit "5 feet, 4 inches" (4 < 12) is untouched.
                    if second and second < 12 and (kind == "bare" or kind == "in_abbr")
                       and (unit == "foot" or unit == "feet") then
                        -- "six foot four" / "five ft. seven in." → feet+inches height.
                        rec._num, rec._num2 = num, second
                        rec["end"] = extend_end(h["end"], second, kind == "in_abbr" and clear_in)
                        -- Range tail: "five foot five or six" → 1.65 or 1.68 m.
                        -- Only for a bare inch, guarded against "or five minutes".
                        -- Keep the connector word so it reads as prose, not "1.65–1.68".
                        local kval, kconn
                        if kind == "bare" then
                            kval, kconn = _inch_range_tail(h.next_text, second)
                        end
                        if kval then
                            local rend = extend_end(rec["end"], kval)
                            if rend ~= rec["end"] then
                                local lo = num * 0.3048 + math.min(second, kval) * 0.0254
                                local hi = num * 0.3048 + math.max(second, kval) * 0.0254
                                local mt = text_of(rec.start, rend) or rec.matched_text
                                rec["end"], rec.matched_text = rend, mt
                                rec._converted = _display(mt) .. " = "
                                    .. _fmt_height(lo) .. " " .. kconn .. " "
                                    .. _fmt_height(hi) .. " m"
                                rec._num, rec._num2, rec._unit = nil, nil, nil
                            end
                        end
                        -- Fractional inch tail: "six feet, one and a half inches"
                        -- → 1.5" (the bare merge above only took the integer "one").
                        -- Only honoured when an "inch(es)" word actually follows the
                        -- fraction, so "six feet, one and a half MILES" isn't read as
                        -- 1.5 inches. Grows the span to cover "<frac> inches" too.
                        if not kval and kind == "bare" and rec._num2 then
                            local nt = (h.next_text or ""):gsub("^[%s,%.%-]+", "")
                            local frac = _frac_tail(nt:gsub("^[%w][%w%.,]*", ""))
                            if frac then
                                local cand, hit_inch = rec["end"], false
                                for _ = 1, 6 do
                                    local okx, nx = pcall(function() return doc:getNextVisibleWordEnd(cand) end)
                                    if not okx or not nx or nx == cand then break end
                                    cand = nx
                                    if (text_of(rec["end"], cand) or ""):lower():match("inch") then
                                        hit_inch = true; break
                                    end
                                end
                                if hit_inch then
                                    rec._num2 = second + frac
                                    rec["end"] = cand
                                end
                            end
                        end
                    elseif second and second < 12 and kind == "in_abbr" and unit == "ft" then
                        -- "5 ft 7 in" — accept the abbreviation only with an
                        -- explicit "in" tail; a bare "5 ft 200" is NOT a height.
                        rec._num, rec._num2 = num, second
                        rec["end"] = extend_end(h["end"], second, clear_in)
                    elseif second and second < 14 and kind == "bare" and unit == "stone" then
                        rec._num, rec._num_stone2 = num, second
                        rec["end"] = extend_end(h["end"], second)
                    end
                    rec.matched_text = text_of(rec.start, rec["end"])
                        or (_fmt(num) .. " " .. h.matched_text)
                    -- "10x10 feet" → "3 × 3 m": NxN dimension, both values
                    -- converted (vs the single-value path that ignored the x10).
                    if not rec._converted and conv.factor and conv.target
                       and not FootFree._IMPERIAL.tags[conv.target] then
                        local nxn = _conv_nxn(rec.matched_text, conv.factor, conv.target)
                        if nxn then
                            rec._converted = _display(rec.matched_text) .. " = " .. nxn
                            rec._unit = nil
                        end
                    end
                    -- "N-foot-by-M-foot" dimension adjective ("a twenty-foot-
                    -- by-hundred-foot rectangle", The Gene) — convert BOTH
                    -- sides ("6 × 30 m"); the single path read only the first
                    -- foot and showed a bare "6 m".
                    if not rec._converted and conv.factor and conv.target then
                        local d1, d2 = rec.matched_text:lower():match(
                            "^(.-)%-f[oe][oe]t%-by%-(.-)%-f[oe][oe]t$")
                        local n1x = d1 and _parse_num(d1)
                        local n2x = d2 and _parse_num(d2)
                        if n1x and n2x then
                            local r1 = _smart_round(n1x * conv.factor, n1x, false, conv.target)
                            local r2 = _smart_round(n2x * conv.factor, n2x, false, conv.target)
                            rec._converted = _display(rec.matched_text) .. " = "
                                .. _fmt(r1) .. " \195\151 " .. _fmt_dist(r2, conv.target)
                            rec._unit = nil
                        end
                    end
                    -- "84 degrees Fahrenheit instead of 86" → a 84–86 range (the
                    -- writer contrasts two temperatures). Scoped to temperature:
                    -- "instead of" is too unusual a connector to treat as a range
                    -- for distances/weights. The forward walk is parse-based so it
                    -- spans a hyphenated spelled second value ("eighty-six").
                    if not rec._converted and conv.cat == "temperature" and conv.factor then
                        local n2t = h.next_text and h.next_text:match("^%s*instead of%s+([%w%-]+)")
                        local n2  = n2t and _parse_num(n2t)
                        if n2 then
                            local rend, cand = nil, rec["end"]
                            for _ = 1, 5 do
                                local okx, nx = pcall(function() return doc:getNextVisibleWordEnd(cand) end)
                                if not okx or not nx or nx == cand then break end
                                cand = nx
                                local t = text_of(rec["end"], cand)
                                if t and _parse_num((t:gsub("^%s*instead of%s*", ""))) == n2 then
                                    rend = cand; break
                                end
                            end
                            if rend then
                                local lo, hi = math.min(num, n2), math.max(num, n2)
                                local rlo = _smart_round(lo * conv.factor + (conv.offset or 0), lo, true, conv.target)
                                local rhi = _smart_round(hi * conv.factor + (conv.offset or 0), hi, true, conv.target)
                                rec["end"]       = rend
                                rec.matched_text = text_of(rec.start, rend) or rec.matched_text
                                rec._converted   = _display(rec.matched_text) .. " = "
                                    .. _fmt_dist_range(rlo, rhi, conv.target, _ENDASH)
                                rec._unit = nil
                            end
                        end
                    end
                    -- Post-unit fractional tail: "two miles and a half" → 2.5.
                    -- Walk the end forward to swallow the tail words, then pin the
                    -- value to num+frac. Skipped if a compound/range already claimed
                    -- the slot, and only for plain factor units (not foot+inch).
                    if not rec._converted and not rec._num2 and not rec._num_stone2
                       and conv.factor then
                        local frac, phrase = _frac_tail(h.next_text)
                        if frac then
                            local rend, cand = nil, rec["end"]
                            for _ = 1, 4 do
                                local okx, nx = pcall(function() return doc:getNextVisibleWordEnd(cand) end)
                                if not okx or not nx or nx == cand then break end
                                cand = nx
                                local t = text_of(rec["end"], cand)
                                if t then
                                    local norm = t:lower():gsub("%-", " "):gsub("^[%s,]+", ""):gsub("%s+$", "")
                                    if norm == phrase then rend = cand; break end
                                end
                            end
                            if rend then
                                local val = num + frac
                                rec["end"] = rend
                                rec.matched_text = text_of(rec.start, rend) or rec.matched_text
                                rec._num = val
                                rec._converted = _value_converted(_display(rec.matched_text), val, conv, unit)
                                seen_end[rend] = true
                            end
                        end
                    end
                    -- Forward "or M" range tail with no repeated unit: "one mile
                    -- or two" → 1–2. (The article form "a mile or two" is handled
                    -- in the article branch.) Distance/length only, to avoid
                    -- re-reading weight/temperature "or" as a range here.
                    if not rec._converted and not rec._num2 and not rec._num_stone2
                       and conv.factor and conv.cat == "length" then
                        local m, conn = _distance_or_tail(h.next_text)
                        if m and m ~= num then
                            local rend, cand = nil, rec["end"]
                            for _ = 1, 3 do
                                local okx, nx = pcall(function() return doc:getNextVisibleWordEnd(cand) end)
                                if not okx or not nx or nx == cand then break end
                                cand = nx
                                local t = text_of(rec["end"], cand)
                                if t and _parse_num((t:gsub("^[%s,]+", ""):gsub("^%a+%s+", ""))) == m then
                                    rend = cand; break
                                end
                            end
                            if rend then
                                local full2 = text_of(rec.start, rend) or rec.matched_text
                                local lo, hi = math.min(num, m), math.max(num, m)
                                local r1 = lo * conv.factor + (conv.offset or 0)
                                local r2 = hi * conv.factor + (conv.offset or 0)
                                rec["end"], rec.matched_text = rend, full2
                                rec._num, rec._unit = nil, nil
                                rec._converted = _display(full2) .. " = "
                                    .. _fmt_dist_range(_smart_round(r1, nil, true, conv.target),
                                                       _smart_round(r2, nil, true, conv.target),
                                                       conv.target, " " .. conn .. " ")
                                seen_end[rend] = true
                            end
                        end
                    end
                    -- Forward "by M" dimension tail: "twenty feet by ten" →
                    -- "6 × 3 m" (both axes share the unit; second number is bare).
                    if not rec._converted and not rec._num2 and not rec._num_stone2
                       and conv.factor and conv.cat == "length" then
                        local m2, phrase = _dim_by_tail(h.next_text)
                        if m2 then
                            local rend, cand = nil, rec["end"]
                            for _ = 1, 3 do
                                local okx, nx = pcall(function() return doc:getNextVisibleWordEnd(cand) end)
                                if not okx or not nx or nx == cand then break end
                                cand = nx
                                local t = text_of(rec["end"], cand)
                                if t then
                                    local norm = t:lower():gsub("^[%s,]+", ""):gsub("%s+$", "")
                                    if norm == phrase then rend = cand; break end
                                end
                            end
                            if rend then
                                local full2 = text_of(rec.start, rend) or rec.matched_text
                                local ra = _smart_round(num * conv.factor, num, false, conv.target)
                                local rb = _smart_round(m2 * conv.factor, m2, false, conv.target)
                                rec["end"], rec.matched_text = rend, full2
                                rec._num, rec._unit = nil, nil
                                rec._converted = _display(full2) .. " = "
                                    .. _fmt(ra) .. " \195\151 " .. _fmt_dist(rb, conv.target)
                                seen_end[rend] = true
                            end
                        end
                    end
                    -- "not two miles away" — a negation directly before the number
                    -- marks the distance as vague/approximate, so round the
                    -- converted value to a whole number in its display unit
                    -- (3.2 km → 3 km). Plain single length values only, and only
                    -- when Smart Rounding is on (exact mode stays exact).
                    if not rec._converted and not rec._num2 and not rec._num_oz
                       and not rec._num_stone2 and conv.factor and conv.cat == "length"
                       and _smart_rounding_enabled() and _word_before_number(p) == "not" then
                        local v = num * conv.factor + (conv.offset or 0)
                        rec._converted = _display(rec.matched_text) .. " = "
                            .. _round_whole_dist(v, num, conv.target)
                        rec._unit = nil
                    end
                    -- If matched_text's own _parse_num would disagree with the
                    -- value we computed (e.g. additive "four and a half" parses
                    -- as just 4), pin the conversion to the right value.
                    if not rec._num2 and not rec._num_stone2 and not rec._num_oz
                       and not rec._converted
                       and _parse_num(rec.matched_text) ~= num then
                        rec._converted = _value_converted(_display(rec.matched_text), num, conv, unit)
                    end
                    -- "1,800 lbs." / "18 lb." — pull a trailing abbreviation
                    -- period into the span (cleaner Mode-3 rewrite + underline).
                    -- Skip a sentence-ending period (". " + a capital), which is
                    -- punctuation, not part of the "lbs." abbreviation.
                    if (unit == "lb" or unit == "lbs")
                       and (h.next_text or ""):match("^%.")
                       and not (h.next_text or ""):match("^%.%s+%u") then
                        local pfx, off = _xpointer_offset(rec["end"])
                        if pfx ~= rec["end"] then
                            local cand = pfx .. tostring(off + 1)
                            if text_of(rec["end"], cand) == "." then
                                rec.matched_text = (text_of(rec.start, cand) or rec.matched_text)
                                rec["end"] = cand
                            end
                        end
                    end
                    seen_end[rec["end"]] = true
                    out[#out + 1] = rec
                elseif conv.factor and (_article_distance_one(unit, h.prev_text, h.next_text)
                       or (_ART_DIST_UNITS[unit] and _frac_tail(h.next_text))) then
                    -- "a/an <distance-unit>" → value 1, either with a spatial cue
                    -- ("a mile away") OR a post-unit fraction ("a mile and a half"
                    -- = 1.5), which is itself a measurement even with no separate
                    -- cue. Extend the start back to swallow the article; accept
                    -- only if the span really begins with "a "/"an ".
                    local astart = h.start
                    local nx = _prevword(h.start)
                    if nx then astart = nx end
                    local full = text_of(astart, h["end"])
                    if full and full:lower():match("^an?%s") then
                        local rec = {
                            start = astart, ["end"] = h["end"],
                            prev_text = h.prev_text, next_text = h.next_text,
                            _search = conv, _cat = conv.cat, _unit = unit, _num = 1,
                            matched_text = full,
                            _converted = _value_converted(_display(full), 1, conv, unit),
                        }
                        -- "a mile and a half" → 1 + fraction. Walk the end forward
                        -- over the "and a half" tail and pin the value.
                        local frac, phrase = _frac_tail(h.next_text)
                        if frac then
                            local rend, cand = nil, h["end"]
                            for _ = 1, 4 do
                                local nx2 = _nextword(cand)
                                if not nx2 or nx2 == cand then break end
                                cand = nx2
                                local t = text_of(h["end"], cand)
                                if t then
                                    local norm = t:lower():gsub("%-", " "):gsub("^[%s,]+", ""):gsub("%s+$", "")
                                    if norm == phrase then rend = cand; break end
                                end
                            end
                            if rend then
                                local full2 = text_of(astart, rend) or full
                                rec["end"], rec.matched_text = rend, full2
                                rec._num = 1 + frac
                                rec._converted = _value_converted(_display(full2), 1 + frac, conv, unit)
                            end
                        end
                        -- "a mile or two" → range 1–M. Walk the end forward over
                        -- the "or two" tail and render as a prose range. (Capture
                        -- BOTH returns with a plain if — the `a and f() or nil`
                        -- idiom truncates f()'s 2nd value, leaving conn nil and
                        -- crashing the "<conn>" concatenation below.)
                        local m, conn
                        if not frac then m, conn = _distance_or_tail(h.next_text) end
                        if m and m > 1 then
                            local rend, cand = nil, h["end"]
                            for _ = 1, 3 do
                                local nx = _nextword(cand)
                                if not nx or nx == cand then break end
                                cand = nx
                                local t = text_of(h["end"], cand)
                                if t and _parse_num((t:gsub("^[%s,]+", ""):gsub("^%a+%s+", ""))) == m then
                                    rend = cand; break
                                end
                            end
                            if rend then
                                local full2 = text_of(astart, rend) or full
                                local r1 = 1 * conv.factor + (conv.offset or 0)
                                local r2 = m * conv.factor + (conv.offset or 0)
                                rec["end"], rec.matched_text = rend, full2
                                rec._num, rec._unit = nil, nil
                                rec._converted = _display(full2) .. " = "
                                    .. _fmt_dist_range(_smart_round(r1, nil, true, conv.target),
                                                       _smart_round(r2, nil, true, conv.target),
                                                       conv.target, " " .. conn .. " ")
                            end
                        end
                        out[#out + 1] = rec
                        seen_end[rec["end"]] = true
                    end
                end
            end
        end
    end


    FootFree._scan_t.loop = _now() - _tL0
    local _tP0 = _now()

    _report(1)  -- per-hit loop done; the prime/°F tail below is the last sliver

    -- Prime notation — skip these extra passes ONLY when we can positively
    -- confirm the book has no prime/apostrophe-inch notation. The gate text is
    -- read via getPageXPointer, which can fail in the forked subprocess (paging
    -- not resolved) even though findAllText works fine — so if bt is
    -- unavailable, run the passes rather than silently dropping primes.
    -- The gate read below is a whole-book getTextFromXPointers over every page.
    -- On an ordinary book it is free (measured: 0.02s on a 366k-word novel).
    -- On a SOFT-HYPHEN book it costs 160 SECONDS — 98% of the entire scan, and
    -- in the measured case it gated nothing at all: zero literal passes ran
    -- afterwards. Two and a half minutes of work to decide to skip work.
    -- (Lonesome Dove + an 82k-soft-hyphen twin of itself, 2026-08-17.)
    -- So shy books skip the gate and take the SAME branch as a gate that fails
    -- to read: run the literal passes unconditionally. That is deliberately the
    -- conservative direction — the passes are what FIND prime and °F notation,
    -- so a wrong "skip" is silent lost coverage, while a wrong "run" only costs
    -- a few extra passes. Deriving the answer from the raw EPUB instead was the
    -- alternative and was rejected: entity forms (&#8242;) and markup between a
    -- digit and its prime mark ("6<span>'</span>") make a raw-text probe prone
    -- to exactly that silent false negative.
    local _tG0 = _now()
    local ok_t, bt
    local probe   -- raw-file answer, shy books only (see below)
    if not shy_book then
        ok_t, bt = pcall(function()
            return doc:getTextFromXPointers(doc:getPageXPointer(1),
                                            doc:getPageXPointer(doc:getPageCount()))
        end)
    else
        -- Shy books can't use the crengine read above (160s), and running every
        -- pass regardless costs ~14s on a book that usually needs none — 73% of
        -- a 45-book corpus contain no height shorthand and no °F at all. So ask
        -- the raw file instead, which metric_epub is already opening for the
        -- soft-hyphen check. Any failure inside probe_notation answers "yes to
        -- everything", so this can only ever cost passes, never lose coverage.
        local mod = _metric_module()
        if mod and mod.probe_notation then
            local okp, res = pcall(mod.probe_notation, doc.file or "")
            probe = (okp and res) or nil
        end
    end
    FootFree._scan_t.gate = _now() - _tG0
    -- `probe` is set for shy books only (raw-file answer); `bt` for every other
    -- book (crengine rendered text). If neither is available, say yes — running
    -- a pass costs time, skipping one loses conversions silently.
    local maybe_primes
    if probe then
        maybe_primes = probe.prime
    else
        maybe_primes = (not ok_t) or (not bt)
            or bt:find(_PRIME, 1, true) or bt:find(_DPRIME, 1, true)
            or bt:find("%d'") or bt:find('%d"')
            or bt:find("%d" .. FootFree._CAPOS) or bt:find("%d" .. FootFree._CDQ)
    end
    -- Literal-match passes (primes, °F): run longest-first, deduped by start AND
    -- end xpointer so a range claims its span before the single-value pass can
    -- re-match an endpoint. seen_end is shared with the main unit loop above.
    local seen_start = {}
    -- ONE findAllText per group, not one per pattern.
    --
    -- A pass costs a full walk of the document whether or not it matches
    -- anything: measured on a 1MB novel, the two prime patterns that found
    -- NOTHING still cost 1.54s each — the same as the two that found hits. So
    -- four patterns cost four walks (6.25s) where the same four as one
    -- alternation cost one (1.56s), for a hit set proven identical. On a Kobo
    -- this phase was 66.7s of an 87s scan (device log, 2026-08-17).
    --
    -- Every entry in a group shares a leading number pattern, so the group
    -- factors cleanly into `pre(suf1|suf2|…)`. Alternation is leftmost-first and
    -- the entries stay ordered longest-first, which is what preserves the old
    -- precedence — the compound "6′8″" form still claims its span before the
    -- bare-feet form sees it. Each hit is then mapped back to its entry by the
    -- group's `classify`, because everything downstream (the converter, the
    -- factor, the currency veto) is per-entry.
    local function run_passes(group)
        -- The category filter lives here rather than at the call sites: a
        -- filtered COPY of the list would renumber it, and classify() returns
        -- an index into the group as written. (This also gives the prime group
        -- a category check it never had — its patterns are all "length", so
        -- unticking Length now skips them, which it should always have done.
        -- No effect on the default, where every category is on.)
        local sufs, enabled = {}, {}
        for i, e in ipairs(group) do
            if cat_enabled[e.cat] ~= false then
                sufs[#sufs + 1] = e.suf
                enabled[i] = true
            end
        end
        if #sufs == 0 then return end
        -- Collect (hit, entry) pairs, then run the guard chain over them.
        local hits = {}
        FootFree._scan_t.litn = FootFree._scan_t.litn + 1
        local pat = group.pre .. "(" .. table.concat(sufs, "|") .. ")"
        local okp, pres = pcall(function()
            return doc:findAllText(pat, true, 5, 2000, true)
        end)
        for _, r in ipairs((okp and pres) or {}) do
            -- Which pattern did this hit come from? A hit we cannot place is
            -- DROPPED, not guessed: picking the wrong entry picks the wrong
            -- conversion factor, and a silently wrong number in someone's book
            -- is worse than a miss. The classifiers are covered by headless
            -- tests, so this should never fire.
            local idx = group.classify and group.classify(r.matched_text or "")
            local e = idx and enabled[idx] and group[idx]
            if e then
                hits[#hits + 1] = { r = r, e = e }
            else
                logger.warn("FootFree: unclassified literal hit "
                            .. tostring(r.matched_text))
            end
        end
        do
            do
                for _, h in ipairs(hits) do
                    local r, e = h.r, h.e
                    if not seen_end[r["end"]] then
                        -- Second half of the boundary rule that used to live in
                        -- the pattern itself (see _ND). The old leading [^0-9,]
                        -- required a character to EXIST before the number, so a
                        -- match starting a text node could never happen.
                        -- Reproduce that rather than quietly widening coverage:
                        -- the one such hit in the corpus was a Library of
                        -- Congress call number on a copyright page
                        -- ("F2546.G747 2008 918.1′" → 280 m), a false positive,
                        -- and whether to start matching there is a coverage
                        -- decision, not a performance one.
                        --
                        -- It CLAIMS the span rather than just skipping. Dropping
                        -- it outright freed the sub-match one character to the
                        -- right — the node "918.1′—dc22" then yielded "18.1′"
                        -- (5.5 m), which the old pattern rejected because a
                        -- digit sat to its left. Claiming is also what blocks
                        -- every other digit-left sub-match: "1950′" and "950′"
                        -- share an end xpointer, and document order delivers the
                        -- longest first, so this needs no document read at all.
                        if group.needs_left_char
                           and select(2, _xpointer_offset(r.start or "")) <= 0 then
                            seen_start[r.start] = true
                            seen_end[r["end"]] = true
                        -- Headings (h1–h6: chapter/book titles) are never converted.
                        elseif (r.start or ""):find("/h[1-6][%[/]") then
                            seen_start[r.start] = true
                            seen_end[r["end"]] = true
                        -- A lat/long coordinate prime (′ arcminute / ″ arcsecond)
                        -- is not feet/inches, and neither is a closing quotation
                        -- mark, a call number or an apostrophe — claim the span so
                        -- no pass converts it.
                        --
                        -- Both checks want the same thing, the match's own
                        -- paragraph up to the number, so they share one read of it.
                        -- crengine's prev_text is five words (~45 characters),
                        -- which is too short for either: the giveaway noun of a
                        -- dictionary entry sits twenty words back ("ABERRATION. In
                        -- astronomy, … the progressive motion of light, is
                        -- established 20″"), and so does the opening quote of
                        -- "'around 50,000'".
                        elseif e.cat == "length" and (function()
                            local prime_fp = FootFree._prime_fp_reason
                            local mtx = r.matched_text or ""
                            if _is_coordinate(r.prev_text, r.next_text) then return true end

                            local wide
                            local elem = (r.start or ""):match("^(.*)/text%(%)")
                            if elem then
                                local okw, w = pcall(function()
                                    return doc:getTextFromXPointers(elem, r.start)
                                end)
                                if okw and w then
                                    wide = #w > 400 and w:sub(-400) or w
                                    if _is_coordinate(wide, r.next_text) then return true end
                                end
                            end

                            -- The real characters after the mark. crengine's
                            -- next_text is no use for ANY of this: it skips the
                            -- adjacent word (for "6' wide" it starts " and hard
                            -- to reach"), and it swallows the letter of "86'd"
                            -- and the ".92" of "823'.92". Only a document read
                            -- sees them. Widths are tried longest-first because
                            -- the match can sit near the end of its text node,
                            -- where the wider read has nothing to return.
                            local after = ""
                            local pfx, off = _xpointer_offset(r["end"] or "")
                            if pfx ~= r["end"] and off then
                                for _, w in ipairs({ 24, 12, 4, 2 }) do
                                    local okc, c = pcall(function()
                                        return doc:getTextFromXPointers(
                                            r["end"], pfx .. tostring(off + w))
                                    end)
                                    if okc and c and c ~= "" then after = c; break end
                                end
                            end

                            local why = prime_fp(mtx, wide or r.prev_text, after)
                            if why then
                                logger.dbg("FootFree: dropped prime "
                                           .. mtx .. " — " .. why)
                                return true
                            end
                            return false
                        end)() then
                            seen_start[r.start] = true
                            seen_end[r["end"]] = true
                        -- Currency veto ("$50 m" = fifty million dollars, not
                        -- fifty meters). The symbol often shares the hit's own
                        -- WORD with the digits, hiding it from the word-based
                        -- prev_text — so also read the raw characters just
                        -- before the hit (same trick as the glued-number
                        -- fallback in the main loop).
                        elseif e.money and (function()
                            local pv = r.prev_text or ""
                            if pv:match("%$%s*$") or pv:match("£%s*$")
                               or pv:match("€%s*$") then return true end
                            local pfx, off = _xpointer_offset(r.start)
                            if pfx ~= r.start and off and off > 0 then
                                local okr, pre = pcall(function()
                                    return doc:getTextFromXPointers(
                                        pfx .. tostring(math.max(0, off - 4)), r.start)
                                end)
                                if okr and pre and (pre:match("%$%s*$")
                                   or pre:match("£%s*$") or pre:match("€%s*$")) then
                                    return true
                                end
                            end
                            return false
                        end)() then
                            seen_start[r.start] = true
                            seen_end[r["end"]] = true
                        elseif not seen_start[r.start] then
                            seen_start[r.start] = true
                            seen_end[r["end"]] = true
                            r._search = e
                            r._cat = e.cat
                            out[#out + 1] = r
                        else
                            seen_end[r["end"]] = true  -- block tail sub-matches
                        end
                    end
                end
            end
        end
    end

    -- Literal passes are direction-specific: primes and °F are imperial
    -- SOURCE notations; °C is the metric-direction twin.
    if dir_imperial then
        local has_degc = (cat_enabled["temperature"] ~= false)
            and (probe and probe.degc
                 or (not probe and ((not ok_t) or (not bt)
                     or bt:find(FootFree._IMPERIAL.degc, 1, true) ~= nil)))
        if has_degc then run_passes(FootFree._IMPERIAL.temp_pats) end
        -- Single-letter aliases ("1.8m", "500g") — see unit_pats for why
        -- these can't ride in the main alternation. run_passes does the
        -- category filtering itself now (a filtered copy would renumber the
        -- group and break classify's index).
        run_passes(FootFree._IMPERIAL.unit_pats)
    else
        if maybe_primes then run_passes(_PRIME_PATS) end

        local has_degf = (cat_enabled["temperature"] ~= false)
            and (probe and probe.degf
                 or (not probe and ((not ok_t) or (not bt)
                     or bt:find(_DEGF, 1, true) ~= nil)))
        if has_degf then run_passes(_TEMP_PATS) end
    end

    -- Drop overlapping spans. The main loop only deduped by END xpointer
    -- (seen_end), so a compound height that didn't merge — e.g. a "foot" hit
    -- ("six-foot") plus the orphaned "inch" hit ("six-foot-five-inch") that
    -- shares its start, or a "feet, one" compound plus an overlapping "one and a
    -- half inches" — left two partially-overlapping matches. This collapses each
    -- such pair to a single match (longest span at a shared start wins, which is
    -- the foot-anchored compound), the same interval filter the reverse path uses.
    -- `lit` deliberately includes the whole-book getTextFromXPointers read that
    -- gates these passes — that read exists only to decide whether to run them,
    -- so its cost belongs to them.
    FootFree._scan_t.lit = _now() - _tP0
    return out
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function FootFree:init()
    self._cat_enabled = {}
    for _, cat in ipairs({"length", "weight", "temperature", "volume", "speed", "area"}) do
        local v = G_reader_settings:readSetting("footcream_cat_" .. cat)
        self._cat_enabled[cat] = (v ~= false)
    end
    self._auto_scan         = G_reader_settings:readSetting("footcream_auto_scan") == true
    -- Developer mode (hidden from users via a marker file). Drives the scan
    -- report; future dev-only tooling can gate on self._dev_mode too.
    self._dev_mode          = _dev_mode_enabled()
    self._debug_report      = self._dev_mode
    self._scanned           = false  -- set true once a scan/sidecar-load completes (6.1)
    self._tap_mode          = G_reader_settings:readSetting("footcream_tap_mode") or 1
    -- _enabled is PER-BOOK ("Enable Footcream in this book"): loaded from the
    -- book's doc_settings in onReaderReady, default true. It is independent
    -- of the conversion mode: switching modes (or reverting/removing a
    -- book's data) must never silently flip it. The old GLOBAL
    -- footcream_enabled setting is retired (it meant "global" in mode 1 but
    -- "this book" in modes 2/3 — user-flagged as confusing 2026-07-14);
    -- clean up the stale key so nothing resurrects it.
    self._enabled = true
    G_reader_settings:delSetting("footcream_enabled")
    -- Distinguish pounds (weight vs £) and UK volumes are always on — their
    -- menu toggles were removed to slim the plugin down.
    self._distinguish_pounds= true
    self._uk_volumes        = true
    -- Smart Rounding of Converted Units: default ON (nil treated as true)
    self._smart_rounding    = _smart_rounding_enabled()
    -- Show unit icon in tooltip: default ON (nil treated as true)
    local show_icon = G_reader_settings:readSetting("footcream_show_icon")
    self._show_icon         = (show_icon ~= false)
    -- Tooltip size: small / medium / large. Default "large" (the original look,
    -- so existing users see no change). Validated against the presets table.
    self._tooltip_size      = G_reader_settings:readSetting("footcream_tooltip_size") or "large"
    if not FootFree._TOOLTIP_SIZES[self._tooltip_size] then self._tooltip_size = "large" end
    -- Underline styling: solid/wavy, 10/20/30/40% grey, Thin/Thick (1px/2px)
    self._underline_style   = G_reader_settings:readSetting("footcream_underline_style") or "solid"
    if self._underline_style == "dotted" then self._underline_style = "solid" end
    self._underline_color   = G_reader_settings:readSetting("footcream_underline_color") or 20
    -- Migrate stale 5%/25% (removed/renumbered options) to the nearest new value.
    if self._underline_color == 5 then self._underline_color = 10
    elseif self._underline_color == 25 then self._underline_color = 20
    elseif not ({ [10]=true, [20]=true, [30]=true, [40]=true })[self._underline_color] then
        self._underline_color = 20
    end
    self._underline_width   = G_reader_settings:readSetting("footcream_underline_width") or 2
    -- Migrate stale 3px/4px (removed options) to "Thick" (2).
    if self._underline_width == 3 or self._underline_width == 4 then
        self._underline_width = 2
    end
    -- Show original units (tooltip) for converted values in "Convert directly
    -- in the text" mode: default OFF.
    self._show_original     = G_reader_settings:readSetting("footcream_show_original") == true
    self._share_reports     = G_reader_settings:readSetting("footcream_share_reports") == true
    self.ui.menu:registerToMainMenu(self)
end

-- ── Scan ─────────────────────────────────────────────────────────────────────

function FootFree:onReaderReady()
    -- A mode change from the picker can convert/revert the book, which
    -- reloads the document and replaces this plugin instance — close any
    -- picker left open by the previous instance (its rows point at dead
    -- state). Class attribute for exactly that reason.
    if FootFree._mode_overlay then
        UIManager:close(FootFree._mode_overlay)
        FootFree._mode_overlay = nil
    end
    local doc = self.ui.document
    if not doc or not doc.file then return end

    -- Footcream only works on reflowable crengine documents (EPUB & co.).
    -- Paged formats (PDF/DjVu via mupdf) lack the whole API this plugin is
    -- built on — findAllText, xpointers, getCurrentPage — so the paintTo
    -- wrapper's doc:getCurrentPage() call crashed the entire reader on the
    -- first repaint after opening a PDF. Bail before hooking anything; the
    -- flag also disables the scan menu entries for this document.
    if type(doc.getCurrentPage) ~= "function" or type(doc.findAllText) ~= "function" then
        self._doc_unsupported = true
        logger.info("FootFree: unsupported document type (not crengine) — plugin inactive for " .. doc.file)
        return
    end
    self._doc_unsupported = nil

    -- Wrap paintTo and tap up front so the view is ready whenever highlights arrive.
    if not self._paintTo_wrapped then
        local orig   = self.view.paintTo
        local plugin = self
        self.view.paintTo = function(view_self, bb, x, y)
            -- Detect page turns so the background scan can pause gracefully
            local cur = doc:getCurrentPage()
            if plugin._scan_last_page and plugin._scan_last_page ~= cur then
                plugin._page_just_turned = true
            end
            plugin._scan_last_page = cur
            orig(view_self, bb, x, y)
            local ok, err = pcall(function() plugin:_drawHighlights(bb) end)
            if not ok then logger.warn("FootFree: draw error: " .. tostring(err)) end
        end
        self._paintTo_wrapped = true
    end

    local hl = self.ui.highlight
    if hl and not self._tap_wrapped then
        local orig_tap = hl.onTap
        local plugin   = self
        hl.onTap = function(hl_self, _, ges)
            if ges and plugin:_handleTap(ges) then return true end
            if orig_tap then return orig_tap(hl_self, _, ges) end
        end
        self._tap_wrapped = true
    end
    -- Long-press on an underline → flag dialog (_handleHold). Falls through
    -- to KOReader's own hold handling (text selection, dictionary) whenever
    -- the hold is NOT on one of our underlines.
    if hl and not self._hold_wrapped then
        local orig_hold = hl.onHold
        local plugin    = self
        hl.onHold = function(hl_self, _, ges)
            if ges and plugin:_handleHold(ges) then return true end
            if orig_hold then return orig_hold(hl_self, _, ges) end
        end
        self._hold_wrapped = true
    end
    -- "⚑ Flag to Footcream" in KOReader's text-selection menu (the dialog
    -- that already hosts Dictionary / Translate / Highlight). The only flag
    -- path that can report a unit the scanner missed entirely — the reader
    -- selects the missed text themselves. "13_" sorts it after the built-in
    -- "12_search", i.e. last in the menu.
    if hl and hl.addToHighlightDialog and not self._sel_flag_added then
        local plugin = self
        hl:addToHighlightDialog("13_footcream_flag", function(this)
            return {
                -- TRANSLATORS: Entry Footcream adds to KOReader's own text-selection popup (the
                -- menu you get after highlighting text). Tapping it opens Footcream's
                -- error-reporting dialog for the selected words. The flag is a symbol, keep it.
                text = _("⚑ Flag to Footcream"),
                -- Same gate as hold-to-flag: only offered once the user has
                -- opted into sending errors to the developer.
                show_in_highlight_dialog_func = function()
                    return plugin._share_reports == true
                end,
                callback = function()
                    local sel = this.selected_text
                    local item = sel and sel.text and sel.text ~= ""
                        and plugin:_flagItemFromSelection(sel) or nil
                    this:onClose()
                    if item then plugin:_showFlagDialog(item, "selection") end
                end,
            }
        end)
        self._sel_flag_added = true
    end

    -- ── Recover from inconsistent leftover states before loading anything ────
    -- Orphaned conversion record: the record stores the converted epub's byte
    -- size, and a different on-disk size means the FILE WAS REPLACED since the
    -- conversion (re-download, sync, regenerated test book). The book is not
    -- actually converted — treating it as metric here would hide underlines,
    -- and any revert/refresh path would splice the old backup into an
    -- unrelated file. Drop the record and continue as an ordinary book.
    if _is_metric_mode(doc.file) then
        local Metric = _metric_module()
        if Metric and Metric.record_matches_file
           and not Metric.record_matches_file(doc.file, _patches_path(doc.file)) then
            logger.warn("FootFree: conversion record is for a replaced file — clearing it")
            local rec = _patches_path(doc.file)
            os.remove(rec .. ".orig")
            os.remove(rec .. ".inprogress")
            os.remove(rec)
            os.remove(_reverse_path(doc.file))
            os.remove(_metric_ver_path(doc.file))
            self._reverse_matches = nil
            if _pending_rescan == doc.file then _pending_rescan = nil end
            if FootFree._pending_reapply == doc.file then FootFree._pending_reapply = nil end
        end
    end
    -- An "apply in progress" marker means a previous conversion was interrupted
    -- (process killed mid-write), so the book may be half-converted. Restore
    -- the original text from the saved backup before doing anything else.
    local marker = _patches_path(doc.file) .. ".inprogress"
    local mfh = io.open(marker)
    if mfh then
        mfh:close()
        logger.warn("FootFree: interrupted apply detected — auto-reverting")
        UIManager:scheduleIn(0.2, function() self:_revertMetricEdition(doc) end)
        return
    end

    -- Per-book opt-out ("Enable Footcream in this book" unchecked, stored in
    -- the book's own metadata): no scanning, loading, prompting or drawing
    -- for this book. Placed after the recovery blocks above (safety-critical
    -- regardless) — and a disabled book that is somehow still converted
    -- (e.g. a dismissed revert) gets its original text back first.
    self._enabled = self.ui.doc_settings:readSetting("footcream_disabled") ~= true
    if not self._enabled then
        if _is_metric_mode(doc.file) then
            logger.info("FootFree: disabled in this book but converted — reverting")
            UIManager:scheduleIn(0.2, function() self:_revertMetricEdition(doc) end)
            return
        end
        logger.info("FootFree: disabled in this book — skipping")
        self._all_matches   = nil
        self._current_boxes = {}
        self._scanned       = false
        return
    end

    -- Book is converted, but in a different mode than the active one — an
    -- inconsistent leftover (e.g. mode changed while a different book was
    -- open). Mode 1 must not draw imperial-position highlights over converted
    -- text, and mode 2's appended text differs from mode 3's replaced text —
    -- so restore the original for consistency. If the active mode is itself a
    -- convert mode (2⇄3 switch), queue the re-apply in the new style: the
    -- _pending_rescan flow reverts → rescans → applies with the current mode.
    if _is_metric_mode(doc.file) then
        local _, _, amode, adir = _read_metric_version(doc.file)
        amode = amode or 3        -- pre-stamp conversions were always mode 3
        adir  = adir or "metric"  -- pre-stamp conversions were always metric
        if self._tap_mode ~= amode then
            logger.info("FootFree: converted book opened in a different mode — reverting for consistency")
            if self._tap_mode >= 2 then FootFree._pending_reapply = doc.file end
            UIManager:scheduleIn(0.2, function() self:_revertMetricEdition(doc) end)
            return
        end
        -- Same for the direction: the baked-in text is for another preferred
        -- system (us vs uk count too — stones, imperial pints). Revert, then
        -- re-apply in the active direction: the preserved sidecar fails the
        -- direction check on reload, so the reapply leg falls back to a
        -- fresh scan before converting.
        if FootFree._IMPERIAL.preferred() ~= adir then
            logger.info("FootFree: converted book's direction is " .. adir
                        .. ", preference is " .. FootFree._IMPERIAL.preferred()
                        .. " — reverting to reconvert")
            FootFree._pending_reapply = doc.file
            UIManager:scheduleIn(0.2, function() self:_revertMetricEdition(doc) end)
            return
        end
    end

    -- "Rescan book" on a converted book reverted it; now that the restored text
    -- is loaded, rescan it and re-apply the conversion (so it stays converted
    -- with fresh data). Driven here, not from a post-revert timer, because the
    -- reload recreated the reader UI.
    if _pending_rescan == doc.file then
        _pending_rescan = nil
        logger.info("FootFree: post-revert rescan+reconvert leg starting")
        os.remove(_sidecar_path(doc.file))
        self._after_scan = function()
            local d2 = self.ui.document
            if d2 then self:_applyMetricEdition(d2, true) end
        end
        self:_startScan(doc)
        return
    end

    -- Mode switch (2⇄3, or the different-mode consistency revert): the revert
    -- restored the original text byte-for-byte AND revalidated the preserved
    -- original-text sidecar, so re-apply straight from it — no rescan. Falls
    -- back to the fresh-scan path when the sidecar didn't survive (deleted,
    -- or written by a different scanner version).
    if FootFree._pending_reapply == doc.file then
        FootFree._pending_reapply = nil
        local raw2 = _load_sidecar_raw(doc.file)
        if raw2 then
            local use_uk = self._uk_volumes and _is_uk_book(doc)
            local applied = _apply_settings_to_matches(raw2, self._distinguish_pounds, use_uk)
            self._all_matches   = #applied > 0 and applied or nil
            self._current_boxes = {}
            self._scanned       = true
        end
        if self._all_matches then
            logger.info("FootFree: mode switch — re-applying from preserved scan ("
                        .. #self._all_matches .. " matches)")
            UIManager:scheduleIn(0.3, function()
                local d2 = self.ui.document
                if d2 then self:_applyMetricEdition(d2, true) end
            end)
        else
            os.remove(_sidecar_path(doc.file))
            self._after_scan = function()
                local d2 = self.ui.document
                if d2 then self:_applyMetricEdition(d2, true) end
            end
            self:_startScan(doc)
        end
        return
    end

    -- A converted (mode-3) book whose in-text conversion was produced by an older
    -- scanner. The matching/idiom logic improves over releases, but the metric
    -- text baked into the EPUB is frozen — so those improvements would otherwise
    -- never reach already-converted books (the worry that prompted this). The
    -- conversion is stamped with the CACHE_VERSION that made it; a lower (or
    -- absent) stamp means it's stale. With auto-scan on we refresh it
    -- automatically (revert → rescan → reconvert); otherwise we offer to. Guarded
    -- per-session so a failed/declined refresh doesn't re-fire on the same open.
    -- (If we reached here in metric mode, tap_mode is already 3 — the ~= 3 case
    -- reverted and returned above.)
    if _is_metric_mode(doc.file) then
        self._metric_update_tried = self._metric_update_tried or {}
        local stamped = _read_metric_version(doc.file)
        if (not stamped or stamped < CACHE_VERSION)
           and not self._metric_update_tried[doc.file] then
            -- ONLY with auto-convert on. Refreshing means reverting the book
            -- and rewriting its text again — a large, unrequested edit to the
            -- reader's own file, triggered by an internal version number they
            -- cannot see. "Auto-convert when opening a new book" is precisely
            -- the standing consent for rewriting without asking, so it is the
            -- right and only gate (user decision, 2026-08-19).
            --
            -- Without it the book keeps its older conversions indefinitely, and
            -- that is fine: "Rescan book" refreshes on demand. Prompting on
            -- open was the previous behaviour and it asked a question the
            -- reader had no way to evaluate, mid-way into opening a book.
            if not (self._auto_scan and _is_english(doc)) then
                logger.info("FootFree: conversions are from scanner "
                            .. tostring(stamped or "?") .. " (now " .. CACHE_VERSION
                            .. ") — leaving them alone; auto-convert is off")
            else
                self._metric_update_tried[doc.file] = true
                logger.info("FootFree: refreshing conversions from scanner "
                            .. tostring(stamped or "?") .. " -> " .. CACHE_VERSION)
                UIManager:show(Notification:new{
                    -- TRANSLATORS: Toast shown when a book was converted by an older Footcream and the
                    -- new version is silently redoing the conversion (auto-scan on).
                    text = _("Footcream improved — updating this book's conversions…"),
                })
                UIManager:scheduleIn(0.2, function()
                    _pending_rescan = doc.file
                    self:_revertMetricEdition(doc)
                end)
                return
            end
        end
    end

    -- ── Load sidecar or wait for user to trigger scan ─────────────────────────
    logger.info(string.format(
        "FootFree: onReaderReady — tap_mode=%d enabled=%s metric_mode=%s lang=%s",
        self._tap_mode, tostring(self._enabled),
        tostring(_is_metric_mode(doc.file)), _get_book_lang(doc)))
    local raw = _load_sidecar_raw(doc.file)
    if raw then
        logger.info("FootFree: loaded " .. #raw .. " match(es) from sidecar")
        local use_uk = self._uk_volumes and _is_uk_book(doc)
        local applied = _apply_settings_to_matches(raw, self._distinguish_pounds, use_uk)
        self._all_matches   = #applied > 0 and applied or nil
        self._current_boxes = {}
        -- The book has been scanned (even if it yielded zero matches). This
        -- distinguishes "scanned, no imperial units" from "never scanned" so
        -- the status line and convert-guard can tell them apart (6.1).
        self._scanned       = true
    else
        self._all_matches   = nil
        self._current_boxes = {}
        self._scanned       = false
        if _is_metric_mode(doc.file) and self._tap_mode >= 2 then
            -- Converted book: the on-disk sidecar is the preserved original-
            -- text scan (kept stale for a no-rescan revert/mode-switch), and
            -- scanning the converted text finds nothing the convert modes
            -- actually use — this "echo scan" was a full second scan after
            -- every convert. Skip it. The menu count reads the stamped total;
            -- announce the conversion from the stamp too, since no scan
            -- notice will fire.
            if FootFree._just_converted == doc.file then
                FootFree._just_converted = nil
                -- Queued, not timed: this is the LAST word on the action, so it
                -- waits for KOReader's re-render bar and our re-locate ring to
                -- both be done. See _deferNotice.
                self:_deferNotice(function()
                    UIManager:show(Notification:new{
                        text = self:_scanNoticeText(0, doc),
                    })
                    -- THEN re-locate, in the background and unannounced. It
                    -- resolves where each converted phrase now sits, which only
                    -- hold-to-flag and mode 3's "show original units" ever read
                    -- — nobody long-presses in the six seconds after a convert.
                    -- Running it before the notice made the reader watch a
                    -- spinner for work they never asked for: on a Kobo it was
                    -- 6.2s of a 28.8s action (2026-08-18), and 18.5s of 42s
                    -- before the plain-pass rewrite.
                    --
                    -- A tap cancels it (Trapper's invisible trap is still
                    -- dismiss-on-tap) and a page turn is a tap, so this may not
                    -- finish. That is deliberate: the reader is reading, and
                    -- reading wins. The next open retries, exactly as it always
                    -- did when the old blocking version was dismissed.
                    UIManager:nextTick(function()
                        if self.view and self.ui.document then
                            self:_loadReverseMatches(doc, true)
                        end
                    end)
                end)
            end
        -- Skip auto-scan for a book whose data the user JUST removed: the
        -- removal's revert reloads the document, and without this the rescan/
        -- convert prompt would pop right back up. Session-only (class table).
        elseif self._auto_scan and _is_english(doc)
           and not self._removed_this_session[doc.file] then
            -- In an in-text mode, convert automatically once this fresh scan
            -- finishes — and WITHOUT asking. Ticking "Auto-convert when opening
            -- a new book" is the consent for this path; re-asking per book is a
            -- question the reader already answered, and it used to arrive after
            -- a 12-second wait (on-device report, 2026-08-17). The menu entry
            -- and its long-press text say plainly that this rewrites the book.
            -- Only on a fresh scan (first time a book is scanned): a book that
            -- was scanned before and left unconverted must not be converted
            -- behind the reader's back on a later open.
            self:_armConvertAfterScan(true)
            self:_startScan(doc)
        end
    end

    -- Mode switched back to underline-only on a converted book. The revert that
    -- carried it out was deliberately silent (see `chained` in
    -- _revertMetricEdition), so this is where the reader learns the new mode is
    -- live — and the count only exists here, after the sidecar reload. Reuses
    -- the existing "Underlined %1 units in book" string, so no new msgid and
    -- nothing for translators to redo.
    if FootFree._pending_underline == doc.file then
        FootFree._pending_underline = nil
        local n = (self._all_matches and #self._all_matches) or 0
        self:_deferNotice(function()
            UIManager:show(Notification:new{
                text = self:_scanNoticeText(n, doc),
            })
        end)
    end

    -- Skipped when a notice is pending: that path (just converted) runs this
    -- itself once the notice has been shown, so the reader is not made to wait
    -- for it. Every other path — a plain open of a converted book, a toggle —
    -- still resolves here, with its ring, as before.
    if not self._pending_notice then self:_loadReverseMatches(doc) end

    -- Flush any error reports queued while offline (no-op unless sharing is
    -- on and the queue file exists).
    if self._share_reports then self:_flushReports() end
end

-- ── Filter + save (called after async scan completes) ─────────────────────────

local function _write_book_report(doc, filtered)
    os.execute("mkdir -p /mnt/macos/debug/book-scans 2>/dev/null")
    local title
    local ok_p, props = pcall(function() return doc:getProps() end)
    if ok_p and props and type(props.title) == "string" and props.title ~= "" then
        title = props.title
    else
        title = doc.file:match("([^/]+)%.%a+$") or "unknown"
    end
    local safe = title:gsub('[/\\:*?"<>|]', "_"):gsub("%s+", " "):sub(1, 80)
    local path = "/mnt/macos/debug/book-scans/" .. safe .. ".txt"
    local fh = io.open(path, "w")
    if not fh then return end

    -- Re-query each unique matched_text at 15 context words and key by xpointer.
    -- The scan itself always runs at 5 words; this separate pass is report-only.
    local queried  = {}
    local long_ctx = {}
    for _, r in ipairs(filtered) do
        local mt = r.matched_text
        if not queried[mt] then
            queried[mt] = true
            local ok, res = pcall(function()
                return doc:findAllText(mt, true, 15, 500, false)
            end)
            if ok and res then
                for _, lr in ipairs(res) do
                    if lr.start then
                        long_ctx[lr.start] = {prev=lr.prev_text or "", next=lr.next_text or ""}
                    end
                end
            end
        end
    end

    fh:write("FOOTCREAM SCAN REPORT\n")
    fh:write("Book:    " .. title .. "\n")
    fh:write("File:    " .. doc.file .. "\n")
    fh:write("Date:    " .. (os.date("%Y-%m-%d %H:%M") or "") .. "\n")
    fh:write("Matches: " .. #filtered .. "\n")
    fh:write(string.rep("=", 72) .. "\n\n")

    for i, r in ipairs(filtered) do
        local match_str = _display(r.matched_text)
        local conv_str  = _convert(r) or "?"
        local ctx  = long_ctx[r.start]
        local prev = ctx and ctx.prev or r.prev_text or ""
        local nxt  = ctx and ctx.next or r.next_text or ""
        fh:write(string.format("[%d] %q  →  %s\n", i, match_str, conv_str))
        fh:write("    ..." .. prev .. "[" .. match_str .. "]" .. nxt .. "...\n\n")
    end

    fh:close()
    logger.info("FootFree: book report → " .. path)
end

-- Tooltip size presets (the "Subtle" scale). Each controls font, icon, padding,
-- corner radius, icon↔text gap, and border thickness; the pointer arrow's WIDTH
-- and HEIGHT stay fixed across sizes (only its border tracks the card's). Values
-- are pre-scale design units (run through Screen:scaleBySize at use). Attached to
-- the FootFree table rather than a top-level local (the main chunk is at Lua's
-- 200-locals ceiling). _show_styling_dialog's live preview reads the same table.
FootFree._TOOLTIP_SIZES = {
    large  = { font = 22, icon = 26, pad_h = 16, pad_v = 4, border = 1.5,  radius = 12, gap = 14 },
    medium = { font = 19, icon = 23, pad_h = 14, pad_v = 4, border = 1.5,  radius = 11, gap = 12 },
    small  = { font = 16, icon = 19, pad_h = 12, pad_v = 3, border = 1.25, radius = 9,  gap = 10 },
}

local function _show_conversion_popup(match, box, show_icon, size_key)
    local S = FootFree._TOOLTIP_SIZES[size_key] or FootFree._TOOLTIP_SIZES.large
    local InputContainer  = require("ui/widget/container/inputcontainer")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local TextWidget      = require("ui/widget/textwidget")
    local ImageWidget     = require("ui/widget/imagewidget")
    local GestureRange    = require("ui/gesturerange")
    local Screen          = require("device").screen
    local Font            = require("ui/font")
    local Geom            = require("ui/geometry")

    local cat       = match._cat or "length"
    local icon_path = _PLUGIN_DIR .. "/unit-icons/" .. (_CAT_ICONS[cat] or "length") .. ".svg"
    local converted = _metric_only(match) or _convert(match) or "?"

    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local sc = function(n) return Screen:scaleBySize(n) end

    local icon_sz = sc(S.icon)
    local gap     = sc(S.gap)
    local pad_h   = sc(S.pad_h)   -- left/right padding
    local pad_v   = sc(S.pad_v)   -- top/bottom padding

    -- Right: converted value (large bold)
    local text_col = TextWidget:new{
        text = converted,
        face = Font:getFace("infofont", S.font),
        bold = true,
    }

    -- Horizontal row: icon (optional) | spacer | text
    local row
    if show_icon then
        -- Left: icon centred in its own box
        local icon_col = CenterContainer:new{
            dimen = Geom:new{ w = icon_sz, h = icon_sz },
            ImageWidget:new{
                file   = icon_path,
                width  = icon_sz,
                height = icon_sz,
                alpha  = true,
                invert = G_reader_settings:isTrue("night_mode"),
            },
        }
        row = HorizontalGroup:new{
            align = "center",
            icon_col,
            WidgetContainer:new{ dimen = Geom:new{ w = gap, h = 1 } },
            text_col,
        }
    else
        row = text_col
    end

    -- Rounded bordered card
    local card = FrameContainer:new{
        padding_top    = pad_v,
        padding_bottom = pad_v,
        padding_left   = pad_h,
        padding_right  = pad_h,
        radius         = sc(S.radius),
        bordersize     = Screen:scaleBySize(S.border),
        background     = Blitbuffer.COLOR_WHITE,
        row,
    }

    -- Position near the tapped word: below if it fits, otherwise above.
    local OverlapGroup   = require("ui/widget/overlapgroup")
    local card_size      = card:getSize()
    local margin         = sc(10)
    local ref_x          = box and (box.x + box.w / 2) or (sw / 2)
    local ref_bottom     = box and (box.y + box.h)     or (sh / 2)
    local ref_top        = box and box.y                or (sh / 2)
    local popup_x = math.max(0, math.min(sw - card_size.w,
                             math.floor(ref_x - card_size.w / 2)))
    local popup_y
    local popup_below_word
    if ref_bottom + margin + card_size.h <= sh then
        popup_y = ref_bottom + margin          -- below the word
        popup_below_word = true
    else
        popup_y = ref_top - margin - card_size.h  -- above the word
        popup_below_word = false
    end
    popup_y = math.max(0, math.min(sh - card_size.h, popup_y))
    card.overlap_offset = { popup_x, popup_y }

    -- Pointer arrow: points toward the tapped word, flipped depending on
    -- whether the popup landed below or above it.
    local arrow_w     = sc(16)   -- arrow size is fixed across tooltip sizes
    local arrow_h     = sc(8)
    local radius      = sc(S.radius)
    local border_px   = math.max(1, math.floor(Screen:scaleBySize(S.border) + 0.5))
    local apex_min    = popup_x + radius + arrow_w / 2
    local apex_max    = popup_x + card_size.w - radius - arrow_w / 2
    local apex_x
    if apex_min <= apex_max then
        apex_x = math.max(apex_min, math.min(apex_max, ref_x))
    else
        apex_x = popup_x + card_size.w / 2
    end
    local arrow_x = math.floor(apex_x - arrow_w / 2)
    local arrow_y
    local arrow_dir
    if popup_below_word then
        arrow_dir = "up"     -- apex on top, base merges into the card's top edge
        arrow_y   = popup_y - arrow_h + border_px
    else
        arrow_dir = "down"   -- apex on bottom, base merges into the card's bottom edge
        arrow_y   = popup_y + card_size.h - border_px
    end
    local arrow = _PointerArrow:new{
        width        = arrow_w,
        height       = arrow_h,
        direction    = arrow_dir,
        apex_offset  = arrow_w / 2,
        border_size  = border_px,
        border_color = Blitbuffer.COLOR_BLACK,
        fill_color   = Blitbuffer.COLOR_WHITE,
    }
    arrow.overlap_offset = { arrow_x, arrow_y }

    -- Full-screen input overlay — tap anywhere to dismiss
    local overlay
    overlay = InputContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        ges_events = {
            TapClose = {
                GestureRange:new{
                    ges   = "tap",
                    range = Geom:new{ w = sw, h = sh },
                },
            },
        },
        OverlapGroup:new{
            dimen = Geom:new{ w = sw, h = sh },
            card,
            arrow,
        },
    }
    function overlay:onTapClose()
        UIManager:close(self)
        return true
    end

    UIManager:show(overlay)
    UIManager:scheduleIn(5, function() UIManager:close(overlay) end)
end

-- Settings dialog with a live preview of the underline styling on a sample
-- word. Each control closes and re-opens the dialog so the preview reflects
-- the change immediately.
local function _show_styling_dialog(plugin)
    local InputContainer  = require("ui/widget/container/inputcontainer")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local OverlapGroup    = require("ui/widget/overlapgroup")
    local MovableContainer = require("ui/widget/container/movablecontainer")
    local TextWidget      = require("ui/widget/textwidget")
    local Button          = require("ui/widget/button")
    local GestureRange    = require("ui/gesturerange")
    local Screen          = require("device").screen
    local Font            = require("ui/font")

    local sc = function(n) return Screen:scaleBySize(n) end
    local sw, sh = Screen:getWidth(), Screen:getHeight()

    local overlay
    local movable
    local function refresh()
        -- Preserve the dragged position across the close+reopen that a setting
        -- change triggers, so toggling an option doesn't snap the modal back to
        -- centre. Stashed on the plugin because refresh() recurses into a fresh
        -- _show_styling_dialog call.
        if movable then plugin._styling_offset = movable:getMovedOffset() end
        UIManager:close(overlay)
        _show_styling_dialog(plugin)
    end

    local label_face = Font:getFace("infofont", 16)
    local function label(text)
        return TextWidget:new{ text = text, face = label_face }
    end

    local function span() return VerticalSpan:new{ width = sc(10) } end

    -- Preview: a worked example ("Five foot six") with its underline
    -- rendered live, plus an always-visible tooltip showing the conversion
    -- exactly as it would appear when tapped in the book.
    local sample = TextWidget:new{
        -- TRANSLATORS: Sample phrase in the Styling preview, shown underlined the way real
        -- measurements will be. Replace it with a short imperial measurement written out
        -- in words in your language (it is an example, not a literal quote).
        text = _("Five foot six"),
        face = Font:getFace("infofont", 24),
    }
    local sample_size = sample:getSize()
    local underline = _UnderlinePreview:new{
        width      = sample_size.w,
        height     = sample_size.h,
        style      = plugin._underline_style,
        color      = _underline_color(plugin._underline_color),
        line_width = sc(plugin._underline_width),
        raw_width  = plugin._underline_width,
        color_pct  = plugin._underline_color,
    }
    local example = OverlapGroup:new{
        dimen = sample_size,
        underline,
        sample,
    }

    -- Tooltip card mirrors _show_conversion_popup's styling for the SELECTED
    -- size, so the preview is true WYSIWYG. The real popup shows _metric_only's
    -- "converted value only" form (e.g. "1.68 m"), so match that here.
    local PS = FootFree._TOOLTIP_SIZES[plugin._tooltip_size] or FootFree._TOOLTIP_SIZES.large
    -- TRANSLATORS: Preview of the tap tooltip in the Styling dialog. %1 is a number;
    -- 'm' is the metre symbol and is not translated.
    local conversion_text = T(_("%1 m"), _fmt_height(5 * 0.3048 + 6 * 0.0254))
    local tooltip_text = TextWidget:new{
        text = conversion_text,
        face = Font:getFace("infofont", PS.font),
        bold = true,
    }
    local tooltip_row = tooltip_text
    if plugin._show_icon then
        local ImageWidget = require("ui/widget/imagewidget")
        local icon_sz   = sc(PS.icon)
        local icon_path = _PLUGIN_DIR .. "/unit-icons/" .. (_CAT_ICONS["length"] or "length") .. ".svg"
        local icon_col = CenterContainer:new{
            dimen = Geom:new{ w = icon_sz, h = icon_sz },
            ImageWidget:new{
                file   = icon_path,
                width  = icon_sz,
                height = icon_sz,
                alpha  = true,
                invert = G_reader_settings:isTrue("night_mode"),
            },
        }
        tooltip_row = HorizontalGroup:new{
            align = "center",
            icon_col,
            WidgetContainer:new{ dimen = Geom:new{ w = sc(PS.gap), h = 1 } },
            tooltip_text,
        }
    end
    local tooltip_card = FrameContainer:new{
        padding_top    = sc(PS.pad_v),
        padding_bottom = sc(PS.pad_v),
        padding_left   = sc(PS.pad_h),
        padding_right  = sc(PS.pad_h),
        radius         = sc(PS.radius),
        bordersize     = Screen:scaleBySize(PS.border),
        background     = Blitbuffer.COLOR_WHITE,
        tooltip_row,
    }

    -- Pointer arrow, base merging into the tooltip card's bottom edge —
    -- same overlap trick as _show_conversion_popup (arrow's top border row
    -- lands exactly on the card's bottom border row). Arrow size is fixed;
    -- only its border tracks the card's so the join stays seamless.
    local arrow_w   = sc(16)
    local arrow_h   = sc(8)
    local border_px = math.max(1, math.floor(Screen:scaleBySize(PS.border) + 0.5))
    local arrow = _PointerArrow:new{
        width        = arrow_w,
        height       = arrow_h,
        direction    = "down",
        apex_offset  = arrow_w / 2,
        border_size  = border_px,
        border_color = Blitbuffer.COLOR_BLACK,
        fill_color   = Blitbuffer.COLOR_WHITE,
    }

    -- Shared drawn radio marker (see the class-level definition by
    -- _UnderlinePreview — also used by the Mode picker dialog).
    local _RadioDot = FootFree._RadioDot

    -- One option = the radio dot + its label, both wrapped in a single tappable
    -- container so a tap anywhere on the item (dot OR label) selects it. The dot
    -- gets padding so its hit area isn't a tiny circle.
    local function option_row(options, current, on_select)
        local row = { align = "center" }
        for i, opt in ipairs(options) do
            if i > 1 then
                table.insert(row, WidgetContainer:new{ dimen = Geom:new{ w = sc(10), h = 1 } })
            end
            local value = opt.value
            -- FrameContainer (not WidgetContainer) records its absolute screen
            -- rect in .dimen on every paint, so the tap GestureRange tracks the
            -- item wherever the modal is dragged to.
            local frame = FrameContainer:new{
                bordersize = 0,
                padding    = sc(4),
                HorizontalGroup:new{
                    align = "center",
                    _RadioDot:new{ size = sc(15), selected = (value == current) },
                    WidgetContainer:new{ dimen = Geom:new{ w = sc(5), h = 1 } },
                    TextWidget:new{ text = opt.text, face = Font:getFace("cfont", 18) },
                },
            }
            local item = InputContainer:new{ frame }
            item.ges_events = {
                Tap = { GestureRange:new{ ges = "tap", range = function() return frame.dimen end } },
            }
            item.onTap = function()
                on_select(value)
                refresh()
                return true
            end
            table.insert(row, item)
        end
        return HorizontalGroup:new(row)
    end

    local style_row = option_row({
        -- TRANSLATORS: Styling dialog, 'Underline style' option: a plain straight
        -- underline.
        { text = _("Solid"), value = "solid" },
        -- TRANSLATORS: Styling dialog, 'Underline style' option: a squiggly underline.
        { text = _("Wavy"),  value = "wavy"  },
    }, plugin._underline_style, function(v)
        plugin._underline_style = v
        G_reader_settings:saveSetting("footcream_underline_style", v)
    end)

    local color_row = option_row({
        { text = "10%", value = 10 },
        { text = "20%", value = 20 },
        { text = "30%", value = 30 },
        { text = "40%", value = 40 },
    }, plugin._underline_color, function(v)
        plugin._underline_color = v
        G_reader_settings:saveSetting("footcream_underline_color", v)
    end)

    local width_row = option_row({
        -- TRANSLATORS: Styling dialog, 'Underline Intensity' option: the lighter/finer of
        -- the two line weights.
        { text = _("Thin"),  value = 1 },
        -- TRANSLATORS: Styling dialog, 'Underline Intensity' option: the heavier line
        -- weight.
        { text = _("Thick"), value = 2 },
    }, plugin._underline_width, function(v)
        plugin._underline_width = v
        G_reader_settings:saveSetting("footcream_underline_width", v)
    end)

    local size_row = option_row({
        -- TRANSLATORS: Styling dialog, 'Tooltip size' option: smallest tap-popup text.
        { text = _("Small"),  value = "small"  },
        -- TRANSLATORS: Styling dialog, 'Tooltip size' option: middle tap-popup text size.
        { text = _("Medium"), value = "medium" },
        -- TRANSLATORS: Styling dialog, 'Tooltip size' option: largest tap-popup text.
        { text = _("Large"),  value = "large"  },
    }, plugin._tooltip_size, function(v)
        plugin._tooltip_size = v
        G_reader_settings:saveSetting("footcream_tooltip_size", v)
    end)

    -- Manually stack tooltip card, arrow, and example, centred horizontally.
    -- The preview frame stretches to match the widest option row below (so
    -- it fills the modal's width), but never shrinks below what the worked
    -- example itself needs.
    local card_size    = tooltip_card:getSize()
    local example_size = example:getSize()
    local natural_content_w = math.max(card_size.w, example_size.w, arrow_w)

    local preview_padding_h = sc(20) * 2
    local preview_border_h  = Screen:scaleBySize(1) * 2
    local max_row_w = 0
    for _, w in ipairs({ style_row, color_row, width_row, size_row }) do
        max_row_w = math.max(max_row_w, w:getSize().w)
    end
    local content_w = math.max(natural_content_w, max_row_w - preview_padding_h - preview_border_h)
    local full_w = content_w + preview_padding_h + preview_border_h

    local CheckButton = require("ui/widget/checkbutton")
    local icon_checkbox = CheckButton:new{
        -- TRANSLATORS: Checkbox in the Styling dialog. When ticked, the tap tooltip shows
        -- a small icon for the kind of measurement (length, weight, ...).
        text       = _("Show Unit Icon"),
        checked    = plugin._show_icon,
        face       = label_face,
        single_line = true,
        width      = full_w,
        callback = function()
            plugin._show_icon = not plugin._show_icon
            G_reader_settings:saveSetting("footcream_show_icon", plugin._show_icon)
            refresh()
        end,
    }

    -- Close spans the full width of the preview frame below it. Pass the "ui"
    -- refresh type to close() so the uncovered area (reader page or file-manager
    -- list) actually repaints on e-ink — context-independent, so it works both
    -- in a book and in the library (where there's no ReaderView to setDirty).
    local function close_overlay()
        -- Forget the dragged position so the next fresh open re-centres
        -- (only refresh() should carry position over).
        plugin._styling_offset = nil
        UIManager:close(overlay, "ui")
    end

    -- Make the Close button 20% taller than its natural height (text stays
    -- vertically centred; "Close" can't truncate at full_w, so no font reflow).
    -- TRANSLATORS: Button that closes a Footcream dialog without changing anything.
    -- Used on the Styling dialog, the mode picker and the long-press report popups.
    local close_natural_h = Button:new{ text = _("Close"), width = full_w }:getSize().h
    local close_button = Button:new{
        -- TRANSLATORS: Button that closes a Footcream dialog without changing anything.
        -- Used on the Styling dialog, the mode picker and the long-press report popups.
        text   = _("Close"),
        width  = full_w,
        height = math.floor(close_natural_h * 1.2 + 0.5),
        callback = close_overlay,
    }

    local example_y = card_size.h + arrow_h - border_px + sc(10)
    local content_h = example_y + example_size.h

    tooltip_card.overlap_offset = { math.floor((content_w - card_size.w) / 2), 0 }
    arrow.overlap_offset = { math.floor((content_w - arrow_w) / 2), card_size.h - border_px }
    example.overlap_offset = { math.floor((content_w - example_size.w) / 2), example_y }

    -- "PREVIEW" label in the top-left corner of the preview frame.
    local preview_label = TextWidget:new{
        -- TRANSLATORS: Corner label on the framed sample area of the Styling dialog,
        -- marking it as a live preview rather than part of the book.
        text   = _("PREVIEW"),
        face   = Font:getFace("infofont", 11),
        -- 20% more contrast vs white than COLOR_DARK_GRAY (0x88): the
        -- white-difference 255-0x88=119 grows ×1.2 to ~143, so 255-143 ≈ 0x70.
        fgcolor = Blitbuffer.Color8(0x70),
    }
    preview_label.overlap_offset = { -sc(5), -sc(5) }

    local content = OverlapGroup:new{
        dimen = Geom:new{ w = content_w, h = content_h },
        tooltip_card,
        arrow,
        example,
        preview_label,
    }

    -- Hairline border frames the whole worked example.
    local preview = FrameContainer:new{
        padding_top    = sc(14),
        padding_bottom = sc(14),
        padding_left   = sc(20),
        padding_right  = sc(20),
        radius         = sc(6),
        bordersize     = Screen:scaleBySize(1),
        color          = Blitbuffer.COLOR_GRAY_B,
        content,
    }

    local card = FrameContainer:new{
        padding_top    = sc(12),
        padding_bottom = sc(12),
        padding_left   = sc(16),
        padding_right  = sc(16),
        radius         = sc(12),
        bordersize     = Screen:scaleBySize(1.5),
        background     = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            preview,
            span(),
            -- TRANSLATORS: Section heading in the Styling dialog, above the Solid/Wavy choice.
            label(_("Underline style")),
            style_row,
            span(),
            -- TRANSLATORS: Section heading in the Styling dialog, above the underline darkness
            -- choice (how strongly the line stands out from the text).
            label(_("Underline Intensity")),
            color_row,
            span(),
            -- TRANSLATORS: Section heading in the Styling dialog, above the Thin/Thick choice.
            label(_("Underline thickness")),
            width_row,
            span(),
            -- TRANSLATORS: Section heading in the Styling dialog, above the Small/Medium/Large
            -- choice for the tap tooltip.
            label(_("Tooltip size")),
            size_row,
            span(),
            icon_checkbox,
            span(),
            close_button,
        },
    }

    -- Wrap the card so it can be dragged around the screen (Hold + pan, or
    -- swipe). The preview area is the natural grab handle — it's the one large
    -- non-interactive region; the option buttons still take taps normally.
    movable = MovableContainer:new{ card }
    -- Re-apply any position carried over from a refresh (see refresh() above).
    if plugin._styling_offset then
        movable:setMovedOffset(plugin._styling_offset)
    end

    overlay = InputContainer:new{
        key_events = {
            Close = { { "Back" } },
        },
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            movable,
        },
    }

    function overlay:onClose()
        close_overlay()
        return true
    end

    -- Pass the "ui" refresh type to show() so the modal's region paints on
    -- e-ink directly, rather than relying on the reader view (nil in the file
    -- manager). Without this, reopening the dialog after an option tap (the rows
    -- close + reopen the dialog) didn't refresh in the library, so the selection
    -- dot and live preview looked frozen.
    UIManager:show(overlay, "ui")
end

-- Visual mode picker: one worked sentence rendered the three ways — a live
-- underline in the user's styling, the parenthetical gloss, and the in-place
-- replacement — each row tappable. Shown OVER the open Footcream menu (the
-- caller doesn't close it, and the Mode item sets keep_menu_open): closing
-- the picker drops the user back into the menu instead of onto the bare
-- page. Direction-aware: under an imperial preference the sample flips to a
-- metric original with imperial output. touchmenu_instance (optional) is the
-- TouchMenu the Mode item lives in — used to refresh its labels after a mode
-- change while it stays open behind the picker.
function FootFree:_showModeDialog(touchmenu_instance)
    local InputContainer   = require("ui/widget/container/inputcontainer")
    local FrameContainer   = require("ui/widget/container/framecontainer")
    local CenterContainer  = require("ui/widget/container/centercontainer")
    local HorizontalGroup  = require("ui/widget/horizontalgroup")
    local VerticalGroup    = require("ui/widget/verticalgroup")
    local VerticalSpan     = require("ui/widget/verticalspan")
    local OverlapGroup     = require("ui/widget/overlapgroup")
    local MovableContainer = require("ui/widget/container/movablecontainer")
    local TextWidget       = require("ui/widget/textwidget")
    local Button           = require("ui/widget/button")
    local GestureRange     = require("ui/gesturerange")
    local Screen           = require("device").screen
    local Font             = require("ui/font")

    local sc = function(n) return Screen:scaleBySize(n) end
    local sw, sh = Screen:getWidth(), Screen:getHeight()

    -- Worked example, direction-aware: under an imperial preference the
    -- book's original text is metric and the conversion is imperial.
    local imp  = FootFree._IMPERIAL.preferred() ~= "metric"
    -- TRANSLATORS: First half of the sample sentence in the mode picker; a measurement
    -- and the second half (' wide.') follow it. Keep the trailing space so the
    -- sentence reads 'The hallway was 1.8 m wide.'
    local pre  = _("The hallway was ")
    local orig = imp and "1.8 m" or "six feet"
    local conv = imp and "5 ft 11 in" or "1.8 m"
    -- TRANSLATORS: Second half of the mode-picker sample sentence, after the
    -- measurement. Keep the leading space; see 'The hallway was '.
    local post = _(" wide.")

    local sample_face  = Font:getFace("infofont", 17)
    local caption_face = Font:getFace("infofont", 13)
    local overlay
    local movable

    -- Only one picker at a time (a mode change re-renders it in place by
    -- closing + reopening — see pick()).
    if FootFree._mode_overlay then
        UIManager:close(FootFree._mode_overlay)
        FootFree._mode_overlay = nil
    end

    -- Row 1's sample carries a live underline under the original phrase, in
    -- the user's current styling (same widget the Styling preview uses).
    local ul_text = TextWidget:new{ text = orig, face = sample_face }
    local ul_size = ul_text:getSize()
    local sample1 = HorizontalGroup:new{
        align = "center",
        TextWidget:new{ text = pre, face = sample_face },
        OverlapGroup:new{
            dimen = ul_size,
            _UnderlinePreview:new{
                width      = ul_size.w,
                height     = ul_size.h,
                style      = self._underline_style,
                color      = _underline_color(self._underline_color),
                line_width = sc(self._underline_width),
                raw_width  = self._underline_width,
                color_pct  = self._underline_color,
            },
            ul_text,
        },
        TextWidget:new{ text = post, face = sample_face },
    }

    local rows = {
        { mode = 1, sample = sample1,
          -- TRANSLATORS: Mode picker, caption under the mode 1 sample. %1 is a converted
          -- measurement such as '1.8 m'. This mode only draws an underline.
          caption = T(_("Underline only — tap it to see %1."), conv),
          -- TRANSLATORS: Mode picker, second caption line for mode 1 - the reassurance that
          -- this mode never edits the book file, unlike modes 2 and 3.
          caption2 = _("The book file is never changed.") },
        { mode = 2,
          sample = TextWidget:new{ text = pre .. orig .. " (" .. conv .. ")" .. post,
                                   face = sample_face },
          -- TRANSLATORS: Mode picker, caption under the mode 2 sample: the conversion is
          -- written into the book next to the original measurement.
          caption = _("Both units, written into the book's text."),
          -- TRANSLATORS: Mode picker, second caption line under the two modes that write
          -- into the book's text: the change can be undone later with 'Remove Footcream data
          -- from this book'.
          caption2 = _("Reversible.") },
        { mode = 3,
          sample = TextWidget:new{ text = pre .. conv .. post, face = sample_face },
          -- TRANSLATORS: Mode picker, caption under the mode 3 sample: the original
          -- measurement is replaced by the conversion in the book's text.
          caption = _("Converted only, written into the book's text."),
          -- TRANSLATORS: Mode picker, second caption line under the two modes that write
          -- into the book's text: the change can be undone later with 'Remove Footcream data
          -- from this book'.
          caption2 = _("Reversible.") },
    }

    -- User-initiated close (Close button, Back, tap outside): only the
    -- picker closes — the user lands back in the still-open menu (user
    -- feedback 2026-07-14). If a mode change happened, the book catches up
    -- when the MENU closes: _reconcileModeWithBook is armed on the menu's
    -- close_callback (TouchMenu's tap-outside/✕ paths run it), so the
    -- convert question / revert appears over the book, never over menu or
    -- picker.
    local function close_overlay()
        FootFree._mode_overlay = nil
        self._mode_dialog_offset = nil
        UIManager:close(overlay, "ui")
        if not self._mode_reconcile_pending then return end
        self._mode_reconcile_pending = nil
        -- If the convert question comes up and the user declines, it
        -- restores the mode from before the picker (nil = no change to
        -- restore, e.g. picks that netted out back to the start).
        local prior = self._mode_before_picker
        self._mode_before_picker = nil
        local restore = prior ~= self._tap_mode and prior or nil
        if not touchmenu_instance then
            -- No menu to wait for — reconcile right away.
            self:_reconcileModeWithBook(restore)
            return
        end
        -- Arm once per menu instance; the flags live on the plugin so a
        -- second picker session in the same menu just updates the pending
        -- state (keeping the FIRST session's restore mode — the last mode
        -- the book was actually stable in).
        if not self._reconcile_on_menu_close then
            self._reconcile_on_menu_close = true
            self._reconcile_restore = restore
        end
        if not touchmenu_instance._footcream_reconcile_hooked then
            touchmenu_instance._footcream_reconcile_hooked = true
            local orig_close = touchmenu_instance.close_callback
            touchmenu_instance.close_callback = function(...)
                if orig_close then orig_close(...) end
                if self._reconcile_on_menu_close then
                    self._reconcile_on_menu_close = nil
                    local r = self._reconcile_restore
                    self._reconcile_restore = nil
                    self:_reconcileModeWithBook(r)
                end
            end
        end
    end

    local function pick(mode)
        if mode == self._tap_mode then return end
        -- The picker only changes the mode SETTING — instantly (dot moves,
        -- menu label refreshes via touchmenu_instance:updateItems()) — and
        -- stays open, as does the menu behind it. All document work (the
        -- convert question, revert/re-apply) is deferred to close_overlay
        -- via _mode_reconcile_pending. The flag lives on the instance: the
        -- re-render below replaces this closure's upvalues.
        self._tap_mode = mode
        G_reader_settings:saveSetting("footcream_tap_mode", mode)
        logger.info("Footcream: mode→" .. mode .. " (picker; book reconciles on close)")
        self._mode_reconcile_pending = true
        if touchmenu_instance then
            pcall(function() touchmenu_instance:updateItems() end)
        end
        -- Re-render with the dot on the new mode, keeping the dragged
        -- position across the close + reopen.
        self._mode_dialog_offset = movable and movable:getMovedOffset()
        FootFree._mode_overlay = nil
        UIManager:close(overlay, "ui")
        self:_showModeDialog(touchmenu_instance)
    end

    -- Caption grey: dark enough to read comfortably on e-ink (0x55 was too
    -- dim — user feedback 2026-07-14).
    local grey = Blitbuffer.Color8(0x3A)
    local body = { align = "left" }
    table.insert(body, TextWidget:new{
        -- TRANSLATORS: Title of the mode picker, opened from the 'Mode: ...' menu entry.
        text = _("How should conversions appear?"),
        face = Font:getFace("infofont", 18),
        bold = true,
    })
    table.insert(body, VerticalSpan:new{ width = sc(14) })
    for i, r in ipairs(rows) do
        -- FrameContainer (not WidgetContainer) records its absolute screen
        -- rect in .dimen on every paint, so the tap GestureRange tracks the
        -- row wherever the modal is dragged to.
        -- The dot is top-aligned with the row and boxed to the SAMPLE line's
        -- height, so it centres on the heading rather than on the whole
        -- sample+captions block (user feedback 2026-07-14).
        local sample_h = r.sample:getSize().h
        local frame = FrameContainer:new{
            bordersize = 0,
            padding    = sc(6),
            HorizontalGroup:new{
                align = "top",
                CenterContainer:new{
                    dimen = Geom:new{ w = sc(15), h = sample_h },
                    FootFree._RadioDot:new{ size = sc(15),
                                            selected = (self._tap_mode == r.mode) },
                },
                WidgetContainer:new{ dimen = Geom:new{ w = sc(9), h = 1 } },
                VerticalGroup:new{
                    align = "left",
                    r.sample,
                    -- Sample→caption gap trimmed to 40% of the original
                    -- sc(5) (user feedback 2026-07-14).
                    VerticalSpan:new{ width = sc(2) },
                    TextWidget:new{ text = r.caption,  face = caption_face, fgcolor = grey },
                    TextWidget:new{ text = r.caption2, face = caption_face, fgcolor = grey },
                },
            },
        }
        local item = InputContainer:new{ frame }
        item.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = function() return frame.dimen end } },
        }
        item.onTap = function() pick(r.mode); return true end
        table.insert(body, item)
        if i < #rows then
            table.insert(body, VerticalSpan:new{ width = sc(12) })
        end
    end
    local options = VerticalGroup:new(body)

    -- Close spans the options' full width (measured after construction).
    local full_w = options:getSize().w
    -- TRANSLATORS: Button that closes a Footcream dialog without changing anything.
    -- Used on the Styling dialog, the mode picker and the long-press report popups.
    local close_natural_h = Button:new{ text = _("Close"), width = full_w }:getSize().h
    local close_button = Button:new{
        -- TRANSLATORS: Button that closes a Footcream dialog without changing anything.
        -- Used on the Styling dialog, the mode picker and the long-press report popups.
        text   = _("Close"),
        width  = full_w,
        height = math.floor(close_natural_h * 1.2 + 0.5),
        callback = close_overlay,
    }

    local card = FrameContainer:new{
        padding_top    = sc(14),
        padding_bottom = sc(12),
        padding_left   = sc(16),
        padding_right  = sc(16),
        radius         = sc(12),
        bordersize     = Screen:scaleBySize(1.5),
        background     = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            options,
            VerticalSpan:new{ width = sc(14) },
            close_button,
        },
    }

    -- movable declared up top so pick() can read the dragged offset before
    -- the re-render; the offset survives the close + reopen.
    movable = MovableContainer:new{ card }
    if self._mode_dialog_offset then
        movable:setMovedOffset(self._mode_dialog_offset)
    end

    overlay = InputContainer:new{
        key_events = {
            Close = { { "Back" } },
        },
        -- Tap anywhere outside the card closes the picker (and lands you
        -- back in the still-open menu). Inside the card the tap falls
        -- through to the option rows.
        ges_events = {
            TapClose = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{ x = 0, y = 0, w = sw, h = sh },
                },
            },
        },
        CenterContainer:new{
            dimen = Geom:new{ w = sw, h = sh },
            movable,
        },
    }

    function overlay:onTapClose(_, ges)
        if card.dimen and ges.pos:intersectWith(card.dimen) then
            return false  -- inside the card: let the rows take it
        end
        close_overlay()
        return true
    end

    function overlay:onClose()
        close_overlay()
        return true
    end

    FootFree._mode_overlay = overlay
    UIManager:show(overlay, "ui")
end

function FootFree:_finishScan(doc, all_matches, t_total, in_subprocess, debug_report)
    -- Words that may follow a *weight* "N stone" — anything else following it
    -- (a concrete noun: cuffs, spheres, foundation, wall) marks it as the rock,
    -- not the unit. A number ("twelve stone six") or clause end also keep it.
    local _STONE_KEEP_FOLLOWERS = {
        ["and"]=true, ["or"]=true, ["odd"]=true, ["exactly"]=true, ["now"]=true,
        ["then"]=true, ["of"]=true, ["in"]=true, ["heavier"]=true, ["lighter"]=true,
        ["more"]=true, ["less"]=true, ["plus"]=true, ["each"]=true, ["apiece"]=true,
        ["per"]=true, ["but"]=true, ["so"]=true, ["to"]=true, ["soaking"]=true,
        ["dripping"]=true, ["at"]=true, ["when"]=true, ["nothing"]=true, ["over"]=true,
    }
    -- A definite/demonstrative determiner right before "stone" marks it as the
    -- rock, not the unit ("to the stone", "this stone"). A weight is always
    -- "<number> stone". "a"/"an" are excluded — "half a stone" is a real weight.
    local _STONE_ROCK_DET = {
        the=true, this=true, that=true, these=true, those=true,
    }
    -- Screens/TVs are conventionally sized in inches and readers expect that, so
    -- an inch measurement near one of these is left unconverted.
    local _SCREEN_WORDS = {
        tv=true, tvs=true, television=true, televisions=true, screen=true,
        screens=true, display=true, displays=true, monitor=true, monitors=true,
        plasma=true, lcd=true, led=true, oled=true, projector=true,
        laptop=true, tablet=true, ["smart-tv"]=true,
    }
    -- Drink/serving context where a pint→litre conversion erases the reader's
    -- sense of "how many glasses": keep pints for milk/blood/etc., drop them here.
    local _DRINK_WORDS = {
        glass=true, glasses=true, beer=true, beers=true, ale=true, lager=true,
        stout=true, cider=true, guinness=true, jameson=true, ["jameson's"]=true,
        whiskey=true, whisky=true, drink=true, drinks=true, drank=true,
        drunk=true, pub=true, bar=true, tankard=true, mug=true, pitcher=true,
    }
    -- Body-action verbs before "foot"/"feet" that mark it as a body part/idiom.
    local _FOOT_PREV_VERBS = {
        own=true, lifted=true, lift=true, raise=true, raised=true, raising=true,
        hop=true, hopping=true, hopped=true, balance=true, balanced=true,
        balancing=true, plant=true, planted=true, planting=true, stamp=true,
        stamped=true, stamping=true, tap=true, tapped=true, tapping=true,
        shuffle=true, shuffling=true,
        -- "put/set/place one foot upon …" — moving a foot, not a measurement.
        put=true, puts=true, set=true, sets=true, place=true, placed=true,
        places=true, rest=true, rested=true,
    }
    -- "<count>-toed/-legged/-clawed/… feet/foot" describes anatomy (how many
    -- toes/legs/etc. per foot), not a distance. The shared _parse_num word
    -- fallback treats a hyphen right after a number word as an ordinary
    -- compound-number boundary ("three-toed" reads as 3, the same mechanism
    -- that composes "twenty-three") — report #9: "sticky and soft
    -- three-toed feet" (lizard mounts) read as 91 cm.
    local _BODY_PART_SUFFIXES = {
        toed=true, legged=true, clawed=true, pawed=true, footed=true,
        fingered=true, handed=true, eyed=true, horned=true, tailed=true,
        winged=true, antlered=true, spotted=true, striped=true, spiked=true,
        scaled=true, furred=true, feathered=true, webbed=true, jointed=true,
        headed=true, armed=true, fanged=true, tusked=true, hoofed=true,
    }
    local filtered = {}
    for _, r in ipairs(all_matches) do
        local keep = true
        local mt   = r.matched_text:lower()
        -- Full 15-word window (lowercased) — used ONLY by the pound currency
        -- block below. All other filters use the legacy 8-word slice.
        local prev_full = (r.prev_text or ""):lower()
        local nxt_full  = (r.next_text or ""):lower()
        local prev = _last_words(prev_full, 8)
        local nxt  = _first_words(nxt_full, 8)

        -- "<length> at a time" — a rate/gradual idiom ("one inch at a time",
        -- "one foot at a time"), describing increments of progress, not a
        -- measured distance. Length units only (target m/cm/km). Gated to
        -- values ≤ 2, same rationale as the foot positional cues: "hauled in
        -- relays, about sixty yards at a time" (South!) is a genuine 55 m
        -- distance per relay, not a gradual-progress idiom.
        if (r._search.target == "cm" or r._search.target == "m"
            or r._search.target == "km") and nxt:match("^%s*at a time") then
            local atn = _parse_num(mt)
            if (not atn) or atn <= 2 then keep = false end
        end

        -- "stone" as rock/material, not the weight unit: an ordinary word follows
        -- it. Kept as weight when followed by a number ("twelve stone six"), a
        -- clause end / period ("weighs twelve stone."), or a weight-continuation
        -- word (and/odd/exactly/…). The %s* (not skipping ".") means a sentence
        -- end leaves nw nil → kept, which is the correct reading for a weight.
        if r._search.target == "kg" and mt:find("stone") then
            local nw = nxt:match("^%s*([%a']+)")
            if nw and not _is_number_word(nw) and not _STONE_KEEP_FOLLOWERS[nw:lower()] then
                keep = false
            end
            -- Rock, not weight: "…to the stone", "this stone" (vs "<number> stone").
            local before_stone = mt:match("(%a+)%s+stone") or prev:match("(%a+)%s*$")
            if before_stone and _STONE_ROCK_DET[before_stone:lower()] then keep = false end
        end
        if mt:find("nine") and mt:find("yard") and prev:find("whole") then keep = false end
        -- "one pounds" is the verb "to pound" (3rd-person singular); never a measurement.
        if mt == "one pounds" then keep = false end
        -- Spelled "pound(s)": suppress at scan time ONLY on HARD currency cues —
        -- those with no weight reading: the £ symbol (U+00A3 = bytes \194\163),
        -- a coin denomination / "sterling" (_pound_hard_currency), "N pounds on
        -- account" (a payment; kept tight so it doesn't hit "on account of …"),
        -- or a "prize" (sterling). The SOFT money cues (paid/worth/sum/wager/…)
        -- are NOT dropped here — they vote in the weighted classifier in
        -- _apply_settings_to_matches(), where strong weight context can outvote
        -- them ("the crate, worth a fortune, weighed two hundred pounds"). This
        -- keeps the soft-currency matches in the sidecar so the decision can be
        -- re-made on load (and re-tuned) without a rescan.
        if r._search.target == "kg" and mt:find("pound") then
            local window = prev_full .. " " .. nxt_full
            if window:find("\194\163", 1, true)
               or nxt_full:match("^%s*on account")
               or prev_full:find("prize", 1, true) or nxt_full:find("prize", 1, true)
               or _pound_hard_currency(window) then
                keep = false
            end
        end
        -- Bare "degrees" (no F/Fahrenheit qualifier): ambiguous unit (angle,
        -- rotation, proof, heading, latitude…). Convert only when nearby
        -- context plausibly reads as temperature — opposite polarity from
        -- the pounds classifier above: here the default is suppress, and a
        -- cue is required to opt IN.
        if r._search.bare_degrees then
            local window = prev_full .. " " .. nxt_full
            if not _degrees_temperature_cue(window) then
                keep = false
            -- "N degrees below zero": the true value is negative even though
            -- the spelled/digit number itself is positive. Getting the sign
            -- right needs the underline to reach past "degrees" into next_text,
            -- which this filter (post-span) can't safely do — so rather than
            -- emit a wrong-signed conversion, suppress it as a documented
            -- residual (a miss, not a wrong answer).
            elseif nxt_full:match("^%s*below%s+zero%f[%A]") then
                keep = false
            -- "ten degrees CELSIUS" — the scale is stated, it's just stated
            -- AFTER the alias, so the bare-"degrees" entry grabbed it first and
            -- read an already-metric figure as Fahrenheit (10 °C came out as
            -- -12 °C). The temperature cue gate can't catch this: the sentence
            -- is genuinely about temperature, which is exactly why the cue
            -- fires. Found 2026-08-07 in smoketest6 ("The water was ten degrees
            -- Celsius, cold enough to steal your breath"). Bare "c" is included
            -- for "40 degrees C"; the %f[%A] frontier keeps it off "cold".
            -- PATTERNS MUST BE LOWERCASE: nxt_full is :lower()ed where it's
            -- built (see prev_full/nxt_full above). The first version of this
            -- guard used "[Cc]elsius"/"[Cc]entigrade"/"C" — the character
            -- classes worked by accident and the uppercase-only "C" could
            -- never fire, so "minus eighteen degrees C" sailed through. Caught
            -- by verify_scan.py, NOT by testing the patterns in isolation
            -- (which passed, against raw-case text that never reaches here).
            elseif nxt_full:match("^%s*celsius%f[%A]")
                or nxt_full:match("^%s*centigrade%f[%A]")
                or nxt_full:match("^%s*c%f[%A]") then
                keep = false
            end
        end
        -- "N-mile-an-hour" is a speed expressed as a compound adjective, not a distance.
        if r._search.target == "km" and mt:find("mile") and nxt:match("^%s*an%s+hour") then keep = false end
        -- Gradient/scale ratio: "112 feet to the mile", "one inch to the mile",
        -- "30 feet per mile" — the number belongs to the NUMERATOR unit and the
        -- mile is just the denominator, so it's not a standalone distance. (Here
        -- the "mile" hit's back-range even mis-read the compound "one hundred and
        -- twelve" as 100–12 via its inner "and", attaching 112 to the mile.) Drop
        -- the mile; the numerator unit still matches on its own (112 feet → 34 m).
        if r._search.target == "km" and mt:find("mile") then
            local g = prev:match("(%a+)%s+to the%s*$") or prev:match("(%a+)%s+per%s*$")
            if g then
                g = g:lower()
                if g == "feet" or g == "foot" or g == "yard" or g == "yards"
                   or g == "inch" or g == "inches" then keep = false end
            end
        end
        -- Suppress numeric tail of a hyphenated compound number when prev_text reaches
        -- back far enough to expose the "-and-" connector (short compounds only).
        -- "five-hundred-and-eleven-foot" is accepted as an imperfect match (rare form).
        if prev:match("%-and%s*$") then keep = false end
        -- "foot"/"feet" as a body part or idiom, not a measurement.
        if mt:find("foot") or mt:find("feet") then
            local pw = _word_before_number(prev)   -- word BEFORE the number ("own", "with")
            -- Positional cues ("into the water", "over the threshold", "on the
            -- path") read as a MOVED/PLACED body part only when the value is
            -- one or two — a larger value is a distance that legitimately
            -- precedes these prepositions ("rose two hundred feet into the
            -- air", "measured three hundred feet over all" — the corpus-sweep
            -- misses in Treasure Island / 20k Leagues). Behavioral verbs
            -- (shuffling, stomping…) stay ungated: they never follow distances.
            local footn = _parse_num(mt)
            local body_scale = (not footn) or footn <= 2
            -- Strip a leading copula so "one foot IS wrapped around the calf"
            -- reaches the same participle cues as a bare "one foot wrapped…".
            -- Report #36 read that sentence as 30 cm: every body-verb cue here
            -- is anchored at the start of the following text, and "is" sat in
            -- front of all of them.
            local nxtv = nxt:gsub("^(%s*)[Ii]s%s+", "%1"):gsub("^(%s*)[Ww]as%s+", "%1")
                            :gsub("^(%s*)[Ww]ere%s+", "%1"):gsub("^(%s*)[Aa]re%s+", "%1")
            local drop_foot =
                (body_scale and (
                    nxt:match("^%s*in front")            or  -- "one foot in front of the other" (anchored: not "…foot tower in front of the cabin")
                    -- The same idiom with an adverb or participle wedged in:
                    -- "one foot carefully placed in front of the other" (Fourth
                    -- Wing), "putting one foot steadily in front of the other"
                    -- (Evicted). The anchor above cannot see past the inserted
                    -- word, so match the whole phrase unanchored instead — "in
                    -- front of the other/next" is only ever walking, never a
                    -- measurement, and the ≤ 2 gate still holds it in.
                    nxt:match("in front of the other")   or
                    nxt:match("in front of the next")    or
                    nxt:match("^%s*into ")               or
                    nxt:match("^%s*over ")               or
                    nxt:match("^%s*forward")             or
                    nxt:match("^%s*out of")              or
                    nxt:match("^%s*in the stirrup")      or
                    nxt:match("^%s*in the water")        or
                    nxt:match("^%s*in the door")         or
                    nxt:match("^%s*in the grave")        or
                    (nxt:match("^%s*on ") and not nxt:match("on%s*%d")) or
                    -- A foot being POSITIONED against something, the verb
                    -- following rather than preceding it (report #36: "one foot
                    -- is wrapped around the calf of her other leg" = 30 cm).
                    -- Kept inside the ≤2 gate: a genuine "fifty feet wrapped
                    -- around the post" is a length of rope, not an ankle.
                    -- "across" is safe from the "cross" cue — the pattern is
                    -- anchored, so " across the room" does not match.
                    nxtv:match("^%s*wrapp")             or
                    nxtv:match("^%s*hook")              or
                    nxtv:match("^%s*tuck")              or
                    nxtv:match("^%s*curl")              or
                    nxtv:match("^%s*propp")             or
                    nxtv:match("^%s*cross")
                )) or
                nxt:match("^%s*grounded")            or
                nxt:match("^%s*braced")              or
                nxt:match("^%s*firmly")              or
                nxt:match("^%s*shuffl")              or
                nxt:match("^%s*clomp")               or
                nxt:match("^%s*padd")                or
                nxt:match("^%s*dangl")               or
                nxt:match("^%s*stomp")               or
                nxt:match("^%s*scrambl")             or
                nxt:match("^%s*tapp")                or
                nxt:match("^%s*pacing")              or
                nxt:match("^%s*kick")
            -- "(his/your) own two feet"; "lifted/raised/hopping/… one foot".
            if pw and _FOOT_PREV_VERBS[pw] then drop_foot = true end
            -- "with one foot" / "on one foot" (hopping/standing), but keep a real
            -- "with one foot of clearance". Widened from "one" to the whole ≤2
            -- body scale for report #35: "had done so on two feet, and operated
            -- the door" is a creature walking upright, and read as 60 cm. The
            -- "of" exception still protects a genuine partitive ("standing on
            -- two feet of packed snow").
            if body_scale and (pw == "with" or pw == "on")
               and not nxt:match("^%s*of ") then
                drop_foot = true
            end
            -- "one's feet" / "one's foot" — possessive, never a count. The number
            -- "one" is glued to an apostrophe-s (straight ' or curly ’ = U+2019).
            if mt:find("one'") or mt:find("one\226\128\153") then drop_foot = true end
            -- "shifting/swaying weight from one foot to the other/another" —
            -- idiom, not a distance. Anchored on "the other"/"another" so
            -- "one foot to the left" survives. ("to another" ×3 in the Nesbø
            -- translations — first metric corpus, 2026-07-13.)
            if nxt:match("^%s*to the other") or nxt:match("^%s*to another") then
                drop_foot = true
            end
            local pwl = pw and pw:lower()
            -- "one hand, then one foot" (climbing) — enumerated limbs, and a
            -- hand this close to a lone "one foot" is never a distance.
            if footn == 1 and _last_words(prev, 4):lower():find("hand", 1, true) then
                drop_foot = true
            end
            -- "moving under one foot" / "Move one foot to just outside …" — a
            -- single covered/placed body part. "under one foot of snow" (real
            -- depth) survives via the "of" tail; larger values ("under six
            -- feet of earth") are ungated by footn == 1.
            if footn == 1 and (pwl == "under" or pwl == "move" or pwl == "moved"
               or pwl == "moves" or pwl == "moving")
               and not nxt:match("^%s*of ") then
                drop_foot = true
            end
            -- "with two feet instead of four" — a leg/limb-count comparison: the
            -- trailing cardinal is bare (no unit, closed by a comma/period), so
            -- it's anatomy, not a length. A genuine distance restated would carry
            -- its unit ("…instead of three hundred feet"), so that survives.
            local iw = nxt:match("^%s*instead of (%a+)%s*[,%.]")
            if iw and _is_number_word(iw) then drop_foot = true end
            -- "count … on the fingers/toes of one foot" — joke, not a measurement.
            if prev:find("fingers of", 1, true) or prev:find("toes of", 1, true) then
                drop_foot = true
            end
            -- "<count>-toed/-legged/-clawed/… feet/foot" — anatomy, not a
            -- distance (report #9). matched_text is exactly "<hyphenated
            -- compound> feet"/"foot" here (span=1 word from the fallback
            -- that read "three-toed" as 3), so the compound is the FIRST
            -- (and only) token before the unit word.
            do
                local first_tok, unit_w = mt:match("^(%S+)%s+(%a+)$")
                if first_tok and (unit_w == "feet" or unit_w == "foot") then
                    local suf = first_tok:match("%-(%a+)$")
                    if suf and _BODY_PART_SUFFIXES[suf] then drop_foot = true end
                end
            end
            if drop_foot then keep = false end
        end
        if mt:find("one") and mt:find("stone") and prev:find("with") then keep = false end
        if r._search.target == "cm" then
            local p = (r.prev_text or ""):lower()
            -- Allow trailing hyphen: "six-foot-[five-inch]" has prev ending "foot-"
            if p:match("feet[%s%-]?$") or p:match("foot[%s%-]?$") or p:match("%sft[%s%-]?$") then keep = false end
            -- Suppress the inches half of compound prime heights like 5'11" or 5′9″
            -- (or the curly-quoted 5’9”, most commercial EPUBs). The _ND boundary
            -- char is the prime/apostrophe between the feet digit and inches
            -- digit, so matched_text starts with one of these marks.
            -- This never happens for a legitimate standalone inches measurement.
            local mt1 = r.matched_text:sub(1, 1)
            if mt1 == "'" or mt1 == '"'
               or r.matched_text:sub(1, 3) == _PRIME
               or r.matched_text:sub(1, 3) == _DPRIME
               or r.matched_text:sub(1, 3) == FootFree._CAPOS
               or r.matched_text:sub(1, 3) == FootFree._CDQ then
                keep = false
            end
        end
        -- "N oz" immediately after "lbs?" is the tail of a compound like "1-lb 4-oz"
        if r._search.target == "g" then
            local p = (r.prev_text or ""):lower()
            if p:match("lbs?%s*$") or p:match("pounds?%s*$") then keep = false end
        end
        -- Suppress mid-word false positives: if next_text starts with a letter
        -- immediately (no leading space/punctuation), the match ended inside a
        -- longer word. e.g. "mi" matching the first 2 chars of "minutes".
        -- Exception: prime/quote matches end in a non-letter symbol (″ ′ " ' ’ ”)
        -- so they can't be mid-word; "3″ in diameter" legitimately precedes a
        -- letter and must not be dropped here.
        local _mt_end1 = r.matched_text:sub(-1)
        local _ends_prime = _mt_end1 == "'" or _mt_end1 == '"'
            or r.matched_text:sub(-3) == _PRIME or r.matched_text:sub(-3) == _DPRIME
            or r.matched_text:sub(-3) == FootFree._CAPOS or r.matched_text:sub(-3) == FootFree._CDQ
        -- (The year/decade possessive guard — "2001's Ghosts of Mars" read as
        -- 2001 ft — used to live here, testing the document's next character
        -- for an "s". It moved into FootFree._prime_fp_reason, which runs on
        -- the prime passes themselves and widens the same test from "s" to any
        -- letter, so "86'd" and "o'clock" are covered too. Kept in ONE place
        -- deliberately: two copies of a rule that are supposed to agree, and
        -- silently do not, is how the cache-65 bug happened.)
        if not _ends_prime and (r.next_text or ""):match("^[a-zA-Z]") then
            -- The letter can also come from the NEXT BLOCK: when the match
            -- ends at its node's last character (sign/label paragraphs —
            -- "ELEVATION: 2,200 FEET" then "POPULATION: ZERO"), crengine's
            -- next-context starts with the following block's text and no
            -- separator. Only drop when the letter is truly adjacent in the
            -- SAME text node; at a node boundary it can't be mid-word.
            local drop_mid = true
            local pfx, off = _xpointer_offset(r["end"])
            if pfx ~= r["end"] and off then
                local okc, c = pcall(function()
                    return doc:getTextFromXPointers(r["end"], pfx .. tostring(off + 1))
                end)
                if okc and (not c or not c:match("[a-zA-Z]")) then drop_mid = false end
            end
            if drop_mid then keep = false end
        end

        -- Mirror of the guard above, for the LEFT boundary. crengine's \b
        -- doesn't honor a leading word boundary either, so the unit alternation
        -- matches an alias glued to the END of a longer word: "ft" in "left"/
        -- "aft"/"swift", "mile"/"mi" in "smile"/"semi"/"Naomi", "pt" in "except"/
        -- "Sept", "pound" in "compound". The unit token is the trailing token of
        -- matched_text; reject when the character right before it is a letter. A
        -- real measurement has a digit, space, hyphen, prime or punctuation there
        -- ("6ft", "6 ft", "six-foot"), so this never drops a genuine unit.
        if keep and not _ends_prime then
            local best
            local sufs = FootFree._IMPERIAL.preferred() ~= "metric"
                and FootFree._IMPERIAL.suffixes or _UNIT_SUFFIXES
            for _, u in ipairs(sufs) do
                if u ~= "°F" then
                    local ul = u:lower()
                    if #ul > 0 and mt:sub(-#ul) == ul and (not best or #ul > #best) then
                        best = ul
                    end
                end
            end
            if best then
                local before = mt:sub(-#best - 1, -#best - 1)
                if before:match("%a") then keep = false end
            end
        end

        -- NOTE: pounds classifier and UK volume recalculation happen in
        -- _apply_settings_to_matches(), called after _finishScan saves the sidecar.
        -- Suppress fractional tail: "a half pounds" / "half pounds" when prev
        -- ends with "and" — it is the second half of "N and a half pounds".
        do
            local frac_starts = {"a half", "half a", "half ", "a quarter",
                                 "a third", "two thirds", "one third", "three quarters"}
            for _, fw in ipairs(frac_starts) do
                if mt:sub(1, #fw) == fw then
                    if prev:match("%sand%s*$") or prev:match("%sand%sa%s*$") then
                        keep = false
                    end
                    break
                end
            end
        end
        -- Suppress the inches-half of a dimension like "4′ × 2″" only when the
        -- "×" *immediately* precedes this match (prev ends in "× "). Matching
        -- "×" anywhere in the context window wrongly dropped a separate inch
        -- measurement that merely followed a dimension — e.g. the 3″ in
        -- "4′ × 2″. The pipe was 3″ in diameter." (The seen_end/seen_start
        -- dedup in _fast_scan_matches already blocks the true inches-half, so
        -- this is a belt-and-suspenders guard for the pat1-didn't-fire case.)
        if prev:match(_TIMES .. "%s*$") then
            local disp = _display(mt)
            if disp:match("^[0-9]+" .. _DPRIME) or disp:match('^[0-9]+"')
               or disp:match("^[0-9]+" .. FootFree._CDQ) then
                keep = false
            end
        end
        -- Decimal false positive: _ND uses [^0-9,] as boundary, so the "."
        -- in "0.5 inches" also creates a spurious ".5 inches" match.
        -- Suppress when matched_text starts with the boundary char "." (period).
        if r.matched_text:match("^%.") then keep = false end
        -- Middle-dot decimal (Victorian British: "·485″" = 0.485″): the mid-dot
        -- U+00B7 is an _ND boundary char, so the digits parse as an integer and
        -- the value comes out 1000× too large. No mid-dot decimal support in
        -- _parse_num, so suppress rather than show a wrong value.
        if r.matched_text:match("^\194\183") then keep = false end
        -- Closing quotation mark read as an inches/feet glyph: the prime-pass
        -- number tolerates trailing punctuation, so '"January 1836." ' matches
        -- ' 1836."' → 4 700 cm. A real prime/quote measurement has a DIGIT
        -- immediately before the glyph ("6'", '3.5"'); a quote right after
        -- ./,/;/etc. is punctuation ending quoted text.
        do
            local body
            if r.matched_text:sub(-3) == _PRIME or r.matched_text:sub(-3) == _DPRIME
               or r.matched_text:sub(-3) == FootFree._CAPOS or r.matched_text:sub(-3) == FootFree._CDQ then
                body = r.matched_text:sub(1, -4)
            elseif r.matched_text:sub(-1) == "'" or r.matched_text:sub(-1) == '"' then
                body = r.matched_text:sub(1, -2)
            end
            if body and not body:sub(-1):match("%d") then keep = false end
        end
        -- The same glyph ENDING A QUOTATION, with a digit legitimately before
        -- it: '“Reach 18”' (a call sign), '“Bolivian Exploration, 1913–1914”'
        -- (a citation). The digit test above cannot see these — the character
        -- before the glyph really is a digit, exactly as in a true 18" — so the
        -- tell is an unmatched OPENING curly quote earlier in the context.
        -- Bare inches only: a spoken height reads '5'10”', which carries a feet
        -- mark and is matched by the compound pattern, so it never lands here.
        -- Corpus check across 45 books before adding this: 4 matches sit inside
        -- an open quotation and ALL FOUR are citations or call signs — zero are
        -- genuine measurements. One of them ("1913–1914”" -> -5 000 cm) was a
        -- live false positive nobody had reported yet.
        do
            local mtx = r.matched_text or ""
            local tail = mtx:sub(-3)
            if tail == _DPRIME or tail == FootFree._CDQ then
                local body = mtx:sub(1, -4)
                local has_feet = body:find("'", 1, true)
                    or body:find(_PRIME, 1, true)
                    or body:find(FootFree._CAPOS, 1, true)
                if not has_feet then
                    local p = r.prev_text or ""
                    local _, opens  = p:gsub(FootFree._CLDQ, "")
                    local _, closes = p:gsub(FootFree._CDQ, "")
                    if opens > closes then keep = false end
                end
            end
        end
        -- Product model numbers: a comma between the number and the unit (e.g.
        -- "VTS989, kn") never appears in real measurements.
        if r.matched_text:match("%d,%s*%a") then keep = false end
        -- URL path fragments: a slash directly between the number and the
        -- unit ("…gamasutra.com/view/news/178650/League_of_Legends…" read
        -- "178650/League" as 860 000 km — Hooked's endnotes). Never prose;
        -- ASCII fractions are digit/digit, so "19-3/10 miles" doesn't trip.
        if r.matched_text:match("%d/%a") then keep = false end

        -- ── Back-of-book indexes and endnote lists ──────────────────────────
        -- The number-walk collects words backwards from the unit, and in an
        -- index entry the words behind the unit are page numbers. "amputations
        -- 263-4, 268; amputation tattoos 279; foot" read as 85 m. All four
        -- rules below are the same principle — the number must be ADJACENT to
        -- the unit, with nothing between them but whitespace or a hyphen —
        -- and all four were measured across the 187-book English corpus
        -- (2026-08-20) with zero legitimate matches caught.
        --
        -- A semicolon between the number and the unit. Written In Bone's index
        -- alone had six ("279; foot", "186-7, 188, 197; feet"). 6 corpus hits,
        -- all wrong. (The comma twin is the model-number rule just above.)
        if r.matched_text:match("%d%s*;%s*%a") then keep = false end
        -- A BLOCK BREAK immediately before the unit word: the number is the last
        -- thing in one paragraph and the unit the first thing in the next, which
        -- is what an index or a table of contents looks like ("287\nfeet",
        -- "116, 268n\nStone", "450\nGal"). 13 corpus hits, all wrong.
        -- Deliberately anchored at the UNIT: a <br/> inside a spelled compound
        -- ("four-and-a-<br/>half feet", smoketest5 CH26 case E) puts the break
        -- mid-number, where it is legitimate, and this rule cannot see it.
        if r.matched_text:match("\n%s*%a+%s*$") then keep = false end
        -- A sentence-ending period crossed on the way back ("30. Fathom" from a
        -- table of contents, "276-277.\n11. Pt" from an endnote list). A real
        -- measurement writes its period AFTER the unit ("6 ft."), never between
        -- the figure and it. Requires whitespace after the period, so decimals
        -- ("3.5 inches") and abbreviations are untouched. 9 corpus hits, all
        -- wrong.
        if r.matched_text:match("%d%.%s") then keep = false end
        -- A runaway span. The compound "N feet M inches" walk can glue two
        -- numbers thousands of characters apart: Moby Dick yielded a single
        -- 9,331-character "match" spanning most of a chapter, and Two Years
        -- Before the Mast one of 6,847. Corpus median is 11 characters and the
        -- 99.9th percentile is 41, so 80 is a backstop nothing real approaches
        -- — exactly two hits in 9,763 exceed it, and both are those runaways.
        if #r.matched_text > 80 then keep = false end
        -- A word GLUED to the number that is not a unit: "8Katzmarzyk PT" (an
        -- endnote reference number fused to an author's surname, with the "pt"
        -- pint alias landing on the initials) read as 3.8 litres. The glued
        -- forms that ARE legitimate all spell a unit alias — "100lb", "95mph",
        -- "6ft", "3QT" — plus the dimension "x" of "10x10 feet" and ordinal
        -- suffixes ("6th, 4 miles"). 28 corpus hits carry a glued letter run;
        -- exactly the 3 non-alias ones are wrong.
        do
            local run = r.matched_text:match("^[0-9][0-9,.]*(%a+)")
            if run then
                local rl = run:lower()
                if rl ~= "x" and rl ~= "st" and rl ~= "nd" and rl ~= "rd"
                   and rl ~= "th" and not _identify_unit(rl) then
                    keep = false
                end
            end
        end
        -- Geographic coordinates ("37°18'32\" N 115°36'52\" W"): the degree
        -- symbol leads the match because the degrees figure sits before it, so a
        -- length match never begins with ° (a real prime height like 5'9" starts
        -- with a digit). Drop anything whose matched_text opens with ° (U+00B0).
        if r.matched_text:match("^\194\176") then keep = false end
        -- Screen/TV sizes: inches near a screen word stay imperial (readers think
        -- of TVs in inches). Scan the surrounding context for a screen noun.
        if keep and r._search.target == "cm" and mt:find("inch") then
            for w in (prev .. " " .. nxt):gmatch("[%w'\226\128\153%-]+") do
                if _SCREEN_WORDS[w:lower()] then keep = false; break end
            end
        end
        -- Pints in a drink/serving context: drop, to preserve "number of glasses".
        if keep and r._search.target == "liters" and mt:find("pint") then
            for w in (prev .. " " .. nxt):gmatch("[%w'\226\128\153%-]+") do
                if _DRINK_WORDS[w:lower()] then keep = false; break end
            end
        end
        -- Mangled vulgar fraction: some EPUBs render "¾" as "3 4'" — a lone
        -- numerator digit, a space, then a single-digit "foot" prime (denominator).
        -- crengine DROPS the lone "3" from prev_text (it's saved as "…still ", no
        -- digit), so read the few chars immediately before the match span instead.
        -- Numerator < denominator (¾, ⅔, ½ …) confirms the fraction; real prose
        -- almost never writes a lone digit immediately before a single-digit prime.
        do
            local denom = r.matched_text:match("^%s*(%d)['\226]")
            if denom and doc then
                local pfx, off = _xpointer_offset(r.start)
                local numer
                if pfx ~= r.start and off and off > 0 then
                    local pre_xp = pfx .. tostring(math.max(0, off - 4))
                    local okp, pre = pcall(function()
                        return doc:getTextFromXPointers(pre_xp, r.start)
                    end)
                    if okp and pre then numer = pre:match("%f[%d](%d)%s*$") end
                end
                numer = numer or prev:match("%f[%d](%d)%s*$")  -- in case it IS in prev
                if numer and tonumber(numer) < tonumber(denom) then
                    keep = false
                end
            end
        end
        if keep then table.insert(filtered, r) end
    end

    -- Collapse overlapping spans — but only now, AFTER the legacy false-positive
    -- filters above have run. Doing it on the raw scan output would let a
    -- soon-to-be-rejected over-catch (e.g. "fifteen-foot-wide stone") win the
    -- overlap and evict the legit match ("fifteen-foot") that the stone guard
    -- would have kept. Among survivors, the longest span at a shared start wins,
    -- which collapses an un-merged foot+inch compound (a "six-foot" hit plus the
    -- overlapping "six-foot-five-inch" hit) to a single match.
    filtered = _filter_overlapping_matches(filtered)

    -- Phase breakdown, logged unconditionally and BEFORE the completion marker
    -- below (sweep.py's vm_scan greps for "match(es) found" to know the scan is
    -- done, then waits on the sidecar tail — keeping that line last preserves
    -- the ordering it relies on). Logged rather than report-only so a headless
    -- VM run can harvest it straight from the reader log, with no dev mode and
    -- no /mnt/macos/debug share.
    local st = FootFree._scan_t
    if st then
        logger.info(string.format(
            "FootFree: scan phases  walk=%.3fs (%d pass%s%s)  probe=%.3fs (%d skipped)"
            .. "  loop=%.3fs (%d hits, %.2fms/hit)"
            .. "  gate=%.3fs  literal=%.3fs (%d pass%s)",
            (st.walk or 0) - (st.probe or 0), st.passes or 1,
            (st.passes or 1) == 1 and "" or "es",
            st.shy and ", shy" or "",
            st.probe or 0, st.skipped or 0, st.loop or 0, st.hits or 0,
            (st.hits or 0) > 0 and (st.loop or 0) * 1000 / st.hits or 0,
            st.gate or 0, (st.lit or 0) - (st.gate or 0),
            st.litn or 0, (st.litn or 0) == 1 and "" or "es"))
    end
    logger.info(string.format("FootFree: %d match(es) found  total=%.3fs", #filtered, t_total or 0))
    _save_sidecar(doc.file, filtered)

    -- Dev-only diagnostics, gated behind dev mode. Both the scan report and the
    -- per-book report write to the Mac↔VM shared debug folder (/mnt/macos/debug),
    -- which doesn't exist on a user's device — gating keeps every user scan from
    -- spawning a shell and leaving a stray /mnt/macos/debug dir behind.
    if debug_report then
        os.execute("mkdir -p /mnt/macos/debug 2>/dev/null")
        local fh = io.open("/mnt/macos/debug/scan_report.txt", "w")
        if fh then
            fh:write(string.format("footcream scan report\nBook: %s\n%d match(es)  total=%.3fs\n%s\n",
                doc.file, #filtered, t_total or 0, string.rep("-", 60)))
            -- Phase timing. (The old per-pattern `t_per_pat` breakdown this
            -- replaces had been dead since the single-alternation rewrite —
            -- every caller passes {}, so the block never printed a row.)
            if st then
                local tt = (t_total or 0) > 0 and t_total or 1
                local function pct(v) return (v or 0) * 100 / tt end
                fh:write(string.format(
                    "phase timing:\n"
                    .. "  document walk   %7.3fs  %5.1f%%   %d pass(es)%s\n"
                    .. "  per-hit loop    %7.3fs  %5.1f%%   %d hits, %.2f ms/hit\n"
                    .. "  prime/degF gate %7.3fs  %5.1f%%   whole-book text read\n"
                    .. "  literal passes  %7.3fs  %5.1f%%   %d pass(es)\n"
                    .. "  unaccounted     %7.3fs  %5.1f%%   (filters, overlap collapse, save)\n",
                    st.walk or 0, pct(st.walk), st.passes or 1, st.shy and "  [SHY: one per alias]" or "",
                    st.loop or 0, pct(st.loop), st.hits or 0,
                    (st.hits or 0) > 0 and (st.loop or 0) * 1000 / st.hits or 0,
                    st.gate or 0, pct(st.gate),
                    (st.lit or 0) - (st.gate or 0), pct((st.lit or 0) - (st.gate or 0)),
                    st.litn or 0,
                    (t_total or 0) - (st.walk or 0) - (st.loop or 0) - (st.lit or 0),
                    pct((t_total or 0) - (st.walk or 0) - (st.loop or 0) - (st.lit or 0))))
                fh:write(string.rep("-", 60) .. "\n")
            end
            for i, r in ipairs(filtered) do
                fh:write(string.format("[%3d] %s\n      Context: ...%s[%s]%s...\n\n",
                    i, _convert(r), r.prev_text or "", _display(r.matched_text), r.next_text or ""))
            end
            fh:close()
        end
        _write_book_report(doc, filtered)
    end

    if not in_subprocess then
        -- Apply current settings (UK volumes, pounds classifier) to the
        -- just-scanned matches and update the live display.
        local use_uk = self._uk_volumes and self.ui.document and _is_uk_book(self.ui.document)
        local applied = _apply_settings_to_matches(filtered, self._distinguish_pounds, use_uk)
        local n = #applied
        self._all_matches   = n > 0 and applied or nil
        self._current_boxes = {}
        self._scanned       = true  -- a scan just completed (even if 0 matches) (6.1)
        if self.view then UIManager:setDirty(self.view.dialog, "ui") end
        self:_announceScan(n, doc)
        self:_runAfterScan()
    end
end

-- Scan-completion notice, contextual to the active mode (user-specified
-- wording): a converted (mode-3) book reports the CONVERSION — the scan that
-- just ran there is the post-apply leftovers pass, and "32 units found" reads
-- as the scanner losing units — using the book's full unit count, same as the
-- menu status line. Mode 1 reports the underlines. A mode-3 book not yet
-- converted keeps the neutral wording (transient — the auto-apply follows).
function FootFree:_scanNoticeText(n, doc)
    if self._tap_mode >= 2 and doc and _is_metric_mode(doc.file) then
        -- NOT `local _, stamped` — `_` is gettext (required at the top of this
        -- file), and discarding into it shadows the module for the rest of the
        -- block, so the _.ngettext below indexes a number and the reader dies:
        --   main.lua:6389: attempt to index local '_' (a number value)
        -- The i18n pass introduced `_` as a module name into a file that used
        -- the `local _` discard idiom in five places; this was the one where
        -- the two overlapped. builder/check_gettext_shadow.py now fails the
        -- build on any recurrence.
        local _ver, stamped = _read_metric_version(doc.file)
        local total = (stamped and stamped > 0) and stamped or n
        -- TRANSLATORS: Toast after a scan of a book whose text has already been converted.
        -- %1 is the number of measurements.
        return T(_.ngettext("Converted %1 unit in book", "Converted %1 units in book", total), total)
    elseif self._tap_mode >= 2 then
        -- TRANSLATORS: Toast after a scan when the mode writes into the book's text but
        -- the conversion hasn't been applied yet. %1 is the number found.
        return T(_.ngettext("Scan complete: %1 unit found", "Scan complete: %1 units found", n), n)
    end
    -- TRANSLATORS: Toast after a scan in underline mode. %1 is the number of
    -- measurements now underlined.
    return T(_.ngettext("Underlined %1 unit in book", "Underlined %1 units in book", n), n)
end

-- ── Metric edition — apply / revert ──────────────────────────────────────────

-- Words that, when they immediately follow an ambiguous "foot" phrase, mark it
-- as a body-part idiom ("one foot in front of the other") rather than a
-- measurement. The in-place rewrite replaces by surface text book-wide, so
-- without this guard a real "one foot deep" match would also convert every
-- idiom "one foot" elsewhere. Mirrors the scanner's "one foot" exclusion so
-- mode 1 (highlight) and mode 3 (convert) stay consistent.
local _FOOT_IDIOM_NEXT = {
    "in front", "into", "onto", "over", "forward",
    "grounded", "braced", "firmly", "on",
}
local function _idiom_guard(original)
    local o = original:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if o == "one foot" or o == "a foot" then return _FOOT_IDIOM_NEXT end
    return nil
end
-- Arm the "Convert?" prompt to fire once the scan in flight completes.
--
-- EVERY path that kicks off a scan while a convert mode is active needs this.
-- It used to be copy-pasted at the two call sites that had it and simply
-- missing from the third — the menu's "Rescan book" — so rescanning a book in
-- mode 2/3 scanned happily and then did nothing at all. The log read
-- "321 match(es) found … subprocess complete" and the book never changed,
-- with no error and no prompt, which is indistinguishable from the plugin
-- being broken. Found on the VM 2026-08-07.
--
-- The 0.5s delay is load-bearing: shown in the same tick, the scan's queued
-- full-view refresh paints the page OVER the ConfirmBox, leaving a
-- half-visible "ghost" dialog whose buttons don't take taps. The Enable
-- toggle guards against the same failure with its own settle delay.
--
-- Conditions are re-checked inside the closure, not just here: a scan is
-- async, and the mode, the per-book enable, or the document itself can all
-- change while it runs.
-- `already_confirmed` skips the post-scan "Convert?" prompt, because consent
-- was given BEFORE the scan started — either by the reader answering
-- _confirmScanAndConvert on an explicit action, or by them ticking
-- "Auto-convert when opening a new book", which is itself the standing answer
-- for that path. Without it the reader is asked a question they have already
-- answered, after a wait, which is what made one action feel like three
-- (on-device report, 2026-08-17).
function FootFree:_armConvertAfterScan(already_confirmed)
    if self._tap_mode < 2 or not self._enabled then return end
    self._after_scan = function()
        UIManager:scheduleIn(0.5, function()
            local d = self.ui.document
            if d and self._tap_mode >= 2 and self._enabled
               and not _is_metric_mode(d.file)
               and self._all_matches and #self._all_matches > 0 then
                self:_applyMetricEdition(d, already_confirmed)
            end
        end)
    end
end

-- Ask BEFORE scanning, then run scan + convert as one uninterrupted action.
-- Used by every explicit entry point (Rescan book, the mode picker, a direction
-- change). Opening a book with auto-convert on deliberately does NOT come here:
-- the toggle is the consent there.
--
-- The already-converted and not-English checks run BEFORE the question, not
-- after it — asking and then refusing is worse than never asking.
-- `cancel_restore_mode` mirrors _applyMetricEdition's: declining from the mode
-- picker puts the previous mode back rather than leaving the reader in a
-- convert mode they just said no to.
function FootFree:_confirmScanAndConvert(doc, cancel_restore_mode, start_scan)
    if not doc or not doc.file then return end
    if self._tap_mode < 2 or not self._enabled then
        start_scan()          -- mode 1: nothing to confirm, just scan
        return
    end
    if _is_metric_mode(doc.file) then
        UIManager:show(InfoMessage:new{
            -- TRANSLATORS: Refusal shown when the book's text has already been converted. The
            -- quoted item is a menu entry - translate it exactly as you translate that entry,
            -- and keep 'Advanced' matching its menu name.
            text = _("This book is already converted.\nUse 'Remove Footcream data from this book' (Advanced) first."),
            timeout = 4,
        })
        return
    end
    local imp = FootFree._IMPERIAL.preferred() ~= "metric"
    -- TRANSLATORS: Name of the unit system being converted TO, inserted as %1 into the
    -- questions and progress messages below ('Convert this book's measurements to
    -- metric?', 'Converting to metric…'). Lowercase, mid-sentence.
    local dir_word = imp and _("imperial") or _("metric")
    local on_cancel
    if cancel_restore_mode then
        on_cancel = function()
            self._tap_mode = cancel_restore_mode
            G_reader_settings:saveSetting("footcream_tap_mode", cancel_restore_mode)
            logger.info("Footcream: scan+convert declined — mode restored to "
                        .. cancel_restore_mode)
            UIManager:show(Notification:new{
                -- TRANSLATORS: Toast confirming the mode was left as it was after the user
                -- declined to convert. %1 is a mode name such as 'Metric only (in text)'.
                text = T(_("Kept mode: %1"), self:_modeLabel(cancel_restore_mode)),
            })
            if self.view then UIManager:setDirty(self.view.dialog, "ui") end
        end
    end
    self._confirm(
        self._tap_mode == 2
            -- TRANSLATORS: Asked BEFORE scanning, when mode 2 will then edit the book:
            -- conversions are added next to the existing measurements. %1 is 'metric' or 'imperial'.
            -- This one question covers BOTH steps, so the translation must say the book
            -- will be scanned AND that conversions will be added. A suggestion offering
            -- only the adding half is the older, convert-only wording — do not accept it.
            and T(_("Scan this book and add %1 conversions alongside its measurements?"),
                  dir_word)
            -- TRANSLATORS: Asked BEFORE scanning, when mode 3 will then edit the book:
            -- measurements are replaced by their conversions. %1 is 'metric' or 'imperial'.
            -- This one question covers BOTH steps, so the translation must say the book
            -- will be scanned AND that its measurements will be converted. A suggestion
            -- offering only the converting half is the older, convert-only wording — do
            -- not accept it.
            or  T(_("Scan this book and convert its measurements to %1?"), dir_word),
        -- TRANSLATORS: Button that starts the scan and then rewrites the book's text; the
        -- other button is the shared 'Cancel'.
        _("Scan and convert"), function()
            logger.info("FootFree: scan+convert confirmed up front")
            -- Stamp for the end-to-end timer. What the reader experiences is
            -- tap -> notice, which spans the scan, the rewrite, the reload AND
            -- KOReader's re-render; the scan phase log alone accounts for well
            -- under a quarter of it. Class table, not a local: main.lua is at
            -- the 200-locals-per-chunk ceiling.
            FootFree._action_t0 = _now()
            self:_armConvertAfterScan(true)
            start_scan()
        end, nil, on_cancel)
end

-- Convert an ALREADY-SCANNED book. `skip_confirm` is set when consent was
-- given before the scan (see _armConvertAfterScan); otherwise this asks its
-- own, shorter question — there is no scan to warn about here.
--
-- cancel_restore_mode (optional): mode to fall back to when the user
-- DECLINES the confirm — set only for picker-originated changes, so a
-- canceled pick snaps back to the mode the picker opened with instead of
-- stranding the book unconverted in a convert mode. Book-originated prompts
-- (new book under an established convert mode, Enable toggle, tap) pass
-- nothing: declining those means "not this book", not "change my mode".
function FootFree:_applyMetricEdition(doc, skip_confirm, cancel_restore_mode)
    -- Which way this conversion goes ("metric"/"imperial"), for the dialogs.
    local imp = FootFree._IMPERIAL.preferred() ~= "metric"
    -- TRANSLATORS: Name of the unit system being converted TO, inserted as %1 into the
    -- questions and progress messages below ('Convert this book's measurements to
    -- metric?', 'Converting to metric…'). Lowercase, mid-sentence.
    local dir_word = imp and _("imperial") or _("metric")
    if _is_metric_mode(doc.file) then
        UIManager:show(InfoMessage:new{
            -- TRANSLATORS: Refusal shown when the book's text has already been converted. The
            -- quoted item is a menu entry - translate it exactly as you translate that entry,
            -- and keep 'Advanced' matching its menu name.
            text = _("This book is already converted.\nUse 'Remove Footcream data from this book' (Advanced) first."),
            timeout = 4,
        })
        return
    end
    if not self._all_matches or #self._all_matches == 0 then
        -- Distinguish "scanned, genuinely no units" from "not scanned yet" —
        -- the two used to share the misleading "scan first" message.
        UIManager:show(InfoMessage:new{
            text = self._scanned
                -- TRANSLATORS: Shown when a scan finished and the book genuinely contains no
                -- measurements to convert. %1 is 'imperial' or 'metric'.
                and T(_("No %1 measurements found in this book — nothing to convert."),
                      -- TRANSLATORS: The unit system searched for, inserted as %1 into 'No %1
                      -- measurements found in this book'. Lowercase, mid-sentence.
                      imp and _("metric") or _("imperial"))
                -- TRANSLATORS: Shown when the book has not been scanned yet, so there is nothing
                -- to convert. 'hints' are the underlined measurements Footcream finds.
                or  _("No hints yet — scan the book first."),
            timeout = 3,
        })
        return
    end
    -- Both convert modes rewrite the book's own text. Confirm first — this is
    -- easy to trigger inadvertently (e.g. via the Enable toggle while the
    -- global mode happens to be set to convert).
    -- One line only — the how/undo details live in the Mode picker captions
    -- and the long-press help texts (the old second paragraph read as
    -- clutter; user feedback 2026-07-14).
    if not skip_confirm then
        local on_cancel
        if cancel_restore_mode then
            on_cancel = function()
                self._tap_mode = cancel_restore_mode
                G_reader_settings:saveSetting("footcream_tap_mode", cancel_restore_mode)
                logger.info("Footcream: convert declined — mode restored to "
                            .. cancel_restore_mode)
                UIManager:show(Notification:new{
                    -- TRANSLATORS: Toast confirming the mode was left as it was after the user
                    -- declined to convert. %1 is a mode name such as 'Metric only (in text)'.
                    text = T(_("Kept mode: %1"), self:_modeLabel(cancel_restore_mode)),
                })
                if self.view then UIManager:setDirty(self.view.dialog, "ui") end
            end
        end
        self._confirm(
            self._tap_mode == 2
                -- TRANSLATORS: Asked before mode 2 edits the book: conversions are added next to
                -- the existing measurements. %1 is 'metric' or 'imperial'.
                and T(_("Add %1 conversions alongside this book's measurements?"),
                      dir_word)
                -- TRANSLATORS: Asked before mode 3 edits the book: measurements are replaced by
                -- their conversions. %1 is 'metric' or 'imperial'.
                or  T(_("Convert this book's measurements to %1?"),
                      dir_word),
            -- TRANSLATORS: Button that starts rewriting the book's text; the other button is
            -- the shared 'Cancel'.
            _("Convert"), function()
                -- Breadcrumb: distinguishes "tap never registered" (ghost
                -- dialog) from "apply failed" when diagnosing a stuck convert.
                logger.info("FootFree: convert confirmed")
                self:_doApplyMetricEdition(doc)
            end, nil, on_cancel)
        return
    end
    self:_doApplyMetricEdition(doc)
end

function FootFree:_doApplyMetricEdition(doc)
    logger.info("FootFree: applying metric edition — " .. #self._all_matches .. " matches")

    -- Process matches in document order so the reverse map records each
    -- converted value's original phrase in reading order. The load path
    -- re-scans the converted text (also document order) and pairs the Nth
    -- occurrence of a converted string with the Nth original here — so two
    -- different originals that round to the same string ("two pounds three
    -- ounces" and "two pounds, four ounces" → "1.0 kg") each recover their
    -- own text instead of both showing the first one (6.2).
    local ordered = {}
    for _, r in ipairs(self._all_matches) do ordered[#ordered + 1] = r end
    table.sort(ordered, function(a, b)
        return _xp_key_less(_xp_numkey(a.start), _xp_numkey(b.start))
    end)

    -- Build the replacement list (deduped by surface text — the in-place
    -- rewrite replaces all occurrences of each phrase) and a converted->original
    -- reverse map (one original per occurrence, in order) for "show original".
    local seen = {}
    local reps = {}
    local rev_map = {}
    local kept_count = {}   -- surface text -> number of KEPT (weight) matches
    local rep_of     = {}   -- surface text -> its rep (to stamp .expected later)
    -- Captured now: after the reload, _all_matches holds only the rewrite's
    -- leftovers, but the menu status line keeps showing this full count.
    local hint_total = #self._all_matches
    for _, r in ipairs(ordered) do
        local original = _display(r.matched_text)
        local metric   = _metric_only(r)
        -- Vague quantities ("a few hundred pounds") are left as the original
        -- imperial text in Mode 3: an inline "≈ 90–230 kg" reads as an awkward
        -- parenthetical, not natural prose. They still show their band on tap in
        -- Mode 1. (Skipping here also avoids the old "over a few 45 kg" break.)
        if r._vague then
            original = nil
        end
        if original and metric then
            kept_count[original] = (kept_count[original] or 0) + 1
            -- Mode 2 ("Metric alongside original") APPENDS the conversion
            -- as a parenthetical gloss instead of replacing the text:
            -- "six feet (1.8 m)". Same rewrite machinery, different `to`.
            -- This is also the reverse-map key: the map is keyed on the
            -- string that actually stands in the converted book, since
            -- that's what the position scan re-locates for hold-to-flag.
            local book_text = self._tap_mode == 2
                and (original .. " (" .. metric .. ")")
                or metric
            if not seen[original] then
                seen[original] = true
                local rep = { from = original, to = book_text }
                local guard = _idiom_guard(original)
                if guard then rep.guard_next = guard end
                reps[#reps + 1] = rep
                rep_of[original] = rep
            end
            local info = rev_map[book_text]
            if not info then
                info = { cat = r._cat or "", originals = {} }
                rev_map[book_text] = info
            end
            info.originals[#info.originals + 1] = original
        end
    end
    if #reps == 0 then return end
    -- Currency/weight homonym guard for the in-place rewrite. A spelled pound
    -- phrase ("ten pounds") can be a genuine weight in one place and sterling
    -- currency (£) elsewhere in the same book. The scanner suppresses the
    -- currency occurrences positionally (Mode 1), but the in-place rewrite is
    -- global surface-string replacement and can't see positions, so it would
    -- convert the currency uses too ("ten pounds (£10)" → "4.5 kg (£10)").
    -- Stamp the number of KEPT weight matches; the rewriter skips any phrase
    -- whose textual occurrences OUTNUMBER them (= some occurrence was currency).
    -- Converting currency is worse than leaving a colliding genuine weight as
    -- imperial — and that weight still converts in the positional Mode 1.
    for original, rep in pairs(rep_of) do
        if original:lower():find("pound") then
            rep.expected = kept_count[original]
        end
    end
    -- Imperial direction: the same collision exists for money-vetoed metric
    -- occurrences ("$2m" is millions; "9mm" next to a count word is handled
    -- positionally; enumerations are skipped positionally). The scanner
    -- suppresses those per-occurrence, but the global rewrite can't — so
    -- stamp EVERY rep with its kept count and let the rewriter skip any
    -- phrase whose textual occurrences outnumber the scanner-approved ones.
    -- Leaving a colliding genuine measurement unconverted beats converting a
    -- money amount (same trade-off as the pounds guard above).
    if FootFree._IMPERIAL.preferred() ~= "metric" then
        for original, rep in pairs(rep_of) do
            rep.expected = kept_count[original]
        end
    end

    local patches = _patches_path(doc.file)
    local Metric = _metric_module()
    if not Metric then
        UIManager:show(InfoMessage:new{
            -- TRANSLATORS: Error when the part of Footcream that edits the book's text can't
            -- be loaded, so the book was left untouched. The install is incomplete; the
            -- underline mode still works.
            text = _("Could not load the metric converter module."), timeout = 4,
        })
        return
    end

    -- Run the EPUB rewrite (pure Lua, libarchive) in a dismissable subprocess so
    -- the UI doesn't freeze — the rewrite takes a few seconds on a real book. The
    -- rewriter guards partial writes with an .inprogress marker + a backup of the
    -- original epub, so an interrupted run is safely auto-reverted on next open.
    local Trapper = require("ui/trapper")
    -- Captured before the subprocess closure: mode 2 appends the gloss (the
    -- rewriter needs its two-phase pass), mode 3 replaces.
    local apply_opts = self._tap_mode == 2 and { append = true } or nil
    local apply_mode = self._tap_mode
    local dir_word   = FootFree._IMPERIAL.preferred() ~= "metric"
                       -- TRANSLATORS: Name of the unit system being converted TO, inserted as %1 into the
                       -- questions and progress messages below ('Convert this book's measurements to
                       -- metric?', 'Converting to metric…'). Lowercase, mid-sentence.
                       and _("imperial") or _("metric")
    Trapper:wrap(function()
        -- An invisible, UNDISMISSABLE shield over the rewrite.
        --
        -- Passing nil here (what this used to do) gets Trapper's own invisible
        -- trap widget — which is invisible but still CANCEL-ON-TAP. Nothing is
        -- drawn, yet any tap anywhere silently abandons the rewrite. That is
        -- the worst possible pairing: the screen cannot tell the reader that a
        -- tap cancels, and tapping is precisely what a reader does when a long
        -- action looks stuck. On a Kobo an 87s scan was followed one second
        -- later by "convert subprocess did not complete" — the reader had
        -- tapped the apparently-frozen screen (device log, 2026-08-17). The
        -- comment that stood here claimed the tap-to-cancel was gone. It never
        -- was; that was read off the call, not off Trapper's source.
        --
        -- So: our own TrapWidget, shown by us and handed to Trapper as a table,
        -- which makes it caller-owned (Trapper neither shows nor closes it),
        -- with its single dismissal path neutered. Taps are still SWALLOWED, so
        -- the book cannot turn pages under a rewrite in flight — they just no
        -- longer throw the work away. The corner ring carries the progress, as
        -- one continuous ring across scan, rewrite and re-locate.
        local TrapWidget = require("ui/widget/trapwidget")
        local shield = TrapWidget:new{ text = nil, resend_event = false }
        -- Every dismissal route in TrapWidget (tap, hold, swipe, pan-release,
        -- any key) funnels through this one method, and it returns true to mark
        -- the event consumed. Replacing it keeps the swallowing, drops the
        -- dismissing.
        shield._dismissAndResend = function() return true end
        UIManager:show(shield)
        -- Undismissable must not mean inescapable. If the rewrite subprocess
        -- ever wedges, nothing else would take the shield down and the reader
        -- would be locked out of their own book. So fire Trapper's dismissal on
        -- a timer as the last resort — the same code path a tap used to take,
        -- now on a deadline instead of an accident. Abandoning is safe: the
        -- rewriter guards partial writes with an .inprogress marker and a
        -- backup of the original epub, auto-reverted on next open. 300s matches
        -- the scan's deadline and is two orders of magnitude above a real
        -- rewrite (312 matches convert in about a second).
        local convert_watchdog = function()
            if shield.dismiss_callback then
                logger.warn("FootFree: convert exceeded 300s — abandoning")
                shield.dismiss_callback()
            end
        end
        UIManager:scheduleIn(300, convert_watchdog)
        -- Stops short of a full circle: the reload and the re-locate that
        -- follow own the last slice, so the ring must not look finished here.
        self:_startRingPulse(_RING.tail_from, _RING.relocate_from)
        local _tAP = _now()
        local completed, result = Trapper:dismissableRunInSubprocess(function()
            return Metric.apply(doc.file, patches, reps, apply_opts)
        end, shield, true)
        logger.info(string.format("FootFree: rewrite took %.2fs", _now() - _tAP))
        UIManager:unschedule(convert_watchdog)
        UIManager:close(shield)
        self:_stopRingPulse()
        if not completed then
            logger.warn("FootFree: convert subprocess did not complete")
            UIManager:show(InfoMessage:new{
                -- TRANSLATORS: Error shown when the in-text conversion was interrupted before it
                -- finished. %1 is 'metric' or 'imperial'. The book is unchanged.
                text = T(_("Converting to %1 was interrupted — the book is unchanged."),
                         dir_word),
                timeout = 4,
            })
            return
        end
        result = result or ""
        if result:match("^OK:") then
            local n = tonumber(result:match(":(%d+)")) or 0
            logger.info("FootFree: metric edition applied, " .. n .. " file(s) modified")
            if n == 0 then
                -- Had measurements to convert, but the in-place rewrite matched
                -- NONE of them in the book's raw markup — i.e. the scanner's text
                -- and the file's bytes diverge (unusual markup/format). Surface it
                -- instead of silently reloading unchanged (which looks like the
                -- convert "refused"). This is the diagnostic for the Kobo report.
                UIManager:show(InfoMessage:new{
                    -- TRANSLATORS: Error when the conversion found measurements but couldn't locate
                    -- them in the book file itself, so nothing was changed. %1 is the number found, %2
                    -- is a mode name ('Underline units, tap for metric').
                    text = T(_.ngettext(
                        "Couldn't convert this book in place.\n\n%1 measurement was found, but it could not be matched in the book's text — its markup/format may not be supported for in-text conversion.\n\nThe '%2' mode still works for this book.",
                        "Couldn't convert this book in place.\n\n%1 measurements were found, but none could be matched in the book's text — its markup/format may not be supported for in-text conversion.\n\nThe '%2' mode still works for this book.",
                        #reps), #reps, self:_modeLabel(1)),
                    timeout = 10,
                })
                return
            end
            -- The sidecar stays on disk untouched: its xpointers are stale
            -- against the rewritten text (the load path won't use it while
            -- converted), but a revert restores byte-identical text and
            -- re-stamps the recorded mtime — making it instantly valid again,
            -- which is what lets mode switches skip the rescan entirely.
            -- Persist the converted->original map: in replace mode (3) it
            -- powers "show original units" AND hold-to-flag; in append mode
            -- (2) the original is already visible in the gloss, so the map's
            -- only consumer is hold-to-flag's position hit-testing.
            _save_reverse_map(doc.file, rev_map)
            -- Stamp the scanner version into the book's conversion, so a later
            -- CACHE_VERSION bump is detected on open and the book can refresh.
            -- The pre-conversion hint count rides along so the menu status line
            -- keeps reporting the book's full unit count while converted, and
            -- the applied mode so open/mode-switch flows can tell the styles apart.
            _write_metric_version(doc.file, hint_total, apply_mode,
                                  FootFree._IMPERIAL.preferred())
            -- Marks the post-reload onReaderReady (fresh plugin instance —
            -- hence the class field) to announce the conversion from the
            -- stamp: with the echo scan gone, no scan notice will fire.
            FootFree._just_converted = doc.file
            -- Hand the ring's position across the reload (which builds a fresh
            -- plugin instance, so an instance field wouldn't survive) — the
            -- re-locate leg resumes here instead of restarting lower down.
            FootFree._ring_carry = _RING.relocate_from
            -- Reload document (seamless — keeps xpointer position)
            self.ui:reloadDocument(nil, true)
        else
            UIManager:show(InfoMessage:new{
                -- TRANSLATORS: Generic failure when rewriting the book's text didn't work; the
                -- technical reason is appended on the next line, untranslated.
                text = _("Could not convert this book.") .. "\n" .. tostring(result),
                timeout = 5,
            })
        end
    end)
end

-- on_done (optional) runs after a successful revert + reload (used by callers
-- that need to act on the restored text, e.g. rescan).
function FootFree:_revertMetricEdition(doc, on_done)
    local patches = _patches_path(doc.file)
    local Metric = _metric_module()
    if not Metric then
        UIManager:show(InfoMessage:new{
            -- TRANSLATORS: Error when the part of Footcream that edits the book's text can't
            -- be loaded, so the book was left untouched. The install is incomplete; the
            -- underline mode still works.
            text = _("Could not load the metric converter module."), timeout = 4,
        })
        return
    end

    -- Run the EPUB restore (pure Lua, libarchive) in a dismissable subprocess so
    -- the UI doesn't freeze. The rewriter restores the original epub byte-for-byte
    -- from its backup, refusing if the on-disk file changed since conversion.
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local completed, result = Trapper:dismissableRunInSubprocess(function()
            return Metric.revert(doc.file, patches)
        -- TRANSLATORS: Progress message while the book's original measurements are being
        -- put back. Tapping it cancels.
        end, _("Restoring original text…"), true)
        if not completed then
            -- Dismissed by the user. If a refresh chain (revert → rescan →
            -- reconvert) queued this revert, abort the whole chain: a stale
            -- _pending_rescan would otherwise fire on a later open and
            -- auto-CONVERT (skip_confirm) a book whose revert never happened.
            -- Same for the mode-switch _pending_reapply chain.
            if _pending_rescan == doc.file then _pending_rescan = nil end
            if FootFree._pending_reapply == doc.file then FootFree._pending_reapply = nil end
            if FootFree._pending_underline == doc.file then FootFree._pending_underline = nil end
            return
        end
        result = result or ""
        -- Same chain-abort on every failed outcome below: only a successful
        -- revert may proceed to the rescan+reconvert leg. This is what silently
        -- reconverted a regenerated smoketest5 — the revert refused ("file
        -- changed since conversion", record rightly dropped), but the pending
        -- flag survived and the next onReaderReady rescanned and re-applied.
        if result ~= "OK" then
            if _pending_rescan == doc.file then _pending_rescan = nil end
            if FootFree._pending_reapply == doc.file then FootFree._pending_reapply = nil end
            if FootFree._pending_underline == doc.file then FootFree._pending_underline = nil end
        end
        if result == "OK" then
            logger.info("FootFree: metric edition reverted")
            -- Read the chain flags NOW: the reload below fires onReaderReady,
            -- which consumes them.
            local chained = _pending_rescan == doc.file
                or FootFree._pending_reapply == doc.file
                or FootFree._pending_underline == doc.file
                or on_done ~= nil
            -- The revert just rewrote the epub (byte-identical text, new
            -- mtime). The sidecar's recorded epub_mtime no longer matches, so
            -- _load_sidecar_raw would discard it on reload even though its
            -- xpointers are still valid — update the recorded value to the
            -- restored file's mtime. (The full-content rewrite also bumps the
            -- sidecar file's own mtime, which keeps legacy sidecars alive.)
            -- EXCEPT a metric_scan sidecar: that one was scanned against the
            -- CONVERTED text (the post-apply leftovers pass), so against the
            -- restored original it is both incomplete and mispositioned —
            -- delete it and let the next open rescan the original text.
            local sp = _sidecar_path(doc.file)
            local sf = io.open(sp, "r")
            if sf then
                local content = sf:read("*a")
                sf:close()
                if content:match("metric_scan = true") then
                    os.remove(sp)
                else
                    local new_mtime = lfs and lfs.attributes(doc.file, "modification")
                    if new_mtime then
                        content = content:gsub("epub_mtime = [%w%.]+",
                            "epub_mtime = " .. tostring(new_mtime), 1)
                    end
                    sf = io.open(sp, "w")
                    if sf then sf:write(content); sf:close() end
                end
            end
            os.remove(_reverse_path(doc.file))
            os.remove(_metric_ver_path(doc.file))
            self._reverse_matches = nil
            -- After a byte-exact revert the restored text is identical to the
            -- original, so the sidecar's xpointer positions are valid again — no
            -- rescan needed. (Rescanning a converted book is separately prevented
            -- in the "Rescan book" handler, which reverts first.)
            self.ui:reloadDocument(nil, true)
            -- Announce the clean-up (user request — the revert was silent) —
            -- but ONLY when the restore is the END STATE.
            --
            -- Every other caller reverts as step one of putting the book back
            -- into a converted state: "Rescan book" and the CACHE_VERSION
            -- refresh (both via _pending_rescan), and a mode or direction
            -- switch (_pending_reapply). There "Restored original units in
            -- book" describes a state the reader never sees and contradicts
            -- the "Converted N units" toast arriving seconds later — it read as
            -- the plugin undoing its own work (user report, 2026-08-17).
            -- on_done is in the list for the same reason: it exists so a caller
            -- can act on the restored text, never to stop there.
            if not chained then
                UIManager:scheduleIn(0.4, function()
                    UIManager:show(Notification:new{
                        -- TRANSLATORS: Toast confirming the book's original measurements were restored.
                        text = _("Restored original units in book"),
                    })
                end)
            end
            if on_done then on_done() end
        elseif result:match("changed since conversion") then
            -- The on-disk file is no longer the one we converted (it was replaced
            -- externally — e.g. a re-download or sync of a different edition under
            -- the same filename). Restoring our saved chapters into it would splice
            -- unrelated content together. Leave the book untouched and just drop the
            -- now-stale conversion record so it isn't stuck appearing "converted".
            os.remove(_patches_path(doc.file))
            os.remove(_reverse_path(doc.file))
            os.remove(_metric_ver_path(doc.file))
            self._reverse_matches = nil
            if self.view then UIManager:setDirty(self.view.dialog, "ui") end
            UIManager:show(InfoMessage:new{
                -- TRANSLATORS: Shown when the book file was edited or replaced outside Footcream,
                -- so the saved original text no longer matches and can't be put back.
                text = _("This book's file changed since Footcream converted it, so the original text can't be restored. Footcream's conversion record has been cleared."),
                timeout = 6,
            })
        else
            UIManager:show(InfoMessage:new{
                -- TRANSLATORS: Generic failure when restoring the book's original text didn't
                -- work; the technical reason is appended on the next line, untranslated.
                text = _("Could not revert.") .. "\n" .. tostring(result),
                timeout = 4,
            })
        end
    end)
end

-- Bring the open book in line with the ACTIVE mode (self._tap_mode, already
-- saved by the caller). State-based and idempotent — handles every starting
-- point: unconverted + convert mode → apply (with its confirm question);
-- converted in the SAME mode → nothing; converted in another mode (or in a
-- convert mode while mode 1 is active) → revert, and for convert modes the
-- _pending_reapply flow re-applies from the preserved sidecar after the
-- reload. Called when the mode picker CLOSES: the picker changes the mode
-- setting instantly, but document work — and the convert question — waits
-- until the user is back at the book (user request 2026-07-14). The "Enable
-- Footcream" preference is deliberately left untouched.
function FootFree:_reconcileModeWithBook(cancel_restore_mode)
    local doc = self.ui.document
    if not doc then return end
    -- A per-book-disabled book never converts (its underlines are hidden
    -- and it was restored on disable) — mode changes only take effect here
    -- once the book is re-enabled.
    if not self._enabled then return end
    if _is_metric_mode(doc.file) then
        local _, _, amode = _read_metric_version(doc.file)
        if (amode or 3) == self._tap_mode then return end
        -- Re-apply from the preserved original-text sidecar after the revert
        -- (no rescan); _pending_rescan is reserved for the flows that WANT a
        -- fresh scan (version refresh, manual "Rescan & reconvert").
        if self._tap_mode >= 2 then
            FootFree._pending_reapply = doc.file
        else
            -- Switching a converted book back to underline-only. The revert is
            -- how that mode change is CARRIED OUT, not the end state, so
            -- "Restored original units in book" answers a question the reader
            -- did not ask: they changed the mode and want to know the new mode
            -- took effect (user report, 2026-08-18). Suppress the restore
            -- toast and announce the underlines instead, after the reload —
            -- which is also the only point at which the count is known.
            -- Class field: the reload builds a fresh plugin instance.
            FootFree._pending_underline = doc.file
        end
        UIManager:scheduleIn(0.3, function() self:_revertMetricEdition(doc) end)
        return
    end
    if self._tap_mode >= 2 then
        -- Apply after the menu closes. Declining the question restores
        -- cancel_restore_mode (the pre-picker mode) so a canceled picker
        -- change doesn't strand the book in an unconverted convert mode.
        --
        -- Two shapes, because the picker can be used on a scanned or an
        -- unscanned book:
        --   scanned   → the data is already here, so only the convert needs
        --               confirming ("Convert this book's measurements…").
        --   unscanned → scan AND convert need confirming, as one action
        --               ("Scan this book and convert…"). Before this,
        --               picking a convert mode on an unscanned book dead-ended
        --               on "No hints yet — scan the book first", which reads
        --               as a refusal to do the thing the reader just asked for.
        UIManager:scheduleIn(0.3, function()
            local d = self.ui.document
            if not d then return end
            if (self._all_matches and #self._all_matches > 0) or self._scanned
               or not _is_english(d) then
                self:_applyMetricEdition(d, nil, cancel_restore_mode)
            else
                self:_confirmScanAndConvert(d, cancel_restore_mode,
                                            function() self:_startScan(d) end)
            end
        end)
    elseif self.view then
        -- Back to mode 1 on an unconverted book: repaint so the underlines
        -- show right away.
        UIManager:setDirty(self.view.dialog, "ui")
    end
end

-- "Convert units to" switch (metric / us / uk). Flips the conversion
-- direction: the open book rescans, and a converted book reverts first, then
-- reconverts in the new direction (revert → the reload's direction-mismatch
-- sidecar check forces a fresh scan → re-apply in the active mode).
function FootFree:_setPreferred(v)
    if FootFree._IMPERIAL.preferred() == v then return end
    G_reader_settings:saveSetting("footcream_preferred_system", v)
    logger.info("Footcream: preferred units → " .. v)
    local doc = self.ui.document
    if not doc then return end
    -- Per-book-disabled book: the setting is saved (it steers every other
    -- book), but this book is left alone — no rescan, no conversion.
    if not self._enabled then return end
    if _is_metric_mode(doc.file) then
        -- Converted in the old direction — restore the original text, then
        -- the reapply leg rescans and reconverts under the new preference.
        FootFree._pending_reapply = doc.file
        self.ui:handleEvent(Event:new("CloseReaderMenu"))
        UIManager:scheduleIn(0.3, function() self:_revertMetricEdition(doc) end)
        return
    end
    -- Rescan the open book in the new direction.
    os.remove(_sidecar_path(doc.file))
    self._all_matches   = nil
    self._current_boxes = {}
    self._scanned       = false
    if self.view then UIManager:setDirty(self.view.dialog, "ui") end
    if _is_english(doc) then
        self.ui:handleEvent(Event:new("CloseReaderMenu"))
        -- Explicit action (the reader changed direction), so ASK FIRST and then
        -- run scan + convert uninterrupted. The 0.3s settle is kept: closing
        -- the menu triggers a full-view refresh, and a dialog raised inside it
        -- comes back as a ghost whose buttons don't take taps.
        UIManager:scheduleIn(0.3, function()
            local d = self.ui.document
            if not d then return end
            self:_confirmScanAndConvert(d, nil, function() self:_startScan(d) end)
        end)
    end
end

-- Build self._reverse_matches: positions of the converted strings in the
-- text (bare metric values in mode 3, "original (metric)" glosses in mode
-- 2), each paired with its original imperial text. Loaded whenever a
-- convert-mode book is converted. Hold-to-flag hit-tests these positions in
-- both modes; underlines and the tap popup are a mode-3 extra behind the
-- "show original units" toggle.
--
-- Returns "missing" if the book is converted but the reverse-map sidecar is
-- gone — e.g. it was deleted while the patches file survived, or the book
-- was converted before the map covered its mode. The toggle caller surfaces
-- a message rather than silently doing nothing (5.4). Returns true/nil
-- otherwise.
function FootFree:_loadReverseMatches(doc, quiet)
    self._reverse_matches = nil
    -- Consume the ring hand-off UNCONDITIONALLY, before any early return below.
    -- It is set by the convert directly before its reload and means "resume the
    -- ring here"; if this call turns out to have no work to do, a carry left
    -- lying around would make some later, unrelated ring start at 88%.
    local ring_from = FootFree._ring_carry
    FootFree._ring_carry = nil
    if self._tap_mode < 2 then return end
    -- The positions have two consumers: hold-to-flag (gated by the
    -- error-reporting opt-in) and, in mode 3, the "show original units"
    -- underline/popup. With neither active, skip the work entirely — the
    -- toggles' callbacks re-invoke this loader when flipped on.
    if not self._share_reports
       and not (self._tap_mode == 3 and self._show_original) then return end
    if not _is_metric_mode(doc.file) then return end

    local data = _load_reverse_data(doc.file)
    if not data or not data.map then
        return "missing"
    end

    -- Fast path: positions already resolved (each carries its own original).
    if data.matches then
        local result = {}
        for _, m in ipairs(data.matches) do
            table.insert(result, { start = m.start, ["end"] = m["end"],
                                    _converted = m.original, _cat = m.cat })
        end
        self._reverse_matches = #result > 0 and result or nil
        return true
    end

    -- First time after applying: find each converted string, then cache. For
    -- each string we walk its ordered originals list in lockstep so the Nth
    -- occurrence recovers the Nth original (6.2).
    --
    -- ONE PLAIN PASS PER STRING, not one regex alternation of all of them.
    -- This was the last place still paying the regex-alternation price the
    -- scanner shed in cache 66: a plain walk costs ~1/100th of a regex walk,
    -- so 41 plain passes beat one 41-branch alternation by a wide margin.
    -- Measured on a Kobo (Bedlam Bride, 41 strings, 2026-08-18): 18.5s -> see
    -- the "re-locate" phase log below. That 18.5s was the whole reason a
    -- scan-and-convert read as 42 seconds when the scan itself was 9.9s.
    --
    -- Precedence is preserved WITHOUT the longest-first sort the alternation
    -- needed: _filter_overlapping_matches sorts by (prefix, start, longest
    -- end first) and drops anything overlapping a kept hit, so where two
    -- converted strings overlap the longer still wins — the same outcome
    -- leftmost-longest alternation gave, now decided after the fact.
    local alts = {}
    for to in pairs(data.map) do table.insert(alts, to) end
    if #alts == 0 then return true end
    -- Sorted because pairs() order is arbitrary and the passes are no longer
    -- one atomic regex: two map keys differing only in case ("one foot (30 cm)"
    -- / "One foot (30 cm)") match the SAME span, so whichever pass ran first
    -- decided the answer and the result changed between runs. Equivalence runs
    -- caught it as an intermittent diff; sorting makes the order reproducible.
    table.sort(alts)

    -- First-time scan: run findAllText in a dismissable subprocess so the UI
    -- doesn't freeze; the resolved positions are then cached so future opens hit
    -- the instant fast path above. _filter_overlapping_matches runs in the child
    -- (on the full hit objects); the parent maps each hit to its original.
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        -- nil message = Trapper's INVISIBLE trap widget: the work still runs
        -- off the UI thread and a tap still cancels it, but nothing is drawn.
        -- The corner ring carries the "busy" signal instead. If a tap does
        -- cancel it, nothing breaks — the positions simply stay unresolved and
        -- the next open retries (same as dismissing the old message did).
        -- Last leg of a scan-and-convert, so this one IS allowed to close the
        -- circle. ring_from is set only by the convert directly before the
        -- reload; when this runs on its own (the "show original units" toggle,
        -- a plain open of a converted book) it falls back to the usual start.
        -- quiet = this is background work the reader never asked for (see the
        -- deferred call in onReaderReady), so it gets NO indicator. Showing a
        -- ring here would put a spinner on screen after the "converted" notice
        -- already said the job was done — the exact contradiction the notice
        -- deferral exists to avoid.
        if not quiet then self:_startRingPulse(ring_from, 1.0) end
        local _tRL = _now()
        local completed, filtered = Trapper:dismissableRunInSubprocess(function()
            local results = {}
            for _, a in ipairs(alts) do
                local okp, res = pcall(function()
                    return doc:findAllText(a, true, 0, 1000, false)
                end)
                if okp and res then
                    for _, h in ipairs(res) do
                        -- Prefer what the DOCUMENT actually holds, falling
                        -- back to the searched string. Neither alone is right:
                        -- findAllText matches case-insensitively, so the "one
                        -- foot (30 cm)" pass also hits "One foot (30 cm)" and
                        -- tagging it with the searched string recovers the
                        -- wrong original's case; but matched_text on a
                        -- soft-hyphen book carries U+00AD and is no map key at
                        -- all. Take matched_text when it IS a key, else `a`.
                        h._src = (data.map[h.matched_text] and h.matched_text)
                                 or a
                        results[#results + 1] = h
                    end
                end
            end
            local out = {}
            for _, r in ipairs(_filter_overlapping_matches(results)) do
                out[#out + 1] = { start = r.start, ["end"] = r["end"],
                                   matched_text = r._src }
            end
            return out
        end, nil)
        logger.info(string.format("FootFree: re-locate %.2fs (%d plain passes)%s",
                                  _now() - _tRL, #alts,
                                  quiet and " [background]" or ""))
        if not quiet then self:_stopRingPulse() end
        if not completed then return end  -- dismissed
        filtered = filtered or {}
        local counters = {}
        local result, cached = {}, {}
        for _, r in ipairs(filtered) do
            local info = data.map[r.matched_text]
            if info and info.originals then
                local idx = (counters[r.matched_text] or 0) + 1
                counters[r.matched_text] = idx
                local original = info.originals[idx] or info.originals[#info.originals]
                table.insert(result, { start = r.start, ["end"] = r["end"],
                                        _converted = original, _cat = info.cat })
                table.insert(cached, { start = r.start, ["end"] = r["end"],
                                        original = original, cat = info.cat })
            end
        end
        _save_reverse_matches(doc.file, data.map, cached)
        self._reverse_matches = #result > 0 and result or nil
        self._current_boxes = {}
        if self.view then UIManager:setDirty(self.view.dialog, "ui") end
    end)
    return true
end

-- ── Broad scan (triggered from menu / auto-scan) ──────────────────────────────

-- Experimental unit-anchored fast scan. Runs synchronously (~a couple of
-- seconds even on a huge book) and hands its records to _finishScan, which
-- applies the same idiom filters and saves the same sidecar as the classic scan.
function FootFree:_startFastScan(doc)
    logger.info("FootFree: fast scan — " .. doc.file)
    -- Re-entrancy guard: a scan subprocess is already running (e.g. the auto-scan
    -- from onReaderReady is still going and the user taps "Scan book", or a
    -- double-tap). Starting another would overwrite self._scan_pid — orphaning the
    -- first child (never reaped, keeps burning CPU on a single-core reader) and
    -- racing it on the progress file + sidecar. Leave the running scan alone.
    if self._scan_pid then
        -- TRANSLATORS: Toast when a scan is asked for while one is already running. The
        -- running scan is left alone.
        UIManager:show(Notification:new{ text = _("A scan is already in progress…") })
        return
    end
    self._all_matches   = nil
    self._current_boxes = {}
    self._scan_progress = 0.0  -- show the corner loader while it runs
    self._scan_poll_n   = 0
    -- Estimate scan duration so the progress bar advances ~linearly (a true-ish
    -- ETA) instead of easing exponentially to 90% and stalling there. The rate
    -- is calibrated from past scans on this device; floor the ETA at 2s.
    local rate = tonumber(G_reader_settings:readSetting("footcream_scan_rate"))
                 or FootFree._DEFAULT_SCAN_RATE
    self._scan_size = _file_size(doc.file)
    self._scan_eta  = math.max(2, (self._scan_size or 0) * rate)
    -- Soft-hyphen books still cost more than ordinary ones, but for a different
    -- reason than they used to. EVERY book now takes the per-alias plain path,
    -- so the pass count is no longer what separates them (it was #_UNIT_SUFFIXES
    -- here, which is now badly wrong). What is left is the prime/°F literal
    -- passes, which stay REGEX and which shy books run unconditionally because
    -- the gate that would skip them costs 160s on such a book. Measured on one
    -- novel and its soft-hyphen twin (2026-08-17): 2.43s vs 16.99s, and 14.36s
    -- of that 17 is those 7 regex passes — ~2s each against 0.02s on ordinary
    -- text. So ~7x, and 8 is used for headroom. The ETA feeds the stuck-child
    -- deadline in _pollFastScan (max(60, eta*8)); under-estimating here is what
    -- SIGKILLed The Stand (60k soft hyphens, 1500 pages) mid-scan, so err high.
    self._scan_shy = nil
    do
        local mod = _metric_module()
        local f = doc.file or ""
        if mod and mod.has_soft_hyphens and f:lower():match("%.epub$") then
            local oks, res = pcall(mod.has_soft_hyphens, f)
            if oks and res then
                self._scan_shy = true
                self._scan_eta = self._scan_eta * 8
            end
        end
    end
    self._scan_t0   = _now()
    os.remove(_PARTIAL_SIDECAR)
    -- Clear any progress file a previous crashed/killed scan may have left, so
    -- the poller can't read a stale fraction before the child writes a fresh one.
    os.remove(_SCAN_PROGRESS_FILE)
    os.remove(_SCAN_PROGRESS_FILE .. ".tmp")
    if self.view then UIManager:setDirty(self.view.dialog, "ui") end

    local cat_enabled  = self._cat_enabled
    local debug_report = self._debug_report

    -- Run in a subprocess so the UI stays responsive (same as the classic scan).
    if ok_ffiutil and ffiutil.runInSubProcess then
        local ok_pid, pid = pcall(function()
            return ffiutil.runInSubProcess(function()
                -- CHILD: inherits crengine state at fork; no UIManager calls.
                -- Run at lowest CPU priority so the parent UI stays responsive
                -- (page turns) on single-core e-readers during the long scan.
                _nice_self()
                local t0 = _now()
                local matches = _fast_scan_matches(doc, cat_enabled)
                FootFree._finishScan(nil, doc, matches, _now() - t0, true, debug_report)
            end)
        end)
        if ok_pid and pid and pid > 0 then
            logger.info("FootFree: fast-scan subprocess pid=" .. tostring(pid))
            self._scan_pid = pid
            self._scan_doc = doc
            self._covered_n = 0
            UIManager:scheduleIn(0.12, function() self:_pollFastScan() end)
            return
        end
        logger.warn("FootFree: fast-scan subprocess spawn failed — running synchronously")
    end

    -- Fallback: synchronous (still only a couple of seconds).
    self._scan_progress = nil
    local t0 = _now()
    local matches = _fast_scan_matches(doc, self._cat_enabled)
    self:_finishScan(doc, matches, _now() - t0, false, self._debug_report)
end

-- The unit-anchored fast scan is the only scan path now; _startScan delegates
-- straight to it. (The old multi-pass classic scan was removed.)
function FootFree:_startScan(doc)
    if not doc or not doc.file then return end
    -- Non-crengine document (PDF/DjVu): no findAllText/xpointers — never scan.
    if self._doc_unsupported then return end
    return self:_startFastScan(doc)
end

-- ── Poll subprocess completion ─────────────────────────────────────────────────

-- Shared scan-completion: load the saved sidecar into _all_matches, clear the
-- progress indicator, and notify. Used by both the classic and fast pollers.
-- Run (once) an action queued to fire after the next scan finishes — used by
-- "Rescan book" on a converted book to re-apply the conversion with fresh data.
-- Scan-complete toast, suppressed when a convert is queued right behind it.
--
-- Without this the reader gets two toasts for one action, moments apart, with
-- two DIFFERENT numbers — "Scan complete: 321 units found" then "Converted 304
-- units in book" (the rewriter skips matches the scanner keeps). The second is
-- the one that describes what actually happened to the book, so the first just
-- adds noise and invites "why did it lose 17?". Mode 1 always announces: there,
-- this toast is the only feedback the reader gets. (User feedback 2026-08-07 —
-- one rescan was producing five separate interruptions.)
--
-- Reads _after_scan BEFORE _runAfterScan consumes it; both call sites announce
-- first, so the flag is still set here.
function FootFree:_announceScan(n, doc)
    -- The reader may have left this book while the scan ran. The subprocess
    -- runs to completion regardless, so without this the toast lands over the
    -- file browser or over whatever book was opened next — reported on device
    -- 2026-08-19 ("'Underlined 58 units' still shows on the home screen").
    -- The scan itself still finishes and its sidecar is still saved; only the
    -- announcement is dropped, because an announcement is about what the
    -- reader is looking at.
    if not self.view or not self.ui.document
       or (doc and doc.file and self.ui.document.file ~= doc.file) then
        logger.info("FootFree: scan notice dropped — that book is no longer open")
        return
    end
    if self._after_scan and self._tap_mode >= 2
       and doc and not _is_metric_mode(doc.file) then
        logger.info("FootFree: scan notice suppressed — convert queued behind it")
        return
    end
    UIManager:show(Notification:new{ text = self:_scanNoticeText(n, doc) })
end

function FootFree:_runAfterScan()
    if self._after_scan then
        local cb = self._after_scan
        self._after_scan = nil
        cb()
    end
end

function FootFree:_onScanComplete(err)
    -- Effective poll interval vs the 0.12s it is scheduled at. If the UI event
    -- loop is saturated (ring repaints + the forked child on a slow single-core
    -- reader), polls slip — and if polls slip, so do taps, which is the
    -- difference between "the scan blocks input" and "the reader took a while".
    local slip = ""
    if self._scan_t0 and self._scan_poll_n and self._scan_poll_n > 0 then
        slip = string.format("  polls=%d effective=%.0fms (scheduled 120ms)",
                             self._scan_poll_n,
                             (_now() - self._scan_t0) / self._scan_poll_n * 1000)
    end
    logger.info("FootFree: subprocess complete" .. slip)
    if self._scan_indicator then
        UIManager:close(self._scan_indicator)
        self._scan_indicator = nil
    end
    local doc = self._scan_doc
    self._scan_pid = nil
    self._scan_doc = nil

    -- Calibrate the per-byte scan rate from this run so the next book's ETA is
    -- accurate. Blend 50/50 with the previous rate so one odd book (e.g. heavy
    -- images) doesn't skew it. Only trust runs long enough to be meaningful.
    -- Shy books run the N-pass fallback (their duration is not the regex-path
    -- rate) — skip them so one shy book doesn't inflate every later ETA.
    if not self._scan_shy
       and self._scan_t0 and self._scan_size and self._scan_size > 0 then
        local dur = _now() - self._scan_t0
        if dur > 1.0 then
            local new_rate = dur / self._scan_size
            local old = tonumber(G_reader_settings:readSetting("footcream_scan_rate"))
            local rate = old and (old * 0.5 + new_rate * 0.5) or new_rate
            G_reader_settings:saveSetting("footcream_scan_rate", rate)
        end
    end

    local raw = doc and _load_sidecar_raw(doc.file)
    if raw then
        local use_uk = self._uk_volumes and doc and _is_uk_book(doc)
        local applied = _apply_settings_to_matches(raw, self._distinguish_pounds, use_uk)
        local n = #applied
        self._all_matches   = n > 0 and applied or nil
        self._current_boxes = {}
        self._scanned       = true  -- background scan finished (6.1)
        if self.view then UIManager:setDirty(self.view.dialog, "ui") end
        self:_announceScan(n, doc)
    else
        logger.warn("FootFree: subprocess done but no sidecar found" ..
                    (err and (" — " .. err) or ""))
        -- SAY SO. This used to be log-only, so a failed scan looked exactly
        -- like a slow one: the ring simply never resolved, and the reader had
        -- no way to tell "still working" from "gave up two minutes ago". It is
        -- how a killed scan was reported as "the scanning froze" (on-device,
        -- 2026-08-17). Deliberately an InfoMessage, not a toast — this one is
        -- worth interrupting for, because nothing else will happen.
        self._scanned = false
        UIManager:show(InfoMessage:new{
            -- TRANSLATORS: Shown when the background scan failed or was stopped, so the book
            -- has no results. 'Scan book' is a menu entry - translate it as you translate that
            -- entry.
            text = _("Couldn't finish scanning this book.\nUse 'Scan book' to try again."),
            timeout = 5,
        })
    end
    -- Hold the ring at the hand-off point when a convert is queued behind this
    -- scan (_after_scan is consumed by _runAfterScan below, so it is still set
    -- here). Clearing it blinked the corner empty for the half-second before
    -- the convert's ring appeared — on e-ink that is a flash, and it broke the
    -- "one action, one ring" the whole tail budget exists to produce. Mode 1
    -- clears it as before: there the scan IS the action and it is over.
    --
    -- Parking requires MATCHES, not just a queued convert. A failed scan leaves
    -- the convert nothing to do, so it declines silently — and a ring parked
    -- for a hand-off that never comes is a spinner that never resolves. That
    -- turned a 60s scan timeout into an apparently frozen reader.
    if self._after_scan and self._tap_mode >= 2
       and self._all_matches and #self._all_matches > 0 then
        self._scan_progress = _RING.tail_from
        -- Belt and braces: the queued convert re-checks its own conditions and
        -- can still decline (book converted meanwhile, mode changed, Footcream
        -- switched off), and _applyMetricEdition has early returns of its own.
        -- Nothing else would ever clear the park, so time it out. Exact
        -- equality is safe — no other writer produces this value, and a convert
        -- that did start owns _ring_pulse.
        UIManager:scheduleIn(3, function()
            if not self._ring_pulse and self._scan_progress == _RING.tail_from then
                logger.info("FootFree: hand-off never taken — releasing the ring")
                self._scan_progress = nil
                self:_refreshRing()
            end
        end)
    else
        self._scan_progress = nil
    end
    os.remove(_SCAN_PROGRESS_FILE)
    os.remove(_SCAN_PROGRESS_FILE .. ".tmp")
    os.remove(_PARTIAL_SIDECAR)
    self:_runAfterScan()
end

-- Terminate any in-flight scan subprocess and clear its state WITHOUT running the
-- normal completion path. Used when the book closes mid-scan so a background scan
-- can't keep burning CPU after the reader navigates away, nor fire a "scan
-- complete" notification over the file browser / the next book.
function FootFree:_cancelScan()
    if not self._scan_pid then return end
    local pid = self._scan_pid
    -- Logged with the OUTCOME, not just the intent. terminateSubProcess sends
    -- SIGKILL to the process GROUP (kill(-pid, 9)) and returns nothing, so a
    -- kill that failed — wrong pid, group already gone, API absent — is
    -- indistinguishable from success unless we go and look.
    local killed = "no terminateSubProcess API"
    if ok_ffiutil and ffiutil.terminateSubProcess then
        pcall(function() ffiutil.terminateSubProcess(pid) end)
        killed = "kill sent"
        if ffiutil.isSubProcessDone then
            local okd, done = pcall(function() return ffiutil.isSubProcessDone(pid) end)
            killed = killed .. ", done=" .. tostring(okd and done)
        end
    end
    logger.info("FootFree: cancelling scan pid=" .. tostring(pid) .. " — " .. killed)
    -- Reap it. terminateSubProcess only SIGNALS; the child then sits in the
    -- process table as a zombie until someone waitpid()s it, which is exactly
    -- what isSubProcessDone does. We are about to clear _scan_pid, which stops
    -- the poll loop, so nothing else would ever collect it — verified on device
    -- 2026-08-19: pid 12959 stayed in state Z (RSS 0) for as long as we
    -- watched. It costs no memory and no CPU, but it is our litter and every
    -- cancelled scan would leave another for the life of the process.
    if ok_ffiutil and ffiutil.isSubProcessDone then
        local tries = 0
        local function reap()
            tries = tries + 1
            local okd, done = pcall(function() return ffiutil.isSubProcessDone(pid) end)
            if okd and done then
                logger.info("FootFree: scan pid=" .. tostring(pid)
                            .. " reaped after " .. tries .. " check(s)")
                return
            end
            if tries < 20 then UIManager:scheduleIn(0.25, reap) end
        end
        UIManager:scheduleIn(0.25, reap)
    end
    -- Drop anything queued behind the scan. In an in-text mode that is the
    -- CONVERT, and a convert that fires after the reader has left rewrites the
    -- book and reloads it behind the file browser — which is exactly what
    -- "I see the horizontal bar on the home screen" is (device, 2026-08-19).
    if self._after_scan then
        logger.info("FootFree: dropping the convert queued behind the cancelled scan")
        self._after_scan = nil
    end
    self._scan_pid      = nil
    self._scan_doc      = nil
    self._scan_progress = nil
    if self._scan_indicator then
        pcall(function() UIManager:close(self._scan_indicator) end)
        self._scan_indicator = nil
    end
    os.remove(_SCAN_PROGRESS_FILE)
    os.remove(_SCAN_PROGRESS_FILE .. ".tmp")
end

-- Book closing: stop any background scan (see _cancelScan). The poll loop checks
-- self._scan_pid at its top, so it halts on its own once this clears it.
function FootFree:onCloseDocument()
    logger.info("FootFree: onCloseDocument — scan in flight: "
                .. tostring(self._scan_pid ~= nil))
    self:_cancelScan()
end

-- Read the scan child's real-progress file (written by _fast_scan_matches):
-- "<tA1> <frac>" where tA1 is the findAllText duration and frac is the per-hit
-- loop fraction (0..1). Returns tA1, frac — or nil if absent/unparseable, in
-- which case the poller falls back to its time-based estimate.
function FootFree:_readScanProgress()
    local fh = io.open(_SCAN_PROGRESS_FILE, "r")
    if not fh then return nil end
    local line = fh:read("*l")
    fh:close()
    if not line then return nil end
    local ta, f = line:match("^([%d%.]+)%s+([%d%.]+)$")
    ta, f = tonumber(ta), tonumber(f)
    if not f then return nil end
    return ta, f
end

-- Poll the fast-scan subprocess. The child reports genuine progress for its
-- dominant phase (the per-hit loop) through _SCAN_PROGRESS_FILE; we map that
-- onto the bar and only time-estimate the opaque findAllText head and the short
-- prime/°F tail. Completion hands off to the shared completion handler.
function FootFree:_pollFastScan()
    if not self._scan_pid then return end
    -- Has the reader left this book? Three signals were tried on device
    -- (2026-08-19) and all three were wrong, for the same underlying reason:
    -- leaving a book does NOT close the reader.
    --   * onCloseDocument never arrives (measured 22s late, 3 runs).
    --   * ReaderUI.instance is still us — nothing was torn down.
    --   * FileManager.instance is nil — the built-in browser need not be
    --     involved at all. This device's home screen is the Bookshelf plugin.
    -- The signal that does not care WHICH screen is in front is the one
    -- KOReader's own renderer uses: walk the window stack from the top to the
    -- first widget with covers_fullscreen; everything beneath it is not
    -- painted. ReaderUI sets it, and so does any full-screen home screen. If
    -- that widget is not ours, the reader is buried and this scan is for a
    -- book nobody is looking at.
    -- Two consecutive polls (0.24s) before acting, so a transient during a
    -- screen handover cannot cancel a scan that has only just started.
    local stack = UIManager._window_stack
    local covered = false
    if type(stack) == "table" then
        for i = #stack, 1, -1 do
            local w = stack[i] and stack[i].widget
            if w and w.covers_fullscreen then
                covered = w ~= self.ui and w ~= (self.view and self.view.dialog)
                break
            end
        end
    end
    if covered then
        self._covered_n = (self._covered_n or 0) + 1
        if self._covered_n >= 2 then
            logger.warn("FootFree: reader is covered by another screen — cancelling scan")
            self:_cancelScan()
            return
        end
    else
        self._covered_n = 0
    end
    if not self.ui.document then
        logger.warn("FootFree: document is gone — cancelling scan")
        self:_cancelScan()
        return
    end
    -- Safety net: never poll forever. isSubProcessDone (waitpid) reaps a crashed
    -- child fine, so the only way we keep polling is a child that is still alive
    -- but stuck — an infinite loop, or (more likely here) blocked on I/O when the
    -- book file changes underneath a network/9p mount mid-scan. Past a generous
    -- deadline, SIGKILL it and finish gracefully so a wedged scan can never leave
    -- the reader frozen on the spinner.
    --
    -- The floor was 60s and that was measurably too tight. This cannot tell
    -- "stuck" from "slow" — it is wall-clock since the scan began — so a book
    -- that legitimately needs longer is killed EVERY time it is opened and can
    -- never be scanned at all. That is what happened to a 1MB LitRPG novel on a
    -- Kobo: 7.8s on the dev VM, over 60s on the device, killed on every open
    -- (report + device log, 2026-08-17). The ETA can't save us here either — it
    -- is size × a learned rate, and the phase that blew the budget (the °F/prime
    -- literal passes) is not modelled in that rate at all.
    --
    -- 300s is chosen knowing the cost of being wrong in each direction: the scan
    -- runs in a subprocess and never blocks the UI, so tolerating a genuinely
    -- hung child for five minutes costs the reader a turning ring, while killing
    -- a slow-but-working one costs them the feature on that book permanently.
    local stuck = _now() - (self._scan_t0 or _now())
    if stuck > math.max(300, (self._scan_eta or 30) * 8) then
        logger.warn("FootFree: scan exceeded deadline (" .. math.floor(stuck)
                    .. "s) — terminating subprocess " .. tostring(self._scan_pid))
        if ok_ffiutil and ffiutil.terminateSubProcess then
            pcall(function() ffiutil.terminateSubProcess(self._scan_pid) end)
        end
        self:_onScanComplete("scan timed out after " .. math.floor(stuck) .. "s")
        return
    end
    local done, err = false, nil
    if ok_ffiutil and ffiutil.isSubProcessDone then
        local ok, result = pcall(function()
            return ffiutil.isSubProcessDone(self._scan_pid)
        end)
        done = ok and result
        if not ok then err = tostring(result) end
    end
    if done then
        self:_onScanComplete(err)
    else
        -- Blend real per-hit-loop progress (when the child has reported it) with
        -- a time estimate for the two opaque ends:
        --   • findAllText head  → time-based, capped below the hand-off point
        --   • per-hit loop (B)  → REAL i/#hits, mapped a1..0.80
        --   • prime/°F tail     → 0.80..0.97, easing, until the child is done
        -- a1 (the loop's start point) is sized from the child's measured
        -- findAllText duration, clamped 0.10..0.50. Monotonic: the bar never
        -- steps backwards even if an estimate over- or under-shoots.
        --
        -- The tail used to get four percentage points (0.93→0.97) and to pin at
        -- the top of them. That assumed the °F/prime literal passes are a short
        -- coda — and on most books they are, or are skipped entirely. On the
        -- book that prompted this rework they were 83% of the whole scan (6.5s
        -- of 7.8s on the dev VM; most of a minute on the device), so the ring
        -- reached "95%" seconds in and then sat motionless for the rest — read,
        -- correctly, as a freeze. The tail now gets a real band and eases
        -- through it on a fixed 30s time constant rather than the ETA, because
        -- the ETA is precisely what does not model this phase.
        local elapsed = _now() - (self._scan_t0 or _now())
        local eta = self._scan_eta or 30
        local ta, f = self:_readScanProgress()
        local computed
        if f then
            -- a1 = the bar position where the finished findAllText head gives way
            -- to real per-hit progress, sized from its MEASURED share of the ETA
            -- (tA1/eta). Empirically findAllText often dominates, so this is left
            -- large: an A1-dominant book keeps the bar where the time estimate
            -- already had it (no backwards jump), while a hit-dense book gets a
            -- long, genuinely-real loop band. Capped BELOW the loop band's top —
            -- above it, `a1 + f * (0.80 - a1)` would run backwards as f grew.
            local a1 = math.min(0.70, math.max(0.05, (eta > 0 and ta) and (ta / eta) or 0.30))
            if f >= 1 then
                -- Time spent in the tail specifically, not since the scan began.
                local tail = math.max(0, elapsed - (ta or 0))
                computed = 0.80 + 0.17 * (1 - math.exp(-tail / 30))
            else
                computed = a1 + f * (0.80 - a1)
            end
        else
            -- findAllText still running (no report yet): time estimate, the best
            -- available for an opaque C call. Eased toward 0.92 rather than
            -- ramped linearly into it, so a book that outruns its ETA keeps
            -- moving instead of parking on the cap — a still ring is read as a
            -- dead one, and this branch owns the whole scan on a book with no
            -- hits to report progress from.
            computed = 0.92 * (1 - math.exp(-elapsed / math.max(2, eta)))
        end
        -- In the in-text modes the scan is only the FIRST leg of the action, so
        -- its 0→0.97 sweep is compressed into 0 → _RING.tail_from and the
        -- convert and re-locate own what is left. Without this the ring filled
        -- to a near-complete circle, vanished, and the convert restarted it at
        -- 75% — "it finished, then went backwards" (on-device report,
        -- 2026-08-17). Mode 1 keeps the full circle: there the scan is the
        -- whole action.
        local span = (self._after_scan and self._tap_mode >= 2)
                     and _RING.tail_from or 1.0
        local cap    = 0.97 * span
        local target = math.min(0.97, computed) * span
        local cur    = self._scan_progress or 0
        -- Estimate spent: KEEP MOVING. The bar used to pin at its ceiling the
        -- moment elapsed passed the ETA and sit there, motionless, for as long
        -- as the scan overran — which on the book that prompted this was most
        -- of a minute. A ring that stops is read as a crash, and the reader
        -- can't tell it from one. So once the estimate is exhausted, ease
        -- toward the ceiling instead: ~1.5% of the remaining gap per poll
        -- (12 polls/s → visibly alive, never arriving, never going backwards).
        if target <= cur then
            target = cur + (cap - cur) * 0.0015
        end
        self._scan_progress = math.max(cur, target)
        self._scan_poll_n = (self._scan_poll_n or 0) + 1
        -- Animate the corner loader ~3×/s, refreshing ONLY its small top-left
        -- region with a gentle partial ("ui") refresh. Never "fast" (leaves
        -- e-ink ghosting over a long scan) and never "full" (hard black flash —
        -- the thing the user was seeing). The page body is never touched, so the
        -- scan no longer flashes or ghosts; the user's own page turns refresh it.
        if self.view and self._scan_poll_n % 3 == 0 then self:_refreshRing() end
        UIManager:scheduleIn(0.12, function() self:_pollFastScan() end)
    end
end


-- Repaint ONLY the corner loader's region. Never "fast" (leaves e-ink ghosting
-- over a long run) and never "full" (hard black flash). The page body is never
-- touched. Extracted from the scan poll so every phase that shows the ring
-- refreshes it identically — the tuning here was hard-won and must not be
-- re-derived per call site.
function FootFree:_refreshRing()
    if not self.view then return end
    local Screen = require("device").screen
    local sz = Screen:scaleBySize(_LOADER_PX) + Screen:scaleBySize(8)
    UIManager:setDirty(self.view.dialog, "ui", Geom:new{
        x = 0, y = 0,
        w = math.floor(Screen:getWidth() / 3) + sz,
        h = sz,
    })
end

-- Indeterminate ring, for work whose progress can't be measured (the reverse-
-- match resolve is one opaque findAllText call). The scan's ring is a real
-- percentage; this one sweeps 15%→90% and repeats, so it reads as "busy"
-- rather than as a stalled 0%.
--
-- Why a ring at all instead of the blocking "Locating converted units…"
-- message it replaces: this is not a decision the reader has to make, it fires
-- right after the convert prompt and the convert progress message, and a third
-- modal in a row is what made a single action feel like it was bombarding
-- them (user feedback 2026-08-07).
--
-- `from` is where the ring resumes and `ceiling` is what it eases toward (both
-- optional). A phase that has more work queued behind it passes a ceiling below
-- 1.0 so it stops short — only the LAST phase of an action is allowed to close
-- the circle, which is what stops the ring reading as finished-then-restarted.
function FootFree:_startRingPulse(from, ceiling)
    if self._ring_pulse then return end
    -- A real scan owns _scan_progress and writes a true percentage into it;
    -- never let a pulse fight it for the same field.
    if self._scan_pid then return end
    self._ring_pulse = true
    self._ring_ceiling = ceiling or 1.0
    -- Resume from wherever the caller left the ring rather than snapping back
    -- to 15%: this runs as the TAIL of a scan-and-convert, so restarting the
    -- ring near zero read as "it's doing the whole thing again".
    self._scan_progress = math.max(self._scan_progress or 0, from or _RING.tail_from)
    local function tick()
        if not self._ring_pulse then return end
        -- Self-terminate if the book closed under us: the reader UI is torn
        -- down without unwinding this closure, and a tick that keeps
        -- rescheduling itself would run for the rest of the session.
        if not self.view or not self.ui.document then
            self._ring_pulse = nil
            self._scan_progress = nil
            return
        end
        -- CREEP, never sweep. This used to loop 15%→90% every ~3s, repainting
        -- four times a second — on e-ink that is visible flashing, and it was
        -- the "spinning madly" in the on-device report (2026-08-17). The work
        -- here has no measurable progress, so the ring now eases toward (but
        -- never reaches) its ceiling and repaints once a second: still
        -- obviously alive, no strobe, and it never travels backwards.
        local cap = self._ring_ceiling or 1.0
        local p = self._scan_progress or _RING.tail_from
        -- Already at or past the ceiling (a caller resumed above its own
        -- slice): hold position rather than easing backwards into it.
        if p < cap then
            self._scan_progress = p + (cap - p) * 0.12
            self:_refreshRing()
        end
        UIManager:scheduleIn(1.0, tick)
    end
    tick()
end

function FootFree:_stopRingPulse()
    if not self._ring_pulse then return end
    self._ring_pulse = nil
    self._ring_ceiling = nil
    self._scan_progress = nil
    -- Clear the ring itself; the page body still isn't touched.
    self:_refreshRing()
end

-- Hold a toast until the action it describes is visibly over — no ring of ours
-- turning and no re-render bar of KOReader's up.
--
-- "Converted 25 units in book" used to fire on a 0.4s timer after the reload,
-- which landed it in the MIDDLE of the work: the bar was still filling and the
-- ring still had its re-locate leg to run, so the reader was told it was done
-- twice before it was (on-device report, 2026-08-17). Overlapping the toast
-- with the bar is fine; announcing completion early is not.
--
-- Only one notice can be queued at a time — a newer one supersedes an older
-- (the poll checks identity, so the stale closure retires itself).
function FootFree:_deferNotice(fn)
    self._pending_notice = fn
    local waited = 0
    -- Instrumented because this hold is INVISIBLE in the log and lands at the
    -- very end of the action, so it is indistinguishable from "the convert is
    -- slow" without knowing WHICH condition held. Measured on a Kobo
    -- (2026-08-18) the whole action read as 42s while the scan was 9.9s and the
    -- rewrite 6s — everything else was here, waiting. Counting per condition is
    -- what separates our work from KOReader's re-render.
    local n_ring, n_prog, n_render = 0, 0, 0
    local function poll()
        if self._pending_notice ~= fn then return end   -- superseded
        -- Book closed under us: drop it rather than toasting over the next book.
        if not self.view or not self.ui.document then
            self._pending_notice = nil
            return
        end
        local rendering = self.ui.rolling and self.ui.rolling.rendering_state
                          and self.ui.rolling.rendering_state ~= 0
        local busy = self._ring_pulse or self._scan_progress ~= nil or rendering
        if busy then
            if self._ring_pulse        then n_ring   = n_ring   + 1 end
            if self._scan_progress ~= nil then n_prog = n_prog + 1 end
            if rendering               then n_render = n_render + 1 end
        end
        if busy and waited < _RING.notice_wait_s then
            waited = waited + 0.5
            UIManager:scheduleIn(0.5, poll)
            return
        end
        local total = FootFree._action_t0
                      and string.format("  action total=%.1fs",
                                        _now() - FootFree._action_t0) or ""
        logger.info(string.format(
            "FootFree: notice held %.1fs (ring=%.1fs scan=%.1fs render=%.1fs)%s%s",
            waited, n_ring * 0.5, n_prog * 0.5, n_render * 0.5,
            waited >= _RING.notice_wait_s and "  HIT THE 60s CAP" or "", total))
        FootFree._action_t0 = nil
        self._pending_notice = nil
        fn()
    end
    -- First check on a delay, not now: the phases that follow a convert start
    -- their own ring a beat later, and polling in the same tick would find the
    -- corner idle and fire immediately — the very bug this exists to fix.
    UIManager:scheduleIn(0.5, poll)
end

-- ── Settings re-application (instant toggle without rescan) ───────────────────

function FootFree:_reapply_settings()
    local doc = self.ui.document
    if not doc or not doc.file then return end
    local raw = _load_sidecar_raw(doc.file)
    if not raw then return end  -- no sidecar yet — user needs to scan first
    local use_uk = self._uk_volumes and _is_uk_book(doc)
    local applied = _apply_settings_to_matches(raw, self._distinguish_pounds, use_uk)
    self._all_matches   = #applied > 0 and applied or nil
    self._current_boxes = {}
    if self.view then UIManager:setDirty(self.view.dialog, "ui") end
end

-- Debug (Advanced › Debug › "Units in book"): a scrollable modal listing every
-- unit found — its converted value and the surrounding sentence — for quickly
-- auditing discovery + conversion. Tap an entry to jump to it in the book;
-- long-press to read the full (untruncated) entry.
function FootFree:_showUnitList()
    local doc = self.ui.document
    if not doc then return end
    if not self._all_matches or #self._all_matches == 0 then
        -- TRANSLATORS: Shown when 'Units in book (list)' is opened before the book has
        -- been scanned, or when the scan found nothing.
        UIManager:show(InfoMessage:new{ text = _("No units found in this book yet.") })
        return
    end
    local Menu         = require("ui/widget/menu")
    local Screen       = require("device").screen
    local GestureRange = require("ui/gesturerange")
    local BD           = require("ui/bidi")

    -- Reading order (same key the convert/report paths use).
    local ordered = {}
    for _, m in ipairs(self._all_matches) do ordered[#ordered + 1] = m end
    table.sort(ordered, function(a, b)
        return _xp_key_less(_xp_numkey(a.start), _xp_numkey(b.start))
    end)

    -- Re-extract the surrounding sentence fresh from each match's (possibly
    -- extended) start/end xpointers, rather than concatenating the saved
    -- prev_text/matched/next_text. For compound and range matches the start/end
    -- were widened after the original 8-word context was captured, so that
    -- concatenation overlapped the widened span — the source of the doubled
    -- words. before = text(start-N words, start) and after = text(end, end+N
    -- words) are disjoint from the matched span by construction, so they can't
    -- double, and N can be larger for a fuller sentence.
    local CTX_WORDS = 12
    local function text_of(a, b)
        if not a or not b then return nil end
        local ok, t = pcall(function() return doc:getTextFromXPointers(a, b) end)
        if ok and t then return t end
        return nil
    end
    local function walk(xp, n, fwd)
        local cand = xp
        for _ = 1, n do
            local ok, nxt = pcall(function()
                return fwd and doc:getNextVisibleWordEnd(cand)
                            or doc:getPrevVisibleWordStart(cand)
            end)
            if not ok or not nxt or nxt == cand then break end
            cand = nxt
        end
        return cand
    end
    local function context_of(r, unit)
        local before = text_of(walk(r.start, CTX_WORDS, false), r.start) or ""
        local after  = r["end"] and (text_of(r["end"], walk(r["end"], CTX_WORDS, true)) or "") or ""
        local ctx = before .. " [" .. unit .. "] " .. after
        ctx = ctx:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        -- Extraction failed (no end xp, or both sides empty) — fall back to the
        -- saved context so the row is never blank.
        if not r["end"] or (before == "" and after == "") then
            ctx = ((r.prev_text or "") .. (r.matched_text or "") .. (r.next_text or ""))
                :gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        end
        return ctx
    end

    local items = {}
    for i, r in ipairs(ordered) do
        local unit = _display(r.matched_text or "")
        local conv = _metric_only(r) or "?"
        local ctx  = context_of(r, unit)
        -- The detected source number(s) in parentheses after the unit ("three
        -- feet (3)"), so a mis-parse stands out. Handles ranges ("5–6") and
        -- compounds ("6, 4"), not just the leading number.
        local valstr = _detected_value_str(r.matched_text or unit)
        items[i] = {
            -- TRANSLATORS: One row of the 'Units in book' list. %1 is the row number, %2 the
            -- measurement as written in the book, %3 the value Footcream read from it, %4 the
            -- conversion, %5 the surrounding sentence. Keep the arrow.
            text      = T(_("%1. %2 (%3)  →  %4\n…%5…"), i, unit, valstr, conv, ctx),
            mandatory = r._cat or "",
            _xp       = r.start,
            _unit     = unit,
            _conv     = conv,
            _ctx      = ctx,
            _numval   = valstr,
            _loc      = r.start,
        }
    end

    local plugin = self
    local menu
    menu = Menu:new{
        -- TRANSLATORS: Title of the 'Units in book' list. %1 is how many measurements it
        -- contains.
        title         = T(_("Units in book (%1)"), #items),
        item_table    = items,
        is_borderless = true,
        is_popout     = false,
        single_line   = false,
        multilines_show_more_text = true,
        items_font_size = 14,   -- compact: fit more of each sentence per row
        items_max_lines = 4,
        items_per_page  = 8,
        covers_fullscreen = true,
        line_color    = Blitbuffer.COLOR_WHITE,
        on_close_ges  = {
            GestureRange:new{
                ges   = "two_finger_swipe",
                range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
                direction = BD.flipDirectionIfMirroredUILayout("east"),
            },
        },
    }
    function menu:onMenuSelect(item)
        UIManager:close(menu)
        if item._xp then
            if plugin.ui.link then plugin.ui.link:addCurrentLocationToStack() end
            plugin.ui:handleEvent(Event:new("GotoXPointer", item._xp, item._xp))
        end
    end
    -- Long-press → flag this conversion as wrong (tagging what's off) or jump to
    -- it. Flags are appended to flagged_errors.txt for later off-device review.
    function menu:onMenuHold(item)
        local ButtonDialog = require("ui/widget/buttondialog")
        local dialog
        local function flag(issue)
            UIManager:close(dialog)
            plugin:_flagError(item, issue)
        end
        dialog = ButtonDialog:new{
            title       = item.text,
            title_align = "left",
            buttons = {
                -- TRANSLATORS: Button in the long-press report dialog: the measurement was
                -- recognised but converted to the wrong value. Keep the flag symbol.
                {{ text = _("⚑ Wrong conversion"),   callback = function() flag("wrong conversion") end }},
                -- TRANSLATORS: Button in the long-press report dialog: Footcream underlined the
                -- wrong words - too much, too little, or the wrong part of the sentence. Keep the
                -- flag symbol.
                {{ text = _("⚑ Wrong text captured"),  callback = function() flag("missed or wrong span") end }},
                -- TRANSLATORS: Button in the long-press report dialog: this isn't a measurement at
                -- all and should never have been underlined. Keep the flag symbol.
                {{ text = _("⚑ Not a unit"),         callback = function() flag("false positive") end }},
                -- TRANSLATORS: Button in the long-press dialog on a row of the 'Units in book'
                -- list: jump to where this measurement appears in the book.
                {{ text = _("Go to in book"), callback = function()
                    UIManager:close(dialog)
                    UIManager:close(menu)
                    if item._xp then
                        if plugin.ui.link then plugin.ui.link:addCurrentLocationToStack() end
                        plugin.ui:handleEvent(Event:new("GotoXPointer", item._xp, item._xp))
                    end
                end }},
                -- TRANSLATORS: Button that closes a Footcream dialog without changing anything.
                -- Used on the Styling dialog, the mode picker and the long-press report popups.
                {{ text = _("Close"), callback = function() UIManager:close(dialog) end }},
            },
        }
        UIManager:show(dialog)
        return true
    end
    menu.close_callback = function() UIManager:close(menu) end
    UIManager:show(menu)
end

-- Append a flagged conversion to flagged_errors.txt — a plain-text, USB-pullable
-- record (book title, what was detected, what it became, the sentence, and the
-- xpointer) so faulty units can be discussed/fixed on a computer.
function FootFree:_flagError(item, issue)
    local doc = self.ui.document
    local title = "(unknown book)"
    if doc then
        local okp, props = pcall(function() return doc:getProps() end)
        if okp and props and props.title and props.title ~= "" then
            title = props.title
        elseif doc.file then
            title = doc.file:match("([^/]+)$") or doc.file
        end
    end
    local f = io.open(_FLAG_FILE, "a")
    if not f then
        -- TRANSLATORS: Error when the flagged-errors file on the device can't be written
        -- to, so the report was lost.
        UIManager:show(InfoMessage:new{ text = _("Couldn't write the flag file.") })
        return
    end
    f:write(string.format(
        "[%s]  %s\n  issue:      %s\n  detected:   %s\n  value:      %s\n  converted:  %s\n  sentence:   %s\n  loc:        %s\n\n",
        os.date("%Y-%m-%d %H:%M"), title, issue,
        item._unit or "?", item._numval or "?", item._conv or "?", item._ctx or "?",
        tostring(item._loc or "?")))
    f:close()
    -- With sharing on, the flag also queues for upload to the developer's
    -- collector (see _REPORTING). Queue first, then try to flush — offline
    -- just leaves it queued for a later open.
    if self._share_reports then
        local e = FootFree._REPORTING.json_escape
        local line = string.format(
            '{"ts":"%s","book":"%s","issue":"%s","detected":"%s","value":"%s"'
            .. ',"converted":"%s","sentence":"%s","loc":"%s"'
            .. ',"plugin_version":"%s","cache_version":%d}',
            e(os.date("%Y-%m-%d %H:%M")), e(title), e(issue),
            e(item._unit or "?"), e(item._numval or "?"), e(item._conv or "?"),
            e(item._ctx or "?"), e(tostring(item._loc or "?")),
            e(_installed_version()), CACHE_VERSION)
        local qf = io.open(_SIDECAR_DIR .. "/report_queue.jsonl", "a")
        if qf then qf:write(line .. "\n"); qf:close() end
        self:_flushReports()
    end
    -- TRANSLATORS: Toast confirming an error report was recorded. %1 is the kind of
    -- problem picked, e.g. 'wrong conversion'.
    UIManager:show(Notification:new{ text = T(_("Flagged: %1"), issue) })
end

-- Upload queued error reports (batch of ≤20 per POST, matching the server
-- cap) in a subprocess — LuaSocket blocks, and a flaky connection must not
-- freeze the UI for the full socket timeout. The CHILD deletes the sent
-- lines on HTTP 200 (keeping any that were appended meanwhile); on any
-- failure the queue survives untouched for the next attempt. No network
-- prompt: if the device is offline the POST just fails quietly.
function FootFree:_flushReports()
    if self._report_flush_pid then return end
    local endpoint = G_reader_settings:readSetting("footcream_report_url")
                     or FootFree._REPORTING.endpoint
    if not endpoint or endpoint == "" then return end
    local qpath = _SIDECAR_DIR .. "/report_queue.jsonl"
    local qf = io.open(qpath, "r")
    if not qf then return end
    local lines = {}
    for l in qf:lines() do
        if l:match("%S") then lines[#lines + 1] = l end
        if #lines >= 20 then break end
    end
    qf:close()
    if #lines == 0 then os.remove(qpath); return end
    local body = '{"reports":[' .. table.concat(lines, ",") .. "]}"
    local sent_count = #lines
    if not (ok_ffiutil and ffiutil.runInSubProcess) then return end
    local okp, pid = pcall(function()
        return ffiutil.runInSubProcess(function()
            if FootFree._REPORTING.post(endpoint, body) then
                local keep = {}
                local f = io.open(qpath, "r")
                if f then
                    local i = 0
                    for l in f:lines() do
                        i = i + 1
                        if i > sent_count and l:match("%S") then keep[#keep + 1] = l end
                    end
                    f:close()
                end
                if #keep == 0 then
                    os.remove(qpath)
                else
                    local w = io.open(qpath, "w")
                    if w then w:write(table.concat(keep, "\n") .. "\n"); w:close() end
                end
            end
        end)
    end)
    if okp and pid and pid > 0 then
        self._report_flush_pid = pid
        -- Reap the child (waitpid via isSubProcessDone); poll a few times,
        -- then let go — a still-running child just gets reaped by the next
        -- flush attempt's poll.
        local tries = 0
        local function reap()
            tries = tries + 1
            local done = true
            if ok_ffiutil and ffiutil.isSubProcessDone then
                local okd, d = pcall(function()
                    return ffiutil.isSubProcessDone(self._report_flush_pid)
                end)
                done = not okd or d
            end
            if done or tries >= 8 then
                self._report_flush_pid = nil
            else
                UIManager:scheduleIn(5, reap)
            end
        end
        UIManager:scheduleIn(5, reap)
    end
end

-- Flush queued error reports the moment connectivity returns — and at
-- launch, when Wi-Fi is already up (NetworkMgr broadcasts an initial
-- NetworkConnected then). The plugin also lives in the file browser (not
-- doc-only) and _flushReports touches nothing document-specific, so queued
-- flags go out from either state, not just on book open.
function FootFree:onNetworkConnected()
    if self._share_reports then self:_flushReports() end
end

-- Debug › "View flagged errors": show the accumulated flag log on-device.
function FootFree:_showFlaggedErrors()
    local f = io.open(_FLAG_FILE, "r")
    local data = f and f:read("*a") or nil
    if f then f:close() end
    if not data or data:gsub("%s", "") == "" then
        -- TRANSLATORS: Shown for 'Advanced > Debug > View flagged errors' when nothing has
        -- been flagged on this device yet.
        UIManager:show(InfoMessage:new{ text = _("No flagged errors yet.") })
        return
    end
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        -- TRANSLATORS: Title of the viewer listing the errors flagged on this device.
        title = _("Flagged errors"),
        text  = data,
    })
end

-- Debug › "Clear flagged errors": delete the log after it's been pulled off.
function FootFree:_clearFlaggedErrors()
    if not _file_exists(_FLAG_FILE) then
        -- TRANSLATORS: Shown for 'Advanced > Debug > Clear flagged errors' when there is
        -- nothing to delete.
        UIManager:show(InfoMessage:new{ text = _("No flagged errors to clear.") })
        return
    end
    -- TRANSLATORS: Question for 'Advanced > Debug > Clear flagged errors'. This only
    -- deletes the local file; reports already sent to the developer are not affected.
    self._confirm(_("Delete all flagged errors?"),
        -- TRANSLATORS: Confirm button on the 'Delete all flagged errors?' question; the
        -- other button is the shared 'Cancel'.
        _("Delete"), function()
        os.remove(_FLAG_FILE)
        -- TRANSLATORS: Toast after the local flagged-errors file was deleted.
        UIManager:show(Notification:new{ text = _("Flagged errors cleared.") })
    end)
end

-- ── Draw ──────────────────────────────────────────────────────────────────────

-- Digit matches include a leading boundary char (the [^0-9,] the _ND pattern
-- requires), so r.start points at the space/punctuation *before* the number,
-- not the number itself. When that leading char wraps onto the previous line,
-- crengine's per-segment box for the first line fragment is computed wrong (or
-- missing) — the cause of the "15°F has no underline / wrong token underlined"
-- bug on wrapped range matches. Start the box at the real first character.
-- (A leading minus sign is kept — we want to underline it.)
local function _draw_start_xp(r)
    local mt = r.matched_text
    if mt then
        local first = mt:match("^([^0-9])[0-9]")
        if first and first ~= "-" then
            local prefix, num = _xpointer_offset(r.start)
            if num then return prefix .. tostring(num + 1) end
        end
    end
    return r.start
end

-- Optional diagnostics: when developer mode is on (the .dev marker file), dump the screen
-- boxes for every match drawn on the current page so wrap/geometry issues can
-- be inspected from the file rather than guessed at.
-- Class attribute, not a local: this file is at the 200-local ceiling.
FootFree._BOX_DEBUG_FILE = "/mnt/macos/debug/footcream_boxes.txt"

-- Cheap, fully data-derived signature of everything that affects WHERE the
-- underline boxes land. The resolved-box cache (below) is valid only while this
-- is unchanged: page turn / scroll (getCurrentPage/Pos), reflow or font/style
-- change (getDocumentRenderingHash), rotation (screen dims), and the plugin-side
-- inputs that change which matches resolve (enabled, tap mode, the match-set
-- identity, the category filter). Because every input is read from live state,
-- no change can be silently missed. Returns nil on any API error, which forces
-- a rebuild every paint — i.e. degrades to the old always-resolve behaviour.
function FootFree:_boxCacheSig(doc, Screen)
    local ok, sig = pcall(function()
        local cats = {}
        for k, v in pairs(self._cat_enabled) do
            cats[#cats + 1] = k .. (v == false and "0" or "1")
        end
        table.sort(cats)
        return table.concat({
            doc:getCurrentPage(),
            doc:getCurrentPos(),
            doc:getDocumentRenderingHash(),
            Screen:getWidth(), Screen:getHeight(),
            self._enabled and "1" or "0",
            tostring(self._tap_mode),
            tostring(self._all_matches),
            tostring(self._reverse_matches),
            table.concat(cats, ","),
        }, "|")
    end)
    return ok and sig or nil
end

-- Resolve the on-screen underline segments for every enabled match into a flat
-- list of { box, match, _reverse }. This is the expensive part — one crengine
-- getScreenBoxesFromPositions per match — so its result is cached by
-- _drawHighlights and only rebuilt when _boxCacheSig changes.
function FootFree:_resolveHighlightBoxes(doc)
    local boxes_out = {}
    local dbg = self._debug_report and {} or nil

    local function resolve_match(r, is_reverse)
        if self._cat_enabled[r._cat] == false then return end
        local start_xp = _draw_start_xp(r)
        -- pcall with the method + args directly (no per-match closure) to avoid
        -- allocating a closure for every match on every rebuild.
        local ok, boxes = pcall(doc.getScreenBoxesFromPositions, doc, start_xp, r["end"], true)
        -- If advancing past the boundary char yielded nothing (e.g. the char
        -- and the digit were in different text nodes), fall back to the raw
        -- start so we never lose an underline that used to render.
        if ok and boxes and #boxes == 0 and start_xp ~= r.start then
            ok, boxes = pcall(doc.getScreenBoxesFromPositions, doc, r.start, r["end"], true)
        end
        if not ok or not boxes then return end
        if dbg and #boxes > 0 then
            dbg[#dbg + 1] = string.format("%s %q  start=%s end=%s  (%d segment%s)",
                is_reverse and "[rev]" or "[fwd]",
                tostring(r.matched_text or r._converted or "?"), tostring(start_xp),
                tostring(r["end"]), #boxes, #boxes == 1 and "" or "s")
        end
        for _, box in ipairs(boxes) do
            local drawn = box.h > 0 and box.w > 0
            if drawn then
                boxes_out[#boxes_out + 1] = { box = box, match = r, _reverse = is_reverse }
            end
            if dbg then
                dbg[#dbg + 1] = string.format("    box x=%s y=%s w=%s h=%s%s",
                    tostring(box.x), tostring(box.y), tostring(box.w), tostring(box.h),
                    drawn and "" or "  [skipped: zero w/h]")
            end
        end
    end

    -- Mode 1 highlights point at imperial-text positions; in mode 3 the book
    -- text is already converted, so those positions are meaningless — never
    -- resolve them there (the reverse-match loop handles mode 3 instead).
    -- Underlines are a mode-1 concept: mode 3 replaced the text and mode 2
    -- carries the conversion inline as a gloss — drawing over either would
    -- just be clutter.
    if self._enabled and self._tap_mode == 1 and self._all_matches then
        for _, r in ipairs(self._all_matches) do resolve_match(r, false) end
    end
    if self._reverse_matches then
        for _, r in ipairs(self._reverse_matches) do resolve_match(r, true) end
    end

    if dbg and #dbg > 0 then
        local fh = io.open(FootFree._BOX_DEBUG_FILE, "w")
        if fh then fh:write(table.concat(dbg, "\n") .. "\n"); fh:close() end
    end
    return boxes_out
end

function FootFree:_drawHighlights(bb)
    if not self._cat_enabled then return end
    local doc = self.ui.document
    if not doc then return end

    local Screen = require("device").screen

    -- Paint the SVG scan-progress loader directly into the framebuffer, at the
    -- same top-left position as KOReader's own re-render progress bar.
    --
    -- When that bar is up we now YIELD to it rather than shifting right to sit
    -- beside it. After a mode 2/3 convert the book's text has genuinely changed,
    -- so KOReader re-renders the whole document and shows its bar — and the old
    -- behaviour put two progress indicators side by side, ours pulsing next to
    -- KOReader's, which is most of why one action read as "buggy" (user report,
    -- on-device, 2026-08-17). One indicator at a time.
    --
    -- The yield is bounded on purpose. rendering_state is KOReader's, not ours,
    -- and if it ever stuck non-zero a bare condition here would hide our ring
    -- for the rest of the session — a scan with no visible progress at all,
    -- which is worse than two rings. So after _RENDER_YIELD_S we stop yielding
    -- and draw beside it again, exactly as before.
    if self._scan_progress ~= nil then
        local x_base = Screen:scaleBySize(4)
        local draw   = true
        local rendering = self.ui.rolling and self.ui.rolling.rendering_state
                          and self.ui.rolling.rendering_state ~= 0
        if rendering then
            self._render_yield_t0 = self._render_yield_t0 or _now()
            if _now() - self._render_yield_t0 < _RENDER_YIELD_S then
                draw = false          -- KOReader's bar owns the corner
            else
                x_base = math.floor(Screen:getWidth() / 3) + Screen:scaleBySize(4)
            end
        else
            self._render_yield_t0 = nil
        end
        -- Skip only the LOADER — the highlight painting below still has to run
        -- (an early return here would blank every underline while rendering).
        if draw then
            local y_base = Screen:scaleBySize(4)
            pcall(_draw_loader, bb, x_base, y_base, self._scan_progress)
        end
    end

    if not self._all_matches and not self._reverse_matches then
        self._current_boxes = {}
        self._box_cache = nil
        self._box_cache_sig = nil
        return
    end

    -- Reuse the resolved boxes across repaints of an unchanged view. Popups,
    -- footer ticks and menu dismissals repaint the whole page but don't move
    -- any text, so re-resolving every match's screen position each time is pure
    -- waste; only a real view/state change (sig miss) re-resolves. In dev debug
    -- mode the cache is bypassed so the per-page box report is always written.
    local sig = (not self._debug_report) and self:_boxCacheSig(doc, Screen) or nil
    if sig and sig == self._box_cache_sig and self._box_cache then
        self._current_boxes = self._box_cache
    else
        self._current_boxes = self:_resolveHighlightBoxes(doc)
        self._box_cache = self._current_boxes
        self._box_cache_sig = sig   -- nil in debug mode → rebuilds every paint
    end

    -- Draw pass — reads the live style settings, so changing underline
    -- style / colour / width takes effect on the next paint with no cache work.
    local color = _underline_color(self._underline_color)
    local width = Screen:scaleBySize(self._underline_width)
    for _, e in ipairs(self._current_boxes) do
        -- Reverse boxes are always resolved (hold-to-flag hit-tests them in
        -- both convert modes) but only drawn in mode 3 with "show original
        -- units" on — mode 2's glosses already show everything inline.
        if not e._reverse or (self._show_original and self._tap_mode == 3) then
            _draw_underline(bb, e.box, self._underline_style, color, width,
                self._underline_width, self._underline_color)
        end
    end
end

-- ── Tap ───────────────────────────────────────────────────────────────────────

function FootFree:_handleTap(ges)
    if not self._enabled and not self._reverse_matches then return false end
    if not self._current_boxes or #self._current_boxes == 0 then return false end
    local tx, ty = ges.pos.x, ges.pos.y

    for _, entry in ipairs(self._current_boxes) do
        local b = entry.box
        if tx >= b.x and tx <= b.x + b.w and
           ty >= b.y - 6 and ty <= b.y + b.h + 6 then
            if entry._reverse then
                -- Converted value tapped: show its original imperial text —
                -- mode 3 with "show original units" on, only. Otherwise the
                -- reverse boxes exist purely for hold-to-flag hit-testing, so
                -- the tap must pass through as if we weren't here.
                if self._tap_mode ~= 3 or not self._show_original then return false end
                _show_conversion_popup(entry.match, b, self._show_icon, self._tooltip_size)
            elseif self._tap_mode >= 2 then
                -- Convert modes: the edition is applied automatically on mode selection.
                -- If tapped before it could run (e.g. no scan data at the time),
                -- try again now.
                local doc = self.ui.document
                if doc and not _is_metric_mode(doc.file) then
                    self:_applyMetricEdition(doc)
                end
            else
                -- Option 1 (default): popup
                _show_conversion_popup(entry.match, b, self._show_icon, self._tooltip_size)
            end
            return true
        end
    end
    return false
end

-- Long-press on Footcream-marked text → the same flag dialog the Units list
-- offers on long-press, without the trip through Advanced › Debug. Consumes
-- the hold only when it lands on a known span (normal text selection and
-- dictionary lookup are untouched everywhere else): mode-1 underlines, and
-- in "Convert directly in the text" mode the converted values located by
-- the reverse map — whether or not their underlines are currently shown.
function FootFree:_handleHold(ges)
    -- Long-press flagging IS the error-reporting feature: the Advanced
    -- toggle ("Long-press units to send errors to the developer") gates it
    -- entirely. With it off, every hold falls through to KOReader.
    if not self._share_reports then return false end
    if not self._current_boxes or #self._current_boxes == 0 then return false end
    local tx, ty = ges.pos.x, ges.pos.y
    for _, entry in ipairs(self._current_boxes) do
        local b = entry.box
        if tx >= b.x and tx <= b.x + b.w
           and ty >= b.y - 6 and ty <= b.y + b.h + 6 then
            if entry._reverse then
                -- Mode-2 gloss spans contain the ORIGINAL English words, so
                -- consuming the hold here hijacks their dictionary lookup —
                -- recover it by offering the held word as a lookup button in
                -- the flag dialog. (Mode 3 spans are bare metric values;
                -- nothing worth looking up.)
                local dict_word
                if self._tap_mode == 2 and self.view and self.ui.dictionary then
                    local ok, w = pcall(function()
                        local pos = self.view:screenToPageTransform(ges.pos)
                        return pos and self.ui.document:getWordFromPosition(pos) or nil
                    end)
                    dict_word = ok and w and w.word or nil
                    if dict_word == "" then dict_word = nil end
                end
                self:_showFlagDialog(self:_flagItemFromReverse(entry.match), nil, dict_word)
                return true
            elseif self._enabled and self._tap_mode == 1 then
                self:_showFlagDialog(self:_flagItemFromMatch(entry.match))
                return true
            end
        end
    end
    return false
end

-- 12-word sentence context around a start/end xpointer pair, with `mid`
-- bracketed in the middle — the same extraction _showUnitList performs for
-- its rows (kept separate on purpose: the flagging system and its list stay
-- untouched by these reading-mode entry points). Returns nil when the
-- document can't resolve the walk; callers supply their own fallback.
function FootFree:_ctxAround(doc, start_xp, end_xp, mid)
    if not doc or not start_xp then return nil end
    local function text_of(a, b)
        if not a or not b then return nil end
        local ok, t = pcall(function() return doc:getTextFromXPointers(a, b) end)
        if ok and t then return t end
        return nil
    end
    local function walk(xp, n, fwd)
        local cand = xp
        for _ = 1, n do
            local ok, nxt = pcall(function()
                return fwd and doc:getNextVisibleWordEnd(cand)
                            or doc:getPrevVisibleWordStart(cand)
            end)
            if not ok or not nxt or nxt == cand then break end
            cand = nxt
        end
        return cand
    end
    local before = text_of(walk(start_xp, 12, false), start_xp) or ""
    local after  = end_xp and (text_of(end_xp, walk(end_xp, 12, true)) or "") or ""
    if before == "" and after == "" then return nil end
    return (before .. " [" .. mid .. "] " .. after)
        :gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Build the same item shape _showUnitList's rows carry (what _flagError
-- consumes), from a raw match record.
function FootFree:_flagItemFromMatch(r)
    local doc = self.ui.document
    local unit   = _display(r.matched_text or "")
    local conv   = _metric_only(r) or "?"
    local valstr = _detected_value_str(r.matched_text or unit)
    local ctx = r["end"] and self:_ctxAround(doc, r.start, r["end"], unit) or nil
    if not ctx then
        ctx = ((r.prev_text or "") .. (r.matched_text or "") .. (r.next_text or ""))
            :gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    end
    return {
        -- TRANSLATORS: Title of the popup after long-pressing an underlined measurement.
        -- %1 is the measurement as written in the book, %2 the value Footcream read, %3
        -- the conversion, %4 the surrounding sentence. Keep the arrow.
        text    = T(_("%1 (%2)  →  %3\n…%4…"), unit, valstr, conv, ctx),
        _unit   = unit,
        _conv   = conv,
        _ctx    = ctx,
        _numval = valstr,
        _loc    = r.start,
    }
end

-- Flag item for a reverse match (a converted span held in the reading view:
-- a bare metric value in mode 3, an "original (metric)" gloss in mode 2).
-- r._converted carries the ORIGINAL imperial text (that's what mode 3's tap
-- popup shows); the converted text as it stands in the book is read back
-- from the xpointers. detected/converted land in the report the same way
-- round as a mode-1 flag.
function FootFree:_flagItemFromReverse(r)
    local doc = self.ui.document
    local original = r._converted or "?"
    local metric = "?"
    if doc then
        local ok, t = pcall(function() return doc:getTextFromXPointers(r.start, r["end"]) end)
        if ok and t and t ~= "" then metric = t end
    end
    local ctx = self:_ctxAround(doc, r.start, r["end"], metric) or metric
    return {
        -- TRANSLATORS: Title of the popup after long-pressing a measurement in a book
        -- whose text was already converted. %1 is the original measurement, %2 what it now
        -- says, %3 the surrounding sentence. Keep the arrow.
        text    = T(_("%1  →  %2\n…%3…"), original, metric, ctx),
        _unit   = original,
        _conv   = metric,
        _ctx    = ctx,
        _numval = _detected_value_str(original),
        _loc    = r.start,
    }
end

-- Flag item from a reader text selection (the "Flag to Footcream" button in
-- KOReader's selection menu) — the only path that can report a unit the
-- scanner MISSED entirely, since a miss has no underline or converted span
-- to hold. Works in every mode.
function FootFree:_flagItemFromSelection(sel)
    local doc = self.ui.document
    local text = require("util").cleanupSelectedText(sel.text or "")
    local ctx = self:_ctxAround(doc, sel.pos0, sel.pos1, text) or text
    return {
        -- TRANSLATORS: Title of the popup after long-pressing text you selected yourself
        -- (reporting a measurement Footcream missed). %1 is the selected text, %2 the
        -- surrounding sentence.
        text    = T(_("%1\n…%2…"), text, ctx),
        _unit   = text,
        _conv   = "?",
        _ctx    = ctx,
        _numval = _detected_value_str(text),
        _loc    = sel.pos0,
    }
end

-- The flag-issue picker: same issue types (and the same _flagError
-- destination — local flag file + optional upload queue) as the Units list's
-- long-press dialog. No "Go to in book" here: the reader is already there.
-- variant == "selection" (the selection-menu button) leads with "Missed
-- unit" — the one issue only that path can report. dict_word (mode-2 holds)
-- adds a dictionary-lookup button for the word whose long-press we consumed.
function FootFree:_showFlagDialog(item, variant, dict_word)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function flag(issue)
        UIManager:close(dialog)
        self:_flagError(item, issue)
    end
    local buttons = {}
    if variant == "selection" then
        buttons[#buttons + 1] =
            -- TRANSLATORS: Button in the long-press report popup, offered only for text you
            -- selected: Footcream should have recognised this and didn't. Keep the flag
            -- symbol.
            {{ text = _("⚑ Missed unit"),         callback = function() flag("missed unit") end }}
    end
    buttons[#buttons + 1] =
        -- TRANSLATORS: Button in the long-press report dialog: the measurement was
        -- recognised but converted to the wrong value. Keep the flag symbol.
        {{ text = _("⚑ Wrong conversion"),    callback = function() flag("wrong conversion") end }}
    buttons[#buttons + 1] =
        -- TRANSLATORS: Button in the long-press report dialog: Footcream underlined the
        -- wrong words - too much, too little, or the wrong part of the sentence. Keep the
        -- flag symbol.
        {{ text = _("⚑ Wrong text captured"), callback = function() flag("missed or wrong span") end }}
    buttons[#buttons + 1] =
        -- TRANSLATORS: Button in the long-press report dialog: this isn't a measurement at
        -- all and should never have been underlined. Keep the flag symbol.
        {{ text = _("⚑ Not a unit"),          callback = function() flag("false positive") end }}
    if dict_word then
        buttons[#buttons + 1] =
            -- TRANSLATORS: Button in the long-press report popup that looks the word up in
            -- KOReader's dictionary. %1 is the word itself.
            {{ text = T(_("Dictionary: %1"), dict_word), callback = function()
                UIManager:close(dialog)
                self.ui.dictionary:onLookupWord(dict_word)
            end }}
    end
    buttons[#buttons + 1] =
        -- TRANSLATORS: Button that closes a Footcream dialog without changing anything.
        -- Used on the Styling dialog, the mode picker and the long-press report popups.
        {{ text = _("Close"), callback = function() UIManager:close(dialog) end }}
    dialog = ButtonDialog:new{
        title       = item.text,
        title_align = "left",
        buttons     = buttons,
    }
    UIManager:show(dialog)
end

-- ── GitHub auto-update (UI flow) ──────────────────────────────────────────────

-- Entry point (menu callback): ensure we're online, then check the latest
-- release. Wrapped in Trapper so the network wait shows a dismissable spinner.
function FootFree:_checkForUpdate()
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        -- Android's ART runtime can't safely fork() a live multi-threaded
        -- process once Binder-backed work (DNS/TLS) runs in the child, and
        -- KOReader's Trapper:dismissableRunInSubprocess always forks — it
        -- crashes the app outright on Android (GitHub issue #4). Run the
        -- check/install inline there instead of through Trapper.
        if require("device"):isAndroid() then
            self:_runUpdateCheckSync()
        else
            local Trapper = require("ui/trapper")
            Trapper:wrap(function() self:_runUpdateCheck(Trapper) end)
        end
    end)
end

-- Shared by the subprocess and Android-synchronous paths: interprets the
-- fetched release JSON and offers to install if a newer version exists.
function FootFree:_handleUpdateCheckBody(body, sync)
    local InfoMessage = require("ui/widget/infomessage")
    if not body or body:match("^ERR:") then
        UIManager:show(InfoMessage:new{
            -- TRANSLATORS: Shown when the update check couldn't reach GitHub. The reason is
            -- appended on the line below it.
            text = _("Update check failed:") .. "\n"
                -- TRANSLATORS: Stands in as the reason on the 'Update check failed:' message when
                -- the server gave no answer at all.
                .. ((body or _("no response")):gsub("^ERR:", "")) })
        return
    end
    local rel = _json_decode(body)
    if not rel or not rel.tag_name then
        -- TRANSLATORS: Shown when GitHub answered the update check with something
        -- Footcream couldn't understand.
        UIManager:show(InfoMessage:new{ text = _("Could not read the latest release info.") })
        return
    end
    local installed = _installed_version()
    if not _ver_gt(rel.tag_name, installed) then
        UIManager:show(InfoMessage:new{
            -- TRANSLATORS: Shown when the update check found no newer release. %1 is the
            -- installed version number.
            text = T(_("You're up to date (v%1)."), installed) })
        return
    end
    -- Prefer an attached .zip asset; fall back to the source zipball.
    local asset_url
    for _, a in ipairs(rel.assets or {}) do
        if a.name and a.name:match("%.zip$") and a.browser_download_url then
            asset_url = a.browser_download_url
            break
        end
    end
    asset_url = asset_url or rel.zipball_url
    if not asset_url then
        -- TRANSLATORS: Shown when a newer release exists but has no installable package
        -- attached to it.
        UIManager:show(InfoMessage:new{ text = _("No downloadable release package found.") })
        return
    end
    self._confirm(
        -- TRANSLATORS: Asked when a newer Footcream is available. %1 is the new version
        -- tag, %2 the installed version number.
        T(_("Update available: %1\n(installed: v%2)\n\nDownload and install now?"),
          rel.tag_name, installed),
        -- TRANSLATORS: Button that downloads and installs the new version; the other
        -- button is the shared 'Cancel'.
        _("Update"), function()
            if sync then
                self:_installUpdateSync(asset_url, rel.tag_name)
            else
                local Trapper2 = require("ui/trapper")
                Trapper2:wrap(function() self:_installUpdate(Trapper2, asset_url, rel.tag_name) end)
            end
        end)
end

function FootFree:_runUpdateCheck(Trapper)
    local api = "https://api.github.com/repos/" .. _GITHUB_REPO .. "/releases/latest"
    -- Fetch in a subprocess so the UI stays responsive and the message is
    -- dismissable (returns the JSON body, or "ERR:<reason>" on failure).
    local completed, body = Trapper:dismissableRunInSubprocess(function()
        local b, err = _http_fetch(api)
        return b or ("ERR:" .. tostring(err))
    -- TRANSLATORS: Progress message while Footcream asks GitHub whether a newer
    -- version exists.
    end, _("Checking for updates…"), true)
    if not completed then return end  -- dismissed by the user
    self:_handleUpdateCheckBody(body, false)
end

-- Android has no fork()-safe way to background this, so it runs inline with
-- a blocking progress message; it's a single small HTTPS request, so a short
-- UI freeze is an acceptable trade for not crashing.
function FootFree:_runUpdateCheckSync()
    local InfoMessage = require("ui/widget/infomessage")
    local api = "https://api.github.com/repos/" .. _GITHUB_REPO .. "/releases/latest"
    -- TRANSLATORS: Progress message while Footcream asks GitHub whether a newer
    -- version exists.
    local im = InfoMessage:new{ text = _("Checking for updates…") }
    UIManager:show(im)
    UIManager:forceRePaint()
    local b, err = _http_fetch(api)
    UIManager:close(im)
    self:_handleUpdateCheckBody(b or ("ERR:" .. tostring(err)), true)
end

function FootFree:_installUpdate(Trapper, asset_url, tag)
    local plugin_dir = _PLUGIN_DIR
    local backup    = plugin_dir .. ".bak"
    local tmp_zip   = _SIDECAR_DIR .. "/update.zip"
    local tmp_dir   = _SIDECAR_DIR .. "/update"

    -- Do the whole download → unzip → install in ONE subprocess so the UI never
    -- freezes and the "Updating…" message stays dismissable.
    local completed, result = Trapper:dismissableRunInSubprocess(function()
        return FootFree._do_install_update(asset_url, tag)
    -- TRANSLATORS: Progress message while the new version downloads and installs. %1
    -- is the version tag, e.g. 'v1.6.0'.
    end, T(_("Updating to %1…"), tag), true)

    if not completed then
        -- Dismissed → the subprocess was SIGKILLed. If it died mid-copy, restore
        -- from the backup so we never leave a broken plugin; then clean debris.
        if _file_exists(backup .. "/main.lua") and not _file_exists(plugin_dir .. "/main.lua") then
            os.execute('rm -rf "' .. plugin_dir .. '" && mv "' .. backup .. '" "' .. plugin_dir .. '"')
        end
        os.execute('rm -rf "' .. backup .. '" "' .. tmp_dir .. '" "' .. tmp_zip .. '"')
        return
    end
    FootFree._report_install_result(result, tag)
end

-- Android counterpart of _installUpdate: same fork-safety issue, plus the
-- install itself does a network download. Runs inline with a blocking
-- progress message — it can't be dismissed mid-flight, but it's short-lived.
function FootFree:_installUpdateSync(asset_url, tag)
    -- TRANSLATORS: Progress message while the new version downloads and installs. %1
    -- is the version tag, e.g. 'v1.6.0'.
    local im = require("ui/widget/infomessage"):new{ text = T(_("Updating to %1…"), tag) }
    UIManager:show(im)
    UIManager:forceRePaint()
    local result = FootFree._do_install_update(asset_url, tag)
    UIManager:close(im)
    FootFree._report_install_result(result, tag)
end

-- ── Menu ──────────────────────────────────────────────────────────────────────

-- Mode labels follow the Preferred-units direction: under an imperial
-- preference the conversions ARE imperial, so "tap for metric" would lie.
-- (Modes 2/3 stay disabled there, but their greyed labels flip too — a
-- greyed "Imperial only" reads as "not available yet", which is the truth.)
function FootFree:_modeLabel(mode)
    local is_metric = FootFree._IMPERIAL.preferred() == "metric"
    if mode == 3 then
        -- TRANSLATORS: Name of mode 3, shown on the 'Mode:' menu entry and in the mode
        -- picker: measurements are replaced by their conversions in the book's text. %1 is
        -- 'Metric' or 'Imperial'.
        return T(_("%1 only (in text)"), is_metric and _("Metric") or _("Imperial"))
    elseif mode == 2 then
        -- TRANSLATORS: Name of mode 2: conversions are written into the book's text next
        -- to the original measurements. %1 is 'Metric' or 'Imperial'.
        return T(_("%1 alongside original (in text)"), is_metric and _("Metric") or _("Imperial"))
    end
    -- TRANSLATORS: Name of mode 1: the book is never edited; measurements are
    -- underlined and you tap one to see its conversion. %1 is 'metric' or 'imperial',
    -- lowercase mid-sentence.
    return T(_("Underline units, tap for %1"), is_metric and _("metric") or _("imperial"))
end

function FootFree:addToMainMenu(menu_items)
    -- Long-press explainers per category (both scan directions listed).
    local cat_help = {
        -- TRANSLATORS: Long-press explainer for the 'Length & Distance' category. The unit
        -- names are English measurement words - use your language's names for the same
        -- units.
        length = _("Inches, feet, yards, miles, fathoms, furlongs, leagues, cubits — and in the imperial direction: millimeters, centimeters, meters, kilometers."),
        -- TRANSLATORS: Long-press explainer for the 'Weight' category. Tons are left alone
        -- on purpose because the word means several different quantities.
        weight = _("Ounces, pounds and stone — and in the imperial direction: grams and kilos. Tons are deliberately not converted (the word is too ambiguous)."),
        -- TRANSLATORS: Long-press explainer for the 'Temperature' category.
        temperature = _("°F and \"degrees Fahrenheit\" — and in the imperial direction, °C and \"degrees Celsius\"."),
        -- TRANSLATORS: Long-press explainer for the 'Volume' category. UK and US pints and
        -- gallons are different sizes, hence the note about the book's origin.
        volume = _("Pints, quarts, gallons and fluid ounces — and in the imperial direction, liters and milliliters. UK and US gallons differ; Footcream picks the right one from the book."),
        -- TRANSLATORS: Long-press explainer for the 'Speed' category.
        speed = _("Miles per hour and knots — and in the imperial direction, km/h and meters per second."),
        -- TRANSLATORS: Long-press explainer for the 'Area' category.
        area = _("Acres and square miles/feet/yards — and in the imperial direction, hectares and square kilometers/meters/centimeters."),
    }
    local cat_items = {}
    for _, c in ipairs({
        -- TRANSLATORS: Tickable measurement category under 'Menu > Footcream > Advanced >
        -- Unit categories'. Untick it and distances are left alone everywhere in the book.
        { key = "length",      label = _("Length & Distance") },
        -- TRANSLATORS: Tickable measurement category under 'Menu > Footcream > Advanced >
        -- Unit categories'. Untick it and weights are left alone everywhere in the book.
        { key = "weight",      label = _("Weight")            },
        -- TRANSLATORS: Tickable measurement category under 'Menu > Footcream > Advanced >
        -- Unit categories'. Untick it and temperatures are left alone everywhere in the
        -- book.
        { key = "temperature", label = _("Temperature")       },
        -- TRANSLATORS: Tickable measurement category under 'Menu > Footcream > Advanced >
        -- Unit categories'. Untick it and volumes are left alone everywhere in the book.
        { key = "volume",      label = _("Volume")            },
        -- TRANSLATORS: Tickable measurement category under 'Menu > Footcream > Advanced >
        -- Unit categories'. Untick it and speeds are left alone everywhere in the book.
        { key = "speed",       label = _("Speed")             },
        -- TRANSLATORS: Tickable measurement category under 'Menu > Footcream > Advanced >
        -- Unit categories'. Untick it and areas are left alone everywhere in the book.
        { key = "area",        label = _("Area")              },
    }) do
        local key = c.key
        table.insert(cat_items, {
            text = c.label,
            help_text = cat_help[key],
            checked_func = function()
                return self._cat_enabled[key] ~= false
            end,
            callback = function()
                self._cat_enabled[key] = not (self._cat_enabled[key] ~= false)
                G_reader_settings:saveSetting("footcream_cat_" .. key, self._cat_enabled[key])
                if self.view then UIManager:setDirty(self.view.dialog, "ui") end
            end,
        })
    end

    menu_items["foot_cream"] = {
        sorting_hint = "tools",
        text = "Footcream",
        -- sub_item_table_func rebuilds items on every open so "Show hints"
        -- can appear/disappear based on current mode without a reload.
        sub_item_table_func = function()
            local items = {}

            -- 1. Hints count (read-only status line)
            table.insert(items, {
                text_func = function()
                    -- TRANSLATORS: First line of the 'Menu > Footcream' menu, which reports what the
                    -- scan found. Shown when no book is open, so there is nothing to report.
                    if not self.ui.document then return _("No book open") end
                    if not self._enabled then
                        -- TRANSLATORS: Same menu line, when Footcream has been switched off for this
                        -- particular book via the entry below it.
                        return _("Footcream is off in this book")
                    end
                    local n = self._all_matches and #self._all_matches or 0
                    -- Converted (mode-3) book: _all_matches holds only the
                    -- leftovers the rewrite skipped, but this line must keep
                    -- reporting the book's FULL unit count in every mode
                    -- (user-specified) — use the count stamped at conversion.
                    if _is_metric_mode(self.ui.document.file) then
                        local _, total = _read_metric_version(self.ui.document.file)
                        if total and total > 0 then n = total end
                    end
                    if n > 0 then
                        local label = _lang_label(self.ui.document)
                        if label then
                            -- TRANSLATORS: Same menu line, reporting the scan result for a book whose English
                            -- variant is known. %1 is the count, %2 a label like 'UK English'.
                            return T(_.ngettext("%1 hint found in this %2 book",
                                                 "%1 hints found in this %2 book", n), n, label)
                        end
                        -- TRANSLATORS: Line at the top of 'Menu > Footcream' reporting what the scan
                        -- found. %1 is the count, and it is 0 for a book that was scanned and contains no
                        -- measurements - deliberately a zero count rather than 'nothing found', so it
                        -- can't be misread as 'not scanned yet'. 'hints' are the measurements Footcream
                        -- found, however they are being shown.
                        return T(_.ngettext("%1 hint found", "%1 hints found", n), n)
                    elseif self._scanned then
                        -- Scanned, but no imperial units — distinct from "never
                        -- scanned" so the user isn't stuck re-scanning forever (6.1).
                        -- TRANSLATORS: Line at the top of 'Menu > Footcream' reporting what the scan
                        -- found. %1 is the count, and it is 0 for a book that was scanned and contains no
                        -- measurements - deliberately a zero count rather than 'nothing found', so it
                        -- can't be misread as 'not scanned yet'. 'hints' are the measurements Footcream
                        -- found, however they are being shown.
                        return T(_.ngettext("%1 hint found", "%1 hints found", 0), 0)
                    else
                        -- TRANSLATORS: Same menu line, for a book that has never been scanned.
                        return _("Not yet scanned")
                    end
                end,
                -- TRANSLATORS: Long-press explainer for the hint-count line at the top of 'Menu >
                -- Footcream'.
                help_text = _("How many measurements Footcream found in this book. The count always shows everything that was found, whichever mode you are in."),
                enabled_func = function() return false end,
            })

            -- 2. Enable Footcream in this book — PER-BOOK opt-out (one
            -- meaning, one scope; the old toggle was global in mode 1 and
            -- per-book in modes 2/3 — user-flagged as confusing 2026-07-14).
            -- The flag lives in the book's own .sdr metadata; the global
            -- mode keeps steering every other book. A true global off is
            -- KOReader's plugin management.
            table.insert(items, {
                -- TRANSLATORS: Tickable entry in 'Menu > Footcream'. Untick it to switch Footcream
                -- off for this book only; every other book keeps following the global setting.
                text = _("Enable Footcream in this book"),
                -- TRANSLATORS: Long-press explainer for 'Enable Footcream in this book'.
                help_text = _("Turn Footcream off for this book only: no underlines, no conversions, no prompts — and a converted book gets its original text back. Other books are unaffected, and the choice is remembered for this book. To disable Footcream everywhere, use KOReader's plugin management."),
                enabled_func = function()
                    return self.ui.document ~= nil and not self._doc_unsupported
                end,
                checked_func = function()
                    return self.ui.document ~= nil and self._enabled
                end,
                callback = function()
                    local doc = self.ui.document
                    if not doc then return end
                    self._enabled = not self._enabled
                    if self._enabled then
                        self.ui.doc_settings:delSetting("footcream_disabled")
                    else
                        self.ui.doc_settings:saveSetting("footcream_disabled", true)
                    end
                    logger.info("Footcream: " .. (self._enabled and "enabled" or "disabled")
                                .. " in this book")
                    if not self._enabled then
                        if _is_metric_mode(doc.file) then
                            -- Off means untouched text — restore the conversion.
                            self.ui:handleEvent(Event:new("CloseReaderMenu"))
                            UIManager:scheduleIn(0.3, function()
                                self:_revertMetricEdition(doc)
                            end)
                        else
                            self._current_boxes = {}
                            if self.view then UIManager:setDirty(self.view.dialog, "ui") end
                        end
                    else
                        -- Re-enabled: run the same load-or-scan flow as opening
                        -- the book (idempotent; recovery/consistency checks are
                        -- no-ops on a clean book). Underlines/conversion offers
                        -- come back exactly as on a fresh open.
                        self:onReaderReady()
                        if self.view then UIManager:setDirty(self.view.dialog, "ui") end
                    end
                end,
            })

            -- 3. Convert units to (conversion direction, a.k.a. the preferred
            -- system; both directions support all three modes).
            table.insert(items, {
                text_func = function()
                    local pref = FootFree._IMPERIAL.preferred()
                    -- TRANSLATORS: US flavour of the imperial system - pounds, US pints and gallons.
                    -- Both a choice under 'Convert units to' and the value shown on that entry.
                    local name = pref == "us" and _("Imperial (US)")
                        -- TRANSLATORS: UK flavour of the imperial system - stones, imperial pints and
                        -- gallons. Both a choice under 'Convert units to' and the value shown on that
                        -- entry.
                        or pref == "uk" and _("Imperial (UK)") or _("Metric")
                    -- TRANSLATORS: Entry in 'Menu > Footcream' showing which unit system the reader
                    -- wants to read in. %1 is 'Metric', 'Imperial (US)' or 'Imperial (UK)'. Opens the
                    -- list of the three.
                    return T(_("Convert units to: %1"), name)
                end,
                -- TRANSLATORS: Long-press explainer for 'Convert units to'.
                help_text = _("The unit system you want to read in. Metric converts imperial measurements (feet, miles, °F) to metric. The Imperial options do the reverse: they find metric measurements (meters, kilometers, kilos, °C) and show imperial values. Works in every mode; a converted book is restored and reconverted when you switch."),
                sub_item_table = {
                    {
                        -- TRANSLATORS: Name of the metric system, capitalised. Used as the choice under
                        -- 'Convert units to' (the default: the book's imperial measurements become metric
                        -- ones) and inserted into the mode names, e.g. 'Metric only (in text)'. Keep it
                        -- identical in both places.
                        text = _("Metric"),
                        -- TRANSLATORS: Long-press explainer for the 'Metric' choice.
                        help_text = _("Convert imperial measurements (feet, miles, pounds, °F, gallons…) to metric."),
                        checked_func = function()
                            return FootFree._IMPERIAL.preferred() == "metric"
                        end,
                        radio = true,
                        callback = function() self:_setPreferred("metric") end,
                    },
                    {
                        -- TRANSLATORS: US flavour of the imperial system - pounds, US pints and gallons.
                        -- Both a choice under 'Convert units to' and the value shown on that entry.
                        text = _("Imperial (US)"),
                        -- TRANSLATORS: Long-press explainer for the 'Imperial (US)' choice. The quoted
                        -- measurements are examples of the output; 'm', 'ft' and 'in' are unit symbols and
                        -- are not translated.
                        help_text = _("Convert metric measurements to US units: meters become feet and inches (\"1.8 m\" → \"5 ft 11 in\"), kilometers become miles, kilos become pounds, °C becomes °F, liters become quarts and gallons."),
                        checked_func = function()
                            return FootFree._IMPERIAL.preferred() == "us"
                        end,
                        radio = true,
                        callback = function() self:_setPreferred("us") end,
                    },
                    {
                        -- TRANSLATORS: UK flavour of the imperial system - stones, imperial pints and
                        -- gallons. Both a choice under 'Convert units to' and the value shown on that
                        -- entry.
                        text = _("Imperial (UK)"),
                        -- TRANSLATORS: Long-press explainer for the 'Imperial (UK)' choice. The quoted
                        -- measurements are examples of the output; 'kg', 'st' and 'lb' are unit symbols
                        -- and are not translated.
                        help_text = _("Like Imperial (US), but with UK measures: body weights in stones (\"75 kg\" → \"11 st 11 lb\") and volumes in imperial pints and gallons."),
                        checked_func = function()
                            return FootFree._IMPERIAL.preferred() == "uk"
                        end,
                        radio = true,
                        callback = function() self:_setPreferred("uk") end,
                    },
                },
            })

            -- 4. Mode (shows active mode name in the label). Opens the visual
            -- picker — a sample sentence rendered in each of the three modes,
            -- with a real styled underline — because the mode NAMES alone
            -- didn't explain what the modes DO to the page. keep_menu_open +
            -- no CloseReaderMenu: the picker floats OVER the open menu, so
            -- closing it drops the user back into the menu (a plain in-menu
            -- submenu was tried, but TouchMenu rows can't control spacing,
            -- caption color, or show a styled underline). Only an actual mode
            -- change closes the menu (see pick() in _showModeDialog).
            table.insert(items, {
                text_func = function()
                    -- TRANSLATORS: Entry in 'Menu > Footcream' showing how conversions are currently
                    -- displayed. %1 is one of the three mode names ('Underline units, tap for metric',
                    -- 'Metric alongside original (in text)', ...).
                    return T(_("Mode: %1"), self:_modeLabel(self._tap_mode))
                end,
                -- TRANSLATORS: Long-press explainer for the 'Mode' entry.
                help_text = _("How conversions are shown while you read. Opens a picker showing a sample sentence in each of the three modes; the change is applied to the book when you leave the menu. The two \"written into the text\" modes rewrite the book file itself — fully reversible at any time. In the \"converted only\" mode, the Advanced option \"Show original unit in tooltip\" lets you tap a converted value to see the original text."),
                keep_menu_open = true,
                -- TouchMenu passes itself to callbacks; the picker uses it
                -- to updateItems() after a mode change so the "Mode: <label>"
                -- row refreshes live in the still-open menu. The mode active
                -- at THIS fresh open is what a canceled convert question
                -- restores (recorded here, not in _showModeDialog — the
                -- picker re-renders itself on every pick).
                callback = function(touchmenu_instance)
                    self._mode_before_picker = self._tap_mode
                    self:_showModeDialog(touchmenu_instance)
                end,
            })

            -- 5. Auto-scan / auto-convert.
            -- One setting, two meanings: in mode 1 it scans, in the in-text
            -- modes it scans AND rewrites the book. The label follows the mode
            -- because a fixed "Auto-scan" understates what it does in 2/3 —
            -- and this toggle is now the ONLY consent for those modes on book
            -- open (the per-book "Convert?" prompt is gone from that path).
            -- The mode-1 string is kept verbatim so its 30 translations survive;
            -- the convert-mode wording is a NEW string, which merely falls back
            -- to English until translated rather than blanking an existing one.
            table.insert(items, {
                text_func = function()
                    if self._tap_mode >= 2 then
                        -- TRANSLATORS: Tickable entry in 'Menu > Footcream', shown only in the two
                        -- in-text modes: convert each book automatically, without asking, the first
                        -- time it is opened.
                        return _("Auto-convert when opening a new book")
                    end
                    -- TRANSLATORS: Tickable entry in 'Menu > Footcream': scan each book by itself the
                    -- first time it is opened, instead of waiting for 'Scan book'.
                    return _("Auto-scan when opening a new book")
                end,
                help_text_func = function()
                    if self._tap_mode >= 2 then
                        -- TRANSLATORS: Long-press explainer for 'Auto-convert when opening a new book'.
                        -- Shown only in the in-text modes, which rewrite the book's own text.
                        return _("Convert every new book automatically when you open it, without asking first — this rewrites the book's own text. Only English books are converted; other languages are left alone. Turn this off to convert books one by one with \"Scan book\", which asks before it starts.")
                    end
                    -- TRANSLATORS: Long-press explainer for 'Auto-scan when opening a new book'.
                    return _("Scan every new book automatically when you open it. Only English books are scanned — other languages are left alone. Turn this off to scan books one by one with \"Scan book\".")
                end,
                checked_func = function() return self._auto_scan end,
                callback = function()
                    self._auto_scan = not self._auto_scan
                    G_reader_settings:saveSetting("footcream_auto_scan", self._auto_scan)
                end,
            })

            -- 6. Scan / Rescan book
            table.insert(items, {
                text_func = function()
                    if self.ui.document then
                        local fh = io.open(_sidecar_path(self.ui.document.file))
                        -- TRANSLATORS: Entry in 'Menu > Footcream' that runs the scan again from scratch.
                        -- Shown instead of 'Scan book' once this book has already been scanned.
                        if fh then fh:close(); return _("Rescan book") end
                    end
                    -- TRANSLATORS: Entry in 'Menu > Footcream' that searches this book for
                    -- measurements. Nothing is underlined or converted until this has run at least
                    -- once.
                    return _("Scan book")
                end,
                -- TRANSLATORS: Long-press explainer for the 'Scan book' / 'Rescan book' entry.
                help_text = _("Scan this book now, or scan it again from scratch. The scan runs in the background, so you can keep reading while it works. Results are saved, so reopening the book later is instant."),
                enabled_func = function()
                    -- Greyed while Footcream is off in this book.
                    return self.ui.document ~= nil and not self._doc_unsupported
                        and self._enabled
                end,
                callback = function()
                    local doc = self.ui.document
                    if not doc then return end
                    local function do_scan()
                        -- Explicit action ("Rescan book"), so ASK FIRST in the
                        -- in-text modes and then run scan + convert as one.
                        -- (Without arming the convert at all, rescanning in
                        -- mode 2/3 used to scan and then do nothing — this was
                        -- the one entry point that never offered it.)
                        self:_confirmScanAndConvert(doc, nil, function()
                            -- An explicit scan overrides the session suppression
                            -- set by "Remove Footcream data from this book".
                            self._removed_this_session[doc.file] = nil
                            os.remove(_sidecar_path(doc.file))
                            self:_startScan(doc)
                        end)
                    end
                    local function maybe_scan()
                        if _is_english(doc) then
                            do_scan()
                        else
                            local lang = _get_book_lang(doc)
                            local msg = lang ~= ""
                                -- TRANSLATORS: Asked before scanning a book that doesn't look English, since
                                -- Footcream only recognises English measurement words. %1 is the language code
                                -- from the book's metadata.
                                and T(_("This book does not appear to be in English (detected: %1).\n\nScan it anyway?"), lang)
                                -- TRANSLATORS: Same question, for a book whose metadata names no language at all.
                                or  _("This book does not appear to be in English.\n\nScan it anyway?")
                            -- TRANSLATORS: Button that scans the book anyway; the other button is the shared
                            -- 'Cancel'.
                            self._confirm(msg, _("Scan"), do_scan)
                        end
                    end
                    -- Rescanning a converted (mode-3) book in place corrupts the
                    -- sidecar/patches/reverse-map consistency: the scan would run
                    -- against metric text and find almost nothing, while the
                    -- patch record still describes the old conversion. Restore the
                    -- original text first, then scan that. (2.4)
                    if _is_metric_mode(doc.file) then
                        self.ui:handleEvent(Event:new("CloseReaderMenu"))
                        -- Deferred past the menu-close repaint: shown in the
                        -- same tick, the queued full-view refresh paints the
                        -- page OVER the dialog — a half-visible "ghost" whose
                        -- buttons don't take taps (same failure the Enable
                        -- toggle and the after-scan auto-apply guard against
                        -- with their own settle delays).
                        UIManager:scheduleIn(0.3, function()
                            self._confirm(
                                -- TRANSLATORS: Asked when 'Rescan book' is used on a book whose text was already
                                -- converted: the old conversion is undone, the book scanned afresh, and the
                                -- conversion written again.
                                _("This book is converted — rescan it and re-apply the conversion?"),
                                -- TRANSLATORS: Button that starts the rescan-and-reconvert; the other button is
                                -- the shared 'Cancel'.
                                _("Rescan & reconvert"), function()
                                    -- Revert runs async now; once it finishes and
                                    -- reloads, scan the restored text (a short delay
                                    -- lets the reload settle first).
                                    -- Flag the book; onReaderReady (after the revert's
                                    -- reload) does the rescan + re-convert. A timer here
                                    -- is unreliable — reloadDocument recreates the reader
                                    -- UI, so self.ui.document is gone by the time it fires.
                                    _pending_rescan = doc.file
                                    self:_revertMetricEdition(doc)
                                end)
                        end)
                        return
                    end
                    maybe_scan()
                end,
            })

            table.insert(items, {
                -- TRANSLATORS: Entry in 'Menu > Footcream' that opens the appearance dialog
                -- (underline look and tooltip size).
                text = _("Styling"),
                -- TRANSLATORS: Long-press explainer for 'Styling'.
                help_text = _("Customise how underlines look (solid or wavy, intensity, thickness) and the tooltip (size, unit icon), with a live preview. Drag the dialog around if it covers the text you want to see."),
                callback = function()
                    self.ui:handleEvent(Event:new("CloseReaderMenu"))
                    UIManager:scheduleIn(0.1, function()
                        _show_styling_dialog(self)
                    end)
                end,
            })

            table.insert(items, {
                text_func = function()
                    -- TRANSLATORS: Entry in 'Menu > Footcream' that looks for a newer Footcream on
                    -- GitHub. %1 is the version installed right now.
                    return T(_("Check for updates (v%1)"), _installed_version())
                end,
                -- TRANSLATORS: Long-press explainer for 'Check for updates'.
                help_text = _("Check GitHub for a newer Footcream release and install it in place. Needs Wi-Fi; you'll be asked to restart KOReader when it's done."),
                keep_menu_open = true,
                callback = function()
                    self:_checkForUpdate()
                end,
            })

            -- Advanced — kept last
            table.insert(items, {
                -- TRANSLATORS: Submenu at the bottom of 'Menu > Footcream' holding the less-used
                -- settings.
                text = _("Advanced"),
                -- TRANSLATORS: Long-press explainer for the 'Advanced' submenu.
                help_text = _("Extra options: unit categories, rounding, original-unit tooltips, error reporting to the developer, per-book cleanup, and debug tools."),
                sub_item_table = {
                    {
                        -- TRANSLATORS: Entry under 'Advanced' opening the list of measurement kinds
                        -- (length, weight, temperature...) that can each be switched off.
                        text = _("Unit categories"),
                        -- TRANSLATORS: Long-press explainer for 'Unit categories'.
                        help_text = _("Choose which kinds of measurements are converted. Anything you untick is ignored everywhere — no underlines, popups or in-text conversions for that category."),
                        sub_item_table = cat_items,
                    },
                    {
                        -- TRANSLATORS: Tickable entry under 'Advanced': round conversions to values a
                        -- person would say out loud rather than exact arithmetic.
                        text = _("Smart rounding for conversions"),
                        -- TRANSLATORS: Long-press explainer for 'Smart rounding for conversions'. The
                        -- quoted values are examples; 'm' is the metre symbol, not translated.
                        help_text = _("Round conversions to friendly, readable values — \"90 m\" instead of \"91.44 m\". Turn off if you prefer exact numbers."),
                        checked_func = function() return self._smart_rounding end,
                        callback = function()
                            self._smart_rounding = not self._smart_rounding
                            G_reader_settings:saveSetting("footcream_smart_rounding",
                                                          self._smart_rounding)
                            -- Conversions are computed at scan time, so a fresh
                            -- scan is needed to apply the change. Auto-rescan when
                            -- a scan exists and the book isn't converted-in-place
                            -- (mode 3 bakes values into the text — re-convert there).
                            local doc = self.ui.document
                            if doc and doc.file and not _is_metric_mode(doc.file)
                               and _file_exists(_sidecar_path(doc.file)) then
                                -- Explicit action (the reader changed a setting
                                -- that invalidates the scan), so ASK FIRST and
                                -- then run scan + convert as one. This branch
                                -- only runs on an UNCONVERTED book, so without
                                -- the convert armed it would rescan and leave
                                -- the book untouched.
                                self:_confirmScanAndConvert(doc, nil, function()
                                    os.remove(_sidecar_path(doc.file))
                                    self:_startScan(doc)
                                end)
                            end
                        end,
                    },
                    {
                        text_func = function()
                            -- Names the mode it belongs to, which follows the
                            -- preferred units ("Metric only" / "Imperial only").
                            local unit = FootFree._IMPERIAL.preferred() ~= "metric"
                                         -- TRANSLATORS: Name of the imperial system, capitalised. Inserted into the mode
                                         -- names ('Imperial only (in text)') and into the menu entry below it, so it must
                                         -- read the same in both.
                                         and _("Imperial") or _("Metric")
                            -- TRANSLATORS: Tickable entry under 'Advanced', for the mode that replaces
                            -- measurements in the book's text: underline the converted values too, so tapping
                            -- one shows what the book originally said. %1 is 'Metric' or 'Imperial' and must
                            -- match that mode's name.
                            return T(_("Show original unit in tooltip (%1 only mode)"), unit)
                        end,
                        -- TRANSLATORS: Long-press explainer for 'Show original unit in tooltip'.
                        help_text = _("In the \"only (in text)\" mode, underline the converted values so you can tap any of them and see the original text. Handy if you want to double-check a conversion against what the author wrote."),
                        checked_func = function() return self._show_original end,
                        callback = function()
                            self._show_original = not self._show_original
                            G_reader_settings:saveSetting("footcream_show_original",
                                                          self._show_original)
                            local doc = self.ui.document
                            if doc then
                                local status = self:_loadReverseMatches(doc)
                                if self._show_original and self._tap_mode == 3
                                   and status == "missing" then
                                    -- Reverse-map data is gone (e.g. deleted)
                                    -- but the book is still converted, so the
                                    -- toggle would silently do nothing (5.4).
                                    UIManager:show(InfoMessage:new{
                                        -- TRANSLATORS: Shown when this toggle can't work because the record of the book's
                                        -- original measurements is gone. The quoted items are menu entries - translate
                                        -- them exactly as you translate those entries.
                                        text = _("Original-unit data for this book is missing.\nTo restore it, use 'Remove Footcream data from this book', then convert again via the Mode menu."),
                                        timeout = 6,
                                    })
                                end
                            end
                            self._current_boxes = {}
                            if self.view then
                                UIManager:setDirty(self.view.dialog, "ui")
                            end
                        end,
                    },
                    {
                        -- TRANSLATORS: Tickable entry under 'Advanced': allow reporting bad conversions by
                        -- long-pressing them while reading.
                        text = _("Long-press units to send errors to the developer"),
                        -- TRANSLATORS: Long-press explainer for 'Long-press units to send errors to the
                        -- developer'.
                        help_text = _("Flag bad conversions while you read: long-press a unit (or select text Footcream missed) and the error is sent anonymously to the developer. Each flag contains the book title, the measurement, its conversion and the surrounding sentence — nothing else. Works offline: flags are queued and sent when you're connected."),
                        checked_func = function() return self._share_reports end,
                        callback = function()
                            self._share_reports = not self._share_reports
                            G_reader_settings:saveSetting("footcream_share_reports",
                                                          self._share_reports)
                            -- The toggle also gates the reading-mode flag
                            -- entry points (hold + selection-menu button), so
                            -- (un)load the hold hit boxes to match.
                            local doc = self.ui.document
                            if doc then self:_loadReverseMatches(doc) end
                            self._current_boxes = {}
                            if self.view then
                                UIManager:setDirty(self.view.dialog, "ui")
                            end
                            if self._share_reports then
                                -- Anything flagged before opting in is queued
                                -- locally too? No — only flags made while
                                -- sharing is ON are queued; flush whatever the
                                -- queue already holds from earlier sessions.
                                self:_flushReports()
                                UIManager:show(Notification:new{
                                    -- TRANSLATORS: Toast when error reporting is switched on, confirming that reports
                                    -- carry no personal information.
                                    text = _("Flagged errors will be shared anonymously"),
                                })
                            end
                        end,
                    },
                    {
                        -- TRANSLATORS: Entry under 'Advanced' that undoes everything Footcream did to this
                        -- book: original text back, underlines gone, scan results deleted.
                        text = _("Remove Footcream data from this book"),
                        -- TRANSLATORS: Long-press explainer for 'Remove Footcream data from this book'.
                        help_text = _("Undo everything for this book: restore the original text, remove all underlines and delete the saved scan. The book file goes back to exactly how it was before Footcream touched it."),
                        enabled_func = function()
                            if not self.ui.document then return false end
                            if _is_metric_mode(self.ui.document.file) then return true end
                            local fh = io.open(_sidecar_path(self.ui.document.file))
                            if fh then fh:close(); return true end
                            return false
                        end,
                        callback = function()
                            local doc = self.ui.document
                            if not doc then return end
                            -- Suppress auto-scan for this book for the rest of
                            -- the session (the revert below reloads the document
                            -- and would otherwise re-prompt immediately).
                            self._removed_this_session[doc.file] = true
                            os.remove(_sidecar_path(doc.file))
                            os.remove(_reverse_path(doc.file))
                            os.remove(_metric_ver_path(doc.file))
                            self._all_matches    = nil
                            self._reverse_matches = nil
                            self._current_boxes  = {}
                            self._scanned        = false  -- sidecar gone (6.1)
                            if self.view then
                                UIManager:setDirty(self.view.dialog, "ui")
                            end
                            if _is_metric_mode(doc.file) then
                                -- The revert announces itself ("Restored
                                -- original units in book").
                                self:_revertMetricEdition(doc)
                            else
                                UIManager:show(Notification:new{
                                    -- TRANSLATORS: Toast confirming Footcream's data for this book was deleted.
                                    text = _("Footcream data removed from book"),
                                })
                            end
                        end,
                    },
                    {
                        -- TRANSLATORS: Submenu under 'Advanced' with the tools for inspecting what the
                        -- scan found and managing reported errors.
                        text = _("Debug"),
                        -- TRANSLATORS: Long-press explainer for the 'Debug' submenu.
                        help_text = _("See exactly what the scan found in this book, and manage errors you've flagged on this device."),
                        sub_item_table = {
                            {
                                -- TRANSLATORS: Entry under 'Debug' listing every measurement the scan found in
                                -- this book, with its conversion.
                                text = _("Units in book (list)"),
                                -- TRANSLATORS: Long-press explainer for 'Units in book (list)'.
                                help_text = _("Every measurement found in this book, with its detected value and conversion. Long-press an entry to flag it as wrong."),
                                enabled_func = function()
                                    return self.ui.document ~= nil
                                        and self._all_matches ~= nil
                                        and #self._all_matches > 0
                                end,
                                callback = function()
                                    self:_showUnitList()
                                end,
                            },
                            {
                                -- TRANSLATORS: Entry under 'Debug' showing the errors flagged on this device.
                                text = _("View flagged errors"),
                                -- TRANSLATORS: Long-press explainer for 'View flagged errors'. The path in
                                -- parentheses is a file location - leave it as it is.
                                help_text = _("Show the errors you've flagged on this device. They're kept in a plain-text file (koreader/footcream/flagged_errors.txt) that you can also attach to a GitHub issue."),
                                separator = true,
                                callback = function()
                                    self:_showFlaggedErrors()
                                end,
                            },
                            {
                                -- TRANSLATORS: Entry under 'Debug' that deletes the local list of flagged errors.
                                text = _("Clear flagged errors"),
                                -- TRANSLATORS: Long-press explainer for 'Clear flagged errors'.
                                help_text = _("Delete the local flagged-errors file. Reports that were already sent to the developer are not affected."),
                                callback = function()
                                    self:_clearFlaggedErrors()
                                end,
                            },
                        },
                    },
                },
            })

            return items
        end,
    }
end

return FootFree
