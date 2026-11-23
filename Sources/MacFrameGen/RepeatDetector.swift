import CoreVideo

/// Tells repeated frames from new ones.
///
/// A console running a 30 fps game still sends 60 frames a second: every game frame arrives twice. Frame
/// generation needs the real frames only, so each arriving frame is compared with the last accepted one.
struct RepeatDetector {
    /// Frames scoring below this are treated as repeats. Found automatically; 0 means "skip nothing".
    ///
    /// No fixed number suits every source and scene. Measured live: repeats score about 0.1 (a clean capture
    /// card gives 0.00), real frames in a slow scene 0.3-2.5, and in motion 5 or more. Every 15 frames the last
    /// 90 scores are sorted and the cut-off is put in the widest gap between the low group and the high group.
    /// If there is no clear gap (a true 60 fps source, or a still picture) nothing is skipped.
    private(set) var threshold = 0.5
    private var recent: [Double] = []

    /// How long look-alike frames may be skipped before one is let through anyway, in seconds. Without a limit
    /// a nearly still scene, where real frames barely differ either, would freeze the picture. At 27 ms, repeats
    /// that simply arrived late were let through as new frames several times a second, so it is 45 ms.
    let maxHold = 0.045

    mutating func reset() { threshold = 0.5; recent.removeAll() }

    mutating func learn(_ score: Double) {
        recent.append(min(score, 50)); if recent.count > 90 { recent.removeFirst() }
        guard recent.count >= 45, recent.count % 15 == 0 else { return }
        let v = recent.sorted(), n = v.count
        var best = 0.0, at = 0.0
        for i in (n / 5)..<(n * 4 / 5) {
            let lo = v[i] + 0.02, hi = v[i + 1] + 0.02
            if hi / lo > best { best = hi / lo; at = (lo * hi).squareRoot() }
        }
        // 1.7: in slow scenes the two groups were measured only about 3x apart (0.09 against 0.30).
        threshold = best >= 1.7 ? min(at, 3) : 0
    }

    /// Mean absolute brightness difference on a sparse grid. Small values mean "same frame again".
    static func difference(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        guard let ra = CVPixelBufferGetBaseAddressOfPlane(a, 0), let rb = CVPixelBufferGetBaseAddressOfPlane(b, 0) else { return 255 }
        let pa = ra.assumingMemoryBound(to: UInt8.self), pb = rb.assumingMemoryBound(to: UInt8.self)
        let sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0), sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        let w = min(CVPixelBufferGetWidthOfPlane(a, 0), CVPixelBufferGetWidthOfPlane(b, 0))
        let h = min(CVPixelBufferGetHeightOfPlane(a, 0), CVPixelBufferGetHeightOfPlane(b, 0))
        var sum = 0, n = 0, y = 0
        while y < h {
            var x = 0
            while x < w { sum += abs(Int(pa[y * sa + x]) - Int(pb[y * sb + x])); n += 1; x += 6 }
            y += 6
        }
        return n == 0 ? 255 : Double(sum) / Double(n)
    }
}
