// Test-host wrapper only. The equipment runner records in native fullscreen:
// the hosted Mac offers 1920x1080, but its windowed desktop loses 109 pixels to
// the Dock/menu bar. Do not rescale footage or relax the final capture guard.
// Restore the original display mode after the recording command exits.
import Foundation
import CoreGraphics
import Darwin

let command = Array(CommandLine.arguments.dropFirst())
guard !command.isEmpty else {
    fputs("Usage: swift with_macos_capture_display.swift command [arguments...]\n", stderr)
    exit(2)
}
let display = CGMainDisplayID()
guard let original = CGDisplayCopyDisplayMode(display),
      let modes = CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode] else {
    fputs("EQUIPMENT_DISPLAY_FAILED: no active display/mode inventory\n", stderr)
    exit(1)
}
print("EQUIPMENT_DISPLAY original=\(original.width)x\(original.height) pixels=\(original.pixelWidth)x\(original.pixelHeight)")
guard let mode = modes.first(where: {
    $0.width == 1920 && $0.height == 1080 && $0.pixelWidth == 1920 && $0.pixelHeight == 1080
}) else {
    for mode in modes { print("EQUIPMENT_DISPLAY available=\(mode.width)x\(mode.height) pixels=\(mode.pixelWidth)x\(mode.pixelHeight)") }
    fputs("EQUIPMENT_DISPLAY_FAILED: no native exact-1080 mode; do not scale evidence\n", stderr)
    exit(1)
}
let changed = CGDisplaySetDisplayMode(display, mode, nil)
guard changed == .success else {
    fputs("EQUIPMENT_DISPLAY_FAILED: mode switch returned \(changed.rawValue)\n", stderr)
    exit(1)
}
print("EQUIPMENT_DISPLAY selected=\(mode.width)x\(mode.height) pixels=\(mode.pixelWidth)x\(mode.pixelHeight) capture=fullscreen")
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
let restored = CGDisplaySetDisplayMode(display, original, nil)
if restored != .success {
    fputs("EQUIPMENT_DISPLAY_FAILED: restoration returned \(restored.rawValue)\n", stderr)
    status = 1
}
exit(status)
