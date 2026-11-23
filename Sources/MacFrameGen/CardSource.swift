import AVFoundation
import CoreMedia

/// A USB capture card (any UVC video device) as the frame source, plus its sound.
final class CardSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Format {
        let format: AVCaptureDevice.Format
        let fps: Double
        let width: Int, height: Int
        let subtype: String
        let compressed: Bool
        var description: String { "\(width)x\(height) up to \(Int(fps.rounded())) fps \(subtype)\(compressed ? " (compressed)" : "")" }
    }

    let session = AVCaptureSession()
    private weak var engine: Engine?
    private(set) var audioOut: AVCaptureAudioPreviewOutput?
    private(set) var summary = ""

    // MARK: Finding devices

    /// External video devices, capture cards first. An iPhone nearby also shows up as an external camera
    /// (Continuity Camera), so those are left out.
    static func devices(includeBuiltIn: Bool = false) -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.external]
        if includeBuiltIn { types.append(.builtInWideAngleCamera) }
        let all = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
            .filter { !$0.modelID.hasPrefix("iPhone") && !$0.modelID.hasPrefix("iPad") }
        return all.filter { $0.modelID.contains("UVC") } + all.filter { !$0.modelID.contains("UVC") }
    }

    private static func fourcc(_ t: FourCharCode) -> String {
        String(bytes: [UInt8(t >> 24), UInt8((t >> 16) & 255), UInt8((t >> 8) & 255), UInt8(t & 255)], encoding: .ascii) ?? "\(t)"
    }
    private static let compressedTypes: Set<String> = ["jpeg", "dmb1", "avc1", "hvc1", "mjpg", "MJPG"]

    static func formats(of device: AVCaptureDevice) -> [Format] {
        device.formats.map { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = fourcc(CMFormatDescriptionGetMediaSubType(f.formatDescription))
            return Format(format: f, fps: f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0,
                          width: Int(d.width), height: Int(d.height), subtype: sub, compressed: compressedTypes.contains(sub))
        }
    }

    /// Picks the card's mode: 60 fps first, then uncompressed (compressed modes add delay and lose quality),
    /// then 1080p, then the "420v" pixel layout.
    ///
    /// "420v" is the layout the interpolator reads, so nothing is converted on the way in. On the card this was
    /// developed with, "420v" and "yuvs" (4:2:2) measured the same hand-off time and delay over two minutes each.
    static func bestFormat(for device: AVCaptureDevice) -> Format? {
        func score(_ f: Format) -> Int {
            var s = (f.fps >= 59 ? 1000 : Int(f.fps)) + (f.compressed ? 0 : 100)
            s += f.height == 1080 ? 50 : (f.height == 720 ? 30 : 0)
            if f.height > 1080 { s -= 40 }
            if f.subtype == "420v" { s += 20 }
            return s
        }
        var best: Format?
        for f in formats(of: device) where best == nil || score(f) > score(best!) { best = f }
        return best
    }

    // MARK: Running

    func start(device: AVCaptureDevice, format f: Format, width: Int, height: Int, queue: DispatchQueue, engine: Engine) throws {
        self.engine = engine
        session.beginConfiguration()
        for i in session.inputs { session.removeInput(i) }
        for o in session.outputs { session.removeOutput(o) }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { session.commitConfiguration(); throw EngineError("cannot open \(device.localizedName)") }
        session.addInput(input)

        try device.lockForConfiguration()
        device.activeFormat = f.format
        let use = min(f.fps, 60)
        if let r = f.format.videoSupportedFrameRateRanges.first(where: { $0.maxFrameRate >= use - 0.5 }) {
            let dur = use >= r.maxFrameRate - 0.5 ? r.minFrameDuration : CMTime(value: 1, timescale: CMTimeScale(use))
            device.activeVideoMinFrameDuration = dur; device.activeVideoMaxFrameDuration = dur
        }
        device.unlockForConfiguration()
        summary = "\(device.localizedName): \(f.width)x\(f.height) at \(Int(f.fps.rounded())) fps, \(f.subtype) \(f.compressed ? "(COMPRESSED mode)" : "(uncompressed)")"

        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                             kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else { session.commitConfiguration(); throw EngineError("cannot read video from \(device.localizedName)") }
        session.addOutput(out)

        // Sound: the card also appears as a separate audio input; play it straight through to the Mac's output.
        // macOS does not always link the two, so fall back to matching by name or by USB vendor and product ID
        // (seen on a real card: video ID ending "345f2131", audio model ID containing "345F:2131").
        audioOut = nil
        let vid = device.uniqueID.lowercased()
        let usb = vid.count >= 8 ? String(vid.suffix(8)) : ""
        let audioDev = device.linkedDevices.first { $0.hasMediaType(.audio) }
            ?? AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .microphone], mediaType: .audio, position: .unspecified).devices
                .filter { !$0.modelID.hasPrefix("iPhone") && !$0.uniqueID.contains("BuiltIn") }
                .first { a in
                    a.uniqueID.contains(device.localizedName) || a.localizedName.contains(device.localizedName)
                        || (usb.count == 8 && a.modelID.lowercased().replacingOccurrences(of: ":", with: "").contains(usb))
                }
        if let a = audioDev, let ai = try? AVCaptureDeviceInput(device: a), session.canAddInput(ai) {
            session.addInput(ai)
            let ap = AVCaptureAudioPreviewOutput(); ap.volume = 1
            if session.canAddOutput(ap) { session.addOutput(ap); audioOut = ap; summary += "; sound from \(a.localizedName)" }
        } else { summary += "; no sound device found for it" }
        session.commitConfiguration()
        session.startRunning()
    }

    func stop() { if session.isRunning { session.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        var t = CMSampleBufferGetPresentationTimeStamp(sb)
        if let clk = session.synchronizationClock { t = CMSyncConvertTime(t, from: clk, to: CMClockGetHostTimeClock()) }
        engine?.submit(pb, t.seconds)
    }
}
