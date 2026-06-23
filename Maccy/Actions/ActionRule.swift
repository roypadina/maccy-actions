import AppKit
import Defaults
import Foundation

// MatchMode: unchanged contract.
enum MatchMode: String, Codable, CaseIterable, Identifiable {
  case all // AND
  case any // OR

  var id: String { rawValue }
  var label: String { self == .all ? "Match ALL conditions" : "Match ANY condition" }
}

// A single condition referencing a provider by id.
struct RuleCondition: Codable, Identifiable, Hashable {
  var id: UUID = UUID()
  var provider: String                 // e.g. "builtin.kind", "com.maccay.soft-wrap"
  var params: JSONValue = .object([:])
}

// Persisted configuration for one action within a rule.
struct ActionConfig: Codable, Identifiable, Hashable {
  var id: UUID = UUID()
  var provider: String                 // e.g. "builtin.openURL", "com.maccay.unwrap"
  var params: JSONValue = .object([:])
  var shortcut: String?                // per-action keyboard shortcut, e.g. "cmd+shift+u"

  // Display name for a bundle id. Retained from the pre-swap ActionConfig
  // because the GUI (TerminalAppsEditor / app picker, Part 5) still calls it.
  static func appName(for bundleID: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      return url.deletingPathExtension().lastPathComponent
    }
    return bundleID
  }
}

// A user-defined rule: when its conditions match, its (ordered) actions become
// available. The first action is the default.
struct ActionRule: Codable, Identifiable, Hashable, Defaults.Serializable {
  var id: UUID = UUID()
  var schemaVersion: Int = 3
  var name: String = "New rule"
  var enabled: Bool = true
  var matchMode: MatchMode = .all
  var conditions: [RuleCondition] = []
  var actions: [ActionConfig] = []
  var autoRunDefault: Bool = false

  static let presets: [ActionRule] = [
    // Open links — kind == url → openURL or webSearch
    ActionRule(
      name: "Open links",
      conditions: [
        RuleCondition(
          provider: "builtin.kind",
          params: .object(["kind": .string("url")])
        )
      ],
      actions: [
        ActionConfig(
          provider: "builtin.openURL",
          params: .emptyObject
        ),
        ActionConfig(
          provider: "builtin.webSearch",
          params: .object(["template": .string(WebSearchTemplate.google)])
        )
      ]
    ),

    // Email address — kind == email → openURL (opens mailto:)
    ActionRule(
      name: "Email address",
      conditions: [
        RuleCondition(
          provider: "builtin.kind",
          params: .object(["kind": .string("email")])
        )
      ],
      actions: [
        ActionConfig(
          provider: "builtin.openURL",
          params: .emptyObject
        )
      ]
    ),

    // Search selected text — kind == text → webSearch
    ActionRule(
      name: "Search selected text",
      conditions: [
        RuleCondition(
          provider: "builtin.kind",
          params: .object(["kind": .string("text")])
        )
      ],
      actions: [
        ActionConfig(
          provider: "builtin.webSearch",
          params: .object(["template": .string(WebSearchTemplate.google)])
        )
      ]
    ),

    // Unwrap terminal command — terminal-source AND soft-wrap → unwrap (auto-run)
    ActionRule(
      name: "Unwrap terminal command",
      matchMode: .all,
      conditions: [
        RuleCondition(
          provider: "com.maccay.terminal-source",
          params: .emptyObject
        ),
        RuleCondition(
          provider: "com.maccay.soft-wrap",
          params: .emptyObject
        )
      ],
      actions: [
        ActionConfig(
          provider: "com.maccay.unwrap",
          params: .emptyObject
        )
      ],
      autoRunDefault: true
    )
  ]
}

enum WebSearchTemplate {
  static let google = "https://www.google.com/search?q={query}"
}
