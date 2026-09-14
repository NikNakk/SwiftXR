import Foundation
import SwiftXR

let instance = try XRInstance(applicationName: "SwiftXR Logo")
let session = try instance.system().makeSession()
let swapchain = try session.makeStereoSwapchain()
let logo = try LogoRenderer(device: session.device, swapchain: swapchain)

while !session.isRunning && !session.shouldExit {
    try session.pollEvents()
    if !session.isRunning { Thread.sleep(forTimeInterval: 0.01) }
}

var frames = 0
while frames < 900 && session.isRunning && !session.shouldExit {
    try session.pollEvents()
    guard session.isRunning && !session.shouldExit else { break }

    try session.renderFrame(to: swapchain) { frame, texture, commandBuffer in
        try logo.encode(frame: frame, texture: texture, commandBuffer: commandBuffer)
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
