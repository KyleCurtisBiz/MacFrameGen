#!/usr/bin/env python3
"""Summarise the per-frame CSV that MacFrameGen writes with --frames <path>: how evenly frames were shown.
Usage: analyze-frames.py frames.csv
Rows: S,kind,t_shown,t_due,t_captured   frame handed to the display (kind R = real, G = generated)
      O,,t_onscreen,0,0                 window seen changing on screen (only while Measure is running)
      A,R|D,t_arrived,t_captured,score  frame arrived from the card (D = skipped as a repeat)"""
import sys, statistics as st
def stats(name, ts, skip=1.0):
    ts = sorted(ts)
    if len(ts) < 10: print(f"{name}: not enough data"); return
    t0 = ts[0] + skip
    g = [(b - a) * 1000 for a, b in zip(ts, ts[1:]) if a >= t0]
    g.sort(); n = len(g)
    pct = lambda p: g[min(n - 1, int(n * p))]
    dur = ts[-1] - t0
    print(f"{name}: {n / dur:5.1f}/s  spacing mean {st.mean(g):5.1f} ms  +/-{st.pstdev(g):4.1f}  p5 {pct(.05):5.1f}  p50 {pct(.5):5.1f}  p95 {pct(.95):5.1f}  max {g[-1]:6.1f}  gaps>25ms {sum(x > 25 for x in g) / dur:4.1f}/s")
S, O, AR, delay, late = [], [], [], [], []
for line in open(sys.argv[1]):
    f = line.strip().split(",")
    if len(f) < 5: continue
    if f[0] == "S":
        t, due, cap = float(f[2]), float(f[3]), float(f[4]); S.append(t)
        if cap > 0: delay.append((t - cap) * 1000)
        if due > 0: late.append((t - due) * 1000)
    elif f[0] == "O": O.append(float(f[2]))
    elif f[0] == "A" and f[1] == "R": AR.append(float(f[3]))
stats("real frames in ", AR); stats("handed to screen", S); stats("seen on screen  ", O)
if delay: print(f"capture-to-show delay of real frames: median {st.median(delay):.0f} ms, p95 {sorted(delay)[int(len(delay) * .95)]:.0f} ms")
if late: print(f"shown later than planned: median {st.median(late):.1f} ms, p95 {sorted(late)[int(len(late) * .95)]:.1f} ms")
