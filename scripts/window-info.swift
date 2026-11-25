// Prints what the window server knows about a process's largest on-screen window (the notes
// panel): "<alpha> <sharingState>". Used by scripts/gui-checks.sh, because opacity and the
// capture setting aren't visible through Accessibility. sharingState 0 means hidden from capture.
// Usage: window-info <pid>
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: window-info <pid>\n".utf8))
    exit(2)
}
let all =
    CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let mine = all.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
func area(_ w: [String: Any]) -> Double {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
}
guard let panel = mine.max(by: { area($0) < area($1) }) else { exit(1) }
let alpha = panel[kCGWindowAlpha as String] as? Double ?? -1
let sharing = panel[kCGWindowSharingState as String] as? Int ?? -1
print(String(format: "%.2f %d", alpha, sharing))
