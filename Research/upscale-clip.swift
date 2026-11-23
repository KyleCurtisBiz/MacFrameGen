// Upscales a video with Apple's MetalFX spatial scaler (the fast upscaler a live version would use).
// Usage: upscale-clip <input.mp4> <output.mp4> <outWidth> <outHeight>
import Foundation
import AVFoundation
import Metal
import MetalFX
import CoreVideo

setvbuf(stdout, nil, _IONBF, 0)
func die(_ s: String) -> Never { print("ERROR: \(s)"); exit(1) }
let a = CommandLine.arguments
guard a.count == 5, let OW = Int(a[3]), let OH = Int(a[4]) else { die("usage: upscale-clip in out w h") }
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1])), outURL = URL(fileURLWithPath: a[2])
var trackOpt: AVAssetTrack?, sz = CGSize.zero
let s0 = DispatchSemaphore(value: 0)
Task { trackOpt = try? await asset.loadTracks(withMediaType: .video).first
       if let t = trackOpt { sz = (try? await t.load(.naturalSize)) ?? .zero }; s0.signal() }
s0.wait()
guard let track = trackOpt else { die("no video track") }
let W = Int(sz.width), H = Int(sz.height)
print("input \(W)x\(H) -> output \(OW)x\(OH)")

let reader = try AVAssetReader(asset: asset)
let rout = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferMetalCompatibilityKey as String: true,
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
reader.add(rout)
guard reader.startReading() else { die("reader: \(String(describing: reader.error))") }

guard let dev = MTLCreateSystemDefaultDevice(), let queue = dev.makeCommandQueue() else { die("no Metal device") }
let desc = MTLFXSpatialScalerDescriptor()
desc.inputWidth = W; desc.inputHeight = H; desc.outputWidth = OW; desc.outputHeight = OH
desc.colorTextureFormat = .bgra8Unorm; desc.outputTextureFormat = .bgra8Unorm
desc.colorProcessingMode = .perceptual
guard let scaler = desc.makeSpatialScaler(device: dev) else { die("scaler creation failed") }
var cacheOpt: CVMetalTextureCache?
CVMetalTextureCacheCreate(nil, nil, dev, nil, &cacheOpt)
let cache = cacheOpt!
func tex(_ pb: CVPixelBuffer, _ usage: MTLTextureUsage) -> (CVMetalTexture, MTLTexture) {
    var t: CVMetalTexture?
    let attrs = [kCVMetalTextureUsage as String: usage.rawValue] as CFDictionary
    CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, attrs, .bgra8Unorm, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &t)
    guard let t, let m = CVMetalTextureGetTexture(t) else { die("texture creation failed") }
    return (t, m)
}
var poolOpt: CVPixelBufferPool?
CVPixelBufferPoolCreate(nil, nil, [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: OW, kCVPixelBufferHeightKey as String: OH,
    kCVPixelBufferMetalCompatibilityKey as String: true,
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &poolOpt)
let pool = poolOpt!

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

var gpu: [Double] = [], wall: [Double] = [], n = 0
let t0 = Date()
while let sb = rout.copyNextSampleBuffer() {
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
    var ob: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, pool, &ob)
    guard let ob else { die("no output buffer") }
    let (keepIn, tin) = tex(pb, scaler.colorTextureUsage), (keepOut, tout) = tex(ob, scaler.outputTextureUsage)
    scaler.colorTexture = tin; scaler.outputTexture = tout
    scaler.inputContentWidth = W; scaler.inputContentHeight = H
    guard let cb = queue.makeCommandBuffer() else { die("no command buffer") }
    let w0 = DispatchTime.now().uptimeNanoseconds
    scaler.encode(commandBuffer: cb); cb.commit(); cb.waitUntilCompleted()
    wall.append(Double(DispatchTime.now().uptimeNanoseconds - w0) / 1e6)
    if let e = cb.error { die("GPU error: \(e)") }
    gpu.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
    _ = keepIn; _ = keepOut
    while !win.isReadyForMoreMediaData { usleep(1000) }
    if !adaptor.append(ob, withPresentationTime: pts) { die("append failed: \(String(describing: writer.error))") }
    n += 1
}
win.markAsFinished()
let s1 = DispatchSemaphore(value: 0); writer.finishWriting { s1.signal() }; s1.wait()
if writer.status != .completed { die("writer finish: \(String(describing: writer.error))") }
func pct(_ v: [Double], _ p: Double) -> Double { let s = v.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))] }
print("frames: \(n)")
print(String(format: "GPU time per frame: p50 %.2f ms, p95 %.2f ms, p99 %.2f ms", pct(gpu, 0.5), pct(gpu, 0.95), pct(gpu, 0.99)))
print(String(format: "submit-to-done per frame: p50 %.2f ms, p95 %.2f ms, p99 %.2f ms", pct(wall, 0.5), pct(wall, 0.95), pct(wall, 0.99)))
print(String(format: "wall time %.1f s", Date().timeIntervalSince(t0)))
