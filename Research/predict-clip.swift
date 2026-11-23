// Offline test of frame PREDICTION (extrapolation) against real frames, next to the interpolation the app uses.
// For consecutive real frames A, B, C of a 30 fps game recorded at 60:
//   prediction : motion A->B (Apple optical flow) pushes B forward to guess C       -> compared with the real C
//   interpolation: Apple's interpolator makes the frame between A and C             -> compared with the real B
//   no generation: B shown again                                                    -> compared with the real C
// Also writes two 60 fps videos with identical timing: <prefix>-interp.mp4 and <prefix>-predict.mp4.
// Usage: predict-clip <input.mp4> <output prefix> [--calibrate] [--max N] [--dump i,j,k] [--quality] [--flow fwd|bwd] [--sign 1|-1] [--iters n] [--novideo]
import Foundation
import AVFoundation
import VideoToolbox
import CoreVideo
import CoreImage
import Metal
setvbuf(stdout, nil, _IONBF, 0)

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: predict-clip in prefix [--calibrate] [--max N] [--dump i,j] [--quality]"); exit(2) }
func opt(_ n: String) -> String? { if let i = args.firstIndex(of: n), i + 1 < args.count { return args[i + 1] }; return nil }
let calibrate = args.contains("--calibrate"), useQuality = args.contains("--quality"), noVideo = args.contains("--novideo") || calibrate
let maxReal = Int(opt("--max") ?? "") ?? Int.max
let dumpSet = Set((opt("--dump") ?? "").split(separator: ",").compactMap { Int($0) })
var useFwd = (opt("--flow") ?? "bwd") == "fwd"
// Normal-quality flow reports motion in units of 8 pixels; quality mode reports pixels (measured with a known shift).
var flowSign = (Float(opt("--sign") ?? "1") ?? 1) * (useQuality ? 1 : 8)
let iters = Int32(opt("--iters") ?? "3") ?? 3
let prefix = args[2]
func die(_ s: String) -> Never { print("ERROR: \(s)"); exit(1) }

// ---------- input
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let sem0 = DispatchSemaphore(value: 0)
var trackOpt: AVAssetTrack?; var sz = CGSize.zero
Task { trackOpt = try? await asset.loadTracks(withMediaType: .video).first
       if let t = trackOpt { sz = (try? await t.load(.naturalSize)) ?? .zero }; sem0.signal() }
sem0.wait()
guard let track = trackOpt else { die("no video track") }
let W = Int(sz.width), H = Int(sz.height)
let reader = try AVAssetReader(asset: asset)
let rout = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
rout.alwaysCopiesSampleData = false
reader.add(rout)
guard reader.startReading() else { die("reader: \(String(describing: reader.error))") }

// ---------- buffers
func makePool(_ attrs: [String: Any], fmt: OSType? = nil) -> CVPixelBufferPool {
    var a = attrs
    a[kCVPixelBufferWidthKey as String] = W; a[kCVPixelBufferHeightKey as String] = H
    if let fmt { a[kCVPixelBufferPixelFormatTypeKey as String] = fmt }
    else if let l = a[kCVPixelBufferPixelFormatTypeKey as String] as? [Any], let f = l.first { a[kCVPixelBufferPixelFormatTypeKey as String] = f }
    a[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
    a[kCVPixelBufferMetalCompatibilityKey as String] = true
    var p: CVPixelBufferPool?; CVPixelBufferPoolCreate(nil, nil, a as CFDictionary, &p); return p!
}
func newBuf(_ pool: CVPixelBufferPool) -> CVPixelBuffer { var b: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, pool, &b); return b! }
func tag709(_ b: CVPixelBuffer) {
    CVBufferSetAttachment(b, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(b, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(b, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
}
func copyYUV(_ src: CVPixelBuffer, _ pool: CVPixelBufferPool) -> CVPixelBuffer {
    let dst = newBuf(pool)
    CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst, [])
    for p in 0..<2 {
        let s = CVPixelBufferGetBaseAddressOfPlane(src, p)!, d = CVPixelBufferGetBaseAddressOfPlane(dst, p)!
        let ss = CVPixelBufferGetBytesPerRowOfPlane(src, p), ds = CVPixelBufferGetBytesPerRowOfPlane(dst, p)
        let h = CVPixelBufferGetHeightOfPlane(src, p), n = min(ss, ds)
        for y in 0..<h { memcpy(d + y * ds, s + y * ss, n) }
    }
    CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(dst, [])
    tag709(dst); return dst
}
// Luma comparisons. step 4 for the cheap repeat check, step 2 for scoring.
func lumaStats(_ a: CVPixelBuffer, _ b: CVPixelBuffer, step: Int) -> (mad: Double, psnr: Double) {
    CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0)!.assumingMemoryBound(to: UInt8.self)
    let pb = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
    let sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0), sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
    var sum = 0, sq = 0, n = 0, y = 0
    while y < H { var x = 0
        while x < W { let d = Int(pa[y * sa + x]) - Int(pb[y * sb + x]); sum += abs(d); sq += d * d; n += 1; x += step }
        y += step }
    let mse = Double(sq) / Double(n)
    return (Double(sum) / Double(n), mse < 1e-6 ? 99 : 10 * log10(255 * 255 / mse))
}

// ---------- Apple interpolator (what the live app uses today)
guard let icfg = VTLowLatencyFrameInterpolationConfiguration(frameWidth: W, frameHeight: H, numberOfInterpolatedFrames: 1) else { die("interpolator config") }
let iproc = VTFrameProcessor(); try iproc.startSession(configuration: icfg)
let yuvPool = makePool(icfg.sourcePixelBufferAttributes, fmt: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
var interpMs: [Double] = []
func interpolate(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> CVPixelBuffer? {
    let af = VTFrameProcessorFrame(buffer: a, presentationTimeStamp: CMTime(value: 0, timescale: 60))!
    let bf = VTFrameProcessorFrame(buffer: b, presentationTimeStamp: CMTime(value: 2, timescale: 60))!
    let o = newBuf(yuvPool)
    let of = VTFrameProcessorFrame(buffer: o, presentationTimeStamp: CMTime(value: 1, timescale: 60))!
    guard let p = VTLowLatencyFrameInterpolationParameters(sourceFrame: bf, previousFrame: af, interpolationPhase: [0.5], destinationFrames: [of]) else { return nil }
    let sem = DispatchSemaphore(value: 0); var err: Error?
    let t0 = DispatchTime.now().uptimeNanoseconds
    iproc.process(parameters: p, completionHandler: { _, e in err = e; sem.signal() }); sem.wait()
    interpMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    if err != nil { return nil }
    tag709(o); return o
}

// ---------- Apple optical flow
guard let fcfg = VTOpticalFlowConfiguration(frameWidth: W, frameHeight: H, qualityPrioritization: useQuality ? .quality : .normal,
                                            revision: VTOpticalFlowConfiguration.defaultRevision) else { die("optical flow config") }
let fproc = VTFrameProcessor(); try fproc.startSession(configuration: fcfg)
let rgbPool = makePool(fcfg.sourcePixelBufferAttributes), flowPool = makePool(fcfg.destinationPixelBufferAttributes)
var xfer: VTPixelTransferSession?; VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &xfer)
var xferWarned = false
func toFlowInput(_ yuv: CVPixelBuffer) -> CVPixelBuffer {
    let o = newBuf(rgbPool); let r = VTPixelTransferSessionTransferImage(xfer!, from: yuv, to: o)
    if r != 0, !xferWarned { print("pixel transfer to flow input failed: \(r)"); xferWarned = true }
    return o
}
var recon: [String: Double] = [:]
var flowMs: [Double] = []
func flow(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> (fwd: CVPixelBuffer, bwd: CVPixelBuffer)? {
    let af = VTFrameProcessorFrame(buffer: a, presentationTimeStamp: CMTime(value: 0, timescale: 60))!
    let bf = VTFrameProcessorFrame(buffer: b, presentationTimeStamp: CMTime(value: 2, timescale: 60))!
    let f = newBuf(flowPool), bk = newBuf(flowPool)
    guard let of = VTFrameProcessorOpticalFlow(forwardFlow: f, backwardFlow: bk),
          let p = VTOpticalFlowParameters(sourceFrame: af, nextFrame: bf, submissionMode: .random, destinationOpticalFlow: of) else { return nil }
    let sem = DispatchSemaphore(value: 0); var err: Error?
    let t0 = DispatchTime.now().uptimeNanoseconds
    fproc.process(parameters: p, completionHandler: { _, e in err = e; sem.signal() }); sem.wait()
    flowMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    if let err { print("flow error: \(err)"); return nil }
    return (f, bk)
}

// ---------- warp on the GPU: each output pixel looks up where it came from in B and copies that
let dev = MTLCreateSystemDefaultDevice()!, queue = dev.makeCommandQueue()!
var cache: CVMetalTextureCache?; CVMetalTextureCacheCreate(nil, nil, dev, nil, &cache)
let shader = """
#include <metal_stdlib>
using namespace metal;
struct P { float t; float sx; float sy; int iters; };
kernel void warp(texture2d<float, access::sample> y, texture2d<float, access::sample> c, texture2d<float, access::sample> flow,
                 texture2d<float, access::write> oy, texture2d<float, access::write> oc,
                 constant P &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    if (gid.x >= oy.get_width() || gid.y >= oy.get_height()) return;
    float2 size = float2(oy.get_width(), oy.get_height());
    float2 sc = float2(p.sx, p.sy);
    float2 uv = (float2(gid) + 0.5) / size, src = uv;
    for (int i = 0; i < p.iters; i++) src = uv + p.t * flow.sample(s, src).xy * sc;
    oy.write(y.sample(s, src), gid);
    if ((gid.x & 1) == 0 && (gid.y & 1) == 0) {
        float2 cuv = (float2(gid) + 1.0) / size, cs = cuv;
        for (int i = 0; i < p.iters; i++) cs = cuv + p.t * flow.sample(s, cs).xy * sc;
        oc.write(c.sample(s, cs), gid / 2);
    }
}
"""
let pipe = try dev.makeComputePipelineState(function: try dev.makeLibrary(source: shader, options: nil).makeFunction(name: "warp")!)
struct WarpP { var t: Float; var sx: Float; var sy: Float; var iters: Int32 }
func tex(_ b: CVPixelBuffer, _ plane: Int, _ fmt: MTLPixelFormat) -> (MTLTexture, CVMetalTexture) {
    let planar = CVPixelBufferIsPlanar(b)
    let w = planar ? CVPixelBufferGetWidthOfPlane(b, plane) : CVPixelBufferGetWidth(b)
    let h = planar ? CVPixelBufferGetHeightOfPlane(b, plane) : CVPixelBufferGetHeight(b)
    var t: CVMetalTexture?
    CVMetalTextureCacheCreateTextureFromImage(nil, cache!, b, nil, fmt, w, h, plane, &t)
    guard let t, let m = CVMetalTextureGetTexture(t) else { die("texture for plane \(plane) fmt \(fmt.rawValue)") }
    return (m, t)
}
var warpMs: [Double] = []
let flowYMul = Float(ProcessInfo.processInfo.environment["FLOWY"] ?? "1") ?? 1, flowXMul = Float(ProcessInfo.processInfo.environment["FLOWX"] ?? "1") ?? 1
var unitsNormalized = false      // set by calibration: whether flow is in pixels or in fractions of the frame
func warp(_ b: CVPixelBuffer, _ fl: CVPixelBuffer, t: Float, normalized: Bool? = nil) -> CVPixelBuffer {
    let o = newBuf(yuvPool)
    let (y, k1) = tex(b, 0, .r8Unorm), (c, k2) = tex(b, 1, .rg8Unorm), (f, k3) = tex(fl, 0, .rg16Float)
    let (oy, k4) = tex(o, 0, .r8Unorm), (oc, k5) = tex(o, 1, .rg8Unorm)
    let norm = normalized ?? unitsNormalized
    var p = WarpP(t: t, sx: (norm ? 1 : 1 / Float(W)) * flowXMul, sy: (norm ? 1 : 1 / Float(H)) * flowYMul, iters: iters)
    let cb = queue.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
    e.setComputePipelineState(pipe)
    e.setTexture(y, index: 0); e.setTexture(c, index: 1); e.setTexture(f, index: 2); e.setTexture(oy, index: 3); e.setTexture(oc, index: 4)
    e.setBytes(&p, length: MemoryLayout<WarpP>.stride, index: 0)
    e.dispatchThreadgroups(MTLSize(width: (W + 15) / 16, height: (H + 15) / 16, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    warpMs.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
    _ = (k1, k2, k3, k4, k5)
    tag709(o); return o
}

// ---------- output
final class Out {
    let w: AVAssetWriter, i: AVAssetWriterInput, a: AVAssetWriterInputPixelBufferAdaptor; var n: Int64 = 0
    init(_ path: String) {
        let u = URL(fileURLWithPath: path); try? FileManager.default.removeItem(at: u)
        w = try! AVAssetWriter(outputURL: u, fileType: .mp4)
        i = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 45_000_000, AVVideoExpectedSourceFrameRateKey: 60,
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]])
        i.expectsMediaDataInRealTime = false
        a = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: nil)
        w.add(i); guard w.startWriting() else { die("writer: \(String(describing: w.error))") }
        w.startSession(atSourceTime: .zero)
    }
    func add(_ b: CVPixelBuffer) {
        while !i.isReadyForMoreMediaData { usleep(1000) }
        if !a.append(b, withPresentationTime: CMTime(value: n, timescale: 60)) { die("append: \(String(describing: w.error))") }
        n += 1
    }
    func finish() { i.markAsFinished(); let s = DispatchSemaphore(value: 0); w.finishWriting { s.signal() }; s.wait() }
}
let outI = noVideo ? nil : Out(prefix + "-interp.mp4"), outP = noVideo ? nil : Out(prefix + "-predict.mp4")
let ci = CIContext()
func png(_ b: CVPixelBuffer, _ name: String) {
    try? ci.writePNGRepresentation(of: CIImage(cvPixelBuffer: b), to: URL(fileURLWithPath: "\(prefix)-\(name).png"), format: .RGBA8,
                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
}
FileManager.default.createFile(atPath: prefix + "-scores.csv", contents: nil)
let csv = FileHandle(forWritingAtPath: prefix + "-scores.csv")!
csv.write("triple,slot,motion,predict_vs_real,repeat_vs_real,interp_vs_real,predhalf_vs_interp\n".data(using: .utf8)!)

// ---------- main loop
struct Real { let yuv: CVPixelBuffer; let rgb: CVPixelBuffer; let slot: Int }
var win: [Real] = []
var prevDecoded: CVPixelBuffer?
var slot = 0, nReal = 0, triple = 0
var scores: [(motion: Double, pred: Double, rep: Double, interp: Double, half: Double)] = []
struct Cand { let name: String; let fwd: Bool; let sign: Float; let norm: Bool; var sum = 0.0; var n = 0 }
var repSum = 0.0
var cands: [Cand] = []
for fwd in [false, true] { for sign in [Float(-8), -4, -2, -1, -0.5, -0.25, 0.25, 0.5, 1, 2, 4, 8] {
    cands.append(Cand(name: "\(fwd ? "forward " : "backward") flow x \(sign)", fwd: fwd, sign: sign, norm: false)) } }

func process(_ A: Real, _ B: Real, _ C: Real) {
    let gapAB = B.slot - A.slot, gapBC = C.slot - B.slot
    guard let fl = flow(A.rgb, B.rgb) else { return }
    if calibrate {
        guard gapAB == 2, gapBC == 2 else { return }
        if triple == 0 {
            CVPixelBufferLockBaseAddress(fl.fwd, .readOnly)
            let p = CVPixelBufferGetBaseAddress(fl.fwd)!.assumingMemoryBound(to: Float16.self), st = CVPixelBufferGetBytesPerRow(fl.fwd) / 2
            var xs: [Double] = []
            var sx = 0.0, sy = 0.0, mx = 0.0, n = 0.0
            for y in stride(from: 0, to: CVPixelBufferGetHeight(fl.fwd), by: 8) { for x in stride(from: 0, to: CVPixelBufferGetWidth(fl.fwd), by: 8) {
                let u = Double(p[y * st + x * 2]), v = Double(p[y * st + x * 2 + 1]); sx += abs(u); sy += abs(v); xs.append(u); mx = max(mx, abs(u), abs(v)); n += 1 } }
            CVPixelBufferUnlockBaseAddress(fl.fwd, .readOnly)
            xs.sort(); print("forward flow x percentiles 1/10/50/90/99:", [0.01, 0.1, 0.5, 0.9, 0.99].map { String(format: "%.2f", xs[Int(Double(xs.count) * $0)]) })
            print(String(format: "flow buffer %dx%d, mean |x| %.3f  mean |y| %.3f  max %.2f", CVPixelBufferGetWidth(fl.fwd), CVPixelBufferGetHeight(fl.fwd), sx / n, sy / n, mx))
        }
        for i in cands.indices {
            let o = warp(B.yuv, cands[i].fwd ? fl.fwd : fl.bwd, t: cands[i].sign, normalized: cands[i].norm)
            cands[i].sum += lumaStats(o, C.yuv, step: 2).psnr; cands[i].n += 1
        }
        repSum += lumaStats(B.yuv, C.yuv, step: 2).psnr
        // Direct check of the flow itself: rebuild B out of A, and A out of B.
        recon["A vs B, untouched", default: 0] += lumaStats(A.yuv, B.yuv, step: 2).psnr
        for k in [Float(0.5), 1, 1.5, 2] {
            recon["B rebuilt from A with backward flow x \(k)", default: 0] += lumaStats(warp(A.yuv, fl.bwd, t: k, normalized: false), B.yuv, step: 2).psnr
            recon["A rebuilt from B with forward flow x \(k)", default: 0] += lumaStats(warp(B.yuv, fl.fwd, t: k, normalized: false), A.yuv, step: 2).psnr
        }
        if triple == 5 { png(A.yuv, "cal-A"); png(B.yuv, "cal-B"); png(C.yuv, "cal-C"); png(warp(A.yuv, fl.bwd, t: 1, normalized: false), "cal-B-from-A") }
        triple += 1; return
    }
    let fb = useFwd ? fl.fwd : fl.bwd
    let mid = gapBC == 2 ? interpolate(B.yuv, C.yuv) : nil
    let half = warp(B.yuv, fb, t: flowSign / Float(gapAB))
    if gapAB == 2, gapBC == 2 {
        let full = warp(B.yuv, fb, t: flowSign)
        let pr = lumaStats(full, C.yuv, step: 2).psnr
        let rs = lumaStats(B.yuv, C.yuv, step: 2)
        let ip = interpolate(A.yuv, C.yuv).map { lumaStats($0, B.yuv, step: 2).psnr } ?? 0
        let hf = mid.map { lumaStats(half, $0, step: 2).psnr } ?? 0
        scores.append((rs.mad, pr, rs.psnr, ip, hf))
        csv.write(String(format: "%d,%d,%.2f,%.2f,%.2f,%.2f,%.2f\n", triple, B.slot, rs.mad, pr, rs.psnr, ip, hf).data(using: .utf8)!)
        if dumpSet.contains(triple) {
            png(C.yuv, "t\(triple)-1-real-next"); png(full, "t\(triple)-2-predicted-next"); png(B.yuv, "t\(triple)-3-current")
            png(half, "t\(triple)-4-predicted-half"); if let mid { png(mid, "t\(triple)-5-interpolated-half") }
        }
    }
    // Both videos: B, then one frame per empty slot before C.
    outI?.add(B.yuv); outP?.add(B.yuv)
    for s in 1..<max(1, gapBC) {
        outI?.add(s == 1 && mid != nil ? mid! : B.yuv)
        outP?.add(gapBC <= 4 ? (s == 1 ? half : warp(B.yuv, fb, t: flowSign * Float(s) / Float(gapAB))) : B.yuv)
    }
    triple += 1
}

// Known-answer test: shift a real frame by a set number of pixels and see what the flow reports.
func shifted(_ src: CVPixelBuffer, _ dx: Int, _ dy: Int) -> CVPixelBuffer {
    let dst = newBuf(yuvPool)
    CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst, [])
    for p in 0..<2 {
        let s = CVPixelBufferGetBaseAddressOfPlane(src, p)!.assumingMemoryBound(to: UInt8.self), d = CVPixelBufferGetBaseAddressOfPlane(dst, p)!.assumingMemoryBound(to: UInt8.self)
        let ss = CVPixelBufferGetBytesPerRowOfPlane(src, p), ds = CVPixelBufferGetBytesPerRowOfPlane(dst, p)
        let h = CVPixelBufferGetHeightOfPlane(src, p), w = CVPixelBufferGetWidthOfPlane(src, p), bpp = p == 0 ? 1 : 2
        let sx = p == 0 ? dx : dx / 2, sy = p == 0 ? dy : dy / 2
        for y in 0..<h { let yy = min(h - 1, max(0, y - sy))
            for x in 0..<w { let xx = min(w - 1, max(0, x - sx)); for k in 0..<bpp { d[y * ds + x * bpp + k] = s[yy * ss + xx * bpp + k] } } }
    }
    CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(dst, [])
    tag709(dst); return dst
}
func flowPct(_ b: CVPixelBuffer, _ ch: Int) -> String {
    CVPixelBufferLockBaseAddress(b, .readOnly); defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    let p = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: Float16.self), st = CVPixelBufferGetBytesPerRow(b) / 2
    var v: [Double] = []
    for y in stride(from: 0, to: CVPixelBufferGetHeight(b), by: 8) { for x in stride(from: 0, to: CVPixelBufferGetWidth(b), by: 8) { v.append(Double(p[y * st + x * 2 + ch])) } }
    v.sort(); return [0.05, 0.5, 0.95].map { String(format: "%.1f", v[Int(Double(v.count) * $0)]) }.joined(separator: "/")
}
if let sh = opt("--synthetic") {
    var first: CVPixelBuffer?; var k = 0
    while let sb = rout.copyNextSampleBuffer() { k += 1; if k == 200, let pb = CMSampleBufferGetImageBuffer(sb) { first = copyYUV(pb, yuvPool); break } }
    let a = first!
    for d in sh.split(separator: ",").compactMap({ Int($0) }) {
        let b = shifted(a, d, d / 4)
        guard let fl = flow(toFlowInput(a), toFlowInput(b)) else { continue }
        print(String(format: "content moved right %d px, down %d px: forward flow x %@  y %@ | backward flow x %@  y %@ | rebuild B from A %.1f dB (untouched %.1f)",
                     d, d / 4, flowPct(fl.fwd, 0), flowPct(fl.fwd, 1), flowPct(fl.bwd, 0), flowPct(fl.bwd, 1),
                     lumaStats(warp(a, fl.bwd, t: 1, normalized: false), b, step: 2).psnr, lumaStats(a, b, step: 2).psnr))
    }
    exit(0)
}
let tStart = Date()
while let sb = rout.copyNextSampleBuffer(), nReal < maxReal {
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
    var isReal = true
    if let pd = prevDecoded { isReal = lumaStats(pd, pb, step: 4).mad >= 3.0 }
    prevDecoded = pb
    if isReal {
        let y = copyYUV(pb, yuvPool)
        win.append(Real(yuv: y, rgb: toFlowInput(y), slot: slot)); nReal += 1
        if win.count == 3 { process(win[0], win[1], win[2]); win.removeFirst() }
        if calibrate, triple >= 40 { break }
        if nReal % 200 == 0 { print("  \(nReal) real frames, \(Int(Date().timeIntervalSince(tStart))) s") }
    }
    slot += 1
}
outI?.finish(); outP?.finish(); csv.closeFile()

func med(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
func pct(_ v: [Double], _ f: Double) -> Double { v.isEmpty ? 0 : v.sorted()[min(v.count - 1, Int(Double(v.count) * f))] }
if calibrate {
    for (k, v) in recon.sorted(by: { $0.value > $1.value }) { print(String(format: "  %.2f dB  %@", v / Double(max(1, cands[0].n)), k)) }
    print("which way round the flow is (higher is better, guess of next real frame, \(cands[0].n) frame triples):")
    print(String(format: "  %.2f dB  no warp (current frame repeated)", repSum / Double(max(1, cands[0].n))))
    for c in cands.sorted(by: { $0.sum > $1.sum }) { print(String(format: "  %.2f dB  %@", c.sum / Double(max(1, c.n)), c.name)) }
} else {
    print("\(scores.count) scored frame triples (clean 30 fps cadence) of \(triple)")
    print(String(format: "timings: flow p50 %.1f ms  warp p50 %.2f ms  interpolator p50 %.1f ms", med(flowMs), med(warpMs), med(interpMs)))
    let byMotion = scores.sorted { $0.motion < $1.motion }
    let n = byMotion.count
    func row(_ name: String, _ s: ArraySlice<(motion: Double, pred: Double, rep: Double, interp: Double, half: Double)>) {
        print(String(format: "%@ n=%4d  motion %.1f | predict %.1f dB (worst 5%% %.1f) | interpolate %.1f dB (worst 5%% %.1f) | repeat %.1f dB | half-step predict vs interpolated %.1f dB",
                     name, s.count, med(s.map { $0.motion }), med(s.map { $0.pred }), pct(s.map { $0.pred }, 0.05), med(s.map { $0.interp }), pct(s.map { $0.interp }, 0.05),
                     med(s.map { $0.rep }), med(s.map { $0.half })))
    }
    if n >= 3 {
        row("all          ", byMotion[0..<n]); row("slow third   ", byMotion[0..<(n / 3)])
        row("middle third ", byMotion[(n / 3)..<(2 * n / 3)]); row("fast third   ", byMotion[(2 * n / 3)..<n])
    }
}
