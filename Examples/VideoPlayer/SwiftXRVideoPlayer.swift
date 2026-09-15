@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import Darwin
import Foundation
import SwiftXR

@MainActor
private final class VideoPlayerAppDelegate: NSObject, NSApplicationDelegate {
    private let initialInput: String?

    private var setupTask: Task<Void, Never>?
    private var mediaOpenTask: Task<Void, Never>?
    private var mediaOpenGeneration = 0

    private var instance: XRInstance?
    private var session: XRSession?
    private var swapchain: XRSwapchain?
    private var source: VideoSource?
    private var renderer: VideoRenderer?
    private var controller: VideoControllerInput?
    private var ambisonic: AmbisonicAudio?

    private var controlsModel: VideoControlsModel?
    private var libraryModel: VideoLibraryModel?
    private var panel: XRSwiftUIPanel<VideoPlayerRootView>?
    private var panelRenderer: VideoControlPanelRenderer?
    private var pointerCapture: XRMacPointerCapture?
    private var youtubeBrowser: YouTubeBrowserController?

    private var panelVisible = true
    private var lastPanelActivity = Date()
    private let panelAutoHideSeconds: TimeInterval = 4
    private var lastYouTubeControllerUpdate = Date()

    private var playbackStarted = false
    private var exitRequested = false
    private var frameIndex = 0
    private var decodedFrameCount = 0
    private var lastDecodedFrameTime: CMTime?
    private var lastSessionState: XRSessionState?
    private var lastControlsUpdate = Date.distantPast

    init(initialInput: String?) {
        self.initialInput = initialInput
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        setupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.setUpXRAndUI()
                if let initialInput {
                    self.beginOpenMedia(initialInput)
                } else {
                    self.libraryModel?.openInitialDirectory()
                    self.panel?.invalidate()
                    print("No media argument: opening in-headset file browser")
                }
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
        mediaOpenTask?.cancel()
        youtubeBrowser?.shutdown()
        pointerCapture?.stop()
        source?.pause()
        ambisonic?.pause()
        if session?.isRunning == true && !exitRequested {
            try? session?.requestExit()
        }
    }

    private func setUpXRAndUI() throws {
        print("SwiftXR video player")

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

        let controls = VideoControlsModel(
            title: "SwiftXR",
            projectionMode: .flat,
            stereoLayout: .mono
        )
        controls.commandHandler = { [weak self] command in
            guard let self else { return }
            do {
                try self.handle(command)
            } catch {
                self.fail(error)
            }
        }

        let library = VideoLibraryModel()
        library.openMedia = { [weak self] input in
            self?.beginOpenMedia(input)
        }
        library.openYouTube = { [weak self] in
            self?.enterYouTubeBrowser()
        }

        let youtube = YouTubeBrowserController()
        youtube.onSnapshot = { [weak self] image in
            guard let self else { return }
            self.libraryModel?.setYouTubeSnapshot(image)
            self.panel?.invalidate()
        }
        youtube.onStatus = { [weak self] status in
            guard let self else { return }
            self.libraryModel?.setYouTubeStatus(status)
            self.panel?.invalidate()
        }
        youtube.onLaunchURL = { [weak self] url in
            self?.beginOpenMedia(url)
        }

        let panel = try XRSwiftUIPanel(
            device: session.device,
            pointSize: CGSize(
                width: YouTubeBrowserController.width,
                height: YouTubeBrowserController.height
            ),
            scale: 1,
            interactionHandler: { [weak self] event in
                self?.handlePanelInteraction(event)
            }
        ) {
            VideoPlayerRootView(library: library, controls: controls)
        }
        let panelRenderer = try VideoControlPanelRenderer(
            device: session.device,
            swapchain: swapchain,
            panelTexture: panel.texture
        )
        let pointerCapture = XRMacPointerCapture(panel: panel)
        let controller = VideoControllerInput()

        self.instance = instance
        self.session = session
        self.swapchain = swapchain
        self.controlsModel = controls
        self.libraryModel = library
        self.panel = panel
        self.panelRenderer = panelRenderer
        self.pointerCapture = pointerCapture
        self.youtubeBrowser = youtube
        self.controller = controller
        self.lastSessionState = session.state

        print("Projection override: SWIFTXR_VIDEO_PROJECTION=flat|vr180|fisheye|eac360")
        print("Stereo override: SWIFTXR_VIDEO_STEREO=mono|sbs|tb")
        print("No argument opens Files; explicit file/YouTube arguments still open directly")
        print("Move the mouse to interact; Escape exits")
    }

    private func beginOpenMedia(_ input: String) {
        guard let session else { return }

        mediaOpenGeneration += 1
        let generation = mediaOpenGeneration
        mediaOpenTask?.cancel()

        libraryModel?.showLoading(input.hasPrefix("http") ? "Resolving YouTube video…" : "Opening video…")
        panelVisible = true
        panel?.invalidate()
        youtubeBrowser?.close()

        source?.pause()
        ambisonic?.pause()
        playbackStarted = false

        mediaOpenTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let resolved = try await Task.detached(priority: .userInitiated) {
                    try MediaInputResolver.resolve(input)
                }.value
                try Task.checkCancellation()
                guard generation == self.mediaOpenGeneration else { return }

                print("Resolved media: \(resolved.url.path)")
                let projectionMode = VideoProjectionMode.resolve(
                    inputPath: resolved.url.path,
                    youtubeEACHint: resolved.youtubeEACHint
                )
                print("Projection: \(projectionMode)")

                print("Opening video with AVFoundation…")
                let newSource = try await VideoSource.open(
                    url: resolved.url,
                    device: session.device
                )
                try await newSource.waitUntilReady()
                try Task.checkCancellation()
                guard generation == self.mediaOpenGeneration else { return }

                let aspect = newSource.displaySize.width / max(newSource.displaySize.height, 1)
                print(
                    String(
                        format: "Video display size: %.0fx%.0f (aspect %.3f)",
                        newSource.displaySize.width,
                        newSource.displaySize.height,
                        aspect
                    )
                )
                if let duration = newSource.durationSeconds {
                    print(String(format: "Duration: %.2f s", duration))
                }

                let stereoLayout = VideoStereoLayout.resolve(
                    inputPath: resolved.url.path,
                    projectionMode: projectionMode,
                    displaySize: newSource.displaySize
                )
                print("Stereo layout: \(stereoLayout)")

                _ = VideoAudioRouting.routeToPSVR2(newSource.player)

                var newAmbisonic: AmbisonicAudio?
                if let sidecar = resolved.ambisonicURL {
                    do {
                        let spatial = try AmbisonicAudio(sidecarURL: sidecar)
                        spatial.setVolume(newSource.volume)
                        newSource.player.isMuted = true
                        newSource.player.automaticallyWaitsToMinimizeStalling = false
                        newAmbisonic = spatial
                    } catch {
                        fputs("[audio] AmbiX unavailable (\(error)); using stereo AVPlayer audio\n", stderr)
                        newSource.player.isMuted = false
                        newSource.player.automaticallyWaitsToMinimizeStalling = true
                    }
                }

                let newRenderer = try VideoRenderer(
                    device: session.device,
                    swapchain: self.swapchain!,
                    displaySize: newSource.displaySize,
                    projectionMode: projectionMode,
                    stereoLayout: stereoLayout
                )

                self.source?.pause()
                self.ambisonic?.pause()
                self.source = newSource
                self.ambisonic = newAmbisonic
                self.renderer = newRenderer
                self.playbackStarted = false
                self.decodedFrameCount = 0
                self.lastDecodedFrameTime = nil

                self.controlsModel?.title = resolved.url.deletingPathExtension().lastPathComponent
                _ = self.controlsModel?.update(
                    isPlaying: false,
                    currentTime: 0,
                    duration: newSource.durationSeconds ?? 0,
                    volume: newSource.volume,
                    projectionMode: projectionMode,
                    stereoLayout: stereoLayout,
                    spatialAudioEnabled: newAmbisonic != nil
                )

                self.libraryModel?.showControls()
                self.panelVisible = true
                self.lastPanelActivity = Date()
                self.panelRenderer?.recenter()
                self.panel?.interaction.movePointer(to: SIMD2<Float>(0.5, 0.5))
                self.panel?.invalidate()

                if session.isRunning {
                    try self.startPlayback()
                    self.playbackStarted = true
                    print("Media opened; playback started")
                }
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.mediaOpenGeneration else { return }
                fputs("swiftxr-video: could not open media: \(error)\n", stderr)
                self.libraryModel?.showError(String(describing: error))
                self.panelVisible = true
                self.panelRenderer?.recenter()
                self.panel?.invalidate()
            }
        }
    }

    @objc
    private func frameStep() {
        guard
            let session,
            let swapchain,
            let controller,
            let libraryModel,
            let panel,
            let panelRenderer,
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
                    source?.pause()
                    ambisonic?.pause()
                    playbackStarted = false
                }
                scheduleFrameStep(after: 0.005)
                return
            }

            try startPointerCaptureIfReady()

            if source != nil && !playbackStarted && libraryModel.mode != .loading {
                try startPlayback()
                playbackStarted = true
                print("OpenXR session running; playback started")
            }

            if let failure = source?.failureDescription {
                throw NSError(
                    domain: "SwiftXR.VideoPlayer",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "AVPlayer failed: \(failure)"]
                )
            }

            pointerCapture.poll()
            try applyController(controller.poll())

            if libraryModel.mode == .youtube {
                youtubeBrowser?.tick()
            }

            updatePanelVisibility()
            updateControlsModelIfNeeded()
            try panel.refreshIfNeeded()

            let videoFrame = try source?.latestFrame()
            if let videoFrame, videoFrame.itemTime != lastDecodedFrameTime {
                decodedFrameCount += 1
                lastDecodedFrameTime = videoFrame.itemTime
            }

            let currentRenderer = renderer
            let showPanel = libraryModel.mode != .controls || panelVisible
            let presentation = panelPresentation(for: libraryModel.mode)
            let frame = try session.renderFrame(to: swapchain) {
                xrFrame,
                texture,
                commandBuffer in

                if let currentRenderer {
                    try currentRenderer.encode(
                        frame: xrFrame,
                        swapchainTexture: texture,
                        videoTexture: videoFrame?.texture,
                        commandBuffer: commandBuffer
                    )
                }

                if showPanel {
                    try panelRenderer.encode(
                        frame: xrFrame,
                        swapchainTexture: texture,
                        panelTexture: panel.texture,
                        pointerPosition: panel.interaction.pointerPosition,
                        commandBuffer: commandBuffer,
                        clearBeforePanel: currentRenderer == nil,
                        worldWidth: presentation.width,
                        distance: presentation.distance,
                        verticalOffset: presentation.verticalOffset
                    )
                }
            }

            if let ambisonic,
               frame.trackingState.orientationValid,
               let view = frame.views.first {
                ambisonic.updateHeadOrientation(
                    from: view,
                    sceneAnchor: renderer?.sceneAnchor
                )
            }

            if frameIndex % 180 == 0 {
                let periodMS = Double(frame.predictedDisplayPeriod) / 1_000_000.0
                if let videoFrame, let source {
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
                            format: "XR frame %d: browser/player UI mode=%@ XR period=%.3f ms",
                            frameIndex,
                            String(describing: libraryModel.mode),
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

    private func panelPresentation(for mode: VideoPanelMode) -> (
        width: Float,
        distance: Float,
        verticalOffset: Float
    ) {
        switch mode {
        case .youtube:
            return (2.55, 1.50, -0.03)
        case .files:
            return (2.15, 1.50, -0.08)
        case .loading:
            return (2.00, 1.50, -0.08)
        case .controls:
            // The controls themselves occupy only the central part of the
            // 1280x720 texture, so this preserves approximately their previous
            // physical size while the browser can use the full larger surface.
            return (2.00, 1.50, -0.14)
        }
    }

    private func enterYouTubeBrowser() {
        libraryModel?.mode = .youtube
        panelVisible = true
        lastPanelActivity = Date()
        panelRenderer?.recenter()
        panel?.interaction.movePointer(to: SIMD2<Float>(0.5, 0.5))
        panel?.invalidate()
        youtubeBrowser?.open()
    }

    private func leaveYouTubeToFiles() {
        youtubeBrowser?.close()
        libraryModel?.showFiles()
        panelVisible = true
        panelRenderer?.recenter()
        panel?.invalidate()
    }

    private func handlePanelInteraction(_ event: XRPanelInteractionEvent) {
        notePanelActivity()

        guard libraryModel?.mode == .youtube else { return }

        switch event {
        case .pointerMoved, .pointerMovedBy:
            youtubeBrowser?.pointerMoved()

        case .pointerUp(.primary):
            guard let point = panel?.interaction.pointerPosition else { return }
            if point.y <= 0.075 && point.x <= 0.12 {
                leaveYouTubeToFiles()
            } else if point.y <= 0.075 && point.x <= 0.24 {
                if youtubeBrowser?.back() != true {
                    leaveYouTubeToFiles()
                }
            } else {
                youtubeBrowser?.click(at: point)
            }

        case let .scroll(delta):
            youtubeBrowser?.scroll(delta)

        case .back:
            if youtubeBrowser?.back() != true {
                leaveYouTubeToFiles()
            }

        default:
            break
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
        notePanelActivity()

        switch command {
        case .showFiles:
            youtubeBrowser?.close()
            libraryModel?.showFiles()
            panelVisible = true
            panelRenderer?.recenter()
            panel?.invalidate()
            return

        case .showYouTube:
            enterYouTubeBrowser()
            return

        default:
            break
        }

        guard let source, let renderer else { return }

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
            panelRenderer?.recenter()
            print("[controls] recenter video + panel")

        case let .setProjection(mode):
            renderer.setProjectionMode(mode)
            controlsModel?.projectionMode = renderer.projectionMode
            controlsModel?.stereoLayout = renderer.stereoLayout
            panel?.invalidate()

        case let .setStereoLayout(layout):
            renderer.setStereoLayout(layout)
            controlsModel?.stereoLayout = renderer.stereoLayout
            panel?.invalidate()

        case .showFiles, .showYouTube:
            break
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
        guard let libraryModel else { return }

        switch libraryModel.mode {
        case .files:
            if controls.navY != 0 {
                libraryModel.moveSelection(controls.navY)
                panel?.invalidate()
            }
            if controls.navX != 0 {
                libraryModel.page(controls.navX)
                panel?.invalidate()
            }
            if controls.select {
                libraryModel.activateSelection()
                panel?.invalidate()
            }
            if controls.back {
                if source != nil {
                    libraryModel.showControls()
                    panelVisible = true
                    panelRenderer?.recenter()
                    panel?.invalidate()
                } else {
                    try requestSessionExitIfNeeded()
                }
            }
            if controls.menu, source != nil {
                libraryModel.showControls()
                panelVisible = true
                panelRenderer?.recenter()
                panel?.invalidate()
            }

        case .youtube:
            let now = Date()
            let dt = min(max(now.timeIntervalSince(lastYouTubeControllerUpdate), 0), 0.05)
            lastYouTubeControllerUpdate = now

            let lx = controls.leftX
            let ly = controls.leftY
            let magnitude = sqrt(lx * lx + ly * ly)
            let deadZone: Float = 0.16
            if magnitude > deadZone && dt > 0 {
                let response = (min(magnitude, 1) - deadZone) / (1 - deadZone)
                let curved = pow(response, 1.45)
                let speed = Float(0.80 * dt) * curved
                panel?.interaction.movePointer(
                    by: SIMD2(lx / magnitude * speed, -ly / magnitude * speed)
                )
            }
            if controls.navX != 0 || controls.navY != 0 {
                panel?.interaction.movePointer(
                    by: SIMD2(Float(controls.navX) * 0.075, Float(controls.navY) * 0.10)
                )
            }
            if abs(controls.rightY) > 0.18, dt > 0 {
                youtubeBrowser?.scroll(
                    SIMD2(0, controls.rightY * Float(dt) * 4.0)
                )
            }
            if controls.select, let point = panel?.interaction.pointerPosition {
                youtubeBrowser?.click(at: point)
            }
            if controls.back {
                if youtubeBrowser?.back() != true {
                    leaveYouTubeToFiles()
                }
            }
            if controls.menu, source != nil {
                youtubeBrowser?.close()
                libraryModel.showControls()
                panelVisible = true
                panelRenderer?.recenter()
                panel?.invalidate()
            }

        case .loading:
            if controls.back {
                mediaOpenGeneration += 1
                mediaOpenTask?.cancel()
                libraryModel.showFiles()
                panelRenderer?.recenter()
                panel?.invalidate()
            }

        case .controls:
            if controls.menu {
                panelVisible.toggle()
                lastPanelActivity = Date()
                if panelVisible {
                    panelRenderer?.recenter()
                }
                panel?.invalidate()
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
            stereoLayout: renderer.stereoLayout,
            spatialAudioEnabled: ambisonic != nil
        )
        if changed, libraryModel?.mode == .controls, panelVisible {
            panel?.invalidate()
        }
    }

    private func notePanelActivity() {
        lastPanelActivity = Date()
        if libraryModel?.mode == .controls {
            panelVisible = true
        }
        panel?.invalidate()
    }

    private func updatePanelVisibility() {
        guard libraryModel?.mode == .controls else {
            panelVisible = true
            return
        }
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
        mediaOpenTask?.cancel()
        youtubeBrowser?.shutdown()
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
        mediaOpenTask?.cancel()
        youtubeBrowser?.shutdown()
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
        guard CommandLine.arguments.count <= 2 else {
            fputs(
                "usage: swiftxr-video [movie-or-youtube-url]\n",
                stderr
            )
            exit(2)
        }

        let initialInput = CommandLine.arguments.count == 2
            ? CommandLine.arguments[1]
            : nil

        let application = XRMacApplication.shared
        application.setActivationPolicy(.regular)

        let appDelegate = VideoPlayerAppDelegate(initialInput: initialInput)
        application.delegate = appDelegate

        withExtendedLifetime(appDelegate) {
            application.run()
        }
    }
}
