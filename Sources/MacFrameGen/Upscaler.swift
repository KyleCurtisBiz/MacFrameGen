import CoreVideo
import Metal
import MetalFX

/// Upscales frames to the window's real pixel size with Apple's MetalFX spatial scaler. Without it the display
/// just stretches the 1080p frame.
///
/// Everything happens on the GPU in one submission per pair of frames: a small compute shader turns the video's
/// Y'CbCr into RGB, then MetalFX scales it. Measured at 1080p -> 3024x1702: 3-5 ms per pair. (A first version that
/// converted colour with a separate CPU-side call and waited on the GPU once per frame measured 6.6 ms.)
final class Upscaler {
    private let dev: MTLDevice, queue: MTLCommandQueue
    private var cache: CVMetalTextureCache?
    private var convert: MTLComputePipelineState?
    private var scaler: MTLFXSpatialScaler?
    private var mids: [MTLTexture] = []
    private var outPool: CVPixelBufferPool?
    private var key = ""
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    // BT.709, video range (16-235 / 16-240).
    kernel void nv12ToRGB(texture2d<float, access::read> yT [[texture(0)]],
                          texture2d<float, access::sample> cT [[texture(1)]],
                          texture2d<float, access::write> o [[texture(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= o.get_width() || gid.y >= o.get_height()) return;
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float y = (yT.read(gid).r - 16.0 / 255.0) * (255.0 / 219.0);
        float2 uv = (float2(gid) + 0.5) / float2(o.get_width(), o.get_height());
        float2 c = (cT.sample(s, uv).rg - 128.0 / 255.0) * (255.0 / 224.0);
        float3 rgb = float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x);
        o.write(float4(saturate(rgb), 1.0), gid);
    }
    """
    init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), MTLFXSpatialScalerDescriptor.supportsDevice(d) else { return nil }
        dev = d; queue = q
        CVMetalTextureCacheCreate(nil, nil, d, nil, &cache)
        guard let lib = try? d.makeLibrary(source: Upscaler.shader, options: nil), let f = lib.makeFunction(name: "nv12ToRGB"),
              let ps = try? d.makeComputePipelineState(function: f) else { return nil }
        convert = ps
    }
    private func tex(_ pb: CVPixelBuffer, plane: Int, _ fmt: MTLPixelFormat, _ usage: MTLTextureUsage) -> (CVMetalTexture, MTLTexture)? {
        guard let cache else { return nil }
        var t: CVMetalTexture?
        let planar = CVPixelBufferIsPlanar(pb)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, plane) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, [kCVMetalTextureUsage as String: usage.rawValue] as CFDictionary, fmt, w, h, plane, &t)
        guard let t, let m = CVMetalTextureGetTexture(t) else { return nil }
        return (t, m)
    }
    // Upscales every frame given, in one GPU submission. An entry is nil if that frame could not be done
    // (the caller then shows it un-upscaled).
    func run(_ srcs: [CVPixelBuffer], outW: Int, outH: Int) -> [CVPixelBuffer?] {
        guard let first = srcs.first, let convert else { return srcs.map { _ in nil } }
        let w = CVPixelBufferGetWidth(first), h = CVPixelBufferGetHeight(first)
        guard outW > w, outH > h else { return srcs.map { _ in nil } }
        let k = "\(w)x\(h)>\(outW)x\(outH)"
        if k != key {
            let d = MTLFXSpatialScalerDescriptor()
            d.inputWidth = w; d.inputHeight = h; d.outputWidth = outW; d.outputHeight = outH
            d.colorTextureFormat = .bgra8Unorm; d.outputTextureFormat = .bgra8Unorm; d.colorProcessingMode = .perceptual
            scaler = d.makeSpatialScaler(device: dev); mids = []
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outW, kCVPixelBufferHeightKey as String: outH, kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &p)
            outPool = p; key = k
        }
        guard let scaler, let outPool else { return srcs.map { _ in nil } }
        while mids.count < srcs.count {           // one intermediate RGB texture per frame in the batch
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = [.shaderWrite, .shaderRead, scaler.colorTextureUsage]; td.storageMode = .private
            guard let t = dev.makeTexture(descriptor: td) else { return srcs.map { _ in nil } }
            mids.append(t)
        }
        var outs: [CVPixelBuffer?] = [], keep: [CVMetalTexture] = [], last: MTLCommandBuffer?
        for (i, src) in srcs.enumerated() {
            var ob: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, outPool, &ob)
            guard let out = ob, CVPixelBufferGetWidth(src) == w, CVPixelBufferGetHeight(src) == h,
                  let (k1, yT) = tex(src, plane: 0, .r8Unorm, .shaderRead), let (k2, cT) = tex(src, plane: 1, .rg8Unorm, .shaderRead),
                  let (k3, oT) = tex(out, plane: 0, .bgra8Unorm, scaler.outputTextureUsage),
                  let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { outs.append(nil); continue }
            keep += [k1, k2, k3]
            enc.setComputePipelineState(convert)
            enc.setTexture(yT, index: 0); enc.setTexture(cT, index: 1); enc.setTexture(mids[i], index: 2)
            let tw = convert.threadExecutionWidth, th = max(1, convert.maxTotalThreadsPerThreadgroup / tw)
            enc.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
            enc.endEncoding()
            scaler.colorTexture = mids[i]; scaler.outputTexture = oT
            scaler.inputContentWidth = w; scaler.inputContentHeight = h
            scaler.encode(commandBuffer: cb)
            cb.commit(); last = cb
            CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            outs.append(out)
        }
        last?.waitUntilCompleted()                 // the queue runs in order, so waiting on the last one covers them all
        if last?.error != nil { return srcs.map { _ in nil } }
        _ = keep
        return outs
    }
}
