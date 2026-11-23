import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Times when this app's own window really changes on screen, using a second, small screen capture of it.
/// Needs the Screen Recording permission; nothing else in the app does.
final class OutputProbe: NSObject, SCStreamOutput {
    weak var engine: Engine?
    private var stream: SCStream?
    private let q = DispatchQueue(label: "macframegen.probe")
    func start(window: SCWindow) async throws {
        let sc = SCStreamConfiguration()
        sc.width = 160; sc.height = 90
        sc.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        sc.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        sc.queueDepth = 8; sc.showsCursor = false
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: sc, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        try await s.startCapture(); stream = s
    }
    func stop() async { try? await stream?.stopCapture(); stream = nil }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = arr.first?[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st != .complete { return }
        engine?.noteOutput(CMSampleBufferGetPresentationTimeStamp(sb).seconds)
    }
}
