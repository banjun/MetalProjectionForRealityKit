import Metal
import RealityKit

enum RenderPassEncoderSettings {
    static func makeTexture(_ label: String? = nil, device: any MTLDevice, width: Int, height: Int, pixelFormat: MTLPixelFormat, usage: MTLTextureUsage = [.renderTarget, .shaderRead], viewCount: Int) -> any MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        d.usage = usage
        d.storageMode = .private // for store for the next pass. (.memoryless cannot be stored)
        d.textureType = .type2DArray // for left/right
        d.arrayLength = viewCount
        let texture = device.makeTexture(descriptor: d)!
        texture.label = label
        return texture
    }

    static func makeRenderPipelineState(label: String = #file, device: any MTLDevice, library: (any MTLLibrary)? = nil, vertexFunction: String = "fullscreen_vertex", fragmentFunction: String, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState {
        let library = library ?? device.makeBundleDebugLibrary()!
        let d = MTLRenderPipelineDescriptor()
        d.label = label
        d.inputPrimitiveTopology = .triangle
        d.vertexFunction = library.makeFunction(name: vertexFunction)!
        d.fragmentFunction = library.makeFunction(name: fragmentFunction)!
        d.colorAttachments[0].pixelFormat = pixelFormat
        d.colorAttachments[0].isBlendingEnabled = false
        return try! device.makeRenderPipelineState(descriptor: d)
    }
    nonisolated static func makeRenderPipelineDescriptor(label: String = #file, device: any MTLDevice, library: (any MTLLibrary)? = nil, vertexFunction: String, fragmentFunction: String, llDescriptor: LowLevelMesh.Descriptor, pixelFormats: [MTLPixelFormat], depthPixelFormat: MTLPixelFormat) -> MTLRenderPipelineDescriptor {
        let library = library ?? device.makeBundleDebugLibrary()!

        let d = MTLRenderPipelineDescriptor()
        d.label = label
        d.inputPrimitiveTopology = .triangle
        d.rasterSampleCount = 1
        d.vertexFunction = library.makeFunction(name: vertexFunction)!
        d.vertexDescriptor = .init()
        llDescriptor.vertexLayouts.enumerated().forEach { i, l in
            d.vertexDescriptor!.layouts[i]!.stride = l.bufferStride
        }
        let vertexAttributes: [LowLevelMesh.Attribute] = llDescriptor.vertexAttributes
        vertexAttributes.enumerated().forEach { i, a in
            d.vertexDescriptor!.attributes[i]!.format = a.format
            d.vertexDescriptor!.attributes[i]!.offset = a.offset
            d.vertexDescriptor!.attributes[i]!.bufferIndex = a.layoutIndex
        }
        d.fragmentFunction = library.makeFunction(name: fragmentFunction)!
        pixelFormats.enumerated().forEach {
            d.colorAttachments[$0.offset].pixelFormat = $0.element
        }
        d.depthAttachmentPixelFormat = depthPixelFormat
        return d
    }
    nonisolated static func makeRenderPipelineState(label: String = #file, device: any MTLDevice, library: (any MTLLibrary)? = nil, vertexFunction: String, fragmentFunction: String, llDescriptor: LowLevelMesh.Descriptor, pixelFormats: [MTLPixelFormat], depthPixelFormat: MTLPixelFormat) -> (MTLRenderPipelineState, MTLFunction) {
        let d = makeRenderPipelineDescriptor(label: label, device: device, library: library, vertexFunction: vertexFunction, fragmentFunction: fragmentFunction, llDescriptor: llDescriptor, pixelFormats: pixelFormats, depthPixelFormat: depthPixelFormat)
        return (try! device.makeRenderPipelineState(descriptor: d), d.fragmentFunction!)
    }
    nonisolated static func makeComputePipelineState(label: String = #file, device: any MTLDevice, library: (any MTLLibrary)? = nil, kernelFunction: String) -> MTLComputePipelineState {
        let library = library ?? device.makeBundleDebugLibrary()!

        let kernel = library.makeFunction(name: kernelFunction)!
        return try! device.makeComputePipelineState(function: kernel)
    }

    static func renderPassDescriptor(texture: any MTLTexture, clearColor: MTLClearColor = .init(red: 0, green: 0, blue: 0, alpha: 0), loadAction: MTLLoadAction = .clear, storeAction: MTLStoreAction = .store, depthTexture: (any MTLTexture)? = nil, depthLoadAction: MTLLoadAction = .clear, depthStoreAction: MTLStoreAction = .store) -> MTLRenderPassDescriptor {
        let d = MTLRenderPassDescriptor()
        d.renderTargetArrayLength = texture.arrayLength
        d.colorAttachments[0]?.texture = texture
        d.colorAttachments[0]?.clearColor = clearColor
        d.colorAttachments[0]?.loadAction = loadAction
        d.colorAttachments[0]?.storeAction = storeAction
        if let depthTexture {
            d.depthAttachment.texture = depthTexture
            d.depthAttachment.loadAction = depthLoadAction
#if DEBUG
            d.depthAttachment.storeAction = .store
#else
            d.depthAttachment.storeAction = depthStoreAction
#endif
            d.depthAttachment.clearDepth = 0
        }
        return d
    }
}
