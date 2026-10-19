import Foundation
import CoreGraphics
import ApplicationServices
import Carbon

public final class InputController {
    private let queue = DispatchQueue(label: "chat.xucheri.AndroidOnMac.input")
    private var heldMouse = false
    private var selectedDisplay: UInt32?
    private var lastPoint: CGPoint?
    private let source = CGEventSource(stateID: .privateState)
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var queuedInputs = 0

    public init() {}
    public var permissionGranted: Bool { AXIsProcessTrusted() }
    public func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    public func releaseAll() {
        lock.lock(); revision &+= 1; lock.unlock()
        queue.sync { releaseMouse(); lastPoint = nil; selectedDisplay = nil }
    }

    public func handle(_ message: [String: Any], displayID: UInt32) {
        lock.lock()
        guard queuedInputs < 256 else { lock.unlock(); return }
        let acceptedRevision = revision
        queuedInputs += 1
        lock.unlock()
        queue.async {
            self.lock.lock()
            let current = self.revision == acceptedRevision
            self.queuedInputs -= 1
            self.lock.unlock()
            if current { self.process(message, displayID: displayID) }
        }
    }

    private func process(_ message: [String: Any], displayID: UInt32) {
        guard permissionGranted, message["type"] as? String == "input", CGDisplayIsActive(displayID) != 0,
              let action = message["action"] as? String else { return }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return }
        if selectedDisplay != displayID { releaseMouse(); selectedDisplay = displayID; lastPoint = nil }
        if action == "text" || action == "key" {
            guard !IsSecureEventInputEnabled(), focusedWindowIsWithin(bounds) else { return }
            if action == "text" {
                guard let text = message["text"] as? String, !text.isEmpty, text.utf8.count <= 4096,
                      !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return }
                let characters = Array(text.utf16)
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
                characters.withUnsafeBufferPointer {
                    down.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                    up.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                }
                down.flags = []; up.flags = []
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            } else if let key = message["key"] as? String { sendKey(key) }
            return
        }
        if action == "scroll" {
            guard let point = lastPoint, bounds.contains(point), let dx = number(message["dx"]), let dy = number(message["dy"]),
                  abs(dx) <= 1000, abs(dy) <= 1000,
                  let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                      wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
            event.location = point; event.post(tap: .cghidEventTap); return
        }
        guard let x = number(message["x"]), let y = number(message["y"]), (0...1).contains(x), (0...1).contains(y) else { return }
        let point = CGPoint(x: bounds.minX + x * max(0, bounds.width - 1), y: bounds.minY + y * max(0, bounds.height - 1))
        lastPoint = point
        switch action {
        case "move": mouse(heldMouse ? .leftMouseDragged : .mouseMoved, at: point)
        case "down": if !heldMouse { mouse(.leftMouseDown, at: point); heldMouse = true }
        case "up": releaseMouse()
        case "click", "doubleClick", "rightClick":
            releaseMouse()
            let right = action == "rightClick"
            for click in 1...(action == "doubleClick" ? 2 : 1) {
                mouse(right ? .rightMouseDown : .leftMouseDown, at: point, right: right, click: click)
                mouse(right ? .rightMouseUp : .leftMouseUp, at: point, right: right, click: click)
            }
        default: break
        }
    }

    private func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private func mouse(_ type: CGEventType, at point: CGPoint, right: Bool = false, click: Int = 1) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: right ? .right : .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(click))
        event.flags = []
        event.post(tap: .cghidEventTap)
    }
    private func releaseMouse() {
        if heldMouse, let point = lastPoint { mouse(.leftMouseUp, at: point) }
        heldMouse = false
    }

    private func sendKey(_ name: String) {
        let keys: [String: (CGKeyCode, CGEventFlags)] = [
            "enter": (36, []), "backspace": (51, []), "delete": (117, []), "escape": (53, []), "tab": (48, []),
            "left": (123, []), "right": (124, []), "up": (126, []), "down": (125, []),
            "home": (115, []), "end": (119, []), "copy": (8, .maskCommand), "paste": (9, .maskCommand),
            "cut": (7, .maskCommand), "selectAll": (0, .maskCommand), "undo": (6, .maskCommand),
            "redo": (6, [.maskCommand, .maskShift])
        ]
        guard let (code, flags) = keys[name],
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return }
        down.flags = flags; up.flags = []
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }

    private func focusedWindowIsWithin(_ bounds: CGRect) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var appValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appValue) == .success,
              let appValue, CFGetTypeID(appValue) == AXUIElementGetTypeID() else { return false }
        let app = unsafeBitCast(appValue, to: AXUIElement.self)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return false }
        let window = unsafeBitCast(windowValue, to: AXUIElement.self)
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue, CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return false }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size) else { return false }
        return bounds.contains(CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2))
    }
}
