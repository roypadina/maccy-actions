import AppKit
import Defaults
import Foundation

// MARK: - Launch seam

/// Injectable launch seam so unit tests can capture launches instead of performing them.
@MainActor enum BuiltinLaunch {
  static var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
  static var openInApp: (_ fileOrURL: URL, _ appURL: URL) -> Void = { fileOrURL, appURL in
    _ = try? NSWorkspace.shared.open(
      [fileOrURL],
      withApplicationAt: appURL,
      configuration: NSWorkspace.OpenConfiguration()
    )
  }
}

// MARK: - Condition providers

/// Matches when the clipboard value is classified as the specified ValueKind.
struct KindCondition: ConditionProvider {

  let descriptor = ProviderDescriptor(
    id: "builtin.kind",
    name: "Value kind",
    description: "Matches when the copied item is a specific type — URL, email, phone number, file path, color, image, or text.",
    longHelp: "Choose a kind from the picker. The rule matches when the clipboard item belongs to that kind. One item can be several kinds at once — a web address is both a URL and text, so it matches either.",
    kind: .condition,
    engine: .native,
    params: [
      ParamSpec(
        key: "kind",
        label: "Kind",
        kind: .valueKind,
        placeholder: "url"
      )
    ],
    capabilities: [],
    source: .builtin
  )

  func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool {
    guard let kindString = params["kind"]?.stringValue else {
      throw BuiltinProviderError.missingParam("kind")
    }
    guard let kind = ValueKind(rawValue: kindString) else {
      throw BuiltinProviderError.invalidParam("kind", value: kindString)
    }
    return input.kinds.contains(kind)
  }
}

/// Matches when the clipboard text matches a regular expression pattern.
struct RegexCondition: ConditionProvider {

  let descriptor = ProviderDescriptor(
    id: "builtin.regex",
    name: "Regex match",
    description: "Matches when the copied text matches a regular expression pattern you provide.",
    longHelp: "Enter a regular expression in the Pattern field. The rule matches when the clipboard text fits the pattern anywhere in the text. Use ^ at the start and $ at the end of your pattern to require the whole text to match. An empty or invalid pattern never matches.",
    kind: .condition,
    engine: .native,
    params: [
      ParamSpec(
        key: "pattern",
        label: "Pattern",
        kind: .text,
        placeholder: "^https?://"
      )
    ],
    capabilities: [],
    source: .builtin
  )

  func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool {
    guard let pattern = params["pattern"]?.stringValue, !pattern.isEmpty else {
      return false
    }
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return false
    }
    let range = NSRange(input.string.startIndex..., in: input.string)
    return regex.firstMatch(in: input.string, range: range) != nil
  }
}

/// Matches when the clipboard text contains a substring (case-insensitive).
struct ContainsCondition: ConditionProvider {

  let descriptor = ProviderDescriptor(
    id: "builtin.contains",
    name: "Contains text",
    description: "Matches when the copied text contains the words you type — uppercase/lowercase doesn't matter.",
    longHelp: "Type any text in the Text field; the rule matches whenever the clipboard contains it, ignoring uppercase and lowercase differences. Leave it empty and it never matches.",
    kind: .condition,
    engine: .native,
    params: [
      ParamSpec(
        key: "needle",
        label: "Text",
        kind: .text,
        placeholder: "search term"
      )
    ],
    capabilities: [],
    source: .builtin
  )

  func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool {
    guard let needle = params["needle"]?.stringValue, !needle.isEmpty else {
      return false
    }
    return input.string.localizedCaseInsensitiveContains(needle)
  }
}

/// Matches when the clipboard was copied from the specified application (by bundle ID).
struct SourceAppCondition: ConditionProvider {

  let descriptor = ProviderDescriptor(
    id: "builtin.sourceApp",
    name: "Source application",
    description: "Matches when the text was copied from a specific app on your Mac.",
    longHelp: "Pick the app from the Application field (or type its identifier). The rule matches only when you copied the text while that app was in the foreground. If no app is selected, the rule never matches.",
    kind: .condition,
    engine: .native,
    params: [
      ParamSpec(
        key: "bundleID",
        label: "Bundle ID",
        kind: .bundleID,
        placeholder: "com.apple.Safari"
      )
    ],
    capabilities: [],
    source: .builtin
  )

  func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool {
    guard let bundleID = params["bundleID"]?.stringValue, !bundleID.isEmpty else {
      return false
    }
    return input.sourceAppBundleID == bundleID
  }
}

// MARK: - Action providers

/// Opens the clipboard text as a URL in the default browser or associated app.
struct OpenURLProvider: ActionProvider {

  let descriptor = ProviderDescriptor(
    id: "builtin.openURL",
    name: "Open as URL",
    description: "Opens the copied text as a link. Web addresses open in your browser; email addresses open in your mail app.",
    longHelp: "No setup needed. If the copied text already looks like a link it opens as-is. Text that looks like an email address opens your mail app. Anything else is treated as a web address. Fails if the text cannot be turned into a valid link.",
    kind: .action,
    engine: .native,
    params: [],
    capabilities: [],
    source: .builtin
  )

  func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome {
    guard let url = makeURL(from: input.string) else {
      throw ActionError.invalidURL
    }
    BuiltinLaunch.open(url)
    return .sideEffect
  }
}

/// Opens the clipboard content in a specific application identified by bundle ID.
struct OpenInAppProvider: ActionProvider {

  let descriptor = ProviderDescriptor(
    id: "builtin.openInApp",
    name: "Open in app",
    description: "Opens the copied text or file in a specific app you choose. Works with links and file paths.",
    longHelp: "Pick the app from the Application field. When the rule fires, the copied content is sent directly to that app — file paths open as files, links open as links. Fails if the chosen app is not installed on your Mac.",
    kind: .action,
    engine: .native,
    params: [
      ParamSpec(
        key: "bundleID",
        label: "Application",
        kind: .bundleID,
        placeholder: "com.apple.Safari"
      )
    ],
    capabilities: [],
    source: .builtin
  )

  func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome {
    guard let bundleID = params["bundleID"]?.stringValue, !bundleID.isEmpty else {
      throw ActionError.missingApp
    }
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      throw ActionError.missingApp
    }
    let urls: [URL]
    if !input.fileURLs.isEmpty {
      urls = input.fileURLs
    } else if let url = makeURL(from: input.string) {
      urls = [url]
    } else {
      throw ActionError.noValue
    }
    for url in urls {
      BuiltinLaunch.openInApp(url, appURL)
    }
    return .sideEffect
  }
}

/// Performs a web search for the clipboard text using a configurable URL template.
struct WebSearchProvider: ActionProvider {

  let descriptor = ProviderDescriptor(
    id: "builtin.webSearch",
    name: "Web search",
    description: "Searches the web for the copied text. Uses Google by default; swap in any search engine URL.",
    longHelp: "The copied text is inserted into the Search URL at the {query} placeholder and the result opens in your browser. The default is a Google search. To use a different search engine, replace the URL with that engine's search URL and put {query} where the search terms go. Fails if the clipboard is empty.",
    kind: .action,
    engine: .native,
    params: [
      ParamSpec(
        key: "template",
        label: "Search URL",
        kind: .text,
        placeholder: WebSearchTemplate.google
      )
    ],
    capabilities: [],
    source: .builtin
  )

  /// Builds the final search URL by percent-encoding `query` and substituting
  /// it into `template` at the `{query}` placeholder. Returns `nil` when the
  /// resulting string cannot be parsed as a URL with a scheme.
  static func buildSearchURL(template: String, query: String) -> URL? {
    let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
    let urlString = template.replacingOccurrences(of: "{query}", with: encoded)
    guard let url = URL(string: urlString), url.scheme != nil else { return nil }
    return url
  }

  func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome {
    guard !input.string.isEmpty else { throw ActionError.noValue }
    let template = params["template"]?.stringValue ?? WebSearchTemplate.google
    guard let url = WebSearchProvider.buildSearchURL(template: template, query: input.string) else {
      throw ActionError.invalidURL
    }
    BuiltinLaunch.open(url)
    return .sideEffect
  }
}

/// Runs a named Apple Shortcut with the clipboard text as input.
struct RunShortcutProvider: ActionProvider {

  let descriptor = ProviderDescriptor(
    id: "builtin.runShortcut",
    name: "Run Shortcut",
    description: "Runs one of your Shortcuts (from the Shortcuts app), passing the copied text to it.",
    longHelp: "Type the exact name of the shortcut in the Shortcut name field — it must already exist in your Shortcuts app. The copied text is handed to the shortcut as its input. The clipboard itself is left unchanged after the shortcut runs.",
    kind: .action,
    engine: .native,
    params: [
      ParamSpec(
        key: "shortcutName",
        label: "Shortcut name",
        kind: .text,
        placeholder: "My Shortcut"
      )
    ],
    capabilities: [],
    source: .builtin
  )

  func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome {
    guard let name = params["shortcutName"]?.stringValue, !name.isEmpty else {
      throw ActionError.missingShortcut
    }
    var components = URLComponents()
    components.scheme = "shortcuts"
    components.host = "run-shortcut"
    components.queryItems = [
      URLQueryItem(name: "name", value: name),
      URLQueryItem(name: "input", value: "text"),
      URLQueryItem(name: "text", value: input.string)
    ]
    guard let url = components.url else { throw ActionError.missingShortcut }
    BuiltinLaunch.open(url)
    return .sideEffect
  }
}

// MARK: - Registration

enum BuiltinProviders {
  /// Registers all eight built-in native providers into `registry`.
  /// Call once at boot (from `ActionEngine.init`) before any rule evaluation.
  @MainActor
  static func registerBuiltins(into registry: ProviderRegistry) {
    registry.register(condition: KindCondition())
    registry.register(condition: RegexCondition())
    registry.register(condition: ContainsCondition())
    registry.register(condition: SourceAppCondition())
    registry.register(action: OpenURLProvider())
    registry.register(action: OpenInAppProvider())
    registry.register(action: WebSearchProvider())
    registry.register(action: RunShortcutProvider())
  }
}

// MARK: - Internal errors

enum BuiltinProviderError: Error, Equatable {
  case missingParam(String)
  case invalidParam(String, value: String)
}
