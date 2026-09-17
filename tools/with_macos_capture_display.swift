// Test-host wrapper only. A 1920x1080 monitor does not fit a 1920x1080
// window when the Dock/menu bar reserve part of the desktop. Select by the
// actual usable area, keep the native capture guard, and restore the mode.
import Foundation
import AppKit
import CoreGraphics
import Darwin

let command = Array(CommandLine.arguments.dropFirst())
guard !command.isEmpty else {
    fputs("Usage: swift with_macos_capture_display.swift command [arguments...]\n", stderr)
    exit(2)
}
let application = NSApplication.shared
let display = CGMainDisplayID()
guard let original = CGDisplayCopyDisplayMode(display),
      let modes = CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode] else {
    fputs("EQUIPMENT_DISPLAY_FAILED: no active display/mode inventory\n", stderr)
    exit(1)
}
print("EQUIPMENT_DISPLAY original=\(original.width)x\(original.height) pixels=\(original.pixelWidth)x\(original.pixelHeight)")
let suitable = modes.filter { $0.width >= 1920 && $0.height >= 1080 }.sorted {
    let left = $0.width * $0.height
    let right = $1.width * $1.height
    if left != right { return left < right }
    return $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight
}
func usableFrame() -> NSRect? {
    return NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
    }?.visibleFrame
}
func restoreDisplay() -> Bool {
    let result = CGDisplaySetDisplayMode(display, original, nil)
    if result != .success {
        fputs("EQUIPMENT_DISPLAY_FAILED: restoration returned \(result.rawValue)\n", stderr)
        return false
    }
    return true
}
var selected: CGDisplayMode?
for mode in suitable {
    let changed = CGDisplaySetDisplayMode(display, mode, nil)
    if changed != .success {
        print("EQUIPMENT_DISPLAY skipped=\(mode.width)x\(mode.height) switch_error=\(changed.rawValue)")
        continue
    }
    // Let AppKit consume the mode-change notification before querying the
    // visible area. Never accept the previous mode's cached screen geometry.
    for _ in 0..<20 {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }), Int(screen.frame.width) == mode.width, Int(screen.frame.height) == mode.height {
            break
        }
    }
    guard let frame = usableFrame() else { continue }
    print("EQUIPMENT_DISPLAY candidate=\(mode.width)x\(mode.height) usable=\(Int(frame.width))x\(Int(frame.height))")
    if frame.width >= 1920 && frame.height >= 1080 {
        selected = mode
        break
    }
}
guard let mode = selected else {
    for mode in modes { print("EQUIPMENT_DISPLAY available=\(mode.width)x\(mode.height) pixels=\(mode.pixelWidth)x\(mode.pixelHeight)") }
    fputs("EQUIPMENT_DISPLAY_FAILED: no usable desktop fits a native 1920x1080 window; do not scale evidence\n", stderr)
    _ = restoreDisplay()
    exit(1)
}
print("EQUIPMENT_DISPLAY selected=\(mode.width)x\(mode.height) pixels=\(mode.pixelWidth)x\(mode.pixelHeight)")
fflush(stdout)
let child = Process()
child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
child.arguments = command
var status: Int32 = 1
do {
    try child.run()
    child.waitUntilExit()
    status = child.terminationReason == .exit ? child.terminationStatus : 1
} catch {
    fputs("EQUIPMENT_DISPLAY_FAILED: launch: \(error)\n", stderr)
}
if !restoreDisplay() { status = 1 }
exit(status)
