import COpenXR
import Metal

/// The role a session plays in a multi-application OpenXR runtime.
public enum XRSessionKind: Sendable, Hashable {
    case primary
    case overlay(layerPlacement: UInt32)
}

/// Composition-layer behavior used when submitting an OpenXR frame.
public struct XRCompositionLayerOptions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Blend the submitted texture using its source alpha.
    public static let blendTextureSourceAlpha = Self(
        rawValue: swiftxr_composition_layer_blend_texture_source_alpha_bit()
    )
}

private func makeOverlayView(_ data: SwiftXRViewData) -> XRView {
    XRView(
        pose: XRPose(
            position: XRVector3(
                x: data.position_x,
                y: data.position_y,
                z: data.position_z
            ),
            orientation: XRQuaternion(
                x: data.orientation_x,
                y: data.orientation_y,
                z: data.orientation_z,
                w: data.orientation_w
            )
        ),
        fov: XRFov(
            angleLeft: data.angle_left,
            angleRight: data.angle_right,
            angleUp: data.angle_up,
            angleDown: data.angle_down
        )
    )
}

private func makeOverlayFrame(
    timing: SwiftXRFrameTiming,
    locatedViews: SwiftXRLocatedViews
) -> XRFrame {
    var views: [XRView] = []
    if locatedViews.view_count > 0 {
        views.append(makeOverlayView(locatedViews.left))
    }
    if locatedViews.view_count > 1 {
        views.append(makeOverlayView(locatedViews.right))
    }

    return XRFrame(
        predictedDisplayTime: timing.predicted_display_time,
        predictedDisplayPeriod: timing.predicted_display_period,
        shouldRender: timing.should_render != 0,
        views: views,
        trackingState: XRViewTrackingState(
            orientationValid: locatedViews.orientation_valid != 0,
            positionValid: locatedViews.position_valid != 0,
            orientationTracked: locatedViews.orientation_tracked != 0,
            positionTracked: locatedViews.position_tracked != 0
        )
    )
}

extension XRSession {
    /// Render a frame with explicit composition-layer options.
    ///
    /// This is primarily useful for overlay sessions, where the projection
    /// layer normally needs `.blendTextureSourceAlpha` so pixels outside the
    /// overlay surface remain transparent over the main application.
    @discardableResult
    public func renderFrame(
        to swapchain: XRSwapchain,
        compositionLayerOptions: XRCompositionLayerOptions,
        encode: (
            _ frame: XRFrame,
            _ texture: any MTLTexture,
            _ commandBuffer: any MTLCommandBuffer
        ) throws -> Void
    ) throws -> XRFrame {
        guard isRunning else {
            throw XRError.sessionNotRunning
        }
        guard swapchain.session === self else {
            throw XRSwapchainError.belongsToDifferentSession
        }

        var timing = SwiftXRFrameTiming()
        try xrCheck(
            swiftxr_wait_frame(handle, &timing),
            "xrWaitFrame"
        )

        try xrCheck(
            swiftxr_begin_frame(handle),
            "xrBeginFrame"
        )

        var locatedViews = SwiftXRLocatedViews()
        do {
            try xrCheck(
                swiftxr_locate_stereo_views(
                    handle,
                    localSpace.handle,
                    timing.predicted_display_time,
                    &locatedViews
                ),
                "xrLocateViews(PRIMARY_STEREO)"
            )
        } catch {
            _ = swiftxr_end_frame_empty(
                handle,
                timing.predicted_display_time,
                environmentBlendMode
            )
            throw error
        }

        let frame = makeOverlayFrame(timing: timing, locatedViews: locatedViews)

        guard frame.shouldRender, locatedViews.view_count == 2 else {
            try xrCheck(
                swiftxr_end_frame_empty(
                    handle,
                    timing.predicted_display_time,
                    environmentBlendMode
                ),
                "xrEndFrame(empty)"
            )
            return frame
        }

        var imageIndex: UInt32 = 0
        var imageAcquired = false

        do {
            try xrCheck(
                swiftxr_acquire_swapchain_image(
                    swapchain.handle,
                    &imageIndex
                ),
                "xrAcquireSwapchainImage"
            )
            imageAcquired = true

            try xrCheck(
                swiftxr_wait_swapchain_image(swapchain.handle),
                "xrWaitSwapchainImage"
            )

            guard Int(imageIndex) < swapchain.textures.count else {
                throw XRSwapchainError.imageIndexOutOfRange(imageIndex)
            }

            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw XRSwapchainError.commandBufferCreationFailed
            }

            try encode(
                frame,
                swapchain.textures[Int(imageIndex)],
                commandBuffer
            )
            commandBuffer.commit()
            swapchain.lastCommandBuffer = commandBuffer

            try xrCheck(
                swiftxr_release_swapchain_image(swapchain.handle),
                "xrReleaseSwapchainImage"
            )
            imageAcquired = false

            try xrCheck(
                swiftxr_end_frame_projection_with_flags(
                    handle,
                    localSpace.handle,
                    swapchain.handle,
                    timing.predicted_display_time,
                    environmentBlendMode,
                    &locatedViews,
                    swapchain.width,
                    swapchain.height,
                    compositionLayerOptions.rawValue
                ),
                "xrEndFrame(projection)"
            )
        } catch {
            if imageAcquired {
                _ = swiftxr_release_swapchain_image(swapchain.handle)
            }
            _ = swiftxr_end_frame_empty(
                handle,
                timing.predicted_display_time,
                environmentBlendMode
            )
            throw error
        }

        return frame
    }
}
