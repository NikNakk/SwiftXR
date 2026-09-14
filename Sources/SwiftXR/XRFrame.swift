import COpenXR
import Metal

public struct XRVector3: Sendable, Hashable {
    public let x: Float
    public let y: Float
    public let z: Float
}

public struct XRQuaternion: Sendable, Hashable {
    public let x: Float
    public let y: Float
    public let z: Float
    public let w: Float
}

public struct XRPose: Sendable, Hashable {
    public let position: XRVector3
    public let orientation: XRQuaternion
}

public struct XRFov: Sendable, Hashable {
    public let angleLeft: Float
    public let angleRight: Float
    public let angleUp: Float
    public let angleDown: Float
}

public struct XRView: Sendable, Hashable {
    public let pose: XRPose
    public let fov: XRFov
}

public struct XRViewTrackingState: Sendable, Hashable {
    public let orientationValid: Bool
    public let positionValid: Bool
    public let orientationTracked: Bool
    public let positionTracked: Bool
}

public struct XRFrame: Sendable, Hashable {
    /// Runtime clock value identifying the predicted display time for this frame.
    public let predictedDisplayTime: Int64

    /// Predicted interval to the next display time, in nanoseconds.
    public let predictedDisplayPeriod: Int64

    /// Whether the runtime currently expects the application to render content.
    public let shouldRender: Bool

    /// Located views for the primary stereo view configuration.
    public let views: [XRView]

    public let trackingState: XRViewTrackingState
}

private func makeView(_ data: SwiftXRViewData) -> XRView {
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

private func makeFrame(
    timing: SwiftXRFrameTiming,
    locatedViews: SwiftXRLocatedViews
) -> XRFrame {
    var views: [XRView] = []
    if locatedViews.view_count > 0 {
        views.append(makeView(locatedViews.left))
    }
    if locatedViews.view_count > 1 {
        views.append(makeView(locatedViews.right))
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
    /// Run one OpenXR frame without submitting composition layers.
    public func nextFrame() throws -> XRFrame {
        guard isRunning else {
            throw XRError.sessionNotRunning
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

        try xrCheck(
            swiftxr_end_frame_empty(
                handle,
                timing.predicted_display_time,
                environmentBlendMode
            ),
            "xrEndFrame(empty)"
        )

        return makeFrame(timing: timing, locatedViews: locatedViews)
    }

    /// Run one rendered OpenXR frame using a stereo two-layer Metal array swapchain.
    ///
    /// SwiftXR owns the OpenXR acquire/wait/release and frame submission sequence.
    /// The application only encodes Metal work into the supplied command buffer.
    @discardableResult
    public func renderFrame(
        to swapchain: XRSwapchain,
        encode: (
            _ frame: XRFrame,
            _ texture: any MTLTexture,
            _ commandBuffer: any MTLCommandBuffer
        ) -> Void
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

        let frame = makeFrame(timing: timing, locatedViews: locatedViews)

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

            encode(
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

        try xrCheck(
            swiftxr_end_frame_projection(
                handle,
                localSpace.handle,
                swapchain.handle,
                timing.predicted_display_time,
                environmentBlendMode,
                &locatedViews,
                swapchain.width,
                swapchain.height
            ),
            "xrEndFrame(projection)"
        )

        return frame
    }
}
