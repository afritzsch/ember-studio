import CoreGraphics
import Metal
import QuartzCore
import simd

/// UI-011: draws `WaveformBar`s with Metal, into the canvas's `CAMetalLayer` or (UI-051, DW-154)
/// into an offscreen texture for `ui.snapshot`, because `cacheDisplay` doesn't capture Metal layers.
/// The shader is compiled from source at startup, so the SwiftPM target and the Xcode app (which
/// compile the same files) need no metallib resource.
@MainActor
final class WaveformRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    /// Nil without a Metal device (the canvas then draws no waveforms).
    static let shared: WaveformRenderer? = try? WaveformRenderer()

    private struct Uniforms {
        /// The drawn area in points, and the view y of its top (the ruler is above it).
        var viewSize: SIMD2<Float>
        var originY: Float
        var pad: Float = 0
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct WaveformBar { float4 rect; float4 color; };   // x0, top, x1, bottom (points, y down)
    struct Uniforms { float2 viewSize; float originY; float pad; };
    struct VertexOut { float4 position [[position]]; float4 color; };

    vertex VertexOut waveformVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                    const device WaveformBar *bars [[buffer(0)]],
                                    constant Uniforms &u [[buffer(1)]]) {
        // Two triangles per bar: corners (0,0) (1,0) (0,1) (1,0) (1,1) (0,1).
        const float2 corners[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        WaveformBar bar = bars[iid];
        float2 c = corners[vid];
        float2 p = float2(mix(bar.rect.x, bar.rect.z, c.x), mix(bar.rect.y, bar.rect.w, c.y) - u.originY);
        VertexOut out;
        out.position = float4(p.x / u.viewSize.x * 2.0 - 1.0, 1.0 - p.y / u.viewSize.y * 2.0, 0, 1);
        out.color = bar.color;
        return out;
    }

    fragment float4 waveformFragment(VertexOut in [[stage_in]]) {
        return float4(in.color.rgb * in.color.a, in.color.a);   // premultiplied
    }
    """

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RendererError.noDevice
        }
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(source: Self.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "waveformVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "waveformFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = Self.pixelFormat
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    enum RendererError: Error { case noDevice, noTexture }

    /// Draws `bars` into the layer's next drawable. `size` is the layer's size in points; `originY`
    /// the view y of the layer's top.
    func draw(_ bars: [WaveformBar], in layer: CAMetalLayer, size: CGSize, originY: Double) {
        guard size.width >= 1, size.height >= 1, let drawable = layer.nextDrawable() else { return }
        encode(bars, into: drawable.texture, size: size, originY: originY) { $0.present(drawable) }
    }

    /// UI-051 / DW-154: the same drawing into an offscreen texture, read back as an image with a
    /// transparent background, `scale` pixels per point.
    func image(_ bars: [WaveformBar], size: CGSize, originY: Double, scale: CGFloat) throws -> CGImage {
        let width = max(Int((size.width * scale).rounded()), 1), height = max(Int((size.height * scale).rounded()), 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RendererError.noTexture }
        encode(bars, into: texture, size: size, originY: originY, wait: true)
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&pixels, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw RendererError.noTexture }
        return image
    }

    private func encode(_ bars: [WaveformBar], into texture: MTLTexture, size: CGSize, originY: Double, wait: Bool = false,
                        before commit: (MTLCommandBuffer) -> Void = { _ in }) {
        guard let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        if !bars.isEmpty {
            let length = bars.count * MemoryLayout<WaveformBar>.stride
            // A fresh buffer per frame: the GPU may still read the previous one, and drawing never waits on it.
            if let buffer = bars.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: length, options: .storageModeShared) }) {
                var uniforms = Uniforms(viewSize: SIMD2(Float(size.width), Float(size.height)), originY: Float(originY))
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: bars.count)
            }
        }
        encoder.endEncoding()
        commit(commands)
        commands.commit()
        if wait { commands.waitUntilCompleted() }
    }
}
