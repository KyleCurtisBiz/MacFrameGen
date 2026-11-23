import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// The pipeline: takes captured frames, drops repeats, generates the in-between frame, upscales, and hands
/// frames to the display at evenly spaced times.
final class Engine {
    let layer: AVSampleBufferDisplayLayer
    let captureQueue = DispatchQueue(label: "macframegen.capture", qos: .userInteractive)
    private let showQ = DispatchQueue(label: "macframegen.show", qos: .userInteractive)

    /// The size frames are processed at (at most 1920x1080).
    var width: Int { generator.width }
    var height: Int { generator.height }

    // Switches, safe to flip while running.
    var genOn = true
    var upscaleOn = true
    /// "Even" pacing shows every real frame a fixed delay after it was captured and puts the generated frame
    /// exactly halfway before it, so spacing follows the source and not how long generation took. With it off,
    /// the generated frame is shown the moment it is ready: slightly less delay, uneven spacing.
    var evenPacing = true
    /// See `submit`.
    var turbo = true

    let generator = FrameGenerator()
    private var repeats = RepeatDetector()
    private let upscaler = Upscaler()
    private var card: CardSource?

    private var prev: CVPixelBuffer?, prevArrive = 0.0, prevCap = 0.0
    private var interval = 1.0 / 30.0        // smoothed time between real frames
    private var latency = 0.060              // current fixed capture-to-show delay for real frames (seconds)
    private var readyHist: [Double] = []
    private var readyEst = 0.030             // recent capture-to-"frames ready" time (seconds)
    private var lastSched = 0.0
    private var fmtDesc: CMVideoFormatDescription?
    private var outW = 0, outH = 0           // size to upscale to, in real pixels, set by the window code

    // Statistics for the current second, guarded by `lock`.
    private let lock = NSLock()
    private var nReal = 0, nGen = 0, nShown = 0, nFail = 0, nLateGen = 0, nUpFail = 0, nArrived = 0
    private var brightness = 0.0
    private var interpMs: [Double] = [], delayMs: [Double] = [], showGaps: [Double] = [], upMs: [Double] = [], arriveMs: [Double] = []
    private var lastShown = 0.0

    /// Optional per-frame CSV for offline analysis (see scripts/analyze-frames.py).
    var frameLog: FileHandle?
    private var logBuf = "", logLines = 0
    private var probe: OutputProbe?
    private var probeTimes: [Double] = [], probeHanded = 0

    init(layer: AVSampleBufferDisplayLayer) { self.layer = layer }

    /// The window's content size in real pixels; the upscaler renders to exactly this.
    func setOutputPixels(_ w: Int, _ h: Int) { lock.lock(); outW = w / 2 * 2; outH = h / 2 * 2; lock.unlock() }

    // MARK: Sources

    /// Starts reading from a capture device. Stops whatever was running before.
    func start(card c: CardSource, device: AVCaptureDevice) throws {
        stop()
        guard let f = CardSource.bestFormat(for: device) else { throw EngineError("\(device.localizedName) offers no usable video mode") }
        // Process at the card's own size, shrunk if needed to the interpolator's 1920x1080 limit.
        let k = min(1.0, min(Double(FrameGenerator.maxWidth) / Double(f.width), Double(FrameGenerator.maxHeight) / Double(f.height)))
        try configure(width: max(64, Int(Double(f.width) * k) / 2 * 2), height: max(64, Int(Double(f.height) * k) / 2 * 2))
        try c.start(device: device, format: f, width: width, height: height, queue: captureQueue, engine: self)
        card = c
    }

    func stop() {
        card?.stop(); card = nil
        synthTimer?.cancel(); synthTimer = nil
    }

    /// Builds the interpolator for a frame size and clears everything carried over from the previous source.
    func configure(width w: Int, height h: Int) throws {
        guard FrameGenerator.isSupported else { throw EngineError("Apple's frame interpolator is not available on this Mac. It needs macOS 26 or later on Apple silicon.") }
        ingestLock.lock(); defer { ingestLock.unlock() }
        os_unfair_lock_lock(&slotLock); slot = nil; os_unfair_lock_unlock(&slotLock)
        prev = nil; lastSched = 0; readyHist.removeAll(); repeats.reset()
        guard generator.start(width: w, height: h) else { throw EngineError("the interpolator would not accept any size near \(w)x\(h)") }
    }

    var synthTimer: DispatchSourceTimer?

    // MARK: Input

    private var slot: (CVPixelBuffer, Double)?
    private var slotLock = os_unfair_lock()
    private let ingestLock = NSLock()
    private var worker: Thread?

    /// Entry point for every captured frame. `captured` is its capture time on the host clock.
    ///
    /// Turbo: frames are handed to a worker thread that never sleeps. Measured: the interpolator takes 8.6 ms at
    /// 1080p when the calling thread stays busy between frames, and about 16 ms when that thread sleeps in between
    /// (as an ordinary capture callback does). Sleeping part of the time, keeping another thread or the GPU busy,
    /// or raising the thread's priority did not help; only this did. It costs one processor core.
    func submit(_ pb: CVPixelBuffer, _ captured: Double) {
        if !turbo { ingestLock.lock(); ingest(pb, captured); ingestLock.unlock(); return }
        os_unfair_lock_lock(&slotLock); slot = (pb, captured); os_unfair_lock_unlock(&slotLock)   // newest frame wins
        if worker == nil {
            let t = Thread { [weak self] in
                // Spin only while frames are arriving. With no picture for a second (card unplugged, console off)
                // the thread naps, so an idle app does not hold a core. Measured before this: 99% CPU for 12 hours.
                var lastFrame = hostNow()
                while let self {
                    os_unfair_lock_lock(&self.slotLock); let f = self.slot; self.slot = nil; os_unfair_lock_unlock(&self.slotLock)
                    if let f { self.ingestLock.lock(); self.ingest(f.0, f.1); self.ingestLock.unlock(); lastFrame = hostNow() }
                    else if !self.turbo || hostNow() - lastFrame > 1 { usleep(2000) }
                }
            }
            t.qualityOfService = .userInteractive; t.name = "macframegen.turbo"; worker = t; t.start()
        }
    }

    private var nRealTotal = 0
    /// Average brightness of a frame on a sparse grid (16 is black, 235 is white). Used to notice a black picture.
    private static func meanBrightness(_ a: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(a, .readOnly); defer { CVPixelBufferUnlockBaseAddress(a, .readOnly) }
        guard let r = CVPixelBufferGetBaseAddressOfPlane(a, 0) else { return 0 }
        let p = r.assumingMemoryBound(to: UInt8.self), st = CVPixelBufferGetBytesPerRowOfPlane(a, 0)
        let w = CVPixelBufferGetWidthOfPlane(a, 0), h = CVPixelBufferGetHeightOfPlane(a, 0)
        var sum = 0, n = 0, y = 8
        while y < h { var x = 8; while x < w { sum += Int(p[y * st + x]); n += 1; x += 16 }; y += 16 }
        return n == 0 ? 0 : Double(sum) / Double(n)
    }

    private func ingest(_ pb: CVPixelBuffer, _ captured: Double) {
        let now = hostNow()
        lock.lock(); nArrived += 1; lock.unlock()
        // The frame's clock is when it was captured, not when it reached us: judging repeats and pacing on
        // arrival times went wrong whenever generation kept this thread busy.
        let cap = (captured > 0 && captured <= now && now - captured < 0.25) ? captured : now
        let diff = prev.map { RepeatDetector.difference($0, pb) } ?? 255
        if prev != nil { repeats.learn(diff) }
        if prev != nil, cap - prevCap < repeats.maxHold, diff < repeats.threshold {
            record("A,D,%.4f,%.4f,%.2f\n", now, cap, diff)
            return
        }
        guard let cur = generator.copy(pb) else { return }
        let gap = prev == nil ? 0 : cap - prevCap
        if prev != nil, gap > 0.004, gap < 0.2 { interval = interval * 0.8 + gap * 0.2 }
        let bright = nRealTotal % 15 == 0 ? Engine.meanBrightness(pb) : -1
        nRealTotal += 1
        lock.lock(); nReal += 1; arriveMs.append((now - cap) * 1000); if bright >= 0 { brightness = bright }; lock.unlock()
        record("A,R,%.4f,%.4f,%.2f\n", now, cap, diff)

        // Generate the halfway frame, unless the source is already faster than about 45 fps (gap under 22 ms,
        // nothing to add) or there was a long pause (gap over 120 ms, the two frames are unrelated).
        var mid: CVPixelBuffer?
        if genOn, let p = prev, gap < 0.12, gap > 0.022,
           let r = generator.interpolate(previous: p, at: prevArrive, current: cur, at: now) {
            lock.lock(); interpMs.append(r.seconds * 1000); if r.frame == nil { nFail += 1 }; lock.unlock()
            mid = r.frame
        }
        prev = cur; prevArrive = now; prevCap = cap
        tagBT709(cur); if let mid { tagBT709(mid) }

        // Upscale before the frames are scheduled, so its cost is part of the planned delay and not a late surprise.
        var curS = cur
        lock.lock(); let ow = outW, oh = outH; lock.unlock()
        if upscaleOn, let up = upscaler, ow > width, oh > height {
            let t0 = hostNow()
            let frames = (mid.map { [$0] } ?? []) + [cur]
            let done = up.run(frames, outW: ow, outH: oh)
            var failed = 0
            if mid != nil { if let u = done[0] { mid = u } else { failed += 1 } }
            if let u = done[frames.count - 1] { curS = u } else { failed += 1 }
            lock.lock(); upMs.append((hostNow() - t0) * 1000); nUpFail += failed; lock.unlock()
        }
        lock.lock(); if mid != nil { nGen += 1 }; lock.unlock()

        if !genOn {
            showQ.async { self.show(curS, capturedAt: cap) }
        } else if evenPacing {
            // The fixed delay drifts slowly toward: recent capture-to-ready time + 1 ms + half a frame interval.
            // Capture-to-ready includes how long the frame took to reach us (12-28 ms from a capture card).
            // A high percentile of the last 60 pairs is used, not a maximum: one slow start-up frame otherwise
            // kept the delay inflated for many seconds. 90th percentile + 1 ms measured 3 ms less delay than
            // 95th + 3 ms with about 2% of generated frames missing their slot, each shown as soon as it was ready.
            let half = min(max(interval * 0.5, 1.0 / 240.0), 1.0 / 20.0)
            let ready = hostNow() - cap
            if ready > 0, ready < 0.2 {
                readyHist.append(ready); if readyHist.count > 60 { readyHist.removeFirst() }
                let v = readyHist.sorted(); readyEst = v[min(v.count - 1, Int(Double(v.count) * 0.90))]
            }
            latency += ((readyEst + 0.001 + half) - latency) * 0.1
            var tReal = cap + latency
            var floor = max(hostNow(), lastSched + 0.004)
            if let m = mid {
                let want = tReal - min(gap, 0.1) * 0.5
                if want < floor - 0.001 { lock.lock(); nLateGen += 1; lock.unlock() }
                let tM = max(want, floor)
                showAt(m, tM, capturedAt: nil, kind: "G")
                floor = tM + 0.004
            }
            tReal = max(tReal, floor)
            showAt(curS, tReal, capturedAt: cap, kind: "R")
            lastSched = tReal
        } else if let m = mid {
            let step = min(max(interval / 2, 1.0 / 240.0), 1.0 / 30.0)
            showQ.async { self.show(m, capturedAt: nil, kind: "G") }
            showQ.asyncAfter(deadline: .now() + step) { self.show(curS, capturedAt: cap) }
        } else {
            showQ.async { self.show(curS, capturedAt: cap) }
        }
    }

    // MARK: Output

    /// Shows a frame at a given host time, with a strict timer (plain asyncAfter can be several ms late).
    private func showAt(_ buf: CVPixelBuffer, _ when: Double, capturedAt: Double?, kind: String) {
        let d = when - hostNow()
        if d <= 0.0005 { showQ.async { self.show(buf, capturedAt: capturedAt, due: when, kind: kind) }; return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: showQ)
        t.schedule(deadline: .now() + d, leeway: .nanoseconds(0))
        t.setEventHandler { self.show(buf, capturedAt: capturedAt, due: when, kind: kind); t.cancel() }
        t.resume()
    }

    private func show(_ buf: CVPixelBuffer, capturedAt: Double?, due: Double = 0, kind: String = "R") {
        if fmtDesc == nil || !CMVideoFormatDescriptionMatchesImageBuffer(fmtDesc!, imageBuffer: buf) {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buf, formatDescriptionOut: &fmtDesc)
        }
        guard let fd = fmtDesc else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buf, formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let r = layer.sampleBufferRenderer
        if r.status == .failed { r.flush() }
        r.enqueue(sb)
        let t = hostNow()
        lock.lock()
        nShown += 1
        if probe != nil { probeHanded += 1 }
        if let c = capturedAt { delayMs.append((t - c) * 1000) }
        if lastShown > 0 { showGaps.append((t - lastShown) * 1000) }
        lastShown = t
        lock.unlock()
        record("S,%@,%.4f,%.4f,%.4f\n", kind, t, due, capturedAt ?? 0)
    }

    // MARK: Statistics

    private func record(_ format: String, _ args: CVarArg...) {
        guard frameLog != nil else { return }
        lock.lock(); defer { lock.unlock() }
        if logLines < 400_000 { logBuf += String(format: format, arguments: args); logLines += 1 }
    }

    /// One line describing the last second, then resets the counters. Call once a second.
    ///
    /// - real / gen / shown: real frames accepted, frames generated, frames handed to the display
    /// - spacing: standard deviation of the time between hand-overs; gaps>25ms: hand-overs more than 25 ms apart
    /// - late: generated frames that were not ready for their slot
    /// - arrive: how long after its capture timestamp a real frame reached the app
    /// - gen / upscale: time per generated frame and per upscaled pair
    /// - delay: capture timestamp to hand-over for real frames. Not button-to-screen delay.
    struct Stats {
        var real = 0, generated = 0, shown = 0, longGaps = 0, late = 0
        /// Frames that arrived from the source, repeats included. Zero means the source is sending nothing.
        var arrived = 0
        /// Average brightness of a recent frame: 16 is black, 235 is white.
        var brightness = 0.0
        var delayMs = 0.0, generateMs = 0.0, upscaleMs = 0.0, arriveMs = 0.0
        /// Everything on one line, for the log and the detailed display.
        var line = ""
    }
    func takeStats() -> Stats {
        lock.lock(); defer { lock.unlock() }
        func med(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        func sd(_ v: [Double]) -> Double {
            guard v.count > 1 else { return 0 }
            let m = v.reduce(0, +) / Double(v.count)
            return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
        }
        let up = upscaleOn ? (upMs.isEmpty ? "upscale idle" : String(format: "upscale %.1f ms%@", med(upMs), nUpFail > 0 ? " (FAILED \(nUpFail))" : "")) : "upscale off"
        let s = String(format: "%dx%d  real %d  gen %d%@  shown %d fps  spacing +/-%.1f ms  gaps>25ms %d  late %d  arrive %.0f ms  gen %.0f ms  %@  delay %.0f ms  %@  FG %@%@",
                       width, height, nReal, nGen, nFail > 0 ? " (FAILED \(nFail))" : "", nShown, sd(showGaps), showGaps.filter { $0 > 25 }.count,
                       nLateGen, med(arriveMs), med(interpMs), up, med(delayMs), evenPacing ? "even" : "immediate", genOn ? "on" : "OFF", turbo ? "  turbo" : "")
        if let h = frameLog, !logBuf.isEmpty, let d = logBuf.data(using: .utf8) { h.write(d) }
        logBuf = ""
        let out = Stats(real: nReal, generated: nGen, shown: nShown, longGaps: showGaps.filter { $0 > 25 }.count, late: nLateGen,
                        arrived: nArrived, brightness: brightness,
                        delayMs: med(delayMs), generateMs: med(interpMs), upscaleMs: upscaleOn ? med(upMs) : 0, arriveMs: med(arriveMs), line: s)
        nReal = 0; nGen = 0; nShown = 0; nFail = 0; nLateGen = 0; nUpFail = 0; nArrived = 0
        interpMs.removeAll(); delayMs.removeAll(); showGaps.removeAll(); upMs.removeAll(); arriveMs.removeAll()
        return out
    }

    // MARK: On-screen measurement

    /// Watches this app's own window with a second, small screen capture to time when frames really reach the
    /// screen. This is the check that what the app hands over is what the display shows.
    func startOutputProbe(window: SCWindow) async -> Bool {
        let p = OutputProbe(); p.engine = self
        clearProbe()
        guard (try? await p.start(window: window)) != nil else { return false }
        probe = p
        return true
    }
    func noteOutput(_ t: Double) {
        lock.lock(); probeTimes.append(t); lock.unlock()
        record("O,,%.4f,0,0\n", t)
    }
    private func clearProbe() { lock.lock(); probeTimes.removeAll(); probeHanded = 0; lock.unlock() }
    private func takeProbe() -> ([Double], Int) {
        lock.lock(); defer { lock.unlock() }
        let r = (probeTimes.sorted(), probeHanded); probeTimes.removeAll(); return r
    }
    /// Stops the probe and describes what it saw: distinct updates of the window per second and their spacing.
    func finishProbe() async -> (short: String, full: String) {
        await probe?.stop(); probe = nil
        let (ts, handed) = takeProbe()
        guard ts.count > 20, let first = ts.first, let last = ts.last, last - first > 2 else {
            return ("No measurement: the window was not visible", "on-screen measurement: no data (is the window visible?)")
        }
        let g = zip(ts, ts.dropFirst()).map { ($1 - $0) * 1000 }.sorted()
        let dur = last - first, m = g.reduce(0, +) / Double(g.count)
        let sd = (g.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(g.count)).squareRoot()
        func pc(_ p: Double) -> Double { g[min(g.count - 1, Int(Double(g.count) * p))] }
        let full = String(format: "ON SCREEN over %.0f s: %.1f updates/s (handed over %.1f/s)  spacing +/-%.1f ms  p5 %.1f  p50 %.1f  p95 %.1f  max %.0f  gaps>25ms %.1f/s",
                      dur, Double(ts.count - 1) / dur, Double(handed) / dur, sd, pc(0.05), pc(0.5), pc(0.95), g.last ?? 0, Double(g.filter { $0 > 25 }.count) / dur)
        return (String(format: "On screen: %.1f frames a second, spacing ±%.1f ms", Double(ts.count - 1) / dur, sd), full)
    }
}

struct EngineError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
