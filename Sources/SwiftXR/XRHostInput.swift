import Foundation
import GameController
import simd

public enum XRGamepadButton: String, CaseIterable, Sendable, Hashable {
    case a
    case b
    case x
    case y
    case leftShoulder
    case rightShoulder
    case leftThumbstick
    case rightThumbstick
    case menu
    case options
    case home
}

public enum XRMouseButton: Sendable, Hashable {
    case left
    case right
    case middle
    case auxiliary(Int)
}

public struct XRGamepadState: Sendable, Hashable {
    public let isConnected: Bool
    public let name: String?

    public let leftStick: SIMD2<Float>
    public let rightStick: SIMD2<Float>
    public let dpad: SIMD2<Float>
    public let leftTrigger: Float
    public let rightTrigger: Float

    public let buttons: Set<XRGamepadButton>
    public let pressed: Set<XRGamepadButton>
    public let released: Set<XRGamepadButton>

    public func isDown(_ button: XRGamepadButton) -> Bool {
        buttons.contains(button)
    }

    public func wasPressed(_ button: XRGamepadButton) -> Bool {
        pressed.contains(button)
    }

    public func wasReleased(_ button: XRGamepadButton) -> Bool {
        released.contains(button)
    }
}

public struct XRMouseState: Sendable, Hashable {
    public let isConnected: Bool

    /// Raw relative mouse movement accumulated since the previous snapshot.
    public let delta: SIMD2<Float>

    /// Scroll-wheel movement accumulated since the previous snapshot.
    public let scroll: SIMD2<Float>

    public let buttons: Set<XRMouseButton>
    public let pressed: Set<XRMouseButton>
    public let released: Set<XRMouseButton>

    public func isDown(_ button: XRMouseButton) -> Bool {
        buttons.contains(button)
    }

    public func wasPressed(_ button: XRMouseButton) -> Bool {
        pressed.contains(button)
    }

    public func wasReleased(_ button: XRMouseButton) -> Bool {
        released.contains(button)
    }
}

public struct XRHostInputState: Sendable, Hashable {
    public let gamepad: XRGamepadState
    public let mouse: XRMouseState
}

/// Native macOS host input for SwiftXR applications.
///
/// This layer is intentionally separate from OpenXR actions. It uses Apple's
/// GameController framework for ordinary gamepads and physical mice, so a macOS
/// application can offer familiar desktop/game-controller controls now while
/// Sense controller input can be added later through OpenXR without changing the
/// application-level control model.
///
/// Call `snapshot()` once per application/XR frame. Analog/button state is
/// sampled at that moment; relative mouse/scroll deltas are consumed by the
/// snapshot and reset ready for the next frame.
public final class XRHostInput: @unchecked Sendable {
    private let lock = NSLock()

    private var mouseDelta = SIMD2<Float>(repeating: 0)
    private var scrollDelta = SIMD2<Float>(repeating: 0)
    private var configuredMouse: GCMouse?

    private var previousGamepadButtons: Set<XRGamepadButton> = []
    private var previousMouseButtons: Set<XRMouseButton> = []

    public init(monitorBackgroundControllerEvents: Bool = true) {
        GCController.shouldMonitorBackgroundEvents = monitorBackgroundControllerEvents
        configureMouseIfNeeded()
    }

    deinit {
        configuredMouse?.mouseInput?.mouseMovedHandler = nil
        configuredMouse?.mouseInput?.scroll.valueChangedHandler = nil
    }

    /// Return the current controller/button state and consume accumulated mouse
    /// movement/scroll deltas since the previous call.
    public func snapshot() -> XRHostInputState {
        configureMouseIfNeeded()

        let gamepad = makeGamepadState()
        let mouse = makeMouseState()

        return XRHostInputState(gamepad: gamepad, mouse: mouse)
    }

    private func currentExtendedController() -> GCController? {
        if let current = GCController.current, current.extendedGamepad != nil {
            return current
        }

        return GCController.controllers().first { $0.extendedGamepad != nil }
    }

    private func makeGamepadState() -> XRGamepadState {
        guard
            let controller = currentExtendedController(),
            let gamepad = controller.extendedGamepad
        else {
            let released = previousGamepadButtons
            previousGamepadButtons = []
            return XRGamepadState(
                isConnected: false,
                name: nil,
                leftStick: .zero,
                rightStick: .zero,
                dpad: .zero,
                leftTrigger: 0,
                rightTrigger: 0,
                buttons: [],
                pressed: [],
                released: released
            )
        }

        var buttons: Set<XRGamepadButton> = []

        func add(_ button: XRGamepadButton, if input: GCControllerButtonInput?) {
            if input?.isPressed == true {
                buttons.insert(button)
            }
        }

        add(.a, if: gamepad.buttonA)
        add(.b, if: gamepad.buttonB)
        add(.x, if: gamepad.buttonX)
        add(.y, if: gamepad.buttonY)
        add(.leftShoulder, if: gamepad.leftShoulder)
        add(.rightShoulder, if: gamepad.rightShoulder)
        add(.leftThumbstick, if: gamepad.leftThumbstickButton)
        add(.rightThumbstick, if: gamepad.rightThumbstickButton)
        add(.menu, if: gamepad.buttonMenu)
        add(.options, if: gamepad.buttonOptions)
        add(.home, if: gamepad.buttonHome)

        let pressed = buttons.subtracting(previousGamepadButtons)
        let released = previousGamepadButtons.subtracting(buttons)
        previousGamepadButtons = buttons

        return XRGamepadState(
            isConnected: true,
            name: controller.vendorName ?? controller.productCategory,
            leftStick: SIMD2(
                gamepad.leftThumbstick.xAxis.value,
                gamepad.leftThumbstick.yAxis.value
            ),
            rightStick: SIMD2(
                gamepad.rightThumbstick.xAxis.value,
                gamepad.rightThumbstick.yAxis.value
            ),
            dpad: SIMD2(
                gamepad.dpad.xAxis.value,
                gamepad.dpad.yAxis.value
            ),
            leftTrigger: gamepad.leftTrigger.value,
            rightTrigger: gamepad.rightTrigger.value,
            buttons: buttons,
            pressed: pressed,
            released: released
        )
    }

    private func currentMouse() -> GCMouse? {
        GCMouse.current ?? GCMouse.mice().first
    }

    private func configureMouseIfNeeded() {
        let mouse = currentMouse()

        if mouse === configuredMouse {
            return
        }

        configuredMouse?.mouseInput?.mouseMovedHandler = nil
        configuredMouse?.mouseInput?.scroll.valueChangedHandler = nil
        configuredMouse = mouse

        guard let input = mouse?.mouseInput else {
            return
        }

        input.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
            guard let self else { return }
            self.lock.lock()
            self.mouseDelta += SIMD2(deltaX, deltaY)
            self.lock.unlock()
        }

        input.scroll.valueChangedHandler = { [weak self] _, xValue, yValue in
            guard let self else { return }
            self.lock.lock()
            self.scrollDelta += SIMD2(xValue, yValue)
            self.lock.unlock()
        }
    }

    private func makeMouseState() -> XRMouseState {
        let input = configuredMouse?.mouseInput
        var buttons: Set<XRMouseButton> = []

        if input?.leftButton.isPressed == true {
            buttons.insert(.left)
        }
        if input?.rightButton?.isPressed == true {
            buttons.insert(.right)
        }
        if input?.middleButton?.isPressed == true {
            buttons.insert(.middle)
        }
        if let auxiliary = input?.auxiliaryButtons {
            for (index, button) in auxiliary.enumerated() where button.isPressed {
                buttons.insert(.auxiliary(index))
            }
        }

        let pressed = buttons.subtracting(previousMouseButtons)
        let released = previousMouseButtons.subtracting(buttons)
        previousMouseButtons = buttons

        lock.lock()
        let delta = mouseDelta
        let scroll = scrollDelta
        mouseDelta = .zero
        scrollDelta = .zero
        lock.unlock()

        return XRMouseState(
            isConnected: input != nil,
            delta: delta,
            scroll: scroll,
            buttons: buttons,
            pressed: pressed,
            released: released
        )
    }
}
