import AppKit
import Foundation

// Runtime behaviour of an action. Built from an `ActionConfig` by `ActionFactory`.
// New action types (including a future `SendToAndroidAction`) conform here and
// the engine/UI pick them up without changes.
@MainActor
protocol ClipboardAction {
  var id: String { get }
  var title: String { get }
  var systemImage: String { get }
  func canRun(on item: HistoryItem) -> Bool
  func run(on item: HistoryItem) async throws
}

enum ActionError: Error {
  case invalidURL
  case missingApp
  case missingShortcut
  case noValue
}

enum ActionFactory {
  @MainActor
  static func make(_ config: ActionConfig) -> ClipboardAction? {
    switch config.type {
    case .openURL:
      return OpenURLAction()
    case .openInApp:
      guard let bundleID = config.appBundleID, !bundleID.isEmpty else { return nil }
      return OpenInAppAction(bundleID: bundleID)
    case .webSearch:
      return WebSearchAction(template: config.searchTemplate ?? WebSearchTemplate.google)
    case .transform:
      return TransformAction(kind: config.transform ?? .trim)
    case .runShortcut:
      guard let name = config.shortcutName, !name.isEmpty else { return nil }
      return RunShortcutAction(shortcutName: name)
    case .sendToAndroid:
      return nil // Feature 1; not available in v1
    }
  }
}

// Builds an openable URL from arbitrary clipboard text: respects an existing
// scheme, turns bare emails into mailto:, otherwise assumes https.
func makeURL(from string: String) -> URL? {
  let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
  if let url = URL(string: trimmed), url.scheme != nil { return url }
  if trimmed.contains("@"), let url = URL(string: "mailto:\(trimmed)") { return url }
  return URL(string: "https://\(trimmed)")
}

// MARK: - Concrete actions

struct OpenURLAction: ClipboardAction {
  let id = "openURL"
  let title = "Open as URL"
  let systemImage = "safari"

  func canRun(on item: HistoryItem) -> Bool {
    makeURL(from: ValueClassifier.primaryString(of: item)) != nil
  }

  func run(on item: HistoryItem) async throws {
    guard let url = makeURL(from: ValueClassifier.primaryString(of: item)) else {
      throw ActionError.invalidURL
    }
    NSWorkspace.shared.open(url)
  }
}

struct OpenInAppAction: ClipboardAction {
  let bundleID: String

  var id: String { "openInApp:\(bundleID)" }
  var title: String { "Open in \(ActionConfig.appName(for: bundleID))" }
  let systemImage = "app.badge"

  func canRun(on item: HistoryItem) -> Bool {
    guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
      return false
    }
    return !item.fileURLs.isEmpty || makeURL(from: ValueClassifier.primaryString(of: item)) != nil
  }

  func run(on item: HistoryItem) async throws {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      throw ActionError.missingApp
    }
    let urls: [URL]
    if !item.fileURLs.isEmpty {
      urls = item.fileURLs
    } else if let url = makeURL(from: ValueClassifier.primaryString(of: item)) {
      urls = [url]
    } else {
      throw ActionError.noValue
    }
    _ = try await NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
  }
}

struct WebSearchAction: ClipboardAction {
  let template: String

  let id = "webSearch"
  let title = "Web search"
  let systemImage = "magnifyingglass"

  func canRun(on item: HistoryItem) -> Bool {
    !ValueClassifier.primaryString(of: item).isEmpty
  }

  func run(on item: HistoryItem) async throws {
    let query = ValueClassifier.primaryString(of: item)
    guard !query.isEmpty else { throw ActionError.noValue }
    let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
    guard let url = URL(string: template.replacingOccurrences(of: "{query}", with: encoded)) else {
      throw ActionError.invalidURL
    }
    NSWorkspace.shared.open(url)
  }
}

struct TransformAction: ClipboardAction {
  let kind: TransformKind

  var id: String { "transform:\(kind.rawValue)" }
  var title: String { kind.label }
  let systemImage = "textformat"

  func canRun(on item: HistoryItem) -> Bool {
    !ValueClassifier.primaryString(of: item).isEmpty
  }

  func run(on item: HistoryItem) async throws {
    let value = ValueClassifier.primaryString(of: item)
    guard !value.isEmpty else { throw ActionError.noValue }
    let result: String
    switch kind {
    case .trim: result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    case .uppercase: result = value.uppercased()
    case .lowercase: result = value.lowercased()
    case .stripFormatting: result = value // already the plain-string representation
    }
    // Record the output so the clipboard poller's echo doesn't auto-trigger again.
    ActionEngine.shared.noteAutoOutput(result)
    Clipboard.shared.copy(result)
  }
}

struct RunShortcutAction: ClipboardAction {
  let shortcutName: String

  var id: String { "runShortcut:\(shortcutName)" }
  var title: String { "Run “\(shortcutName)”" }
  let systemImage = "wand.and.stars"

  func canRun(on item: HistoryItem) -> Bool { true }

  func run(on item: HistoryItem) async throws {
    let value = ValueClassifier.primaryString(of: item)
    var components = URLComponents()
    components.scheme = "shortcuts"
    components.host = "run-shortcut"
    components.queryItems = [
      URLQueryItem(name: "name", value: shortcutName),
      URLQueryItem(name: "input", value: "text"),
      URLQueryItem(name: "text", value: value)
    ]
    guard let url = components.url else { throw ActionError.missingShortcut }
    NSWorkspace.shared.open(url)
  }
}

// MARK: - Sync seam (Feature 1: Android clipboard sync)

// Reserved interface so a future `SendToAndroidAction` can delegate here without
// any engine changes. No implementation ships in v1.
@MainActor
protocol SyncService {
  func send(_ value: String) async throws
}
