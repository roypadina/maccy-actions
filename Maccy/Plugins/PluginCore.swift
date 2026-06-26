import Foundation

// MARK: - JSONValue

enum JSONValue: Codable, Hashable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case array([JSONValue])
  case object([String: JSONValue])
  case null

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let d = try? c.decode(Double.self) {
      self = .number(d)
    } else if let s = try? c.decode(String.self) {
      self = .string(s)
    } else if let a = try? c.decode([JSONValue].self) {
      self = .array(a)
    } else if let o = try? c.decode([String: JSONValue].self) {
      self = .object(o)
    } else if c.decodeNil() {
      self = .null
    } else {
      throw DecodingError.dataCorruptedError(
        in: c, debugDescription: "Cannot decode JSONValue"
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let s): try c.encode(s)
    case .number(let d): try c.encode(d)
    case .bool(let b):   try c.encode(b)
    case .array(let a):  try c.encode(a)
    case .object(let o): try c.encode(o)
    case .null:          try c.encodeNil()
    }
  }

  var stringValue: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  var doubleValue: Double? {
    if case .number(let d) = self { return d }
    return nil
  }

  var intValue: Int? {
    if case .number(let d) = self { return Int(exactly: d) ?? Int(d) }
    return nil
  }

  var boolValue: Bool? {
    if case .bool(let b) = self { return b }
    return nil
  }

  var arrayValue: [JSONValue]? {
    if case .array(let a) = self { return a }
    return nil
  }

  var objectValue: [String: JSONValue]? {
    if case .object(let o) = self { return o }
    return nil
  }

  subscript(_ key: String) -> JSONValue? {
    objectValue?[key]
  }

  static var emptyObject: JSONValue { .object([:]) }
}

// MARK: - PluginInput

struct PluginInput {
  let string: String
  let kinds: Set<ValueKind>
  let sourceAppBundleID: String?
  let fileURLs: [URL]
}

// MARK: - ActionOutcome

enum ActionOutcome: Equatable {
  case replace(String)
  case sideEffect
  case none
}

// MARK: - Capability

enum Capability: String, Codable, Hashable, CaseIterable {
  case network
  case fileRead
  case fileWrite
  case storage

  var label: String {
    switch self {
    case .network:   return "Network access"
    case .fileRead:  return "File read"
    case .fileWrite: return "File write"
    case .storage:   return "Local storage"
    }
  }

  var consentSentence: String {
    switch self {
    case .network:
      return "Send the text you run it on — which may include passwords — over the network."
    case .fileRead:
      return "Read files from your Mac."
    case .fileWrite:
      return "Write or modify files on your Mac."
    case .storage:
      return "Store data persistently on your Mac."
    }
  }
}

// MARK: - ProviderKind / ProviderEngine

enum ProviderKind: String, Codable, Hashable {
  case condition
  case action
}

enum ProviderEngine: String, Codable, Hashable {
  case native
  case declarative
  case javascript
}

// MARK: - ProviderSource

enum ProviderSource: Codable, Hashable {
  case builtin
  case bundled
  case marketplace(String)
  case local(String)

  var isVerified: Bool {
    switch self {
    case .builtin, .bundled:         return true
    case .marketplace(let id):       return id == "maccyplus-official"
    case .local:                     return false
    }
  }

  private enum CodingKeys: String, CodingKey { case type, payload }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let type = try c.decode(String.self, forKey: .type)
    switch type {
    case "builtin":
      self = .builtin
    case "bundled":
      self = .bundled
    case "marketplace":
      let payload = try c.decode(String.self, forKey: .payload)
      self = .marketplace(payload)
    case "local":
      let payload = try c.decode(String.self, forKey: .payload)
      self = .local(payload)
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: c, debugDescription: "Unknown ProviderSource type: \(type)"
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .builtin:
      try c.encode("builtin", forKey: .type)
    case .bundled:
      try c.encode("bundled", forKey: .type)
    case .marketplace(let id):
      try c.encode("marketplace", forKey: .type)
      try c.encode(id, forKey: .payload)
    case .local(let path):
      try c.encode("local", forKey: .type)
      try c.encode(path, forKey: .payload)
    }
  }
}

// MARK: - ParamKind / ParamSpec

enum ParamKind: String, Codable, Hashable {
  case text
  case valueKind
  case bundleID
}

struct ParamSpec: Codable, Hashable, Identifiable {
  var id: String { key }
  let key: String
  let label: String
  let kind: ParamKind
  let placeholder: String?
}

// MARK: - ProviderDescriptor

struct ProviderDescriptor: Identifiable, Hashable {
  let id: String
  let name: String
  let description: String
  let longHelp: String?
  let kind: ProviderKind
  let engine: ProviderEngine
  let params: [ParamSpec]
  let capabilities: [Capability]
  let source: ProviderSource

  /// The id of the package (plugin) this provider belongs to; nil for core
  /// built-ins, which are not owned by any installable package.
  let pluginID: String?
  /// The display name of the owning package; nil for core built-ins.
  let pluginName: String?

  var isVerified: Bool { source.isVerified }

  /// Trailing `pluginID`/`pluginName` default to nil so existing call sites
  /// (BuiltinProviders, tests) construct unchanged and read as having no
  /// owning package.
  init(
    id: String,
    name: String,
    description: String,
    longHelp: String?,
    kind: ProviderKind,
    engine: ProviderEngine,
    params: [ParamSpec],
    capabilities: [Capability],
    source: ProviderSource,
    pluginID: String? = nil,
    pluginName: String? = nil
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.longHelp = longHelp
    self.kind = kind
    self.engine = engine
    self.params = params
    self.capabilities = capabilities
    self.source = source
    self.pluginID = pluginID
    self.pluginName = pluginName
  }
}

// MARK: - Protocols

@MainActor protocol ConditionProvider {
  var descriptor: ProviderDescriptor { get }
  func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool
}

@MainActor protocol ActionProvider {
  var descriptor: ProviderDescriptor { get }
  func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome
}
