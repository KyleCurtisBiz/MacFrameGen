# Findings and dead ends

Things learned along the way that are not obvious from Apple's documentation, and approaches that were tried and
dropped. Numbers are from the setup described in [MEASUREMENTS.md](MEASUREMENTS.md).

## Apple's low-latency frame interpolator

- **Requires macOS 26.** `VTLowLatencyFrameInterpolationConfiguration` and friends sit on the `VTFrameProcessor`
  framework that arrived in macOS 15.4.
- **Input:** 4:2:0 bi-planar video-range buffers only, at most 1920x1080.
- **Silent failure at some sizes.** At height 1080, widths 1896 to 1904 start a session without error and then
  fail every frame with "Processor is not initialized" (error -19730). Widths 1888, 1838, 1728, 1662 and 1920
  work, as does 1920x1042. Run a trial interpolation before trusting a size.
- **Speed depends on what the calling thread does between calls.** 8.6 ms back to back, about 16 ms when the
  caller sleeps for the rest of a 33 ms period. Only a caller that spins the whole gap gets the fast figure.
  Partial spinning, a spinning helper thread, GPU keep-alive work on another thread, user-interactive QoS and a
  real-time thread policy made no difference. `Research/interpolator-pacing.swift` reproduces this.
- **More frames per pair scale badly at 1080p.** Three frames per pair: 9 ms at 720p, 37 ms at 1080p.

## Apple's optical flow (`VTOpticalFlow`)

- **Normal quality reports motion in units of 8 pixels.** Shifting a frame by 64 pixels gives a flow of 8.0 in
  normal mode and 64.0 in quality mode. The output buffer is full size in both modes. This is not documented;
  it was found with a known-shift test (`predict-clip --synthetic`).
- **Direction:** the backward flow at a pixel in the second frame points to where that pixel came from in the
  first, in pixel units, x then y, top-left origin.
- **Accuracy on a known shift:** quality mode rebuilt the shifted frame at 42 to 46 dB for shifts up to 32
  pixels; normal mode managed 31 dB at 8 pixels and 23 dB at 64.
- **Speed at 1080p:** 8.4 ms normal, 15.5 ms quality. The older Vision framework flow took 22 to 39 ms.

## Tried and dropped

### Predicting frames instead of interpolating

**Why:** interpolation has to hold each real frame back by half a frame interval (17 ms) so the generated frame
can go first. Predicting the *next* frame from the last two would let every real frame be shown immediately,
cutting about 26 ms.

**Test:** on a recording of the game, take consecutive real frames A, B, C. Estimate motion from A to B with
Apple's optical flow, push B forward by that motion, and compare the result with the real C. 456 triples.

| Method | Match to the real frame (PSNR, higher is better) | Worst 5% |
|---|---|---|
| Interpolation (the frame between A and C, compared with B) | 27.3 dB | 22.2 dB |
| Repeat the last frame (B compared with C) | 20.9 dB | |
| Prediction, quality flow | 20.5 dB | 18.3 dB |
| Prediction, normal flow | 17.8 dB | 14.7 dB |

**Result:** predicted frames were no closer to the truth than showing the last frame again. Normal-mode flow is
too coarse to help, and quality mode takes about 16 ms, which does not fit in the 17 ms available.

**Caveats:** PSNR punishes anything slightly out of place, so it is harsher than the eye. The test predicts a
full 33 ms ahead where live use would need 17 ms. The warp was a plain backward warp with no handling of
revealed areas. A better motion estimator could change the answer. `Research/predict-clip.swift` is the test.

### Capturing Xbox Remote Play in a browser

No capture card needed: capture the browser window with ScreenCaptureKit and draw the result over it. It worked,
with a lot of machinery (a click-through overlay that never takes focus, because Remote Play pauses when the
browser loses it; a strip left uncovered so the browser keeps drawing; automatic cropping to the game picture).
It was dropped because the stream itself was the problem: heavy input lag, visible compression, and it appeared to load
the console enough to slow the game. That code is not in this repository.

### Apple's machine-learning upscaler (`VTSuperResolutionScaler`)

4x only, 1080p input at most, about 0.3 seconds per frame. Cleaner edges than MetalFX with a smoothed, painted
look. Far too slow to run live. Apple also ships a low-latency ML upscaler; that one has not been tried.

### 720p processing and 4x generation

At 720p the interpolator is fast enough for three generated frames per pair (4x, 120 fps). The picture was too
soft to be worth it, and at 1080p 4x does not fit in a frame. Both were removed.

### The capture card's other pixel format

The card offers `yuvs` (4:2:2) and `420v`. They measured the same over two minutes each. The app uses `420v`
because it needs no conversion.

### Locking hand-overs to the display's refresh

Snapping each hand-over to half a refresh before the refresh it was meant for. It was never shown to improve
on-screen spacing in testing and was removed.
