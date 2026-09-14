import Foundation
import SwiftUI
import SwiftXR

private struct SwiftXRCard: View {
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

            VStack(spacing: 12) {
                Image(systemName: "swift")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(.orange)

                Text("SwiftXR")
                    .font(.system(size: 48, weight: .bold, design: .rounded))

                Text("SwiftUI → Metal → OpenXR")
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .foregroundStyle(.white)
            .padding(32)
        }
        .frame(width: 480, height: 280)
        .padding(8)
    }
}

@main
struct SwiftUIPanelExample {
    @MainActor
    static func main() throws {
        let instance = try XRInstance(applicationName: "SwiftUI Panel")
        let session = try instance.system().makeSession()
        let swapchain = try session.makeStereoSwapchain()

        let panel = try XRSwiftUIPanel(
            device: session.device,
            pointSize: CGSize(width: 496, height: 296),
            scale: 2
        ) {
            SwiftXRCard()
        }

        let renderer = try PanelRenderer(
            device: session.device,
            swapchain: swapchain,
            panelTexture: panel.texture
        )

        while !session.isRunning && !session.shouldExit {
            try session.pollEvents()
            if !session.isRunning {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        var frames = 0
        while frames < 900 && session.isRunning && !session.shouldExit {
            try session.pollEvents()
            guard session.isRunning && !session.shouldExit else { break }

            try session.renderFrame(to: swapchain) { frame, texture, commandBuffer in
                try renderer.encode(
                    frame: frame,
                    texture: texture,
                    commandBuffer: commandBuffer
                )
            }

            frames += 1
        }

        if session.isRunning && !session.shouldExit {
            try session.requestExit()
        }

        while !session.shouldExit {
            try session.pollEvents()
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
