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
            fputs("usage: swiftxr-video /path/to/movie.mp4\n", stderr)
            exit(2)
        }

        let expandedPath = NSString(
            string: CommandLine.arguments[1]
        ).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw NSError(
                domain: "SwiftXR.VideoPlayer",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Video file does not exist: \(expandedPath)"
                ]
            )
        }
        let url = URL(fileURLWithPath: expandedPath)

        print("SwiftXR video player proof of concept")
        print("Input: \(url.path)")

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
        let source = try await VideoSource.open(url: url, device: session.device)
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

        let renderer = try VideoRenderer(
            device: session.device,
            swapchain: swapchain,
            displaySize: source.displaySize
        )
        print(
            String(
                format: "Virtual screen: %.2f m × %.2f m at %.1f m in LOCAL space",
                renderer.geometry.widthMeters,
                renderer.geometry.heightMeters,
                -renderer.geometry.center.z
            )
        )
        print("Audio follows the current macOS output device")

        try await waitForSessionToRun(session)

        guard session.isRunning else {
            if session.shouldExit {
                print("Runtime requested exit before playback started")
            } else {
                print("OpenXR session did not reach READY within 10 seconds")
            }
            return
        }

        source.play()
        print("OpenXR session running; AVPlayer playback started")
        print("Press Ctrl-C to stop")

        try renderVideo(
            session: session,
            swapchain: swapchain,
            source: source,
            renderer: renderer
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
    private static func renderVideo(
        session: XRSession,
        swapchain: XRSwapchain,
        source: VideoSource,
        renderer: VideoRenderer
    ) throws {
        var frameIndex = 0
        var decodedFrameCount = 0
        var lastFrameTime: CMTime?
        var lastState = session.state

        while session.isRunning && !session.shouldExit {
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

            if frameIndex % 180 == 0 {
                let periodMS = Double(frame.predictedDisplayPeriod) / 1_000_000.0
                let playback = source.currentTimeSeconds
                if let videoFrame {
                    print(
                        String(
                            format: "XR frame %d: video=%dx%d t=%.2fs decoded=%d XR period=%.3f ms",
                            frameIndex,
                            videoFrame.texture.width,
                            videoFrame.texture.height,
                            playback,
                            decodedFrameCount,
                            periodMS
                        )
                    )
                } else {
                    print(
                        String(
                            format: "XR frame %d: waiting for first decoded video frame, XR period=%.3f ms",
                            frameIndex,
                            periodMS
                        )
                    )
                }
            }

            frameIndex += 1
        }

        source.pause()
        print("Rendered \(frameIndex) XR frames using \(decodedFrameCount) decoded video frames")
    }
}
