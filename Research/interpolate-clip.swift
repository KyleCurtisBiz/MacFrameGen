// Offline test of Apple's low-latency frame interpolation on a recorded game clip.
// Usage: interpolate-clip <input.mp4> <output.mp4> [--analyze] [--threshold 3.0]
// Finds repeated frames (game running below the 60 Hz video rate), and replaces each
// repeat with a generated in-between frame. Real frames are passed through untouched.
import Foundation
import AVFoundation
import VideoToolbox
import CoreVideo

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: interpolate-clip in out [--analyze] [--threshold x]"); exit(2) }
let inURL = URL(fileURLWithPath: args[1]), outURL = URL(fileURLWithPath: args[2])
let analyzeOnly = args.contains("--analyze")
var threshold = 3.0
if let i = args.firstIndex(of: "--threshold"), i + 1 < args.count { threshold = Double(args[i + 1]) ?? 3.0 }

func die(_ s: String) -> Never { print("ERROR: \(s)"); exit(1) }

let asset = AVURLAsset(url: inURL)
let sem0 = DispatchSemaphore(value: 0)
var trackOpt: AVAssetTrack?
Task { trackOpt = try? await asset.loadTracks(withMediaType: .video).first; sem0.signal() }
sem0.wait()
guard let track = trackOpt else { die("no video track") }
var sz = CGSize.zero
let sem1 = DispatchSemaphore(value: 0)
Task { sz = (try? await track.load(.naturalSize)) ?? .zero; sem1.signal() }
sem1.wait()
let W = Int(sz.width), H = Int(sz.height)
print("input \(W)x\(H)")

let reader = try AVAssetReader(asset: asset)
let rout = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
rout.alwaysCopiesSampleData = false
reader.add(rout)
guard reader.startReading() else { die("reader: \(String(describing: reader.error))") }

// Mean absolute luma difference, sampling every 4th pixel in each direction.
func lumaDiff(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0)!.assumingMemoryBound(to: UInt8.self)
    let pb = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
    let sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0), sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
    var sum = 0, n = 0
    var y = 0
    while y < H { var x = 0
        while x < W { sum += abs(Int(pa[y * sa + x]) - Int(pb[y * sb + x])); n += 1; x += 4 }
        y += 4 }
    return Double(sum) / Double(n)
}

func makePool(_ attrs: [String: Any]) -> CVPixelBufferPool {
    var a = attrs
    a[kCVPixelBufferWidthKey as String] = W; a[kCVPixelBufferHeightKey as String] = H
    if a[kCVPixelBufferPixelFormatTypeKey as String] == nil { a[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange }
    if a[kCVPixelBufferIOSurfacePropertiesKey as String] == nil { a[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]() }
    var p: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, nil, a as CFDictionary, &p)
    return p!
}
func newBuf(_ pool: CVPixelBufferPool) -> CVPixelBuffer {
    var b: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, pool, &b); return b!
}
func copyBuf(_ src: CVPixelBuffer, _ pool: CVPixelBufferPool) -> CVPixelBuffer {
    let dst = newBuf(pool)
    CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst, [])
    for p in 0..<2 {
        let s = CVPixelBufferGetBaseAddressOfPlane(src, p)!, d = CVPixelBufferGetBaseAddressOfPlane(dst, p)!
        let ss = CVPixelBufferGetBytesPerRowOfPlane(src, p), ds = CVPixelBufferGetBytesPerRowOfPlane(dst, p)
        let h = CVPixelBufferGetHeightOfPlane(src, p), n = min(ss, ds)
        for y in 0..<h { memcpy(d + y * ds, s + y * ss, n) }
    }
    CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(dst, [])
    return dst
}

// Two interpolators: one for a single midpoint frame (30 -> 60), one that allows quarter points (for drops).
guard VTLowLatencyFrameInterpolationConfiguration.isSupported else { die("LLFI unsupported") }
guard let cfg1 = VTLowLatencyFrameInterpolationConfiguration(frameWidth: W, frameHeight: H, numberOfInterpolatedFrames: 1),
      let cfg2 = VTLowLatencyFrameInterpolationConfiguration(frameWidth: W, frameHeight: H, numberOfInterpolatedFrames: 2)
else { die("config failed") }
let proc1 = VTFrameProcessor(), proc2 = VTFrameProcessor()
if !analyzeOnly { try proc1.startSession(configuration: cfg1); try proc2.startSession(configuration: cfg2) }
let srcPool = makePool(cfg1.sourcePixelBufferAttributes), dstPool = makePool(cfg1.destinationPixelBufferAttributes)

var writer: AVAssetWriter?, win: AVAssetWriterInput?, adaptor: AVAssetWriterInputPixelBufferAdaptor?
if !analyzeOnly {
    try? FileManager.default.removeItem(at: outURL)
    let w = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
    let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
        AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 45_000_000, AVVideoExpectedSourceFrameRateKey: 60,
                                          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]])
    i.expectsMediaDataInRealTime = false
    let a = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: nil)
    w.add(i); guard w.startWriting() else { die("writer: \(String(describing: w.error))") }
    w.startSession(atSourceTime: .zero)
    writer = w; win = i; adaptor = a
}
func write(_ b: CVPixelBuffer, _ t: CMTime) {
    guard let win, let adaptor else { return }
    while !win.isReadyForMoreMediaData { usleep(1000) }
    if !adaptor.append(b, withPresentationTime: t) { die("append failed: \(String(describing: writer?.error))") }
}

var times: [Double] = []
var phaseFail = 0
func interpolate(_ prev: CVPixelBuffer, _ pt: CMTime, _ cur: CVPixelBuffer, _ ct: CMTime, _ phases: [Float], _ outTimes: [CMTime]) -> [CVPixelBuffer]? {
    let proc = phases == [0.5] ? proc1 : proc2
    guard let pf = VTFrameProcessorFrame(buffer: prev, presentationTimeStamp: pt),
          let cf = VTFrameProcessorFrame(buffer: cur, presentationTimeStamp: ct) else { die("frame wrap failed") }
    let outs = outTimes.map { _ in newBuf(dstPool) }
    let ofs = zip(outs, outTimes).map { VTFrameProcessorFrame(buffer: $0, presentationTimeStamp: $1)! }
    guard let p = VTLowLatencyFrameInterpolationParameters(sourceFrame: cf, previousFrame: pf, interpolationPhase: phases, destinationFrames: ofs) else { return nil }
    let sem = DispatchSemaphore(value: 0); var err: Error?
    let t0 = DispatchTime.now().uptimeNanoseconds
    proc.process(parameters: p, completionHandler: { _, e in err = e; sem.signal() })
    sem.wait()
    times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / Double(phases.count))
    if let err { if phaseFail == 0 { print("process error for phases \(phases): \(err)") }; phaseFail += 1; return nil }
    return outs
}

var diffs: [Double] = []
var gapCount: [Int: Int] = [:]
var lastReal: CVPixelBuffer?, lastRealT = CMTime.zero
var pending: [CMTime] = []     // timestamps of repeated frames since lastReal
var prevDecoded: CVPixelBuffer?
var nIn = 0, nGen = 0, nHeld = 0, nReal = 0
var realTimes: [Double] = []
let tStart = Date()

while let sb = rout.copyNextSampleBuffer() {
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
    let t = CMSampleBufferGetPresentationTimeStamp(sb)
    nIn += 1
    var isReal = true
    if let pd = prevDecoded { let d = lumaDiff(pd, pb); diffs.append(d); isReal = d >= threshold }
    prevDecoded = pb
    if analyzeOnly { if isReal { realTimes.append(t.seconds) }; continue }
    if !isReal && lastReal != nil { pending.append(t); continue }
    // New real frame: fill the repeats that came before it.
    let cur = copyBuf(pb, srcPool)
    realTimes.append(t.seconds); nReal += 1
    if let lr = lastReal, !pending.isEmpty {
        let g = pending.count + 1
        gapCount[g, default: 0] += 1
        var made: [CVPixelBuffer]? = nil
        if g <= 4 {
            let phases = (1..<g).map { Float($0) / Float(g) }
            made = interpolate(lr, lastRealT, cur, t, phases, pending)
        }
        if let made { for (b, pt) in zip(made, pending) { write(b, pt); nGen += 1 } }
        else { for pt in pending { write(lr, pt); nHeld += 1 } }
    } else if lastReal != nil { gapCount[1, default: 0] += 1 }
    pending.removeAll()
    write(cur, t)
    lastReal = cur; lastRealT = t
    if nIn % 600 == 0 { print("  \(nIn) frames...") }
}
if let lr = lastReal { for pt in pending { write(lr, pt); nHeld += 1 } }

if analyzeOnly {
    let edges: [Double] = [0, 0.1, 0.25, 0.5, 1, 1.5, 2, 3, 4, 5, 7.5, 10, 15, 255]
    for (a, b) in zip(edges, edges.dropFirst()) { print(String(format: "diff %5.2f-%6.2f: %d", a, b, diffs.filter { $0 >= a && $0 < b }.count)) }
    print("real frames at threshold \(threshold): \(realTimes.count) of \(nIn)")
    exit(0)
}
win!.markAsFinished()
let semW = DispatchSemaphore(value: 0)
writer!.finishWriting { semW.signal() }
semW.wait()
if writer!.status != .completed { die("writer finish: \(String(describing: writer!.error))") }

let dur = (realTimes.last ?? 0) - (realTimes.first ?? 0)
print("frames in: \(nIn)  real: \(nReal)  generated: \(nGen)  held (no interpolation): \(nHeld)")
print(String(format: "average real frame rate: %.1f fps over %.1f s", Double(nReal - 1) / dur, dur))
print("gaps between real frames (in 60 Hz slots): " + gapCount.keys.sorted().map { "\($0): \(gapCount[$0]!)" }.joined(separator: ", "))
// Per-second real frame rate
var perSec: [Int: Int] = [:]
for t in realTimes { perSec[Int(t), default: 0] += 1 }
let rates = perSec.keys.sorted().dropLast().map { perSec[$0]! }
print("real fps per second: min \(rates.min() ?? 0), max \(rates.max() ?? 0)")
print("per-second: " + rates.map(String.init).joined(separator: " "))
let s = times.sorted()
if !s.isEmpty { print(String(format: "interpolation time per generated frame: p50 %.1f ms, p95 %.1f ms, p99 %.1f ms, max %.1f ms (%d calls)", s[s.count / 2], s[Int(Double(s.count) * 0.95)], s[Int(Double(s.count) * 0.99)], s.last!, s.count)) }
if phaseFail > 0 { print("interpolation calls that failed and fell back to holding: \(phaseFail)") }
print(String(format: "wall time %.1f s", Date().timeIntervalSince(tStart)))
