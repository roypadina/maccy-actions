import AppKit
import Defaults
import Foundation

// What an action does. `sendToAndroid` is reserved for the future clipboard-sync
// feature and is hidden/disabled in v1.
enum ActionType: String, Codable, CaseIterable, Identifiable {
  case openURL
  case openInApp
  case webSearch
  case transform
  case runShortcut
  case sendToAndroid

  var id: String { rawValue }

  var label: String {
    switch self {
    case .openURL: return "Open as URL"
    case .openInApp: return "Open in app"
    case .webSearch: return "Web search"
    case .transform: return "Transform text"
    case .runShortcut: return "Run Shortcut"
    case .sendToAndroid: return "Send to Android"
    }
  }

  var systemImage: String {
    switch self {
    case .openURL: return "safari"
    case .openInApp: return "app.badge"
    case .webSearch: return "magnifyingglass"
    case .transform: return "textformat"
    case .runShortcut: return "wand.and.stars"
    case .sendToAndroid: return "iphone"
    }
  }

  // Reserved actions are not offered in the editor yet.
  var isAvailable: Bool { self != .sendToAndroid }

  static var available: [ActionType] { allCases.filter(\.isAvailable) }
}

enum TransformKind: String, Codable, CaseIterable, Identifiable {
  case trim
  case uppercase
  case lowercase
  case stripFormatting

  var id: String { rawValue }

  var label: String {
    switch self {
    case .trim: return "Trim whitespace"
    case .uppercase: return "UPPERCASE"
    case .lowercase: return "lowercase"
    case .stripFormatting: return "Strip formatting"
    }
  }
}

// A single condition tested against a clipboard value. A rule ANDs/ORs several.
enum RuleCondition: Codable, Identifiable, Hashable {
  case kind(ValueKind)
  case regex(String)
  case contains(String)
  case sourceApp(String) // bundle identifier

  var id: String {
    switch self {
    case .kind(let value): return "kind:\(value.rawValue)"
    case .regex(let value): return "regex:\(value)"
    case .contains(let value): return "contains:\(value)"
    case .sourceApp(let value): return "app:\(value)"
    }
  }
}

enum MatchMode: String, Codable, CaseIterable, Identifiable {
  case all // AND
  case any // OR

  var id: String { rawValue }
  var label: String { self == .all ? "Match ALL conditions" : "Match ANY condition" }
}

// Persisted configuration for one action within a rule.
struct ActionConfig: Codable, Identifiable, Hashable {
  var id: UUID = UUID()
  var type: ActionType = .openURL
  var appBundleID: String?      // openInApp
  var searchTemplate: String?   // webSearch, e.g. https://www.google.com/search?q={query}
  var transform: TransformKind? // transform
  var shortcutName: String?     // runShortcut

  var title: String {
    switch type {
    case .openInApp:
      return appBundleID.map { "Open in \(Self.appName(for: $0))" } ?? "Open in app"
    case .transform:
      return transform?.label ?? "Transform text"
    case .runShortcut:
      return shortcutName.map { "Run “\($0)”" } ?? "Run Shortcut"
    default:
      return type.label
    }
  }

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
  var name: String = "New rule"
  var enabled: Bool = true
  var matchMode: MatchMode = .all
  var conditions: [RuleCondition] = []
  var actions: [ActionConfig] = []
  var autoRunDefault: Bool = false

  static let presets: [ActionRule] = [
    ActionRule(
      name: "Open links",
      conditions: [.kind(.url)],
      actions: [
        ActionConfig(type: .openURL),
        ActionConfig(type: .webSearch, searchTemplate: WebSearchTemplate.google)
      ]
    ),
    ActionRule(
      name: "Email address",
      conditions: [.kind(.email)],
      actions: [ActionConfig(type: .openURL)]
    ),
    ActionRule(
      name: "Search selected text",
      conditions: [.kind(.text)],
      actions: [ActionConfig(type: .webSearch, searchTemplate: WebSearchTemplate.google)]
    )
  ]
}

enum WebSearchTemplate {
  static let google = "https://www.google.com/search?q={query}"
}
