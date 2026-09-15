import CoreGraphics
import Metal
import simd
import SwiftXR

struct VideoSurfaceGeometry {
    let center: SIMD3<Float>
    let widthMeters: Float
    let heightMeters: Float

    init(displaySize: CGSize) {
        let width = max(Float(displaySize.width), 1)
        let height = max(Float(displaySize.height), 1)
        let aspect = width / height

        var panelHeight: Float = 1.20
        var panelWidth = panelHeight * aspect

        if panelWidth > 2.40 {
            panelWidth = 2.40
            panelHeight = panelWidth / aspect
        }
        if panelHeight > 1.60 {
            panelHeight = 1.60
            panelWidth = panelHeight * aspect
        }

        self.center = SIMD3<Float>(0, 0, -2.0)
        self.widthMeters = panelWidth
        self.heightMeters = panelHeight
    }
}

enum VideoRendererError: Error, CustomStringConvertible {
    case shaderFunctionMissing(String)
    case vertexBufferCreationFailed
    case samplerCreationFailed
    case renderEncoderCreationFailed

    var description: String {
        switch self {
        case let .shaderFunctionMissing(name):
            return "Metal shader function not found: \(name)"
        case .vertexBufferCreationFailed:
            return "Could not create the video-surface vertex buffer"
        case .samplerCreationFailed:
            return "Could not create the video-surface sampler"
        case .renderEncoderCreationFailed:
            return "Could not create the video render encoder"
        }
    }
}

private struct VideoVertex {
    var position: SIMD3<Float>
    var uv: SIMD2<Float>
}

private struct VideoUniforms {
    var viewProjection: simd_float4x4
}

final class VideoRenderer {
    let geometry: VideoSurfaceGeometry

    private let pipelineState: any MTLRenderPipelineState
    private let samplerState: any MTLSamplerState
    private let vertexBuffer: any MTLBuffer

    init(
        device: any MTLDevice,
        swapchain: XRSwapchain,
        displaySize: CGSize
    ) throws {
        self.geometry = VideoSurfaceGeometry(displaySize: displaySize)

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard let vertexFunction = library.makeFunction(name: "video_vertex") else {
            throw VideoRendererError.shaderFunctionMissing("video_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "video_fragment") else {
            throw VideoRendererError.shaderFunctionMissing("video_fragment")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "SwiftXR video pipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = swapchain.pixelFormat
        pipelineDescriptor.rasterSampleCount = 1
        self.pipelineState = try device.makeRenderPipelineState(
            descriptor: pipelineDescriptor
        )

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.label = "SwiftXR video sampler"
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw VideoRendererError.samplerCreationFailed
        }
        self.samplerState = sampler

        let c = geometry.center
        let halfWidth = geometry.widthMeters * 0.5
        let halfHeight = geometry.heightMeters * 0.5
        let vertices = [
            VideoVertex(
                position: SIMD3(c.x - halfWidth, c.y + halfHeight, c.z),
                uv: SIMD2(0, 0)
            ),
            VideoVertex(
                position: SIMD3(c.x - halfWidth, c.y - halfHeight, c.z),
                uv: SIMD2(0, 1)
            ),
            VideoVertex(
                position: SIMD3(c.x + halfWidth, c.y + halfHeight, c.z),
                uv: SIMD2(1, 0)
            ),
            VideoVertex(
                position: SIMD3(c.x + halfWidth, c.y - halfHeight, c.z),
                uv: SIMD2(1, 1)
            ),
        ]

        let buffer = vertices.withUnsafeBufferPointer { pointer -> (any MTLBuffer)? in
            guard let baseAddress = pointer.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: baseAddress,
                length: pointer.count * MemoryLayout<VideoVertex>.stride,
                options: []
            )
        }
        guard let buffer else {
            throw VideoRendererError.vertexBufferCreationFailed
        }
        buffer.label = "SwiftXR video surface vertices"
        self.vertexBuffer = buffer
    }

    func encode(
        frame: XRFrame,
        swapchainTexture: any MTLTexture,
        videoTexture: (any MTLTexture)?,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        guard frame.views.count >= 2 else { return }

        for eye in 0..<2 {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = swapchainTexture
            pass.colorAttachments[0].slice = eye
            pass.colorAttachments[0].level = 0
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: 1
            )

            guard let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: pass
            ) else {
                throw VideoRendererError.renderEncoderCreationFailed
            }

            encoder.label = eye == 0
                ? "SwiftXR video left eye"
                : "SwiftXR video right eye"
            encoder.setViewport(
                MTLViewport(
                    originX: 0,
                    originY: 0,
                    width: Double(swapchainTexture.width),
                    height: Double(swapchainTexture.height),
                    znear: 0,
                    zfar: 1
                )
            )

            if let videoTexture {
                encoder.setRenderPipelineState(pipelineState)
                encoder.setCullMode(.none)

                var uniforms = VideoUniforms(
                    viewProjection: frame.views[eye].viewProjectionMatrix(
                        nearZ: 0.05,
                        farZ: 50
                    )
                )
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(
                    &uniforms,
                    length: MemoryLayout<VideoUniforms>.stride,
                    index: 1
                )
                encoder.setFragmentTexture(videoTexture, index: 0)
                encoder.setFragmentSamplerState(samplerState, index: 0)
                encoder.drawPrimitives(
                    type: .triangleStrip,
                    vertexStart: 0,
                    vertexCount: 4
                )
            }

            encoder.endEncoding()
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VideoVertex {
        float3 position;
        float2 uv;
    };

    struct VideoUniforms {
        float4x4 viewProjection;
    };

    struct VideoVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VideoVertexOut video_vertex(
        uint vertexID [[vertex_id]],
        const device VideoVertex *vertices [[buffer(0)]],
        constant VideoUniforms &uniforms [[buffer(1)]])
    {
        VideoVertexOut output;
        VideoVertex input = vertices[vertexID];
        output.position = uniforms.viewProjection * float4(input.position, 1.0);
        output.uv = input.uv;
        return output;
    }

    fragment float4 video_fragment(
        VideoVertexOut input [[stage_in]],
        texture2d<float> video [[texture(0)]],
        sampler videoSampler [[sampler(0)]])
    {
        return video.sample(videoSampler, input.uv);
    }
    """
}
