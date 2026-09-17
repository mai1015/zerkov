// Test-host wrapper only. Keep a real display large enough for an exact-1080
// window while the recording command runs, then restore the original mode.
// CGDisplaySetDisplayMode is synchronous and scoped to this process lifetime.
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
let suitable = modes.filter { $0.width >= 1920 && $0.height >= 1080 }.sorted {
    let left = $0.width * $0.height
    let right = $1.width * $1.height
    if left != right { return left < right }
    return $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight
}
guard let mode = suitable.first else {
    for mode in modes { print("EQUIPMENT_DISPLAY available=\(mode.width)x\(mode.height) pixels=\(mode.pixelWidth)x\(mode.pixelHeight)") }
    fputs("EQUIPMENT_DISPLAY_FAILED: native 1920x1080 window cannot fit; do not scale evidence\n", stderr)
    exit(1)
}
let changed = CGDisplaySetDisplayMode(display, mode, nil)
guard changed == .success else {
    fputs("EQUIPMENT_DISPLAY_FAILED: mode switch returned \(changed.rawValue)\n", stderr)
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
let restored = CGDisplaySetDisplayMode(display, original, nil)
if restored != .success {
    fputs("EQUIPMENT_DISPLAY_FAILED: restoration returned \(restored.rawValue)\n", stderr)
    status = 1
}
exit(status)
