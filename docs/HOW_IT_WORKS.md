# How it works

The app is a five-stage pipeline. Each stage has one file in `Sources/MacFrameGen`.

```
capture card ──► drop repeats ──► generate ──► upscale ──► pace ──► display
 CardSource     RepeatDetector  FrameGenerator  Upscaler    Engine
```

## 1. Capture (`CardSource.swift`)

A USB capture card is a UVC device, the same class as a webcam, so macOS reads it through AVFoundation and asks
for the Camera permission. The app picks the card's video mode in this order: 60 fps, then uncompressed, then
1080p, then the `420v` pixel layout (which is what the interpolator reads, so nothing is converted).

The card's sound is a separate audio device. macOS does not always link it to the video device, so the app
matches it by name or by USB vendor and product ID and plays it straight through.

Each frame carries a capture timestamp. Everything downstream is timed from that timestamp, not from when the
frame happened to arrive.

## 2. Drop the repeats (`RepeatDetector.swift`)

A console outputs 60 frames a second whatever the game does. A 30 fps game means each game frame is sent twice.
Interpolating between a frame and its own copy would produce nothing useful, so repeats have to go.

Each arriving frame is compared with the last accepted one by mean absolute brightness difference on a sparse
grid. The hard part is the cut-off:

- Through a clean capture card, repeats score 0.00.
- Real frames in a slow scene score as low as 0.3; in motion, 5 or more.
- Through a lossy source (a compressed stream), repeats score about 0.1.

No fixed number works everywhere, so the cut-off is learned: every 15 frames the last 90 scores are sorted and
the cut-off goes in the widest gap between the low group and the high group. If there is no clear gap, such as a
true 60 fps game or a still picture, nothing is skipped and frames pass straight through.

One more rule: a run of look-alike frames is never skipped for longer than 45 ms. Without it, a nearly still
scene would freeze the picture.

## 3. Generate (`FrameGenerator.swift`)

`VTLowLatencyFrameInterpolation` (VideoToolbox, macOS 26) takes two frames and returns the frame halfway between
them. It is limited to 1920x1080 and to 4:2:0 video-range pixel buffers.

Two things about it are not in the documentation and cost time to find:

- **It silently fails at some sizes.** At height 1080, widths 1896 to 1904 start without error and then every
  frame fails with "Processor is not initialized"; 1888 and 1920 work. The app runs one real interpolation at
  startup and steps the width down by 8 until one succeeds.
- **It is twice as slow in a real-time loop as in a benchmark.** See turbo, below.

Generation is skipped when two real frames are less than 22 ms apart (the source is already fast) or more than
120 ms apart (a pause; the two frames are unrelated).

### Turbo

Called back to back, the interpolator takes 8.6 ms for a 1080p frame. Called once every 33 ms from a thread that
sleeps in between, as any capture callback does, it takes about 16 ms.

What did not fix it: spinning for part of the gap, keeping a different thread busy, keeping the GPU busy with
small jobs, a higher quality-of-service class, a real-time thread policy.

What did: handing frames to a dedicated worker thread that never sleeps. It spins while it waits for the next
frame. That costs one CPU core and brings generation back to 9 ms. It is on by default; the Advanced menu calls
it Fast Generation.

## 4. Upscale (`Upscaler.swift`)

A 1080p frame on a 3024x1964 MacBook screen would otherwise be stretched by the display layer. Instead a Metal
compute shader converts the frame to RGB (BT.709, video range) and MetalFX's spatial scaler renders it at the
window's exact pixel size. Both frames of a pair go to the GPU in one submission: 3 to 5 ms for the pair.

Upscaling happens before the frames are scheduled, so its cost is inside the planned delay.

## 5. Pace (`Engine.swift`)

Getting 60 frames a second to the display is easy. Getting them evenly spaced is the part that decides whether
it looks smooth.

The naive approach, showing the generated frame when it is ready and the real frame straight after, gives
uneven spacing, because generation time varies and so does arrival time. It reads as judder.

The app instead keeps one number: a fixed delay from capture to display for real frames.

- A real frame is shown at `capture time + delay`.
- Its generated frame is shown half a frame interval before that.
- `delay` drifts slowly toward: the recent time from capture to "both frames ready" (90th percentile of the last
  60 pairs) + 1 ms + half a frame interval.

Because both frames hang off the capture timestamp, spacing follows the source's own rhythm. If a generated
frame is not ready for its slot it is shown as soon as it is; the stats line counts those as `late`.

Frames are handed to an `AVSampleBufferDisplayLayer` marked "display immediately", using strict dispatch timers
(a plain `asyncAfter` can be several milliseconds late).

### Where the delay goes

With frame generation on, a real frame is displayed about 32 ms after the Mac receives it:

| Piece | Time | Notes |
|---|---|---|
| Hold-back | 17 ms | The generated frame has to be shown first. Half the interval between real frames, by definition. |
| Generation | 9 ms | Apple's interpolator, with turbo. |
| Upscaling | 3 to 5 ms | Zero with the upscaler off. |
| Margin | 1 to 2 ms | |

With frame generation off the same frame is displayed about 2 ms after it is received.

## Checking the result (`OutputProbe.swift`)

Counting the frames the app hands over proves little; what matters is what the display shows. Advanced >
Measure What Reaches the Screen starts a
second, small screen capture of the app's own window at 120 Hz for ten seconds and reports how many distinct
updates appeared and how they were spaced. Early in development this was what showed that a version reporting 60
frames a second was putting them on screen unevenly.
