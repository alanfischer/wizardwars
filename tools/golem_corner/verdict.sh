#!/usr/bin/env bash
# GOOD/BAD for one probe_golem_real run: did the corner rider stay inside the cockpit?
#
# GOOD = 300 ticks with the hull-1 trace point never past the rear wall (body-local x
# -16.00) or the right wall (y -80.00); the 0.5-unit slack is the margin standoff.
# Calibrated against a hand test: WW main with hop e5ce7b9 is GOOD and a player cannot
# get out of the golem; with hop 537ee9a it is BAD and a player can. See TODO.md.
python3 - "$1" <<'PY'
import re,sys
rows=[];left=None
for ln in open(sys.argv[1]):
    m=re.match(r"^t\s*(\d+)\s+local GS \(\s*([-0-9.]+),\s*([-0-9.]+),\s*([-0-9.]+)\)",ln)
    if m: rows.append(tuple(float(m.group(i)) for i in (2,3,4)))
    if "LEFT THE GOLEM" in ln: left=ln.strip()
if not rows:
    print("no ticks — the probe did not run"); raise SystemExit(2)
xs=[r[0] for r in rows]; ys=[r[1] for r in rows]
good = len(rows) >= 300 and min(xs) >= -16.5 and min(ys) >= -80.5
print("%s ticks=%-4d x[%7.2f..%7.2f] y[%7.2f..%7.2f]  %s" % (
    "GOOD" if good else "BAD ", len(rows), min(xs), max(xs), min(ys), max(ys), left or ""))
raise SystemExit(0 if good else 1)
PY
