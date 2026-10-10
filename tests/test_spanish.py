#!/usr/bin/env python3
"""Deep tests for the Spanish layer of foot-cream (lupa + stubs)."""
import os, sys
from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.join(HERE, "..", "main.lua")

lua = LuaRuntime(unpack_returned_tuples=True)
g = lua.globals()
g.FC_MAIN = MAIN
lua.execute(open(os.path.join(HERE, "harness.lua")).read())

T = g.__T
FF = T.FootFree
fails = []
def check(name, cond, extra=""):
    if cond:
        print("  ok  " + name)
    else:
        print("  FAIL " + name + (" -- " + str(extra) if extra else ""))
        fails.append(name)

def approx(a, b, tol=1e-9):
    return a is not None and b is not None and abs(a - b) <= tol

pn = T.parse_num
pw = T.prev_num_words

print("== deaccent ==")
da = T.deaccent
check("millón→millon", da("millón") == "millon", da("millón"))
check("veintidós→veintidos", da("veintidós") == "veintidos")
check("año→ano", da("año") == "ano")
check("pingüino→pinguino", da("pingüino") == "pinguino")
check("ASCII identity", da("hello 123") == "hello 123")
check("§ passes through", da("a § b") == "a § b")

print("== parse_num: Spanish cardinals ==")
cases = [
    ("uno", 1), ("un", 1), ("una", 1), ("dos", 2), ("tres", 3),
    ("diez", 10), ("once", 11), ("quince", 15),
    ("dieciséis", 16), ("veintidós", 22), ("veintitrés", 23),
    ("veinticinco", 25), ("treinta", 30), ("cuarenta", 40),
    ("noventa y nueve", 99), ("treinta y cinco", 35),
    ("ciento veinte", 120), ("cien", 100), ("ciento", 100),
    ("doscientos", 200), ("doscientos treinta", 230),
    ("quinientos", 500), ("novecientos noventa y nueve", 999),
    ("trescientas", 300), ("doscientas millas", 200),
    ("mil", 1000), ("dos mil", 2000),
    ("mil novecientos ochenta y cuatro", 1984),
    ("un millón", 1000000), ("millón", 1000000), ("dos millones", 2000000),
    ("tres millones", 3000000), ("un billón", 1000000000),
    ("medio", 0.5), ("media", 0.5), ("un medio", 0.5),
    ("un cuarto", 0.25), ("dos y medio", 2.5), ("tres y media", 3.5),
    ("tres cuartos", 0.75), ("dos tercios", 2/3), ("un tercio", 1/3),
]
for text, want in cases:
    got = pn(text)
    check("parse_num(%r)=%s" % (text, want), approx(got, want), got)

print("== parse_num: locale decimals ==")
dec = [
    ("1,5", 1.5), ("1,50", 1.5), ("2,75", 2.75),
    ("1.609,34", 1609.34), ("1.000.000,5", 1000000.5),
    ("1,500", 1500), ("1,500,000", 1500000),
    ("1,609.34", 1609.34), ("1.5", 1.5), ("1.5,", 1.5),
    ("250", 250), ("3.14", 3.14),
]
for text, want in dec:
    got = pn(text)
    check("parse_num(%r)=%s" % (text, want), approx(got, want), got)

print("== parse_num: English regressions ==")
eng = [
    ("twenty-three", 23), ("one hundred and five", 105),
    ("six and a half", 6.5), ("two thirds", 2/3),
    ("three quarters", 0.75), ("a dozen", 12),
    ("two thousand thirty", 2030),
]
for text, want in eng:
    got = pn(text)
    check("parse_num(%r)=%s" % (text, want), approx(got, want), got)

print("== prev_num_words: Spanish ==")
def pwv(prev):
    r = pw(prev)
    if r is None:
        return None
    return (r[0], r[1])
spw = [
    ("treinta y cinco", (35, 3)),
    ("doscientos treinta", (230, 2)),
    ("un cuarto de", (0.25, 3)),
    ("dos tercios de", (2/3, 3)),
    ("medio", (0.5, 1)),
    ("una", (1, 1)),
    ("ciento veinte", (120, 2)),
    ("dos y medio", (2.5, 3)),
    ("millones de", None),
    ("un par de", None),
    ("dos millones", (2000000, 2)),
]
for prev, want in spw:
    got = pwv(prev)
    ok = (want is None and got is None) or (
        got is not None and want is not None
        and approx(got[0], want[0]) and got[1] == want[1])
    check("prev_num_words(%r)=%s" % (prev, want), ok, got)

print("== prev_num_words: English regressions ==")
epw = [
    ("two thirds of a", (2/3, 4)),
    ("four and a half", (4.5, 4)),
    ("twenty-three", (23, 1)),
]
for prev, want in epw:
    got = pwv(prev)
    ok = got is not None and approx(got[0], want[0]) and got[1] == want[1]
    check("prev_num_words(%r)=%s" % (prev, want), ok, got)

print("== pound/libra classifier ==")
pcw = T.pound_currency_wins
phc = T.pound_hard_currency
prt = T.pound_rate_tail
check("pagó…libras esterlinas → money",
      pcw("pagó veinte libras esterlinas ayer", 20, False) == True)
check("weight context keeps",
      pcw("la caja pesaba veinte libras y la carga era grande", 20, False) == False)
check("hard: libras esterlinas", phc("eran libras esterlinas") == True)
check("rate tail: al año", prt("al año") == True)
check("rate tail: por mes", prt("por mes") == True)
check("rate tail: cada mes", prt("cada mes") == True)
check("rate tail: EN 'a year' still", prt("a year") == True)
check("rate tail: EN 'per month' still", prt("per month") == True)
check("tie keeps (weight cue + money cue)",
      pcw("pesaba veinte libras y pagó", 20, False) == False)
check("minus five via prev_num_words",
      pwv("minus five") is not None and approx(pwv("minus five")[0], -5))

print("== temperature cue ==")
dtc = T.degrees_temperature_cue
check("hacía mucho frío → temp", dtc("hacía mucho frío afuera") == True)
check("la temperatura subió → temp", dtc("la temperatura subió a") == True)
check("ola de calor → temp", dtc("una ola de calor terrible") == True)
check("bajo cero → temp", dtc("diez grados bajo cero") == True)
check("angle stays suppressed", dtc("giró cuarenta grados el") == False)
check("EN 'cold' still works", dtc("it was cold outside") == True)

print("== detect_vague ==")
dv = T.detect_vague
def dvv(prev):
    r = dv(prev)
    return None if r is None else (r[0], r[1], r[2], r[3], r[4])
check("unos cientos de → band",
      dvv("unos cientos de") == (2, 5, "unos", 100, True), dvv("unos cientos de"))
check("varios miles de → band",
      dvv("varios miles de") == (3, 7, "varios", 1000, True))
check("un par de cientos de → band",
      dvv("un par de cientos de") == (2, 2, "un par de", 100, True))
check("EN a few hundred unchanged",
      dvv("a few hundred") == (2, 5, "a few", 100, None) or
      dvv("a few hundred")[:4] == (2, 5, "a few", 100), dvv("a few hundred"))
check("precise: doscientos → nil", dvv("doscientos") is None)
check("millones de (no quant) → nil", dvv("millones de") is None)

print("== reverse direction (ES metric aliases) ==")
ic = FF._IMPERIAL.conv
def icheck(alias, target, cat):
    e = ic[alias]
    return e is not None and e["target"] == target and e["cat"] == cat
for a, t, c in [("kilometros", "mi", "length"), ("kilometro", "mi", "length"),
                ("metros", "ftin", "length"), ("metro", "ftin", "length"),
                ("centimetros", "in", "length"),
                ("kilogramos", "lboz", "weight"), ("kilos", "lboz", "weight"),
                ("gramos", "oz", "weight"),
                ("grados celsius", "°F", "temperature"),
                ("litros", "vol", "volume"), ("mililitros", "vol", "volume"),
                ("hectareas", "acres", "area"),
                ("kilometros cuadrados", "sqmi", "area"),
                ("metros cuadrados", "sqft", "area"),
                ("kilometros por hora", "mph", "speed")]:
    check("IMPERIAL.conv[%r] → %s" % (a, t), icheck(a, t, c))
sufs = [FF._IMPERIAL.suffixes[i] for i in range(1, len(FF._IMPERIAL.suffixes) + 1)]
check("sq km ES before linear",
      sufs.index("kilometros cuadrados") < sufs.index("kilometros"))
check("kilometros before metros (tail)",
      sufs.index("kilometros") < sufs.index("metros"))
check("kilogramos before gramos (tail)",
      sufs.index("kilogramos") < sufs.index("gramos"))
check("identify '5 Kilómetros' → kilómetros (accented alias)",
      T.identify_unit("5 Kilómetros", sufs) == "kilómetros",
      T.identify_unit("5 Kilómetros", sufs))
check("identify '5 kilometros' → kilometros (unaccented)",
      T.identify_unit("5 kilometros", sufs) == "kilometros")
check("identify '5 metros' → metros (no km tail)",
      T.identify_unit("5 metros", sufs) == "metros")

print()
if fails:
    print("FAILURES: %d" % len(fails))
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("ALL GREEN")
