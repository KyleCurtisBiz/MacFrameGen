# Research tools

Single-file experiments that produced the numbers in [docs/MEASUREMENTS.md](../docs/MEASUREMENTS.md) and
[docs/FINDINGS.md](../docs/FINDINGS.md). They are rough: each one was written to answer one question. They are
not part of the app.

Build them all with `Research/build.sh`; the binaries land in `Research/bin/`.

| Tool | Question it answers |
|---|---|
| `interpolate-clip` | Does Apple's interpolator look good on a recording of a 30 fps game? Writes a 60 fps video. |
| `upscale-clip` | What does the MetalFX spatial upscaler do to a 1080p recording? |
| `superres-clip` | How does Apple's machine-learning upscaler compare, and how slow is it? |
| `predict-clip` | Could frames be predicted (extrapolated) instead of interpolated, to remove the hold-back delay? Scores predicted frames against real ones. `--synthetic 8,32,64` runs a known-shift check of the optical flow. |
| `optical-flow-speed` | How fast are Apple's two optical-flow APIs at several sizes? |
| `interpolator-pacing` | Why is the interpolator twice as slow in a real-time loop as in a benchmark? (The "turbo" finding.) |

The clip tools expect a 60 fps recording of a game running at 30 fps, such as a console's built-in capture.
