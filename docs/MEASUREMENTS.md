# Measurements

Every number here was measured, on one setup. Where something is an estimate or was not measured, it says so.

## Test setup

| | |
|---|---|
| Mac | MacBook Pro, M5 Pro (18 cores), built-in 120 Hz display, macOS 27 |
| Console | Xbox Series S, 1080p 60 Hz output |
| Game | GTA 6, which runs at 30 fps on that console |
| Capture card | A $25 USB 3 HDMI card (USB ID 345f:2131), 1920x1080 at 60 fps, uncompressed |
| Processing size | 1920x1080 |
| Upscale target | 3024x1702 (the MacBook's full-screen 16:9 area) |

The Mac was in normal use during testing, with other apps open, so timings lean pessimistic.

## What reaches the screen

Measured with the app's own on-screen probe (Advanced > Measure What Reaches the Screen): a 120 Hz screen capture of the app's window, counting
distinct updates. Two 10-second runs during play:

| | Run 1 | Run 2 |
|---|---|---|
| Updates per second | 59.7 | 59.9 |
| Spacing, standard deviation | 2.0 ms | 1.5 ms |
| Spacing, 5th / 50th / 95th percentile | 14.1 / 16.7 / 19.5 ms | 14.8 / 16.8 / 18.5 ms |
| Longest gap | 27 ms | 33 ms |
| Gaps over 25 ms | 0.4 a second | 0.1 a second |

The source itself occasionally went 50 ms between real frames. The likely cause is the game dipping below
30 fps; that was not confirmed.

## Stage timings

| Stage | Time | Conditions |
|---|---|---|
| Generate one frame, 1080p | 8.5 to 9 ms | Calling thread never sleeps (turbo) |
| Generate one frame, 1080p | 16 to 17 ms | Calling thread sleeps between frames |
| Generate one frame, 720p | 3 ms | Back to back |
| Upscale a pair, 1080p → 3024x1702 | 3 to 5 ms | One GPU submission for both frames |
| Generate three frames per pair (for 4x), 720p | 9 ms | |
| Generate three frames per pair (for 4x), 1080p | 37 ms | Longer than a 30 fps frame, so 4x was dropped |

## Delay

The app's `delay` figure is the time from the capture card's timestamp on a real frame to the moment that frame
is handed to the display.

| | Frame generation on | Frame generation off |
|---|---|---|
| Frame reaches the Mac after its timestamp (`arrive`) | 12 to 28 ms | 12 to 28 ms |
| App's own share | 32 ms (31 to 33) | about 2 ms |
| `delay` | 45 to 57 ms, median 50 | about 20 ms |

So frame generation adds about 30 ms.

**Not measured: button-to-screen delay.** The figures above leave out the game's own input delay, whatever
happens inside the capture card before it stamps a frame, and the display. The way to measure the total is to
film the controller and screen at 240 fps and count frames. That has not been done.

### The capture card's 100-second cycle

The `arrive` time is not steady. It slides down about 1.6 ms every 10 seconds, from about 28 ms to about 13 ms,
then jumps back up by about 15 ms. One cycle takes roughly 100 seconds. Medians per 10 seconds from one run:

```
arrive: 19 17 16 15 13 27 25 24 22 20 19 17 16 14
delay:  53 51 51 50 48 62 61 59 58 56 54 52 52 49      (before the pacing margin was trimmed by 3 ms)
```

A jump of about one 60 Hz frame every 100 seconds looks like two clocks running at slightly different rates,
with one frame slipped each time they drift a full frame apart. That is an interpretation, not a measurement.
It is also unknown whether the swing is real delay inside the card or only how the card timestamps frames.

Both of the card's uncompressed pixel formats (`yuvs` and `420v`) showed the identical pattern over two minutes
each, so the format is not the cause.

## Load

Measured with `top` and the GPU's utilisation counter while playing, turbo on, window at 1080p size (so the
upscaler was idle):

| | |
|---|---|
| CPU | 70 to 79% of one core. Most of this is the turbo thread spinning by design. |
| GPU | About 30% busy. This counter covers the whole Mac, not only this app. |
| Memory | 383 MB |

## Self-test

`MacFrameGen --selftest` feeds a synthetic 30 fps picture through the full pipeline for 6 seconds and prints
the stats line. On the test Mac, with real footage as input: generation 9 ms, upscale 4.2 ms per pair, delay
33 ms with turbo and 42 ms without. There is no capture card in that path, so its delay is lower than in play.
