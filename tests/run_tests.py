#!/usr/bin/env python3
"""Run Lua assertions against foot-cream's pure logic via lupa + stubs."""
import os, sys
from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.join(HERE, "..", "main.lua")

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute('arg = { [0]="harness" }')
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

def conv(alias):
    e = T.UNIT_CONV[alias]
    if not e:
        return None
    return (e["factor"] if "factor" in e else "converter", e["target"], e["cat"])

print("== Spanish unit aliases ==")
check("libras -> kg", conv("libras") == (0.453592, "kg", "weight"), conv("libras"))
check("libra -> kg", conv("libra") == (0.453592, "kg", "weight"), conv("libra"))
check("millas -> km", conv("millas") == (1.60934, "km", "length"), conv("millas"))
check("milla -> km", conv("milla") == (1.60934, "km", "length"), conv("milla"))
check("pies -> m", conv("pies") == (0.3048, "m", "length"), conv("pies"))
check("pie -> m", conv("pie") == (0.3048, "m", "length"), conv("pie"))
check("pulgadas -> cm", conv("pulgadas") == (2.54, "cm", "length"), conv("pulgadas"))
check("onzas -> g", conv("onzas") == (28.3495, "g", "weight"), conv("onzas"))
check("galones -> liters", conv("galones") and conv("galones")[1] == "liters", conv("galones"))
check("grados fahrenheit", conv("grados fahrenheit") == (5/9, "\u00b0C", "temperature"), conv("grados fahrenheit"))
check("millas por hora -> km/h", conv("millas por hora") and conv("millas por hora")[1] == "km/h", conv("millas por hora"))
check("nudos -> km/h", conv("nudos") and conv("nudos")[1] == "km/h", conv("nudos"))
check("acres -> ha", conv("acres") == ("converter", "ha", "area"), conv("acres"))
check("leguas -> km", conv("leguas") == (4.82803, "km", "length"), conv("leguas"))

print("== suffixes longest-first ==")
sufs = [T.UNIT_SUFFIXES[i] for i in range(1, len(T.UNIT_SUFFIXES) + 1)]
check("'millas por hora' before 'millas'",
      sufs.index("millas por hora") < sufs.index("millas"))
check("'grados fahrenheit' before 'grados'",
      sufs.index("grados fahrenheit") < sufs.index("grados"))

print("== Spanish number words ==")
pn = T.parse_num
check("dos = 2", pn("dos") == 2, pn("dos"))
check("veinticinco = 25", pn("veinticinco") == 25, pn("veinticinco"))
check("treinta y cinco = 35", pn("treinta y cinco") == 35, pn("treinta y cinco"))
check("ciento veinte = 120", pn("ciento veinte") == 120, pn("ciento veinte"))
check("dos mil = 2000", pn("dos mil") == 2000, pn("dos mil"))
def get(t, k):
    try:
        return t[k]
    except Exception:
        return None
check("millon = 1e6", get(T.NUM_SCALE, "millon") == 1000000)
check("medio = 0.5", get(T.NUM_FRAC, "medio") == 0.5)
check("y is connector", get(T.NUM_CONNECTOR, "y") == True)

print("== identify_unit ==")
iu = T.identify_unit
check("identify 'Libras'", iu("Libras") == "libras", iu("Libras"))
check("identify 'millas por hora'", iu("millas por hora") == "millas por hora", iu("millas por hora"))

print("== Spanish context cues ==")
check("weight cue: pesar", get(T.WEIGHT_WORDS, "pesar") == True)
check("money cue: esterlina(s)", get(T.CURRENCY_HARD, "esterlinas") == True)
check("money cue: pago", get(T.CURRENCY_SOFT, "pago") == True)
check("temp cue: frio", get(g.__T.FootFree._TEMP_CUE_WORDS, "frio") == True)

print()
if fails:
    print("FAILURES:", len(fails))
    sys.exit(1)
print("ALL GREEN")
