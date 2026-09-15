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
private func configure(
    mouse: GCMouse,
    panel: XRSwiftUIPanel<SwiftXRCard>
) {
    guard let input = mouse.mouseInput else { return }

    panel.interaction.movePointer(to: SIMD2(0.5, 0.5))

    input.mouseMovedHandler = { _, deltaX, deltaY in
        DispatchQueue.main.async {
            panel.interaction.movePointer(
                by: SIMD2(
                    Float(deltaX) / 700.0,
                    Float(-deltaY) / 500.0
                )
            )
        }
    }

    input.leftButton.pressedChangedHandler = { _, _, pressed in
        DispatchQueue.main.async {
            if pressed {
                panel.interaction.pointerDown()
            } else {
                panel.interaction.pointerUp()
            }
        }
    }

    input.rightButton?.pressedChangedHandler = { _, _, pressed in
        guard pressed else { return }
        DispatchQueue.main.async {
            panel.interaction.back()
        }
    }

    input.scroll.valueChangedHandler = { _, xValue, yValue in
        DispatchQueue.main.async {
            panel.interaction.scroll(
                SIMD2(Float(xValue), Float(yValue)) / 8.0
            )
        }
    }
}

@main
struct SwiftUIPanelExample {
    @MainActor
    static func main() throws {
        GCController.shouldMonitorBackgroundEvents = true

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

        var configuredController: GCController?
        var configuredMouse: GCMouse?

        while !session.isRunning && !session.shouldExit {
            try session.pollEvents()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }

        var frames = 0
        while frames < 1800 && session.isRunning && !session.shouldExit {
            try session.pollEvents()
            guard session.isRunning && !session.shouldExit else { break }

            let controller = GCController.current ?? GCController.controllers().first
            if controller !== configuredController {
                configuredController = controller
                if let controller {
                    configure(controller: controller, panel: panel)
                }
            }

            let mouse = GCMouse.current ?? GCMouse.mice().first
            if mouse !== configuredMouse {
                configuredMouse = mouse
                if let mouse {
                    configure(mouse: mouse, panel: panel)
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

            // This is a command-line demo rather than a normal NSApplication run
            // loop, so explicitly allow queued SwiftUI/GameController callbacks to
            // run briefly between XR frames.
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            frames += 1
        }

        if session.isRunning && !session.shouldExit {
            try session.requestExit()
        }

        while !session.shouldExit {
            try session.pollEvents()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }
}
