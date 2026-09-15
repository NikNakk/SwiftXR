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

@main
struct SwiftUIPanelExample {
    @MainActor
    static func main() throws {
        // Do not monitor controllers while the app is in the background. Pointer
        // capture likewise releases automatically whenever SwiftXR loses focus.
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

        let pointerCapture = XRMacPointerCapture(
            interaction: panel.interaction
        )
        var configuredController: GCController?

        while !session.isRunning && !session.shouldExit {
            try session.pollEvents()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }

        if session.isRunning && !session.shouldExit {
            try pointerCapture.start()
            // Give AppKit one main-loop turn to complete foreground activation
            // and install the capture windows before the first interactive frame.
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        defer {
            pointerCapture.stop()
        }

        var frames = 0
        while frames < 1800 &&
                session.isRunning &&
                !session.shouldExit &&
                !pointerCapture.escapeRequested {
            try session.pollEvents()
            guard session.isRunning &&
                    !session.shouldExit &&
                    !pointerCapture.escapeRequested else {
                break
            }

            let controller = GCController.current ?? GCController.controllers().first
            if controller !== configuredController {
                configuredController = controller
                if let controller {
                    configure(controller: controller, panel: panel)
                }
            }

            renderer.pointerPosition = panel.interaction.pointerPosition

            try session.renderFrame(to: swapchain) { frame, texture, commandBuffer in
                try renderer.encode(
                    frame: frame,
                    texture: texture,
                    commandBuffer: commandBuffer
                )
            }

            // The example owns its XR frame loop directly, so give AppKit a short
            // main-loop turn for captured pointer and SwiftUI responder events.
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            frames += 1
        }

        pointerCapture.stop()

        if session.isRunning && !session.shouldExit {
            try session.requestExit()
        }

        while !session.shouldExit {
            try session.pollEvents()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }
}
