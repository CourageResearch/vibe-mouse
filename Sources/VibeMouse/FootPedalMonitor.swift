import Foundation
import IOKit.hid

final class FootPedalMonitor {
    enum StartResult {
        case started
        case failed(String)
    }

    var onPedalDown: (@MainActor @Sendable () -> Void)?

    private static let vendorID = 0x3553
    private static let productID = 0xB001

    private var hidManager: IOHIDManager?
    private var attachedRunLoop: CFRunLoop?
    private var isPedalPressed = false

    func start() -> StartResult {
        if hidManager != nil {
            return .started
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(
            manager,
            Self.inputValueCallback,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let runLoop = CFRunLoopGetMain() else {
            return .failed("Could not access the main run loop for the foot pedal monitor.")
        }
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.commonModes.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.commonModes.rawValue)
            return .failed("Could not open the PCsensor foot pedal HID device.")
        }

        hidManager = manager
        attachedRunLoop = runLoop
        isPedalPressed = false
        return .started
    }

    func stop() {
        guard let hidManager else { return }
        if let attachedRunLoop {
            IOHIDManagerUnscheduleFromRunLoop(hidManager, attachedRunLoop, CFRunLoopMode.commonModes.rawValue)
        }
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.hidManager = nil
        attachedRunLoop = nil
        isPedalPressed = false
    }

    private static let inputValueCallback: IOHIDValueCallback = { context, _, _, value in
        guard let context else { return }
        let monitor = Unmanaged<FootPedalMonitor>.fromOpaque(context).takeUnretainedValue()
        monitor.handleInputValue(value)
    }

    private func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let elementType = IOHIDElementGetType(element)
        let isInputElement = elementType == kIOHIDElementTypeInput_Button
            || elementType == kIOHIDElementTypeInput_Misc
            || elementType == kIOHIDElementTypeInput_ScanCodes
        guard isInputElement else { return }

        let integerValue = IOHIDValueGetIntegerValue(value)
        if integerValue != 0 {
            guard !isPedalPressed else { return }
            isPedalPressed = true
            dispatchPedalDown()
            return
        }

        isPedalPressed = false
    }

    private func dispatchPedalDown() {
        let callback = onPedalDown
        Task { @MainActor in
            callback?()
        }
    }
}
