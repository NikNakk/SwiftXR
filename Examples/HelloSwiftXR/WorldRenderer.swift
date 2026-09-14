import Metal
import simd
import SwiftXR

enum WorldRendererError: Error, CustomStringConvertible {
    case shaderFunctionMissing(String)
    case bufferCreationFailed(String)
    case depthTextureCreationFailed
    case renderEncoderCreationFailed

    var description: String {
        switch self {
        case let .shaderFunctionMissing(name):
            return "Metal shader function not found: \(name)"
        case let .bufferCreationFailed(name):
            return "Could not create Metal buffer: \(name)"
        case .depthTextureCreationFailed:
            return "Could not create the depth texture for the SwiftXR sample scene"
        case .renderEncoderCreationFailed:
            return "Could not create a Metal render command encoder for the SwiftXR sample scene"
        }
    }
}

private struct WorldVertex {
    var position: SIMD3<Float>
    var color: SIMD3<Float>
}

private struct WorldUniforms {
    var viewProjection: simd_float4x4
}

final class WorldRenderer {
    private let pipelineState: any MTLRenderPipelineState
    private let depthState: any MTLDepthStencilState
    private let depthTexture: any MTLTexture
    private let cubeBuffer: any MTLBuffer
    private let gridBuffer: any MTLBuffer
    private let cubeVertexCount: Int
    private let gridVertexCount: Int

    init(device: any MTLDevice, swapchain: XRSwapchain) throws {
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)

        guard let vertexFunction = library.makeFunction(name: "world_vertex") else {
            throw WorldRendererError.shaderFunctionMissing("world_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "world_fragment") else {
            throw WorldRendererError.shaderFunctionMissing("world_fragment")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "SwiftXR world pipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = swapchain.pixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        pipelineDescriptor.rasterSampleCount = 1
        self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.label = "SwiftXR world depth state"
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw WorldRendererError.depthTextureCreationFailed
        }
        self.depthState = depthState

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: Int(swapchain.width),
            height: Int(swapchain.height),
            mipmapped: false
        )
        textureDescriptor.label = "SwiftXR world depth texture"
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [.renderTarget]
        guard let depthTexture = device.makeTexture(descriptor: textureDescriptor) else {
            throw WorldRendererError.depthTextureCreationFailed
        }
        self.depthTexture = depthTexture

        let cubeVertices = Self.makeCubeVertices()
        let gridVertices = Self.makeGridVertices()

        self.cubeVertexCount = cubeVertices.count
        self.gridVertexCount = gridVertices.count
        self.cubeBuffer = try Self.makeBuffer(
            device: device,
            values: cubeVertices,
            label: "SwiftXR cube vertices"
        )
        self.gridBuffer = try Self.makeBuffer(
            device: device,
            values: gridVertices,
            label: "SwiftXR floor grid vertices"
        )
    }

    func encode(
        frame: XRFrame,
        texture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        guard frame.views.count >= 2 else {
            return
        }

        for eye in 0..<2 {
            let passDescriptor = MTLRenderPassDescriptor()
            passDescriptor.colorAttachments[0].texture = texture
            passDescriptor.colorAttachments[0].slice = eye
            passDescriptor.colorAttachments[0].level = 0
            passDescriptor.colorAttachments[0].loadAction = .clear
            passDescriptor.colorAttachments[0].storeAction = .store
            passDescriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: 0.018,
                green: 0.024,
                blue: 0.040,
                alpha: 1.0
            )

            passDescriptor.depthAttachment.texture = depthTexture
            passDescriptor.depthAttachment.loadAction = .clear
            passDescriptor.depthAttachment.storeAction = .dontCare
            passDescriptor.depthAttachment.clearDepth = 1.0

            guard let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: passDescriptor
            ) else {
                throw WorldRendererError.renderEncoderCreationFailed
            }

            encoder.label = eye == 0 ? "SwiftXR left eye" : "SwiftXR right eye"
            encoder.setViewport(
                MTLViewport(
                    originX: 0,
                    originY: 0,
                    width: Double(texture.width),
                    height: Double(texture.height),
                    znear: 0,
                    zfar: 1
                )
            )
            encoder.setRenderPipelineState(pipelineState)
            encoder.setDepthStencilState(depthState)
            encoder.setCullMode(.none)

            var uniforms = WorldUniforms(
                viewProjection: frame.views[eye].viewProjectionMatrix(
                    nearZ: 0.05,
                    farZ: 50.0
                )
            )
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<WorldUniforms>.stride,
                index: 1
            )

            encoder.setVertexBuffer(gridBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(
                type: .line,
                vertexStart: 0,
                vertexCount: gridVertexCount
            )

            encoder.setVertexBuffer(cubeBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: cubeVertexCount
            )

            encoder.endEncoding()
        }
    }

    private static func makeBuffer<T>(
        device: any MTLDevice,
        values: [T],
        label: String
    ) throws -> any MTLBuffer {
        let buffer = values.withUnsafeBufferPointer { pointer -> (any MTLBuffer)? in
            guard let baseAddress = pointer.baseAddress else {
                return nil
            }
            return device.makeBuffer(
                bytes: baseAddress,
                length: pointer.count * MemoryLayout<T>.stride,
                options: []
            )
        }

        guard let buffer else {
            throw WorldRendererError.bufferCreationFailed(label)
        }
        buffer.label = label
        return buffer
    }

    private static func makeCubeVertices() -> [WorldVertex] {
        let left: Float = -0.32
        let right: Float = 0.32
        let bottom: Float = -0.90
        let top: Float = -0.26
        let front: Float = -1.70
        let back: Float = -2.34

        let lbf = SIMD3<Float>(left, bottom, front)
        let rbf = SIMD3<Float>(right, bottom, front)
        let ltf = SIMD3<Float>(left, top, front)
        let rtf = SIMD3<Float>(right, top, front)
        let lbb = SIMD3<Float>(left, bottom, back)
        let rbb = SIMD3<Float>(right, bottom, back)
        let ltb = SIMD3<Float>(left, top, back)
        let rtb = SIMD3<Float>(right, top, back)

        var vertices: [WorldVertex] = []

        func addFace(
            _ a: SIMD3<Float>,
            _ b: SIMD3<Float>,
            _ c: SIMD3<Float>,
            _ d: SIMD3<Float>,
            color: SIMD3<Float>
        ) {
            vertices.append(WorldVertex(position: a, color: color))
            vertices.append(WorldVertex(position: b, color: color))
            vertices.append(WorldVertex(position: c, color: color))
            vertices.append(WorldVertex(position: a, color: color))
            vertices.append(WorldVertex(position: c, color: color))
            vertices.append(WorldVertex(position: d, color: color))
        }

        addFace(lbf, rbf, rtf, ltf, color: SIMD3(0.95, 0.28, 0.22))
        addFace(rbb, lbb, ltb, rtb, color: SIMD3(0.22, 0.42, 0.95))
        addFace(lbb, lbf, ltf, ltb, color: SIMD3(0.22, 0.82, 0.45))
        addFace(rbf, rbb, rtb, rtf, color: SIMD3(0.95, 0.68, 0.20))
        addFace(ltf, rtf, rtb, ltb, color: SIMD3(0.68, 0.30, 0.95))
        addFace(lbb, rbb, rbf, lbf, color: SIMD3(0.20, 0.78, 0.88))

        return vertices
    }

    private static func makeGridVertices() -> [WorldVertex] {
        let floorY: Float = -1.50
        let minor = SIMD3<Float>(0.28, 0.31, 0.36)
        let major = SIMD3<Float>(0.48, 0.52, 0.58)
        let xAxis = SIMD3<Float>(0.75, 0.18, 0.18)
        let zAxis = SIMD3<Float>(0.18, 0.38, 0.80)

        var vertices: [WorldVertex] = []

        for index in -10...10 {
            let x = Float(index) * 0.5
            let color = index == 0 ? zAxis : (index % 2 == 0 ? major : minor)
            vertices.append(
                WorldVertex(position: SIMD3(x, floorY, -6.0), color: color)
            )
            vertices.append(
                WorldVertex(position: SIMD3(x, floorY, 1.0), color: color)
            )
        }

        for index in -12...2 {
            let z = Float(index) * 0.5
            let color = index == 0 ? xAxis : (index % 2 == 0 ? major : minor)
            vertices.append(
                WorldVertex(position: SIMD3(-5.0, floorY, z), color: color)
            )
            vertices.append(
                WorldVertex(position: SIMD3(5.0, floorY, z), color: color)
            )
        }

        return vertices
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct WorldVertex {
        float3 position;
        float3 color;
    };

    struct WorldUniforms {
        float4x4 viewProjection;
    };

    struct WorldVertexOut {
        float4 position [[position]];
        float3 color;
    };

    vertex WorldVertexOut world_vertex(
        uint vertexID [[vertex_id]],
        const device WorldVertex *vertices [[buffer(0)]],
        constant WorldUniforms &uniforms [[buffer(1)]])
    {
        WorldVertexOut output;
        WorldVertex input = vertices[vertexID];
        output.position = uniforms.viewProjection * float4(input.position, 1.0);
        output.color = input.color;
        return output;
    }

    fragment float4 world_fragment(WorldVertexOut input [[stage_in]])
    {
        return float4(input.color, 1.0);
    }
    """
}
