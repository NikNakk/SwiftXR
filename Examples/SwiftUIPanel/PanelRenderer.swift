import Metal
import simd
import SwiftXR

private struct PanelVertex {
    var position: SIMD3<Float>
    var uv: SIMD2<Float>
}

private struct PanelUniforms {
    var viewProjection: simd_float4x4
    var pointer: SIMD4<Float>
}

final class PanelRenderer {
    private let pipeline: any MTLRenderPipelineState
    private let vertexBuffer: any MTLBuffer
    private let panelTexture: any MTLTexture
    private let vertexCount: Int

    var pointerPosition: SIMD2<Float>?

    init(
        device: any MTLDevice,
        swapchain: XRSwapchain,
        panelTexture: any MTLTexture,
        worldWidth: Float = 1.20,
        distance: Float = 1.80
    ) throws {
        self.panelTexture = panelTexture

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "panel_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "panel_fragment")
        descriptor.colorAttachments[0].pixelFormat = swapchain.pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let aspect = Float(panelTexture.height) / Float(panelTexture.width)
        let halfWidth = worldWidth * 0.5
        let halfHeight = worldWidth * aspect * 0.5
        let z = -distance

        let vertices: [PanelVertex] = [
            PanelVertex(position: SIMD3(-halfWidth,  halfHeight, z), uv: SIMD2(0, 0)),
            PanelVertex(position: SIMD3(-halfWidth, -halfHeight, z), uv: SIMD2(0, 1)),
            PanelVertex(position: SIMD3( halfWidth, -halfHeight, z), uv: SIMD2(1, 1)),
            PanelVertex(position: SIMD3(-halfWidth,  halfHeight, z), uv: SIMD2(0, 0)),
            PanelVertex(position: SIMD3( halfWidth, -halfHeight, z), uv: SIMD2(1, 1)),
            PanelVertex(position: SIMD3( halfWidth,  halfHeight, z), uv: SIMD2(1, 0)),
        ]
        vertexCount = vertices.count

        let buffer = vertices.withUnsafeBufferPointer { pointer -> (any MTLBuffer)? in
            guard let baseAddress = pointer.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: baseAddress,
                length: pointer.count * MemoryLayout<PanelVertex>.stride,
                options: []
            )
        }

        guard let buffer else {
            throw PanelRendererError.bufferCreationFailed
        }
        vertexBuffer = buffer
    }

    func encode(
        frame: XRFrame,
        texture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        guard frame.views.count >= 2 else { return }

        for eye in 0..<2 {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].slice = eye
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(
                red: 0.012,
                green: 0.016,
                blue: 0.026,
                alpha: 1
            )

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw PanelRendererError.encoderCreationFailed
            }

            let pointer = pointerPosition ?? .zero
            var uniforms = PanelUniforms(
                viewProjection: frame.views[eye].viewProjectionMatrix(
                    nearZ: 0.05,
                    farZ: 20
                ),
                pointer: SIMD4(
                    pointer.x,
                    pointer.y,
                    pointerPosition == nil ? 0 : 1,
                    Float(panelTexture.width) / Float(panelTexture.height)
                )
            )

            encoder.setRenderPipelineState(pipeline)
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<PanelUniforms>.stride,
                index: 1
            )
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<PanelUniforms>.stride,
                index: 1
            )
            encoder.setFragmentTexture(panelTexture, index: 0)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: vertexCount
            )
            encoder.endEncoding()
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct PanelVertex {
        float3 position;
        float2 uv;
    };

    struct PanelUniforms {
        float4x4 viewProjection;
        float4 pointer;
    };

    struct PanelVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex PanelVertexOut panel_vertex(
        uint vertexID [[vertex_id]],
        const device PanelVertex *vertices [[buffer(0)]],
        constant PanelUniforms &uniforms [[buffer(1)]])
    {
        PanelVertexOut output;
        PanelVertex input = vertices[vertexID];
        output.position = uniforms.viewProjection * float4(input.position, 1.0);
        output.uv = input.uv;
        return output;
    }

    fragment float4 panel_fragment(
        PanelVertexOut input [[stage_in]],
        constant PanelUniforms &uniforms [[buffer(1)]],
        texture2d<float> panel [[texture(0)]])
    {
        constexpr sampler panelSampler(
            address::clamp_to_edge,
            filter::linear
        );

        float4 color = panel.sample(panelSampler, input.uv);

        if (uniforms.pointer.z > 0.5) {
            float2 d = input.uv - uniforms.pointer.xy;
            d.x *= uniforms.pointer.w;
            float distance = length(d);

            if (distance < 0.010) {
                color = float4(1.0, 1.0, 1.0, 1.0);
            } else if (distance < 0.016) {
                color = float4(0.02, 0.02, 0.02, 1.0);
            }
        }

        return color;
    }
    """
}

enum PanelRendererError: Error {
    case bufferCreationFailed
    case encoderCreationFailed
}
