// How long one 1080p interpolation takes depending on how the calls are spaced.
import Foundation
import VideoToolbox
import CoreVideo
import Metal
setvbuf(stdout, nil, _IONBF, 0)
let w = 1920, h = 1080
func pool(_ attrs: [String: Any]) -> CVPixelBufferPool {
    var a = attrs; a[kCVPixelBufferWidthKey as String] = w; a[kCVPixelBufferHeightKey as String] = h
    a[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    if a[kCVPixelBufferIOSurfacePropertiesKey as String] == nil { a[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]() }
    var p: CVPixelBufferPool?; CVPixelBufferPoolCreate(nil, nil, a as CFDictionary, &p); return p!
}
func buf(_ p: CVPixelBufferPool, _ seed: Int) -> CVPixelBuffer {
    var b: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, p, &b)
    CVPixelBufferLockBaseAddress(b!, [])
    let st = CVPixelBufferGetBytesPerRowOfPlane(b!, 0), d = CVPixelBufferGetBaseAddressOfPlane(b!, 0)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<h { for x in 0..<w { d[y * st + x] = (((x + seed * 9) / 40 + y / 40) % 2 == 0) ? 200 : 40 } }
    memset(CVPixelBufferGetBaseAddressOfPlane(b!, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(b!, 1) * CVPixelBufferGetHeightOfPlane(b!, 1))
    CVPixelBufferUnlockBaseAddress(b!, []); return b!
}
let cfg = VTLowLatencyFrameInterpolationConfiguration(frameWidth: w, frameHeight: h, numberOfInterpolatedFrames: 1)!
let proc = VTFrameProcessor(); try proc.startSession(configuration: cfg)
let sp = pool(cfg.sourcePixelBufferAttributes), dp = pool(cfg.destinationPixelBufferAttributes)
let src = (0..<8).map { buf(sp, $0) }
func once(_ i: Int) -> Double {
    let a = VTFrameProcessorFrame(buffer: src[i % 8], presentationTimeStamp: CMTime(value: CMTimeValue(i * 2), timescale: 60))!
    let b = VTFrameProcessorFrame(buffer: src[(i + 1) % 8], presentationTimeStamp: CMTime(value: CMTimeValue(i * 2 + 2), timescale: 60))!
    var o: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, dp, &o)
    let of = VTFrameProcessorFrame(buffer: o!, presentationTimeStamp: CMTime(value: CMTimeValue(i * 2 + 1), timescale: 60))!
    let p = VTLowLatencyFrameInterpolationParameters(sourceFrame: b, previousFrame: a, interpolationPhase: [0.5], destinationFrames: [of])!
    let sem = DispatchSemaphore(value: 0)
    let t0 = DispatchTime.now().uptimeNanoseconds
    proc.process(parameters: p, completionHandler: { _, _ in sem.signal() }); sem.wait()
    return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
}
func run(_ name: String, gapMs: Double, n: Int, warm: (() -> Void)? = nil) {
    var t: [Double] = []
    for i in 0..<n {
        let d = once(i); if i >= 8 { t.append(d) }
        if gapMs > 0 {
            let until = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, gapMs - d) * 1e6)
            if let warm { while DispatchTime.now().uptimeNanoseconds < until { warm() } } else { usleep(useconds_t(max(0, gapMs - d) * 1000)) }
        }
    }
    let s = t.sorted()
    print(String(format: "%@: p50 %.1f ms  p95 %.1f ms  max %.1f ms", name, s[s.count / 2], s[Int(Double(s.count) * 0.95)], s.last!))
}
for _ in 0..<10 { _ = once(0) }
func runCustom(_ name: String, n: Int, wait: (Double) -> Void) {
    var t: [Double] = []
    for i in 0..<n { let d = once(i); if i >= 8 { t.append(d) }; wait(max(0, 33.3 - d)) }
    let s = t.sorted()
    print(String(format: "%@: p50 %.1f ms  p95 %.1f ms  max %.1f ms", name, s[s.count / 2], s[Int(Double(s.count) * 0.95)], s.last!))
}
func spin(_ ms: Double) { let u = DispatchTime.now().uptimeNanoseconds + UInt64(ms * 1e6); while DispatchTime.now().uptimeNanoseconds < u {} }
func makeRealtime() -> Bool {
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    let ms = { (x: Double) -> UInt32 in UInt32(x * 1e6 * Double(tb.denom) / Double(tb.numer)) }
    var pol = thread_time_constraint_policy_data_t(period: ms(33.3), computation: ms(12), constraint: ms(20), preemptible: 1)
    let r = withUnsafeMutablePointer(to: &pol) { $0.withMemoryRebound(to: integer_t.self, capacity: 4) {
        thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)) } }
    return r == KERN_SUCCESS
}
runCustom("idle between (baseline)                 ", n: 120) { usleep(useconds_t($0 * 1000)) }
runCustom("spin the whole gap                      ", n: 120) { spin($0) }
runCustom("half duty: spin 1 ms, sleep 1 ms        ", n: 120) { var left = $0; while left > 0 { spin(min(1, left)); usleep(1000); left -= 2.1 } }
runCustom("quarter duty: spin 0.5 ms, sleep 1.5 ms ", n: 120) { var left = $0; while left > 0 { spin(min(0.5, left)); usleep(1500); left -= 2.1 } }
// another thread keeps the GPU busy with tiny blits; caller sleeps
let dev = MTLCreateSystemDefaultDevice()!, q = dev.makeCommandQueue()!
let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
let ta = dev.makeTexture(descriptor: td)!, tb2 = dev.makeTexture(descriptor: td)!
var stop = false
let th = Thread { while !stop { let cb = q.makeCommandBuffer()!; let e = cb.makeBlitCommandEncoder()!
    e.copy(from: ta, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: 64, height: 64, depth: 1), to: tb2, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    e.endEncoding(); cb.commit(); cb.waitUntilCompleted(); usleep(1000) } }
th.start()
runCustom("other thread: tiny GPU job every 1 ms   ", n: 120) { usleep(useconds_t($0 * 1000)) }
stop = true; usleep(50000)
let me = Thread {
    print("realtime policy set:", makeRealtime())
    runCustom("caller is a realtime thread, idle between", n: 120) { usleep(useconds_t($0 * 1000)) }
    exit(0)
}
me.start()
while true { sleep(1) }
