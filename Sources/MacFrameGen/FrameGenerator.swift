import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Wraps Apple's low-latency frame interpolator (`VTLowLatencyFrameInterpolation`, macOS 26+).
/// Given two real frames it produces the frame halfway between them.
final class FrameGenerator {
    /// The interpolator accepts at most 1920x1080.
    static let maxWidth = 1920, maxHeight = 1080

    private(set) var width = 0, height = 0
    private var processor: VTFrameProcessor?
    private var sourcePool: CVPixelBufferPool?, outputPool: CVPixelBufferPool?

    static var isSupported: Bool { VTLowLatencyFrameInterpolationConfiguration.isSupported }

    /// Starts an interpolator for the given size. Returns false if no nearby size works.
    ///
    /// The interpolator silently fails at some sizes: it starts without error and then every frame fails with
    /// "Processor is not initialized". Measured at height 1080: widths 1896-1904 fail while 1888 and 1920 work.
    /// So one real interpolation is run here, and the width is stepped down by 8 until it succeeds.
    func start(width w: Int, height h: Int) -> Bool {
        stop()
        width = w; height = h
        for _ in 0..<16 {
            if let cfg = VTLowLatencyFrameInterpolationConfiguration(frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: 1) {
                let p = VTFrameProcessor()
                if (try? p.startSession(configuration: cfg)) != nil {
                    processor = p
                    sourcePool = makePool(cfg.sourcePixelBufferAttributes)
                    outputPool = makePool(cfg.destinationPixelBufferAttributes)
                    if trialRun() { return true }
                    p.endSession()
                    processor = nil
                }
            }
            width -= 8
        }
        return false
    }

    func stop() {
        processor?.endSession()
        processor = nil; sourcePool = nil; outputPool = nil
    }

    /// A new, uninitialised frame buffer in the layout the interpolator reads (4:2:0 bi-planar, video range).
    func newSourceBuffer() -> CVPixelBuffer? { sourcePool.flatMap(newBuffer) }

    /// Copies a captured frame into a buffer the interpolator can read. Capture buffers are recycled by their
    /// source, so every frame that is kept gets its own copy.
    func copy(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        guard let dst = newSourceBuffer() else { return nil }
        CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst, [])
        for p in 0..<2 {
            guard let s = CVPixelBufferGetBaseAddressOfPlane(src, p), let d = CVPixelBufferGetBaseAddressOfPlane(dst, p) else { continue }
            let ss = CVPixelBufferGetBytesPerRowOfPlane(src, p), ds = CVPixelBufferGetBytesPerRowOfPlane(dst, p)
            let h = min(CVPixelBufferGetHeightOfPlane(src, p), CVPixelBufferGetHeightOfPlane(dst, p)), n = min(ss, ds)
            for y in 0..<h { memcpy(d + y * ds, s + y * ss, n) }
        }
        CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(dst, [])
        return dst
    }

    /// Generates the frame halfway between `previous` and `current`. Blocks until it is done.
    /// Returns nil if the request could not be made at all; otherwise the time taken and the frame (nil on failure).
    func interpolate(previous: CVPixelBuffer, at tPrev: Double, current: CVPixelBuffer, at tCur: Double) -> (frame: CVPixelBuffer?, seconds: Double)? {
        guard let processor, let pool = outputPool, let out = newBuffer(pool),
              let pf = VTFrameProcessorFrame(buffer: previous, presentationTimeStamp: CMTime(seconds: tPrev, preferredTimescale: 90000)),
              let cf = VTFrameProcessorFrame(buffer: current, presentationTimeStamp: CMTime(seconds: tCur, preferredTimescale: 90000)),
              let of = VTFrameProcessorFrame(buffer: out, presentationTimeStamp: CMTime(seconds: tPrev + (tCur - tPrev) * 0.5, preferredTimescale: 90000)),
              let params = VTLowLatencyFrameInterpolationParameters(sourceFrame: cf, previousFrame: pf, interpolationPhase: [0.5], destinationFrames: [of])
        else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var err: Error?
        let t0 = hostNow()
        processor.process(parameters: params, completionHandler: { _, e in err = e; sem.signal() })
        sem.wait()
        return (err == nil ? out : nil, hostNow() - t0)
    }

    private func trialRun() -> Bool {
        guard let a = newSourceBuffer(), let b = newSourceBuffer() else { return false }
        return interpolate(previous: a, at: 0, current: b, at: 1.0 / 30.0)?.frame != nil
    }

    private func makePool(_ attrs: [String: Any]) -> CVPixelBufferPool? {
        var a = attrs
        a[kCVPixelBufferWidthKey as String] = width; a[kCVPixelBufferHeightKey as String] = height
        a[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if a[kCVPixelBufferIOSurfacePropertiesKey as String] == nil { a[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]() }
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, a as CFDictionary, &p)
        return p
    }
    private func newBuffer(_ pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var b: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &b)
        return b
    }
}

/// Labels a frame as BT.709 video so the display and the upscaler interpret its colours the same way.
func tagBT709(_ b: CVPixelBuffer) {
    CVBufferSetAttachment(b, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(b, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(b, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
}

func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
