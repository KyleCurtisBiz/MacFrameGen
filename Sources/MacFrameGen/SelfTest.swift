import AVFoundation
import CoreVideo
import Foundation

extension Engine {
    /// Self-test source: a 30 fps picture inside a 60 Hz stream (each frame sent twice, as a console does),
    /// fed through the same entry point a capture card uses. Needs no card and no permission.
    ///
    /// With `file`, real footage is used: 24 frames from a video recorded off a 30 fps game at 60 fps (every
    /// other frame, starting ten seconds in). Otherwise a moving checkerboard.
    /// `fps` is the game's frame rate inside the 60 Hz stream: 30 sends every frame twice, 60 sends each once,
    /// 40 alternates. `width` x `height` is the size of the stream.
    func startSelfTest(file: String? = nil, fps: Double = 30, width w: Int = FrameGenerator.maxWidth, height h: Int = FrameGenerator.maxHeight) throws {
        stop()
        try configure(width: w, height: h)
        var frames: [CVPixelBuffer] = []
        if let file { frames = footage(file) }
        if frames.isEmpty {
            for k in 0..<12 {
                guard let b = generator.newSourceBuffer() else { continue }
                CVPixelBufferLockBaseAddress(b, [])
                let st = CVPixelBufferGetBytesPerRowOfPlane(b, 0), d = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height { for x in 0..<width { d[y * st + x] = (((x + k * 12) / 48 + y / 48) % 2 == 0) ? 190 : 50 } }
                memset(CVPixelBufferGetBaseAddressOfPlane(b, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(b, 1) * CVPixelBufferGetHeightOfPlane(b, 1))
                CVPixelBufferUnlockBaseAddress(b, [])
                frames.append(b)
            }
        }
        var n = 0
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: captureQueue)
        t.schedule(deadline: .now() + 0.2, repeating: 1.0 / 60.0, leeway: .nanoseconds(0))
        t.setEventHandler { [weak self] in
            guard let self, !frames.isEmpty else { return }
            self.submit(frames[Int(Double(n) * fps / 60.0) % frames.count], hostNow()); n += 1
        }
        t.resume(); synthTimer = t
    }

    private func footage(_ file: String) -> [CVPixelBuffer] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: file))
        let sem = DispatchSemaphore(value: 0)
        var track: AVAssetTrack?
        Task { track = try? await asset.loadTracks(withMediaType: .video).first; sem.signal() }
        sem.wait()
        guard let track, let reader = try? AVAssetReader(asset: asset) else { return [] }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        reader.add(out)
        guard reader.startReading() else { return [] }
        var frames: [CVPixelBuffer] = [], i = 0
        while frames.count < 24, let sb = out.copyNextSampleBuffer() {
            if i >= 600, i % 2 == 0, let pb = CMSampleBufferGetImageBuffer(sb), let c = generator.copy(pb) { frames.append(c) }
            i += 1
        }
        reader.cancelReading()
        return frames
    }
}
