import AppKit
import Metal
import MetalKit

/// Metal-based bloom/glow post-processing for the modern skin system.
/// Renders window content to an offscreen texture, applies multi-pass Gaussian blur
/// on bright pixels, and composites the bloom back over the original.
class BloomPostProcessor {
    
    // MARK: - Properties
    
    /// Whether bloom is enabled
    var isEnabled: Bool = true
    
    /// Bloom radius (blur kernel size)
    var radius: CGFloat = 8.0
    
    /// Bloom intensity (brightness multiplier)
    var intensity: CGFloat = 0.6
    
    /// Brightness threshold (pixels above this contribute to bloom)
    var threshold: CGFloat = 0.7
    
    // MARK: - Metal State
    
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var brightnessExtractPipeline: MTLComputePipelineState?
    private var blurHorizontalPipeline: MTLComputePipelineState?
    private var blurVerticalPipeline: MTLComputePipelineState?
    private var compositePipeline: MTLComputePipelineState?
    
    // Textures
    private var sourceTexture: MTLTexture?
    private var brightnessTexture: MTLTexture?
    private var blurTempTexture: MTLTexture?
    private var bloomTexture: MTLTexture?
    private var outputTexture: MTLTexture?
    
    /// Whether Metal setup succeeded
    private(set) var isAvailable: Bool = false
    
    // MARK: - Initialization
    
    init() {
        setupMetal()
    }
    
    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            NSLog("BloomPostProcessor: No Metal device available")
            return
        }
        
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        
        do {
            let library = try device.makeBundledLibrary("BloomShader")
            if let fn = library.makeFunction(name: "bloom_extract_brightness") {
                brightnessExtractPipeline = try device.makeComputePipelineState(function: fn)
            }
            if let fn = library.makeFunction(name: "bloom_blur_horizontal") {
                blurHorizontalPipeline = try device.makeComputePipelineState(function: fn)
            }
            if let fn = library.makeFunction(name: "bloom_blur_vertical") {
                blurVerticalPipeline = try device.makeComputePipelineState(function: fn)
            }
            if let fn = library.makeFunction(name: "bloom_composite") {
                compositePipeline = try device.makeComputePipelineState(function: fn)
            }
            
            isAvailable = brightnessExtractPipeline != nil &&
                          blurHorizontalPipeline != nil &&
                          blurVerticalPipeline != nil &&
                          compositePipeline != nil
            
            if isAvailable {
                NSLog("BloomPostProcessor: Metal setup complete")
            }
        } catch {
            NSLog("BloomPostProcessor: Metal setup failed: \(error)")
        }
    }

    // MARK: - Texture Management
    
    private func ensureTextures(width: Int, height: Int) {
        guard let device = device else { return }
        
        // Check if existing textures match
        if let existing = sourceTexture,
           existing.width == width, existing.height == height {
            return
        }
        
        // The ends are CPU-visible (written and read back); the passes between stay on the GPU.
        func texture(_ storage: MTLStorageMode) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = storage
            return device.makeTexture(descriptor: descriptor)
        }
        sourceTexture = texture(.managed)
        brightnessTexture = texture(.private)
        blurTempTexture = texture(.private)
        bloomTexture = texture(.private)
        outputTexture = texture(.managed)
    }

    // MARK: - Processing

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    /// Apply bloom to a CGImage and return the result. The image is redrawn as RGBA8 premultiplied —
    /// the textures' own layout — so any input format works; an unbloomed image comes back when
    /// Metal cannot run the passes.
    func apply(to image: CGImage) -> CGImage? {
        guard isEnabled, isAvailable, let commandQueue,
              let extract = brightnessExtractPipeline, let blurH = blurHorizontalPipeline,
              let blurV = blurVerticalPipeline, let composite = compositePipeline else { return image }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        let region = MTLRegionMake2D(0, 0, width, height)
        var pixels = Data(count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: Self.colorSpace,
                                          bitmapInfo: Self.bitmapInfo) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return image }

        ensureTextures(width: width, height: height)

        guard let source = sourceTexture,
              let brightness = brightnessTexture,
              let blurTemp = blurTempTexture,
              let bloom = bloomTexture,
              let output = outputTexture,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return image }
        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            source.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow)
        }

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        func encode<T>(_ pipeline: MTLComputePipelineState, _ textures: [MTLTexture], _ value: T) -> Bool {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
            encoder.setComputePipelineState(pipeline)
            for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
            var value = value
            encoder.setBytes(&value, length: MemoryLayout<T>.size, index: 0)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
            encoder.endEncoding()
            return true
        }

        // Extract bright pixels, blur them both ways, and add them back over the original.
        guard encode(extract, [source, brightness], Float(threshold)),
              encode(blurH, [brightness, blurTemp], Int32(radius)),
              encode(blurV, [blurTemp, bloom], Int32(radius)),
              encode(composite, [source, bloom, output], Float(intensity)),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return image }
        blit.synchronize(resource: output)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            output.getBytes(base, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return image }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: Self.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    
    // MARK: - Configuration
    
    /// Configure from skin glow settings
    func configure(with glowConfig: GlowConfig) {
        isEnabled = glowConfig.enabled
        radius = glowConfig.radius ?? 8.0
        intensity = glowConfig.intensity ?? 0.6
        threshold = glowConfig.threshold ?? 0.7
    }
}
