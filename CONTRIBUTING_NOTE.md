# Reply to the maintainer — merging upstream 1.8.2

Hi — I merged the latest upstream release and it went smoothly, with one
small thing worth flagging.

Here's what changed for readers: Footcream no longer mistakes quotation
marks for measurements. So a label that quotes a number in single quotes,
like `'18'`, is no longer turned into "5.5 m". That was the whole point of
the release — good.

But that same cleanup risked also dropping real heights written with a
bare `6'`, like "the pole was 6' long". Those are genuine measurements,
not quotation marks.

To keep the fix without losing those:

- A bare `6'` still converts **when it's clearly a measurement** —
  "the pole was 6' long" → 1.8 m.
- It stays suppressed when it's clearly not — `2001'`, `'18'`, call
  numbers — exactly as the upstream release intended.

So real measurements keep working and the false alarms are gone. The full
headless test suite passes (151/151).
