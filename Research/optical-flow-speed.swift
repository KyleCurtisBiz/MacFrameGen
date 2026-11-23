// How fast Apple's optical flow runs (VideoToolbox and Vision) at several sizes. Caller spins between calls, like turbo.
import Foundation
import VideoToolbox
import CoreVideo
import Vision
setvbuf(stdout, nil, _IONBF, 0)
func pool(_ attrs: [String: Any], _ w: Int, _ h: Int, fmt: OSType? = nil) -> CVPixelBufferPool {
    var a = attrs; a[kCVPixelBufferWidthKey as String] = w; a[kCVPixelBufferHeightKey as String] = h
    if let fmt { a[kCVPixelBufferPixelFormatTypeKey as String] = fmt }
    else if let l = a[kCVPixelBufferPixelFormatTypeKey as String] as? [Any], let f = l.first { a[kCVPixelBufferPixelFormatTypeKey as String] = f }
    if a[kCVPixelBufferIOSurfacePropertiesKey as String] == nil { a[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]() }
    var p: CVPixelBufferPool?; CVPixelBufferPoolCreate(nil, nil, a as CFDictionary, &p); return p!
}
func new(_ p: CVPixelBufferPool) -> CVPixelBuffer { var b: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, p, &b); return b! }
func fill(_ b: CVPixelBuffer, _ seed: Int) {
    CVPixelBufferLockBaseAddress(b, [])
    let planar = CVPixelBufferIsPlanar(b)
    let h = planar ? CVPixelBufferGetHeightOfPlane(b, 0) : CVPixelBufferGetHeight(b)
    let st = planar ? CVPixelBufferGetBytesPerRowOfPlane(b, 0) : CVPixelBufferGetBytesPerRow(b)
    let d = (planar ? CVPixelBufferGetBaseAddressOfPlane(b, 0)! : CVPixelBufferGetBaseAddress(b)!).assumingMemoryBound(to: UInt8.self)
    let bpp = planar ? 1 : max(1, st / CVPixelBufferGetWidth(b))
    for y in 0..<h { for x in 0..<st { d[y * st + x] = ((((x / bpp) + seed * 9) / 40 + y / 40) % 2 == 0) ? 200 : 40 } }
    if planar, CVPixelBufferGetPlaneCount(b) > 1 { memset(CVPixelBufferGetBaseAddressOfPlane(b, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(b, 1) * CVPixelBufferGetHeightOfPlane(b, 1)) }
    CVPixelBufferUnlockBaseAddress(b, [])
}
func fcc(_ f: OSType) -> String { String(bytes: [UInt8(f >> 24 & 255), UInt8(f >> 16 & 255), UInt8(f >> 8 & 255), UInt8(f & 255)], encoding: .ascii) ?? "\(f)" }
func spin(_ ms: Double) { let u = DispatchTime.now().uptimeNanoseconds + UInt64(ms * 1e6); while DispatchTime.now().uptimeNanoseconds < u {} }
func report(_ name: String, _ t: [Double]) { let s = t.sorted(); print(String(format: "%@: p50 %.1f ms  p95 %.1f ms  max %.1f ms", name, s[s.count / 2], s[Int(Double(s.count) * 0.95)], s.last!)) }

print("VTOpticalFlow supported:", VTOpticalFlowConfiguration.isSupported)
for (w, h) in [(1920, 1080), (1280, 720), (960, 540), (640, 360)] {
    for (qn, q) in [("normal ", VTOpticalFlowConfiguration.QualityPrioritization.normal), ("quality", .quality)] {
        guard let cfg = VTOpticalFlowConfiguration(frameWidth: w, frameHeight: h, qualityPrioritization: q, revision: VTOpticalFlowConfiguration.defaultRevision) else { print("VT \(w)x\(h) \(qn): no configuration"); continue }
        let proc = VTFrameProcessor()
        do { try proc.startSession(configuration: cfg) } catch { print("VT \(w)x\(h) \(qn): start failed \(error)"); continue }
        let sp = pool(cfg.sourcePixelBufferAttributes, w, h), dp = pool(cfg.destinationPixelBufferAttributes, w, h)
        let src = (0..<8).map { i -> CVPixelBuffer in let b = new(sp); fill(b, i); return b }
        let f0 = new(dp)
        var t: [Double] = [], err: Error?
        for i in 0..<70 {
            let a = VTFrameProcessorFrame(buffer: src[i % 8], presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 30))!
            let b = VTFrameProcessorFrame(buffer: src[(i + 1) % 8], presentationTimeStamp: CMTime(value: CMTimeValue(i + 1), timescale: 30))!
            let flow = VTFrameProcessorOpticalFlow(forwardFlow: new(dp), backwardFlow: new(dp))!
            let p = VTOpticalFlowParameters(sourceFrame: a, nextFrame: b, submissionMode: .sequential, destinationOpticalFlow: flow)!
            let sem = DispatchSemaphore(value: 0)
            let t0 = DispatchTime.now().uptimeNanoseconds
            proc.process(parameters: p, completionHandler: { _, e in err = e; sem.signal() }); sem.wait()
            let d = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            if err != nil { break }
            if i >= 10 { t.append(d) }
            spin(max(0, 33.3 - d))
        }
        if let err { print("VT \(w)x\(h) \(qn): process failed \(err)") }
        else { report("VT \(w)x\(h) \(qn) (in \(fcc(CVPixelBufferGetPixelFormatType(src[0]))), flow \(fcc(CVPixelBufferGetPixelFormatType(f0))) \(CVPixelBufferGetWidth(f0))x\(CVPixelBufferGetHeight(f0)))", t) }
        proc.endSession()
    }
}
// Vision's optical flow for comparison
for (w, h) in [(1920, 1080), (960, 540)] {
    let p = pool([kCVPixelBufferMetalCompatibilityKey as String: true], w, h, fmt: kCVPixelFormatType_32BGRA)
    let src = (0..<8).map { i -> CVPixelBuffer in let b = new(p); fill(b, i); return b }
    for (an, acc) in [("low", VNGenerateOpticalFlowRequest.ComputationAccuracy.low), ("medium", .medium), ("high", .high), ("veryHigh", .veryHigh)] {
        var t: [Double] = [], failed = false
        for i in 0..<40 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let r = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: src[(i + 1) % 8], options: [:]); r.computationAccuracy = acc
            do { try VNImageRequestHandler(cvPixelBuffer: src[i % 8], options: [:]).perform([r]) } catch { print("Vision \(w)x\(h) \(an): \(error)"); failed = true; break }
            let d = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            if i >= 8 { t.append(d) }
            spin(max(0, 33.3 - d))
        }
        if !failed { report("Vision \(w)x\(h) \(an)", t) }
    }
}
