@preconcurrency import AVFoundation
import CoreMedia
import Darwin
import Foundation
import SwiftXR

@main
struct SwiftXRVideoPlayer {
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("swiftxr-video: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: swiftxr-video /path/to/movie.mp4\n       swiftxr-video https://youtube.com/watch?v=...\n", stderr)
            exit(2)
        }

        let rawInput = CommandLine.arguments[1]
        print("SwiftXR video player")
        print("Input: \(rawInput)")

        let resolved = try MediaInputResolver.resolve(rawInput)
        print("Resolved media: \(resolved.url.path)")
        let projectionMode = VideoProjectionMode.resolve(
            inputPath: resolved.url.path,
            youtubeEACHint: resolved.youtubeEACHint
        )
        print("Projection: \(projectionMode)")

        let capabilities = try XRRuntime.capabilities()
        try capabilities.requireMetal()

        let instance = try XRInstance(applicationName: "SwiftXR Video Player")
        print("Runtime: \(instance.runtime.name) \(instance.runtime.version)")

        let system = try instance.system()
        print("OpenXR system: \(system.info.name)")

        let session = try system.makeSession()
        let swapchain = try session.makeStereoSwapchain()
        print("Runtime Metal device: \(session.device.name)")
        print("XR swapchain: \(swapchain.width)x\(swapchain.height), arraySize=2")

        print("Opening video with AVFoundation…")
        let source = try await VideoSource.open(url: resolved.url, device: session.device)
        let aspect = source.displaySize.width / max(source.displaySize.height, 1)
        print(
            String(
                format: "Video display size: %.0fx%.0f (aspect %.3f)",
                source.displaySize.width,
                source.displaySize.height,
                aspect
            )
        )
        if let duration = source.durationSeconds {
            print(String(format: "Duration: %.2f s", duration))
        }

        print("Waiting for AVPlayerItem readiness…")
        try await source.waitUntilReady()
        print("AVPlayerItem status: \(source.itemStatusDescription)")

        _ = VideoAudioRouting.routeToPSVR2(source.player)

        var ambisonic: AmbisonicAudio?
        if let sidecar = resolved.ambisonicURL {
            do {
                let spatial = try AmbisonicAudio(sidecarURL: sidecar)
                spatial.setVolume(source.volume)
                source.player.isMuted = true
                source.player.automaticallyWaitsToMinimizeStalling = false
                ambisonic = spatial
            } catch {
                fputs("[audio] AmbiX unavailable (\(error)); using stereo AVPlayer audio\n", stderr)
                source.player.isMuted = false
                source.player.automaticallyWaitsToMinimizeStalling = true
            }
        }

        let renderer = try VideoRenderer(
            device: session.device,
            swapchain: swapchain,
            displaySize: source.displaySize,
            projectionMode: projectionMode
        )
        if projectionMode == .flat {
            print(
                String(
                    format: "Virtual screen: %.2f m × %.2f m at %.1f m in LOCAL space",
                    renderer.geometry.widthMeters,
                    renderer.geometry.heightMeters,
                    -renderer.geometry.center.z
                )
            )
        } else {
            print("Immersive scene will anchor to initial headset gaze")
        }

        let controller = VideoControllerInput()

        try await waitForSessionToRun(session)

        guard session.isRunning else {
            if session.shouldExit {
                print("Runtime requested exit before playback started")
            } else {
                print("OpenXR session did not reach READY within 10 seconds")
            }
            return
        }

        try startPlayback(source: source, ambisonic: ambisonic)
        print("OpenXR session running; playback started")
        print("Projection override: SWIFTXR_VIDEO_PROJECTION=flat|vr180|fisheye|eac360")
        print("Press Ctrl-C to stop")

        try renderVideo(
            session: session,
            swapchain: swapchain,
            source: source,
            renderer: renderer,
            controller: controller,
            ambisonic: ambisonic
        )
    }

    @MainActor
    private static func waitForSessionToRun(_ session: XRSession) async throws {
        let deadline = Date().addingTimeInterval(10)
        var lastState = session.state
        print("Initial OpenXR session state: \(lastState)")

        while !session.isRunning && !session.shouldExit && Date() < deadline {
            for state in try session.pollEvents() where state != lastState {
                print("Session state: \(state)")
                lastState = state
            }

            if !session.isRunning && !session.shouldExit {
                try await Task<Never, Never>.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    @MainActor
    private static func startPlayback(
        source: VideoSource,
        ambisonic: AmbisonicAudio?
    ) throws {
        if let ambisonic {
            try ambisonic.startSynchronized(
                videoPlayer: source.player,
                mediaTimeSeconds: source.currentTimeSeconds
            )
        } else {
            source.play()
        }
    }

    @MainActor
    private static func renderVideo(
        session: XRSession,
        swapchain: XRSwapchain,
        source: VideoSource,
        renderer: VideoRenderer,
        controller: VideoControllerInput,
        ambisonic: AmbisonicAudio?
    ) throws {
        var frameIndex = 0
        var decodedFrameCount = 0
        var lastFrameTime: CMTime?
        var lastState = session.state

        while session.isRunning && !session.shouldExit {
            // Match the working GAV OpenXR player: keep Foundation/AppKit media
            // and GameController delivery alive while xrWaitFrame drives the loop.
            _ = RunLoop.current.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0)
            )

            for state in try session.pollEvents() where state != lastState {
                print("Session state: \(state)")
                lastState = state
            }

            guard session.isRunning && !session.shouldExit else { break }

            if let failure = source.failureDescription {
                throw NSError(
                    domain: "SwiftXR.VideoPlayer",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "AVPlayer failed: \(failure)"]
                )
            }

            let controls = controller.poll()
            try applyControls(
                controls,
                source: source,
                renderer: renderer,
                ambisonic: ambisonic
            )

            let videoFrame = try source.latestFrame()
            if let videoFrame, videoFrame.itemTime != lastFrameTime {
                decodedFrameCount += 1
                lastFrameTime = videoFrame.itemTime
            }

            let frame = try session.renderFrame(to: swapchain) {
                xrFrame,
                texture,
                commandBuffer in
                try renderer.encode(
                    frame: xrFrame,
                    swapchainTexture: texture,
                    videoTexture: videoFrame?.texture,
                    commandBuffer: commandBuffer
                )
            }

            if let ambisonic,
               frame.trackingState.orientationValid,
               let view = frame.views.first {
                ambisonic.updateHeadOrientation(
                    from: view,
                    sceneAnchor: renderer.sceneAnchor
                )
            }

            if frameIndex % 180 == 0 {
                let periodMS = Double(frame.predictedDisplayPeriod) / 1_000_000.0
                let playback = source.currentTimeSeconds
                if let videoFrame {
                    print(
                        String(
                            format: "XR frame %d: video=%dx%d t=%.2fs rate=%.2f decoded=%d XR period=%.3f ms",
                            frameIndex,
                            videoFrame.texture.width,
                            videoFrame.texture.height,
                            playback,
                            source.playbackRate,
                            decodedFrameCount,
                            periodMS
                        )
                    )
                } else {
                    print(
                        String(
                            format: "XR frame %d: NO VIDEO FRAME t=%.2fs rate=%.2f item=%@ XR period=%.3f ms",
                            frameIndex,
                            playback,
                            source.playbackRate,
                            source.itemStatusDescription,
                            periodMS
                        )
                    )
                }
            }

            frameIndex += 1
        }

        source.pause()
        ambisonic?.pause()
        print("Rendered \(frameIndex) XR frames using \(decodedFrameCount) decoded video frames")
    }

    @MainActor
    private static func applyControls(
        _ controls: VideoControllerSnapshot,
        source: VideoSource,
        renderer: VideoRenderer,
        ambisonic: AmbisonicAudio?
    ) throws {
        if controls.togglePlay {
            if source.isPlaying {
                source.pause()
                ambisonic?.pause()
                print("[controller] pause")
            } else {
                try startPlayback(source: source, ambisonic: ambisonic)
                print("[controller] play")
            }
        }

        if controls.seekSteps != 0 {
            let delta = Double(controls.seekSteps) * 15
            if let ambisonic, source.isPlaying {
                var target = max(0, source.currentTimeSeconds + delta)
                if let duration = source.durationSeconds {
                    target = min(target, duration)
                }
                try ambisonic.startSynchronized(
                    videoPlayer: source.player,
                    mediaTimeSeconds: target
                )
            } else {
                source.seek(by: delta)
            }
            print(String(format: "[controller] seek %+.0fs", delta))
        }

        if controls.volumeSteps != 0 {
            source.adjustVolume(by: Float(controls.volumeSteps) * 0.05)
            ambisonic?.setVolume(source.volume)
            print(String(format: "[controller] volume %.0f%%", source.volume * 100))
        }

        if controls.recenter {
            renderer.recenter()
            print("[controller] recenter")
        }

        let stickX = stickAfterDeadZone(controls.rightX)
        let stickY = stickAfterDeadZone(controls.rightY)
        if stickX != 0 || stickY != 0 {
            let yaw = stickX * abs(stickX) * 0.010
            let pitch = -stickY * abs(stickY) * 0.010
            renderer.tilt(yawRadians: yaw, pitchRadians: pitch)
        }
    }

    private static func stickAfterDeadZone(_ value: Float) -> Float {
        let deadZone: Float = 0.18
        guard abs(value) > deadZone else { return 0 }
        let scaled = (abs(value) - deadZone) / (1 - deadZone)
        return value.sign == .minus ? -scaled : scaled
    }
}
