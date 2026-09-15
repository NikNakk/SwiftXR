@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import Darwin
import Foundation
import SwiftXR

@MainActor
private final class VideoPlayerAppDelegate: NSObject, NSApplicationDelegate {
    private let rawInput: String

    private var setupTask: Task<Void, Never>?
    private var instance: XRInstance?
    private var session: XRSession?
    private var swapchain: XRSwapchain?
    private var source: VideoSource?
    private var renderer: VideoRenderer?
    private var controller: VideoControllerInput?
    private var ambisonic: AmbisonicAudio?

    private var controlsModel: VideoControlsModel?
    private var controlsPanel: XRSwiftUIPanel<VideoControlsView>?
    private var controlsRenderer: VideoControlPanelRenderer?
    private var pointerCapture: XRMacPointerCapture?

    private var panelVisible = true
    private var lastPanelActivity = Date()
    private let panelAutoHideSeconds: TimeInterval = 4

    private var playbackStarted = false
    private var exitRequested = false
    private var frameIndex = 0
    private var decodedFrameCount = 0
    private var lastDecodedFrameTime: CMTime?
    private var lastSessionState: XRSessionState?
    private var lastControlsUpdate = Date.distantPast

    init(rawInput: String) {
        self.rawInput = rawInput
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        setupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.setUpPlayer()
                self.scheduleFrameStep()
            } catch {
                self.fail(error)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        do {
            try startPointerCaptureIfReady()
        } catch {
            fail(error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        setupTask?.cancel()
        pointerCapture?.stop()
        source?.pause()
        ambisonic?.pause()
        if session?.isRunning == true && !exitRequested {
            try? session?.requestExit()
        }
    }

    private func setUpPlayer() async throws {
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
        let model = VideoControlsModel(
            title: resolved.url.deletingPathExtension().lastPathComponent,
            projectionMode: projectionMode
        )
        model.commandHandler = { [weak self] command in
            guard let self else { return }
            do {
                try self.handle(command)
            } catch {
                self.fail(error)
            }
        }

        let panel = try XRSwiftUIPanel(
            device: session.device,
            pointSize: CGSize(width: 662, height: 257),
            scale: 2,
            interactionHandler: { [weak self] _ in
                self?.notePanelActivity()
            }
        ) {
            VideoControlsView(model: model)
        }
        let controlsRenderer = try VideoControlPanelRenderer(
            device: session.device,
            swapchain: swapchain,
            panelTexture: panel.texture
        )
        let pointerCapture = XRMacPointerCapture(panel: panel)

        self.instance = instance
        self.session = session
        self.swapchain = swapchain
        self.source = source
        self.renderer = renderer
        self.controller = controller
        self.ambisonic = ambisonic
        self.controlsModel = model
        self.controlsPanel = panel
        self.controlsRenderer = controlsRenderer
        self.pointerCapture = pointerCapture
        self.lastSessionState = session.state

        _ = model.update(
            isPlaying: false,
            currentTime: source.currentTimeSeconds,
            duration: source.durationSeconds ?? 0,
            volume: source.volume,
            projectionMode: renderer.projectionMode,
            spatialAudioEnabled: ambisonic != nil
        )
        panel.invalidate()

        print("Projection override: SWIFTXR_VIDEO_PROJECTION=flat|vr180|fisheye|eac360")
        print("Move the mouse to show controls; Escape exits")
    }

    @objc
    private func frameStep() {
        guard
            let session,
            let swapchain,
            let source,
            let renderer,
            let controller,
            let controlsPanel,
            let controlsRenderer,
            let pointerCapture
        else {
            return
        }

        do {
            for state in try session.pollEvents() where state != lastSessionState {
                print("Session state: \(state)")
                lastSessionState = state
            }

            if session.shouldExit {
                pointerCapture.stop()
                NSApplication.shared.terminate(nil)
                return
            }

            if pointerCapture.escapeRequested {
                try requestSessionExitIfNeeded()
                scheduleFrameStep(after: 0.005)
                return
            }

            guard session.isRunning else {
                if playbackStarted {
                    source.pause()
                    ambisonic?.pause()
                    playbackStarted = false
                }
                scheduleFrameStep(after: 0.005)
                return
            }

            try startPointerCaptureIfReady()
            if !playbackStarted {
                try startPlayback()
                playbackStarted = true
                print("OpenXR session running; playback started")
            }

            if let failure = source.failureDescription {
                throw NSError(
                    domain: "SwiftXR.VideoPlayer",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "AVPlayer failed: \(failure)"]
                )
            }

            pointerCapture.poll()
            try applyController(controller.poll())
            updatePanelVisibility()
            updateControlsModelIfNeeded()
            try controlsPanel.refreshIfNeeded()

            let videoFrame = try source.latestFrame()
            if let videoFrame, videoFrame.itemTime != lastDecodedFrameTime {
                decodedFrameCount += 1
                lastDecodedFrameTime = videoFrame.itemTime
            }

            let showControls = panelVisible
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
                if showControls {
                    try controlsRenderer.encode(
                        frame: xrFrame,
                        swapchainTexture: texture,
                        panelTexture: controlsPanel.texture,
                        pointerPosition: controlsPanel.interaction.pointerPosition,
                        commandBuffer: commandBuffer
                    )
                }
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
                if let videoFrame {
                    print(
                        String(
                            format: "XR frame %d: video=%dx%d t=%.2fs rate=%.2f decoded=%d XR period=%.3f ms",
                            frameIndex,
                            videoFrame.texture.width,
                            videoFrame.texture.height,
                            source.currentTimeSeconds,
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
                            source.currentTimeSeconds,
                            source.playbackRate,
                            source.itemStatusDescription,
                            periodMS
                        )
                    )
                }
            }

            frameIndex += 1
            scheduleFrameStep()
        } catch {
            fail(error)
        }
    }

    private func startPlayback() throws {
        guard let source else { return }
        if let ambisonic {
            try ambisonic.startSynchronized(
                videoPlayer: source.player,
                mediaTimeSeconds: source.currentTimeSeconds
            )
        } else {
            source.play()
        }
    }

    private func handle(_ command: VideoControlCommand) throws {
        guard let source, let renderer else { return }
        notePanelActivity()

        switch command {
        case .togglePlayback:
            if source.isPlaying {
                source.pause()
                ambisonic?.pause()
                print("[controls] pause")
            } else {
                try startPlayback()
                print("[controls] play")
            }

        case let .seekBy(delta):
            try seek(to: source.currentTimeSeconds + delta)

        case let .seekTo(target):
            try seek(to: target)

        case let .setVolume(value):
            source.setVolume(value)
            ambisonic?.setVolume(value)

        case .recenter:
            renderer.recenter()
            print("[controls] recenter")

        case let .setProjection(mode):
            renderer.setProjectionMode(mode)
            controlsPanel?.invalidate()
        }
    }

    private func seek(to requestedTime: Double) throws {
        guard let source else { return }
        var target = max(0, requestedTime)
        if let duration = source.durationSeconds {
            target = min(target, duration)
        }

        if let ambisonic, source.isPlaying {
            try ambisonic.startSynchronized(
                videoPlayer: source.player,
                mediaTimeSeconds: target
            )
        } else {
            source.player.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
        print(String(format: "[controls] seek %.2fs", target))
    }

    private func applyController(_ controls: VideoControllerSnapshot) throws {
        if controls.menu {
            panelVisible.toggle()
            lastPanelActivity = Date()
            controlsPanel?.invalidate()
        }
        if controls.back {
            panelVisible = false
        }
        if controls.togglePlay {
            try handle(.togglePlayback)
        }
        if controls.seekSteps != 0 {
            try handle(.seekBy(Double(controls.seekSteps) * 15))
        }
        if controls.volumeSteps != 0, let source {
            try handle(.setVolume(source.volume + Float(controls.volumeSteps) * 0.05))
        }
        if controls.recenter {
            try handle(.recenter)
        }

        let stickX = stickAfterDeadZone(controls.rightX)
        let stickY = stickAfterDeadZone(controls.rightY)
        if stickX != 0 || stickY != 0 {
            let yaw = stickX * abs(stickX) * 0.010
            let pitch = -stickY * abs(stickY) * 0.010
            renderer?.tilt(yawRadians: yaw, pitchRadians: pitch)
        }
    }

    private func updateControlsModelIfNeeded() {
        guard
            Date().timeIntervalSince(lastControlsUpdate) >= 0.20,
            let model = controlsModel,
            let source,
            let renderer
        else { return }

        lastControlsUpdate = Date()
        let changed = model.update(
            isPlaying: source.isPlaying,
            currentTime: source.currentTimeSeconds,
            duration: source.durationSeconds ?? 0,
            volume: source.volume,
            projectionMode: renderer.projectionMode,
            spatialAudioEnabled: ambisonic != nil
        )
        if changed, panelVisible {
            controlsPanel?.invalidate()
        }
    }

    private func notePanelActivity() {
        panelVisible = true
        lastPanelActivity = Date()
        controlsPanel?.invalidate()
    }

    private func updatePanelVisibility() {
        guard panelVisible, controlsModel?.isScrubbing != true else { return }
        if Date().timeIntervalSince(lastPanelActivity) >= panelAutoHideSeconds {
            panelVisible = false
        }
    }

    private func startPointerCaptureIfReady() throws {
        guard
            NSApplication.shared.isActive,
            session?.isRunning == true,
            let pointerCapture,
            !pointerCapture.isCaptureRequested
        else {
            return
        }

        try pointerCapture.start()
        guard pointerCapture.isCaptured else {
            throw XRMacPointerCaptureError.applicationNotActive
        }
    }

    private func requestSessionExitIfNeeded() throws {
        guard !exitRequested else { return }
        exitRequested = true
        pointerCapture?.stop()
        source?.pause()
        ambisonic?.pause()

        if session?.isRunning == true {
            try session?.requestExit()
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    private func scheduleFrameStep(after delay: TimeInterval = 0) {
        perform(
            #selector(frameStep),
            with: nil,
            afterDelay: delay,
            inModes: [.common, .eventTracking]
        )
    }

    private func fail(_ error: Error) {
        fputs("swiftxr-video: \(error)\n", stderr)
        pointerCapture?.stop()
        source?.pause()
        ambisonic?.pause()

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "SwiftXR Video Player"
        alert.informativeText = String(describing: error)
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }

    private func stickAfterDeadZone(_ value: Float) -> Float {
        let deadZone: Float = 0.18
        guard abs(value) > deadZone else { return 0 }
        let scaled = (abs(value) - deadZone) / (1 - deadZone)
        return value.sign == .minus ? -scaled : scaled
    }
}

@main
struct SwiftXRVideoPlayer {
    @MainActor
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs(
                "usage: swiftxr-video /path/to/movie.mp4\n       swiftxr-video https://youtube.com/watch?v=...\n",
                stderr
            )
            exit(2)
        }

        let application = XRMacApplication.shared
        application.setActivationPolicy(.regular)

        let appDelegate = VideoPlayerAppDelegate(rawInput: CommandLine.arguments[1])
        application.delegate = appDelegate

        withExtendedLifetime(appDelegate) {
            application.run()
        }
    }
}
