#!/usr/bin/env python3
"""End-to-end-ish: Spanish sentence -> (unit, number) -> converted value,
mirroring the scanner's classify step (identify_unit + prev_num_words)."""
import os, sys
from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.join(HERE, "..", "main.lua")

lua = LuaRuntime(unpack_returned_tuples=True)
g = lua.globals()
g.FC_MAIN = MAIN
lua.execute(open(os.path.join(HERE, "harness.lua")).read())

T = g.__T
fails = []
def check(name, cond, extra=""):
    if cond:
        print("  ok  " + name)
    else:
        print("  FAIL " + name + (" -- " + str(extra) if extra else ""))
        fails.append(name)

def approx(a, b, tol=1e-6):
    return a is not None and abs(a - b) <= tol

def convert(sentence, unit_hit, prev):
    """unit_hit: the alias as found in text; prev: words before it."""
    unit = T.identify_unit(unit_hit)
    if not unit:
        return None, "no-unit"
    conv = T.UNIT_CONV[unit]
    num_r = T.prev_num_words(prev)
    if num_r is None:
        return None, "no-num"
    num = num_r[0]
    # pound/libra money gate (mirrors _apply_settings_to_matches)
    ml = unit_hit.lower()
    if ("pound" in ml or "libra" in ml):
        window = (prev + " " + "").lower()
        if T.pound_currency_wins(window, num, False):
            return None, "money-suppressed"
    val = num * conv["factor"] + (conv["offset"] or 0)
    return (val, conv["target"]), None

cases = [
    # (sentence, unit_hit, prev, expected_value, expected_target)
    ("Pesaba noventa y cinco libras", "libras", "pesaba noventa y cinco",
     95 * 0.453592, "kg"),
    ("Caminó tres millas", "millas", "caminó tres",
     3 * 1.60934, "km"),
    ("noventa grados Fahrenheit", "grados Fahrenheit", "noventa",
     (90 - 32) * 5 / 9, "°C"),
    ("dos y medio galones", "galones", "dos y medio",
     2.5 * 3.78541, "liters"),
    ("un cuarto de milla", "milla", "un cuarto de",
     0.25 * 1.60934, "km"),
    ("doscientos treinta pies", "pies", "doscientos treinta",
     230 * 0.3048, "m"),
    ("1,5 millas", "millas", "1,5",
     1.5 * 1.60934, "km"),
    ("1.609,34 millas", "millas", "1.609,34",
     1609.34 * 1.60934, "km"),
    ("a 120 millas por hora", "millas por hora", "a 120",
     120 * 1.60934, "km/h"),
    ("veinte nudos", "nudos", "veinte",
     20 * 1.852, "km/h"),
    ("tres onzas", "onzas", "tres",
     3 * 28.3495, "g"),
    ("cinco pulgadas", "pulgadas", "cinco",
     5 * 2.54, "cm"),
    ("dos pintas", "pintas", "dos",
     2 * 0.473176, "liters"),
    ("diez brazas", "brazas", "diez",
     10 * 1.8288, "m"),
    ("tres leguas", "leguas", "tres",
     3 * 4.82803, "km"),
    ("una milla náutica", "milla náutica", "una",
     1.60934, "km"),  # wait: 1 * 1.852
    ("media onza líquida", "onza líquida", "media",
     0.5 * 29.5735, "mL"),
]

for sent, hit, prev, want_v, want_t in cases:
    if "náutica" in hit:
        want_v = 1 * 1.852
    got, err = convert(sent, hit, prev)
    ok = err is None and approx(got[0], want_v) and got[1] == want_t
    check("%r → %.4g %s" % (sent, want_v, want_t), ok,
          got if err is None else err)

print("== money suppression ==")
for sent, hit, prev in [
    ("pagó veinte libras esterlinas", "libras", "pagó veinte"),
    ("costó treinta libras", "libras", "costó treinta"),
    ("ganaba dos mil libras al año", "libras", "ganaba dos mil"),
]:
    got, err = convert(sent, hit, prev)
    check("%r suppressed" % sent, err == "money-suppressed", (got, err))

print("== bare 'grados' temperature gate ==")
dtc = T.degrees_temperature_cue
check("frío → converts", dtc("hacía un frío de cuarenta") == True)
check("angle → suppressed", dtc("giró treinta grados a la") == False)

print()
if fails:
    print("FAILURES: %d" % len(fails))
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("ALL GREEN")
