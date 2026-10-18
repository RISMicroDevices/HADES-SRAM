#!/usr/bin/env python3
"""Coverage gate for the HADES-SRAM DUT (spec 6.1):
   line coverage >= 95%, FSM (state+transition) = 100%.
Parses urg's modlist.txt: the 'Total Module Definition Coverage Summary'
row is 'SCORE LINE FSM' = three floats."""
import sys

path = sys.argv[1]
txt = open(path).read()

i = txt.index("Total Module Definition Coverage Summary")
row = None
for ln in txt[i:].splitlines():
    f = ln.split()
    if len(f) >= 3 and all(x.replace(".", "").isdigit() or x == "--" for x in f[:3]):
        row = f
        break

if row is None or row[1] == "--" or row[2] == "--":
    print("COV-GATE FAIL: could not parse LINE/FSM totals from modlist.txt")
    sys.exit(1)

line, fsm = float(row[1]), float(row[2])
ok = True
if line < 95.0:
    print(f"COV-GATE FAIL: line coverage {line}% < 95%")
    ok = False
if fsm < 100.0:
    print(f"COV-GATE FAIL: FSM coverage {fsm}% < 100%")
    ok = False
if ok:
    print(f"COV-GATE PASS: line={line}% fsm={fsm}%")
sys.exit(0 if ok else 1)
