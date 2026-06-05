import AppKit

struct Accessibility {
  static var allowed: Bool { AXIsProcessTrusted() }

  static func check() {
    guard !allowed else {
      return
    }
    // Show the system "grant Accessibility" prompt. This lets macOS register the
    // correct (current) binary itself, instead of relying on a manual drag-in
    // that TCC churn keeps invalidating.
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }
}
