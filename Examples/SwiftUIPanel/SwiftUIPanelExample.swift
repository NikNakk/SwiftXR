import AppKit
import Foundation
import GameController
import SwiftUI
import SwiftXR

@MainActor
private final class PanelModel: ObservableObject {
    @Published var playing = false
    @Published var enhanced = true
    @Published var volume = 0.65
    @Published var activationCount = 0
}

@MainActor
private struct SwiftXRCard: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.12, blue: 0.22),
                            Color(red: 0.12, green: 0.36, blue: 0.56),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 2)

            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "swift")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("SwiftXR")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                        Text("interactive SwiftUI panel")
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.70))
                    }
                }

                HStack(spacing: 14) {
                    Button(model.playing ? "Pause" : "Play") {
                        model.playing.toggle()
                        model.activationCount += 1
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Action \(model.activationCount)") {
                        model.activationCount += 1
                    }
                    .buttonStyle(.bordered)
                }

                Toggle("Enhanced mode", isOn: $model.enhanced)

                HStack {
                    Image(systemName: "speaker.fill")
                    Slider(value: $model.volume, in: 0...1)
                    Text("\(Int(model.volume * 100))%")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }
            .controlSize(.large)
            .foregroundStyle(.white)
            .padding(34)
        }
        .frame(width: 540, height: 390)
        .padding(8)
    }
}

@MainActor
private func configure(
    controller: GCController,
    panel: XRSwiftUIPanel<SwiftXRCard>
) {
    guard let pad = controller.extendedGamepad else { return }

    func onPress(
        _ button: GCControllerButtonInput,
        _ action: @escaping @MainActor () -> Void
    ) {
        button.pressedChangedHandler = { _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async {
                action()
            }
        }
    }

    onPress(pad.dpad.up) { panel.interaction.navigate(.up) }
    onPress(pad.dpad.down) { panel.interaction.navigate(.down) }
    onPress(pad.dpad.left) { panel.interaction.navigate(.left) }
    onPress(pad.dpad.right) { panel.interaction.navigate(.right) }
    onPress(pad.buttonA) { panel.interaction.select() }
    onPress(pad.buttonB) { panel.interaction.back() }
    onPress(pad.buttonMenu) { panel.interaction.select() }
}

@MainActor
private final class SwiftUIPanelAppDelegate: NSObject, NSApplicationDelegate {
    private var instance: XRInstance?
    private var session: XRSession?
    private var swapchain: XRSwapchain?
    private var panel: XRSwiftUIPanel<SwiftXRCard>?
    private var renderer: PanelRenderer?
    private var pointerCapture: XRMacPointerCapture?
    private var configuredController: GCController?
    private var exitRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Plain Swift executables do not get LaunchServices activation for free.
        // Activate explicitly, then repeat on the next main-queue turn after
        // AppKit has completed finishLaunching.
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        do {
            try setUpXR()
            scheduleFrameStep()
        } catch {
            fail(error)
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
        pointerCapture?.stop()
        if session?.isRunning == true && !exitRequested {
            try? session?.requestExit()
        }
    }

    private func setUpXR() throws {
        GCController.shouldMonitorBackgroundEvents = false

        let instance = try XRInstance(applicationName: "SwiftUI Panel")
        let session = try instance.system().makeSession()
        let swapchain = try session.makeStereoSwapchain()
        let model = PanelModel()

        let panel = try XRSwiftUIPanel(
            device: session.device,
            pointSize: CGSize(width: 556, height: 406),
            scale: 2
        ) {
            SwiftXRCard(model: model)
        }

        let renderer = try PanelRenderer(
            device: session.device,
            swapchain: swapchain,
            panelTexture: panel.texture
        )

        let pointerCapture = XRMacPointerCapture(panel: panel)

        self.instance = instance
        self.session = session
        self.swapchain = swapchain
        self.panel = panel
        self.renderer = renderer
        self.pointerCapture = pointerCapture
    }

    @objc
    private func frameStep() {
        guard
            let session,
            let swapchain,
            let panel,
            let renderer,
            let pointerCapture
        else {
            return
        }

        do {
            try session.pollEvents()

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

            if session.isRunning {
                try startPointerCaptureIfReady()

                // GAV-style physical input sampling. XRMacApplication filters
                // the competing physical capture-window mouse events before a
                // native SwiftUI/AppKit control can consume them, leaving only
                // the synthetic host-window stream produced from this polling.
                pointerCapture.poll()

                let controller = GCController.current ?? GCController.controllers().first
                if controller !== configuredController {
                    configuredController = controller
                    if let controller {
                        configure(controller: controller, panel: panel)
                    }
                }

                try panel.refreshIfNeeded()
                renderer.pointerPosition = panel.interaction.pointerPosition

                try session.renderFrame(to: swapchain) { frame, texture, commandBuffer in
                    try renderer.encode(
                        frame: frame,
                        texture: texture,
                        commandBuffer: commandBuffer
                    )
                }

                scheduleFrameStep()
            } else {
                scheduleFrameStep(after: 0.005)
            }
        } catch {
            fail(error)
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
        pointerCapture?.stop()

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "SwiftXR SwiftUI Panel"
        alert.informativeText = String(describing: error)
        alert.runModal()

        NSApplication.shared.terminate(nil)
    }
}

@main
struct SwiftUIPanelExample {
    @MainActor
    static func main() {
        // Apple explicitly supports constructing a custom NSApplication subclass
        // by sending `shared` to that subclass first. This gives SwiftXR its
        // nextEvent filtering hook without NSPrincipalClass, NSApplicationMain,
        // LaunchServices, or a temporary .app bundle.
        let application = XRMacApplication.shared
        application.setActivationPolicy(.regular)

        let appDelegate = SwiftUIPanelAppDelegate()
        application.delegate = appDelegate

        // Keep the delegate alive for the duration of AppKit's blocking run loop.
        withExtendedLifetime(appDelegate) {
            application.run()
        }
    }
}