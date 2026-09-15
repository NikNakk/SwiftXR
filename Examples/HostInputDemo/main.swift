import Foundation
import SwiftXR

let input = XRHostInput()
print("SwiftXR host input demo")
print("Move a mouse, scroll, click, or use a standard game controller for 30 seconds.")

let deadline = Date().addingTimeInterval(30)
var lastGamepadConnected = false
var lastMouseConnected = false

while Date() < deadline {
    let state = input.snapshot()

    if state.gamepad.isConnected != lastGamepadConnected {
        lastGamepadConnected = state.gamepad.isConnected
        if state.gamepad.isConnected {
            print("Gamepad connected: \(state.gamepad.name ?? "unknown")")
        } else {
            print("Gamepad disconnected")
        }
    }

    if state.mouse.isConnected != lastMouseConnected {
        lastMouseConnected = state.mouse.isConnected
        print(state.mouse.isConnected ? "Mouse connected" : "Mouse disconnected")
    }

    if !state.gamepad.pressed.isEmpty {
        print("Gamepad pressed: \(state.gamepad.pressed)")
    }
    if !state.gamepad.released.isEmpty {
        print("Gamepad released: \(state.gamepad.released)")
    }

    let left = state.gamepad.leftStick
    let right = state.gamepad.rightStick
    let dpad = state.gamepad.dpad
    if abs(left.x) > 0.05 || abs(left.y) > 0.05 ||
        abs(right.x) > 0.05 || abs(right.y) > 0.05 ||
        abs(dpad.x) > 0.05 || abs(dpad.y) > 0.05 ||
        state.gamepad.leftTrigger > 0.05 || state.gamepad.rightTrigger > 0.05 {
        print(
            String(
                format: "sticks L(%.2f, %.2f) R(%.2f, %.2f) dpad(%.2f, %.2f) triggers(%.2f, %.2f)",
                left.x, left.y,
                right.x, right.y,
                dpad.x, dpad.y,
                state.gamepad.leftTrigger,
                state.gamepad.rightTrigger
            )
        )
    }

    if state.mouse.delta != .zero {
        print(
            String(
                format: "mouse delta (%.1f, %.1f)",
                state.mouse.delta.x,
                state.mouse.delta.y
            )
        )
    }
    if state.mouse.scroll != .zero {
        print(
            String(
                format: "mouse scroll (%.2f, %.2f)",
                state.mouse.scroll.x,
                state.mouse.scroll.y
            )
        )
    }
    if !state.mouse.pressed.isEmpty {
        print("Mouse pressed: \(state.mouse.pressed)")
    }
    if !state.mouse.released.isEmpty {
        print("Mouse released: \(state.mouse.released)")
    }

    RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 120.0))
}
