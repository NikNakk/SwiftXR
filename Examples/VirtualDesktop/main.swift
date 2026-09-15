import Foundation
import Metal
import SwiftXR

@main
struct VirtualDesktopExample {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("swiftxr-desktop: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        print("SwiftXR virtual desktop")
        print("Stage 1: mirror the primary macOS display onto a world-locked XR quad")

        let capabilities = try XRRuntime.capabilities()
        try capabilities.requireMetal()

        let instance = try XRInstance(applicationName: "SwiftXR Virtual Desktop")
        print("Runtime: \(instance.runtime.name) \(instance.runtime.version)")

        let system = try instance.system()
        print("OpenXR system: \(system.info.name)")

        let session = try system.makeSession()
        let swapchain = try session.makeStereoSwapchain()
        print("Runtime Metal device: \(session.device.name)")
        print("XR swapchain: \(swapchain.width)x\(swapchain.height), arraySize=2")

        print("Discovering ScreenCaptureKit displays…")
        print("macOS may request Screen Recording permission on first use.")
        let capture = try await DesktopCapture.primaryDisplay(device: session.device)
        print(
            "Selected display \(capture.display.displayID): " +
            "\(capture.display.width)x\(capture.display.height)"
        )
        print("Display frame: \(capture.displayFrame)")

        try await capture.start()
        print("ScreenCaptureKit stream started")

        do {
            try await waitForFirstDesktopFrame(capture)

            let renderer = try DesktopRenderer(
                device: session.device,
                swapchain: swapchain,
                capturedPixelSize: capture.pixelSize
            )
            print(
                String(
                    format: "Desktop surface: %.2f m × %.2f m at z=%.2f m",
                    renderer.geometry.widthMeters,
                    renderer.geometry.heightMeters,
                    renderer.geometry.center.z
                )
            )
            print("Stage-2 coordinate mapping: quad UV -> captured desktop pixels ready")

            try await waitForSessionToRun(session)

            if session.isRunning {
                print("OpenXR session running; rendering desktop")
                try renderDesktop(
                    session: session,
                    swapchain: swapchain,
                    capture: capture,
                    renderer: renderer
                )
            } else if session.shouldExit {
                print("Runtime requested exit before the session became running")
            } else {
                print("Session did not reach READY within 10 seconds")
            }
        } catch {
            try? await capture.stop()
            throw error
        }

        try await capture.stop()
        print("ScreenCaptureKit stream stopped")
    }

    private static func waitForFirstDesktopFrame(
        _ capture: DesktopCapture
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try capture.latestFrame() != nil {
                print("First desktop frame received")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        throw NSError(
            domain: "SwiftXR.VirtualDesktop",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "ScreenCaptureKit started but no desktop frame arrived within 5 seconds"
            ]
        )
    }

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
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    private static func renderDesktop(
        session: XRSession,
        swapchain: XRSwapchain,
        capture: DesktopCapture,
        renderer: DesktopRenderer
    ) throws {
        var frameIndex = 0
        let maximumFrames = 3_600
        var lastState = session.state

        while frameIndex < maximumFrames && session.isRunning && !session.shouldExit {
            for state in try session.pollEvents() where state != lastState {
                print("Session state: \(state)")
                lastState = state
            }

            guard session.isRunning && !session.shouldExit else { break }

            let desktopFrame = try capture.latestFrame()
            let frame = try session.renderFrame(to: swapchain) {
                xrFrame,
                texture,
                commandBuffer in
                try renderer.encode(
                    frame: xrFrame,
                    swapchainTexture: texture,
                    desktopTexture: desktopFrame?.texture,
                    commandBuffer: commandBuffer
                )
            }

            if frameIndex % 180 == 0 {
                let periodMS = Double(frame.predictedDisplayPeriod) / 1_000_000.0
                if let desktopFrame {
                    print(
                        "Frame \(frameIndex): desktop=" +
                        "\(desktopFrame.width)x\(desktopFrame.height) " +
                        String(format: "XR period=%.3f ms", periodMS)
                    )
                } else {
                    print("Frame \(frameIndex): waiting for desktop texture")
                }
            }

            frameIndex += 1
        }

        print("Rendered \(frameIndex) virtual-desktop XR frames")

        if session.isRunning && !session.shouldExit {
            try session.requestExit()

            let deadline = Date().addingTimeInterval(5)
            while !session.shouldExit && Date() < deadline {
                _ = try session.pollEvents()
                usleep(10_000)
            }
        }
    }
}
