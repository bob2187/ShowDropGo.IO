import Foundation
import CoreGraphics
import AppKit

/// Handles input events arriving as JSON lines on stdin and injects them
/// into the HID event stream via CGEventPost.
///
/// JSON formats:
///   {"type":"mouse","x":100,"y":200,"buttons":1,"dx":0,"dy":0}
///   {"type":"key","keycode":0,"down":true,"flags":0}
///   {"type":"clipboard","text":"hello"}
enum InputHandler {
    static func handle(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return }
        switch type {
        case "mouse":     handleMouse(json)
        case "key":       handleKey(json)
        case "clipboard": handleClipboard(json)
        default:          break
        }
    }

    // MARK: - Mouse

    private static var prevButtons = 0
    private static var prevPos = CGPoint.zero

    private static func handleMouse(_ json: [String: Any]) {
        let x       = json["x"]       as? Double ?? 0
        let y       = json["y"]       as? Double ?? 0
        let buttons = json["buttons"] as? Int    ?? 0
        let dx      = json["dx"]      as? Double ?? 0
        let dy      = json["dy"]      as? Double ?? 0
        let pos     = CGPoint(x: x, y: y)

        // Scroll wheel
        if dx != 0 || dy != 0 {
            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) {
                e.location = pos
                e.post(tap: .cghidEventTap)
            }
        }

        let leftDown  = (buttons & 1) != 0
        let rightDown = (buttons & 2) != 0
        let prevLeft  = (prevButtons & 1) != 0
        let prevRight = (prevButtons & 2) != 0

        // Fire button events only on state change
        if leftDown != prevLeft {
            post(mouseType: leftDown ? .leftMouseDown : .leftMouseUp, at: pos, button: .left)
            prevPos = pos  // reset so drag only fires on subsequent movement
        }
        if rightDown != prevRight {
            post(mouseType: rightDown ? .rightMouseDown : .rightMouseUp, at: pos, button: .right)
            prevPos = pos
        }

        prevButtons = buttons

        // Only fire move/drag if position actually changed since last button event or move
        if pos != prevPos {
            if leftDown {
                post(mouseType: .leftMouseDragged, at: pos, button: .left)
            } else if rightDown {
                post(mouseType: .rightMouseDragged, at: pos, button: .right)
            } else {
                post(mouseType: .mouseMoved, at: pos, button: .left)
            }
            prevPos = pos
        }
    }

    private static let eventSource = CGEventSource(stateID: .hidSystemState)

    private static func post(mouseType: CGEventType, at pos: CGPoint, button: CGMouseButton) {
        let e = CGEvent(mouseEventSource: eventSource, mouseType: mouseType,
                        mouseCursorPosition: pos, mouseButton: button)
        e?.post(tap: .cghidEventTap)
        fputs("mouse: \(mouseType.rawValue) at (\(Int(pos.x)),\(Int(pos.y)))\n", stderr)
    }

    // MARK: - Keyboard
    //
    // Browser sends `e.keyCode` values. These match macOS CGKeyCode for
    // A-Z (65-90 → 0-25 mapped below) and most special keys.
    // The browserToMac table covers the common cases; unmapped keys are dropped.

    private static let browserToMac: [Int: CGKeyCode] = [
        // Letters A-Z
        65: 0, 83: 1, 68: 2, 70: 3, 72: 4, 71: 5, 90: 6, 88: 7, 67: 8,
        86: 9, 66: 11, 81: 12, 87: 13, 69: 14, 82: 15, 89: 16, 84: 17,
        49: 18, // '1' — note: digits
        85: 32, 73: 34, 80: 35, 76: 37, 74: 38, 79: 31, 75: 40, 78: 45,
        77: 46, 59: 41, // semicolon
        // Digits 0-9 (top row)
        48: 29, // 0
        // (1 above = 18), 2=19, 3=20, 4=21, 5=23, 6=22, 7=26, 8=28, 9=25
        50: 19, 51: 20, 52: 21, 53: 23, 54: 22, 55: 26, 56: 28, 57: 25,
        // Special
        32: 49,  // Space
        13: 36,  // Return
        9:  48,  // Tab
        8:  51,  // Backspace/Delete
        27: 53,  // Escape
        37: 123, // Arrow Left
        39: 124, // Arrow Right
        38: 126, // Arrow Up
        40: 125, // Arrow Down
        46: 117, // Delete (forward)
        36: 115, // Home
        35: 119, // End
        33: 116, // Page Up
        34: 121, // Page Down
        // Modifier keys (sent but CGEventPost handles via flags)
        16: 56,  // Shift
        17: 59,  // Control
        18: 58,  // Alt/Option
        91: 55,  // Meta/Command (left)
        93: 54,  // Meta/Command (right)
        // Function keys
        112: 122, 113: 120, 114: 99, 115: 118, 116: 96, 117: 97,
        118: 98,  119: 100, 120: 101, 121: 109, 122: 103, 123: 111,
    ]

    private static func handleKey(_ json: [String: Any]) {
        guard let browserCode = json["keycode"] as? Int,
              let macCode = browserToMac[browserCode],
              let down = json["down"] as? Bool else { return }
        let rawFlags = json["flags"] as? UInt64 ?? 0
        let event = CGEvent(keyboardEventSource: eventSource, virtualKey: macCode, keyDown: down)
        if rawFlags != 0 {
            event?.flags = CGEventFlags(rawValue: rawFlags)
        }
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Clipboard

    private static func handleClipboard(_ json: [String: Any]) {
        guard let text = json["text"] as? String else { return }
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
