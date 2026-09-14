import Darwin
import simd

public extension XRVector3 {
    var simdValue: SIMD3<Float> {
        SIMD3(x, y, z)
    }
}

public extension XRQuaternion {
    var simdValue: simd_quatf {
        simd_quatf(ix: x, iy: y, iz: z, r: w)
    }
}

public extension XRPose {
    /// Transform from this OpenXR pose's local coordinates into its reference space.
    var transformMatrix: simd_float4x4 {
        var matrix = simd_float4x4(orientation.simdValue)
        matrix.columns.3 = SIMD4(
            position.x,
            position.y,
            position.z,
            1.0
        )
        return matrix
    }

    /// View matrix for rendering the world from this OpenXR pose.
    var viewMatrix: simd_float4x4 {
        simd_inverse(transformMatrix)
    }
}

public extension XRFov {
    /// Build an off-axis right-handed projection matrix for Metal.
    ///
    /// OpenXR view coordinates are right-handed with -Z forward. Metal's
    /// normalized device depth range is 0...1, so this differs from the
    /// traditional OpenGL -1...1 depth projection.
    func projectionMatrix(
        nearZ: Float = 0.05,
        farZ: Float = 100.0
    ) -> simd_float4x4 {
        precondition(nearZ > 0, "nearZ must be greater than zero")
        precondition(farZ > nearZ, "farZ must be greater than nearZ")

        let tanLeft = tan(angleLeft)
        let tanRight = tan(angleRight)
        let tanDown = tan(angleDown)
        let tanUp = tan(angleUp)

        let tanWidth = tanRight - tanLeft
        let tanHeight = tanUp - tanDown

        let xScale = 2.0 / tanWidth
        let yScale = 2.0 / tanHeight
        let xOffset = (tanRight + tanLeft) / tanWidth
        let yOffset = (tanUp + tanDown) / tanHeight

        let zScale = farZ / (nearZ - farZ)
        let zTranslate = (farZ * nearZ) / (nearZ - farZ)

        return simd_float4x4(
            SIMD4(xScale, 0, 0, 0),
            SIMD4(0, yScale, 0, 0),
            SIMD4(xOffset, yOffset, zScale, -1),
            SIMD4(0, 0, zTranslate, 0)
        )
    }
}

public extension XRView {
    var viewMatrix: simd_float4x4 {
        pose.viewMatrix
    }

    func projectionMatrix(
        nearZ: Float = 0.05,
        farZ: Float = 100.0
    ) -> simd_float4x4 {
        fov.projectionMatrix(nearZ: nearZ, farZ: farZ)
    }

    func viewProjectionMatrix(
        nearZ: Float = 0.05,
        farZ: Float = 100.0
    ) -> simd_float4x4 {
        projectionMatrix(nearZ: nearZ, farZ: farZ) * viewMatrix
    }
}
