// Offline test of Apple's machine-learning video upscaler (VTSuperResolutionScaler, 4x only).
// Upscales each frame 4x, then shrinks the result to the requested size before saving.
// Usage: superres-clip <input.mp4> <output.mp4> <outWidth> <outHeight> [maxFrames]
import Foundation
import AVFoundation
import VideoToolbox
import CoreVideo

setvbuf(stdout, nil, _IONBF, 0)
func die(_ s: String) -> Never { print("ERROR: \(s)"); exit(1) }
let a = CommandLine.arguments
guard a.count >= 5, let OW = Int(a[3]), let OH = Int(a[4]) else { die("usage: superres-clip in out w h [maxFrames]") }
let maxFrames = a.count > 5 ? Int(a[5]) ?? Int.max : Int.max
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1])), outURL = URL(fileURLWithPath: a[2])
var trackOpt: AVAssetTrack?, sz = CGSize.zero
let s0 = DispatchSemaphore(value: 0)
Task { trackOpt = try? await asset.loadTracks(withMediaType: .video).first
       if let t = trackOpt { sz = (try? await t.load(.naturalSize)) ?? .zero }; s0.signal() }
s0.wait()
guard let track = trackOpt else { die("no video track") }
let W = Int(sz.width), H = Int(sz.height)

guard VTSuperResolutionScalerConfiguration.isSupported else { die("super resolution unsupported") }
guard let cfg = VTSuperResolutionScalerConfiguration(frameWidth: W, frameHeight: H, scaleFactor: 4, inputType: .video,
        usePrecomputedFlow: false, qualityPrioritization: .normal, revision: VTSuperResolutionScalerConfiguration.defaultRevision)
else { die("config failed") }
if cfg.configurationModelStatus != .ready {
    print("model not on this Mac yet; asking the system to download it...")
    let sd = DispatchSemaphore(value: 0); var derr: Error?
    cfg.downloadConfigurationModel { e in derr = e; sd.signal() }
    var last = -1
    while sd.wait(timeout: .now() + 2) == .timedOut {
        let p = Int(cfg.configurationModelPercentageAvailable * 100)
        if p != last { print("  download \(p)%"); last = p }
    }
    if let derr { die("model download failed: \(derr)") }
    print("model status now: \(cfg.configurationModelStatus.rawValue) (2 = ready)")
}
let srcAttrs = cfg.sourcePixelBufferAttributes, dstAttrs = cfg.destinationPixelBufferAttributes
func fmt(_ d: [String: Any]) -> String {
    guard let v = d[kCVPixelBufferPixelFormatTypeKey as String] else { return "unspecified" }
    let list = (v as? [NSNumber]) ?? [(v as! NSNumber)]
    return list.map { n in let x = n.uint32Value; return String(bytes: [UInt8(x >> 24), UInt8((x >> 16) & 255), UInt8((x >> 8) & 255), UInt8(x & 255)], encoding: .ascii) ?? "\(x)" }.joined(separator: ",")
}
print("input \(W)x\(H); source formats: \(fmt(srcAttrs)); destination formats: \(fmt(dstAttrs)); dst size \(dstAttrs[kCVPixelBufferWidthKey as String] ?? "?")x\(dstAttrs[kCVPixelBufferHeightKey as String] ?? "?")")

func firstFormat(_ d: [String: Any]) -> OSType {
    guard let v = d[kCVPixelBufferPixelFormatTypeKey as String] else { return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange }
    if let l = v as? [NSNumber] { return l.contains(NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)) ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : l[0].uint32Value }
    return (v as! NSNumber).uint32Value
}
let srcFmt = firstFormat(srcAttrs), dstFmt = firstFormat(dstAttrs)
func makePool(_ attrs: [String: Any], _ f: OSType, _ w: Int, _ h: Int) -> CVPixelBufferPool {
    var d = attrs
    d[kCVPixelBufferPixelFormatTypeKey as String] = f
    d[kCVPixelBufferWidthKey as String] = w; d[kCVPixelBufferHeightKey as String] = h
    if d[kCVPixelBufferIOSurfacePropertiesKey as String] == nil { d[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]() }
    var p: CVPixelBufferPool?; CVPixelBufferPoolCreate(nil, nil, d as CFDictionary, &p); return p!
}
func newBuf(_ p: CVPixelBufferPool) -> CVPixelBuffer { var b: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, p, &b); guard let b else { die("buffer alloc failed") }; return b }
let srcPool = makePool(srcAttrs, srcFmt, W, H), bigPool = makePool(dstAttrs, dstFmt, W * 4, H * 4)
let outPool = makePool([:], kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, OW, OH)

let reader = try AVAssetReader(asset: asset)
let rout = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: srcFmt, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
reader.add(rout)
guard reader.startReading() else { die("reader: \(String(describing: reader.error))") }

var xferOpt: VTPixelTransferSession?
VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &xferOpt)
let xfer = xferOpt!
VTSessionSetProperty(xfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)

let proc = VTFrameProcessor()
try proc.startSession(configuration: cfg)

try? FileManager.default.removeItem(at: outURL)
let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
let win = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: OW, AVVideoHeightKey: OH,
    AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 70_000_000, AVVideoExpectedSourceFrameRateKey: 60]])
win.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: win, sourcePixelBufferAttributes: nil)
writer.add(win)
guard writer.startWriting() else { die("writer: \(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)

func copyInto(_ src: CVPixelBuffer, _ pool: CVPixelBufferPool) -> CVPixelBuffer {
    let dst = newBuf(pool)
    let st = VTPixelTransferSessionTransferImage(xfer, from: src, to: dst)
    if st != 0 { die("pixel transfer failed \(st)") }
    return dst
}

var prevSrc: VTFrameProcessorFrame?, prevOut: VTFrameProcessorFrame?
var times: [Double] = [], n = 0
let t0 = Date()
while n < maxFrames, let sb = rout.copyNextSampleBuffer() {
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
    let src = copyInto(pb, srcPool), big = newBuf(bigPool)
    guard let sf = VTFrameProcessorFrame(buffer: src, presentationTimeStamp: pts),
          let df = VTFrameProcessorFrame(buffer: big, presentationTimeStamp: pts) else { die("frame wrap failed") }
    guard let p = VTSuperResolutionScalerParameters(sourceFrame: sf, previousFrame: prevSrc, previousOutputFrame: prevOut,
            opticalFlow: nil, submissionMode: n == 0 ? .random : .sequential, destinationFrame: df) else { die("parameters failed") }
    let sem = DispatchSemaphore(value: 0); var err: Error?
    let w0 = DispatchTime.now().uptimeNanoseconds
    proc.process(parameters: p, completionHandler: { _, e in err = e; sem.signal() })
    sem.wait()
    times.append(Double(DispatchTime.now().uptimeNanoseconds - w0) / 1e6)
    if let err { die("process failed at frame \(n): \(err)") }
    prevSrc = sf; prevOut = df
    let small = copyInto(big, outPool)
    while !win.isReadyForMoreMediaData { usleep(1000) }
    if !adaptor.append(small, withPresentationTime: pts) { die("append failed: \(String(describing: writer.error))") }
    n += 1
    if n % 200 == 0 { print(String(format: "  %d frames, %.1f s elapsed", n, Date().timeIntervalSince(t0))) }
}
reader.cancelReading()
win.markAsFinished()
let s1 = DispatchSemaphore(value: 0); writer.finishWriting { s1.signal() }; s1.wait()
if writer.status != .completed { die("writer finish: \(String(describing: writer.error))") }
let s = times.sorted()
print("frames: \(n)")
if !s.isEmpty { print(String(format: "upscale time per frame: p50 %.1f ms, p95 %.1f ms, max %.1f ms", s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.95))], s.last!)) }
print(String(format: "wall time %.1f s", Date().timeIntervalSince(t0)))
