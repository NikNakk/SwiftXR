import Metal
import simd
import SwiftXR

private struct LogoVertex {
    var position: SIMD3<Float>
    var color: SIMD3<Float>
}

private struct LogoUniforms {
    var viewProjection: simd_float4x4
}

final class LogoRenderer {
    private let pipeline: any MTLRenderPipelineState
    private let ringBuffer: any MTLBuffer
    private let markBuffer: any MTLBuffer
    private let ringVertexCount: Int
    private let markVertexCount: Int

    init(device: any MTLDevice, swapchain: XRSwapchain) throws {
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "logo_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "logo_fragment")
        descriptor.colorAttachments[0].pixelFormat = swapchain.pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let ring = Self.makeRing()
        let mark = Self.makeMark()
        ringVertexCount = ring.count
        markVertexCount = mark.count

        guard
            let ringBuffer = device.makeBuffer(
                bytes: ring,
                length: ring.count * MemoryLayout<LogoVertex>.stride
            ),
            let markBuffer = device.makeBuffer(
                bytes: mark,
                length: mark.count * MemoryLayout<LogoVertex>.stride
            )
        else {
            throw LogoRendererError.bufferCreationFailed
        }

        self.ringBuffer = ringBuffer
        self.markBuffer = markBuffer
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
                red: 0.015,
                green: 0.020,
                blue: 0.032,
                alpha: 1
            )

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw LogoRendererError.encoderCreationFailed
            }

            var uniforms = LogoUniforms(
                viewProjection: frame.views[eye].viewProjectionMatrix(
                    nearZ: 0.05,
                    farZ: 20
                )
            )

            encoder.setRenderPipelineState(pipeline)
            encoder.setCullMode(.none)
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<LogoUniforms>.stride,
                index: 1
            )

            encoder.setVertexBuffer(ringBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(
                type: .line,
                vertexStart: 0,
                vertexCount: ringVertexCount
            )

            encoder.setVertexBuffer(markBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: markVertexCount
            )

            encoder.endEncoding()
        }
    }

    private static func makeRing() -> [LogoVertex] {
        let segments = 96
        let radius: Float = 0.48
        let center = SIMD3<Float>(0, 0, -1.85)
        let color = SIMD3<Float>(0.18, 0.72, 1.00)
        var vertices: [LogoVertex] = []
        vertices.reserveCapacity(segments * 2)

        for index in 0..<segments {
            let a0 = Float(index) / Float(segments) * 2 * .pi
            let a1 = Float(index + 1) / Float(segments) * 2 * .pi

            vertices.append(
                LogoVertex(
                    position: center + SIMD3(cos(a0) * radius, sin(a0) * radius, 0),
                    color: color
                )
            )
            vertices.append(
                LogoVertex(
                    position: center + SIMD3(cos(a1) * radius, sin(a1) * radius, 0),
                    color: color
                )
            )
        }

        return vertices
    }

    private static func makeMark() -> [LogoVertex] {
        var vertices: [LogoVertex] = []
        vertices += makeBar(
            angle: .pi / 4,
            color: SIMD3<Float>(1.00, 0.30, 0.20)
        )
        vertices += makeBar(
            angle: -.pi / 4,
            color: SIMD3<Float>(0.20, 0.78, 1.00)
        )
        return vertices
    }

    private static func makeBar(
        angle: Float,
        color: SIMD3<Float>
    ) -> [LogoVertex] {
        let halfLength: Float = 0.34
        let halfWidth: Float = 0.07
        let center = SIMD3<Float>(0, 0, -1.80)
        let direction = SIMD2<Float>(cos(angle), sin(angle))
        let normal = SIMD2<Float>(-direction.y, direction.x)

        func point(_ along: Float, _ across: Float) -> SIMD3<Float> {
            let p = direction * along + normal * across
            return center + SIMD3<Float>(p.x, p.y, 0)
        }

        let a = point(-halfLength, -halfWidth)
        let b = point( halfLength, -halfWidth)
        let c = point( halfLength,  halfWidth)
        let d = point(-halfLength,  halfWidth)

        return [
            LogoVertex(position: a, color: color),
            LogoVertex(position: b, color: color),
            LogoVertex(position: c, color: color),
            LogoVertex(position: a, color: color),
            LogoVertex(position: c, color: color),
            LogoVertex(position: d, color: color),
        ]
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct LogoVertex {
        float3 position;
        float3 color;
    };

    struct LogoUniforms {
        float4x4 viewProjection;
    };

    struct LogoVertexOut {
        float4 position [[position]];
        float3 color;
    };

    vertex LogoVertexOut logo_vertex(
        uint vertexID [[vertex_id]],
        const device LogoVertex *vertices [[buffer(0)]],
        constant LogoUniforms &uniforms [[buffer(1)]])
    {
        LogoVertexOut output;
        LogoVertex input = vertices[vertexID];
        output.position = uniforms.viewProjection * float4(input.position, 1.0);
        output.color = input.color;
        return output;
    }

    fragment float4 logo_fragment(LogoVertexOut input [[stage_in]])
    {
        return float4(input.color, 1.0);
    }
    """
}

enum LogoRendererError: Error {
    case bufferCreationFailed
    case encoderCreationFailed
}
