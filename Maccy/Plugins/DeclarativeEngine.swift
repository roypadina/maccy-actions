import Foundation

enum DeclarativeError: Error, Equatable {
  case unknownOp(String)
  case badSpec
}

// MARK: - Action provider (transform-op fold)

struct DeclarativeActionProvider: ActionProvider {
  let descriptor: ProviderDescriptor
  let spec: JSONValue   // { "transform": [ { "op": ... }, ... ] }

  func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome {
    guard let ops = spec["transform"]?.arrayValue else {
      throw DeclarativeError.badSpec
    }
    var current = input.string
    for op in ops {
      current = try Self.apply(op, to: current)
    }
    return .replace(current)
  }

  private static func apply(_ op: JSONValue, to text: String) throws -> String {
    guard let name = op["op"]?.stringValue else {
      throw DeclarativeError.badSpec
    }
    switch name {
    case "regexReplace":
      guard let pattern = op["pattern"]?.stringValue,
            let replacement = op["replacement"]?.stringValue else {
        throw DeclarativeError.badSpec
      }
      let flags = op["flags"]?.stringValue ?? ""
      let options: NSRegularExpression.Options = flags.contains("i") ? [.caseInsensitive] : []
      guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
        throw DeclarativeError.badSpec
      }
      let range = NSRange(text.startIndex..., in: text)
      return regex.stringByReplacingMatches(
        in: text, range: range, withTemplate: replacement
      )

    case "case":
      guard let value = op["value"]?.stringValue else {
        throw DeclarativeError.badSpec
      }
      switch value {
      case "upper": return text.uppercased()
      case "lower": return text.lowercased()
      default:      throw DeclarativeError.badSpec
      }

    case "trim":
      return text.trimmingCharacters(in: .whitespacesAndNewlines)

    case "prepend":
      guard let prefix = op["text"]?.stringValue else {
        throw DeclarativeError.badSpec
      }
      return prefix + text

    case "append":
      guard let suffix = op["text"]?.stringValue else {
        throw DeclarativeError.badSpec
      }
      return text + suffix

    default:
      throw DeclarativeError.unknownOp(name)
    }
  }
}

// MARK: - Condition provider (predicate-tree evaluator)

struct DeclarativeConditionProvider: ConditionProvider {
  let descriptor: ProviderDescriptor
  let spec: JSONValue   // { "predicate": <tree> }

  func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool {
    guard let predicate = spec["predicate"] else {
      throw DeclarativeError.badSpec
    }
    return try Self.eval(predicate, input: input)
  }

  private static func eval(_ node: JSONValue, input: PluginInput) throws -> Bool {
    guard let object = node.objectValue else {
      throw DeclarativeError.badSpec
    }

    // Logical nodes.
    if let children = object["all"]?.arrayValue {
      for child in children where try !eval(child, input: input) {
        return false
      }
      return true
    }
    if let children = object["any"]?.arrayValue {
      for child in children where try eval(child, input: input) {
        return true
      }
      return false
    }
    if let child = object["not"] {
      return try !eval(child, input: input)
    }

    // Leaves.
    if let pattern = object["regex"]?.stringValue {
      guard let regex = try? NSRegularExpression(pattern: pattern) else {
        throw DeclarativeError.badSpec
      }
      let range = NSRange(input.string.startIndex..., in: input.string)
      return regex.firstMatch(in: input.string, range: range) != nil
    }
    if let needle = object["contains"]?.stringValue {
      return !needle.isEmpty && input.string.localizedCaseInsensitiveContains(needle)
    }
    if let rawKind = object["kind"]?.stringValue {
      guard let kind = ValueKind(rawValue: rawKind) else {
        throw DeclarativeError.badSpec
      }
      return input.kinds.contains(kind)
    }
    if let bundleID = object["sourceApp"]?.stringValue {
      return input.sourceAppBundleID == bundleID
    }

    throw DeclarativeError.badSpec
  }
}

// MARK: - Factory

enum DeclarativeEngine {
  /// Builds the declarative provider(s) declared by a manifest.
  /// Returns one provider on the side matching `manifest.kind`; empty if the
  /// manifest carries no `declarative` spec.
  static func makeProviders(
    manifest: PluginManifest,
    source: ProviderSource
  ) -> (conditions: [ConditionProvider], actions: [ActionProvider]) {
    guard let spec = manifest.declarative else {
      return (conditions: [], actions: [])
    }
    let descriptor = manifest.descriptor(source: source)
    switch manifest.kind {
    case .condition:
      let provider = DeclarativeConditionProvider(descriptor: descriptor, spec: spec)
      return (conditions: [provider], actions: [])
    case .action:
      let provider = DeclarativeActionProvider(descriptor: descriptor, spec: spec)
      return (conditions: [], actions: [provider])
    }
  }
}
