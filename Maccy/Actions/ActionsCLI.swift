import Defaults
import Foundation

// Headless CLI control surface for rules + the terminal-app list, invoked from
// `main.swift` when the binary is run as `Maccy rules …` / `Maccy terminals …`.
//
// Operates directly on the shared `Defaults` domain — it never touches
// `ActionEngine.shared` (that would spin up the @MainActor GUI singleton). All
// output is pretty JSON to stdout; errors go to stderr; exit 0 on success,
// non-zero on error. After any successful mutation it posts a distributed
// notification so a running GUI reloads (see `AppDelegate`).
enum ActionsCLI {
  static let rulesChangedNotification = "com.royp.MaccyActions.rulesChanged"

  // MARK: Entry point

  static func run(_ args: [String]) -> Int32 {
    // Populate the provider registry before any sub-command runs: `describe`
    // emits the registry catalog, and rule decode/validate reference provider
    // ids. Native providers only in Milestone A (no PluginLoader yet).
    registerProviders()

    guard let namespace = args.first else {
      return fail("Missing command. Expected 'rules' or 'terminals'.")
    }
    let rest = Array(args.dropFirst())
    switch namespace {
    case "rules": return runRules(rest)
    case "terminals": return runTerminals(rest)
    default: return fail("Unknown command: \(namespace). Expected 'rules' or 'terminals'.")
    }
  }

  // Register the native condition/action providers into the shared registry so
  // the headless CLI's `describe` catalog (and any registry-backed validation)
  // matches the running app. `ProviderRegistry` is @MainActor; the CLI has no
  // run loop, so we enter the actor synchronously (same pattern AppDelegate uses
  // for the distributed-notification reload).
  //
  // Milestone A: native providers only. Milestones B/C add a
  // `PluginLoader.loadAll(into:extraFolders:)` call here so the CLI catalog also
  // includes folder-loaded plugins.
  private static func registerProviders() {
    MainActor.assumeIsolated {
      BuiltinProviders.registerBuiltins(into: .shared)
      FirstPartyProviders.registerFirstParty(into: .shared)
    }
  }

  // MARK: rules

  private static func runRules(_ args: [String]) -> Int32 { // swiftlint:disable:this cyclomatic_complexity
    guard let sub = args.first else {
      return fail("Missing rules subcommand (list, get, add, update, remove, move, " +
                  "enable, disable, import, export, describe).")
    }
    let rest = Array(args.dropFirst())
    switch sub {
    case "list", "export": return rulesList()
    case "get": return rulesGet(rest)
    case "add": return rulesAdd(rest)
    case "update": return rulesUpdate(rest)
    case "remove": return rulesRemove(rest)
    case "move": return rulesMove(rest)
    case "enable": return rulesSetEnabled(rest, enabled: true)
    case "disable": return rulesSetEnabled(rest, enabled: false)
    case "import": return rulesImport(rest)
    case "describe": return rulesDescribe()
    default: return fail("Unknown rules subcommand: \(sub).")
    }
  }

  private static func rulesList() -> Int32 {
    emit(Defaults[.actionRules])
  }

  private static func rulesGet(_ args: [String]) -> Int32 {
    guard let id = args.first else { return fail("Usage: rules get <id>") }
    guard let rule = Defaults[.actionRules].first(where: { $0.id.uuidString == id }) else {
      return fail("No rule with id \(id).")
    }
    return emit(rule)
  }

  private static func rulesAdd(_ args: [String]) -> Int32 {
    let rule: ActionRule
    do {
      let data = try readInput(args)
      rule = try normalizedRule(from: data, forcingID: nil)
    } catch {
      return fail(describe(error))
    }
    do { try validate(rule) } catch { return fail(describe(error)) }
    var rules = Defaults[.actionRules]
    rules.append(rule)
    Defaults[.actionRules] = rules
    postChanged()
    return emit(rule)
  }

  private static func rulesUpdate(_ args: [String]) -> Int32 {
    guard let id = args.first else { return fail("Usage: rules update <id> (--json … | --file f | stdin)") }
    guard let uuid = UUID(uuidString: id) else { return fail("Invalid id: \(id).") }
    let rule: ActionRule
    do {
      let data = try readInput(Array(args.dropFirst()))
      rule = try normalizedRule(from: data, forcingID: uuid)
    } catch {
      return fail(describe(error))
    }
    do { try validate(rule) } catch { return fail(describe(error)) }
    var rules = Defaults[.actionRules]
    guard let index = rules.firstIndex(where: { $0.id == uuid }) else {
      return fail("No rule with id \(id).")
    }
    rules[index] = rule
    Defaults[.actionRules] = rules
    postChanged()
    return emit(rule)
  }

  private static func rulesRemove(_ args: [String]) -> Int32 {
    guard let id = args.first else { return fail("Usage: rules remove <id>") }
    var rules = Defaults[.actionRules]
    guard let index = rules.firstIndex(where: { $0.id.uuidString == id }) else {
      return fail("No rule with id \(id).")
    }
    rules.remove(at: index)
    Defaults[.actionRules] = rules
    postChanged()
    return 0
  }

  private static func rulesMove(_ args: [String]) -> Int32 {
    guard args.count >= 2 else { return fail("Usage: rules move <id> <index>") }
    let id = args[0]
    guard let target = Int(args[1]) else { return fail("Index must be an integer: \(args[1]).") }
    var rules = Defaults[.actionRules]
    guard let from = rules.firstIndex(where: { $0.id.uuidString == id }) else {
      return fail("No rule with id \(id).")
    }
    let rule = rules.remove(at: from)
    let clamped = max(0, min(target, rules.count))
    rules.insert(rule, at: clamped)
    Defaults[.actionRules] = rules
    postChanged()
    return emit(rules)
  }

  private static func rulesSetEnabled(_ args: [String], enabled: Bool) -> Int32 {
    guard let id = args.first else {
      return fail("Usage: rules \(enabled ? "enable" : "disable") <id>")
    }
    var rules = Defaults[.actionRules]
    guard let index = rules.firstIndex(where: { $0.id.uuidString == id }) else {
      return fail("No rule with id \(id).")
    }
    rules[index].enabled = enabled
    Defaults[.actionRules] = rules
    postChanged()
    return emit(rules[index])
  }

  private static func rulesImport(_ args: [String]) -> Int32 {
    let imported: [ActionRule]
    do {
      let data = try readInput(args)
      imported = try normalizedRules(from: data)
    } catch {
      return fail(describe(error))
    }
    for rule in imported {
      do { try validate(rule) } catch { return fail(describe(error)) }
    }
    Defaults[.actionRules] = imported
    postChanged()
    return emit(imported)
  }

  private static func rulesDescribe() -> Int32 {
    // Built from the LIVE provider registry so the catalog can't drift from the
    // installed providers. `ProviderRegistry` is @MainActor; enter synchronously
    // (the CLI has no run loop). `registerProviders()` ran in `run(_:)` first.
    let catalog: [String: Any] = MainActor.assumeIsolated {
      func encode(_ descriptors: [ProviderDescriptor]) -> [[String: Any]] {
        descriptors.map { descriptor -> [String: Any] in
          [
            "id": descriptor.id,
            "name": descriptor.name,
            "description": descriptor.description,
            "engine": descriptor.engine.rawValue,
            "params": descriptor.params.map { spec -> [String: Any] in
              [
                "key": spec.key,
                "label": spec.label,
                "kind": spec.kind.rawValue
              ]
            },
            "capabilities": descriptor.capabilities.map(\.rawValue),
            "verified": descriptor.isVerified
          ]
        }
      }

      let conditionProviders = encode(ProviderRegistry.shared.descriptors(kind: .condition))
      let actionProviders = encode(ProviderRegistry.shared.descriptors(kind: .action))

      return [
        "conditionProviders": conditionProviders,
        "actionProviders": actionProviders,
        "valueKinds": ValueKind.allCases.map(\.rawValue),
        "matchModes": MatchMode.allCases.map(\.rawValue),
        "shortcutGrammar": [
          "modifiers": [
            "cmd": ["cmd", "command", "⌘"],
            "shift": ["shift", "⇧"],
            "opt": ["opt", "option", "alt", "⌥"],
            "ctrl": ["ctrl", "control", "⌃"]
          ],
          "keys": [
            "letters a-z, digits 0-9",
            "space", "return/enter", "tab", "escape/esc",
            "delete/backspace", "f1-f12"
          ],
          "format": "modifiers and key joined by '+', case-insensitive",
          "example": "cmd+shift+u"
        ],
        "actionShortcutNote": "Optional per-action 'shortcut' field (e.g. \"cmd+shift+u\") " +
                              "runs that action unconditionally on the most recent clip.",
        "defaultTerminalApps": TerminalApps.defaults
      ]
    }

    return emitJSONObject(catalog)
  }

  // MARK: terminals

  private static func runTerminals(_ args: [String]) -> Int32 {
    guard let sub = args.first else {
      return fail("Missing terminals subcommand (list, add, remove, reset).")
    }
    let rest = Array(args.dropFirst())
    switch sub {
    case "list": return emit(Defaults[.terminalAppBundleIDs])
    case "add": return terminalsAdd(rest)
    case "remove": return terminalsRemove(rest)
    case "reset":
      Defaults[.terminalAppBundleIDs] = TerminalApps.defaults
      postChanged()
      return emit(Defaults[.terminalAppBundleIDs])
    default: return fail("Unknown terminals subcommand: \(sub).")
    }
  }

  private static func terminalsAdd(_ args: [String]) -> Int32 {
    guard let bundleID = args.first, !bundleID.isEmpty else {
      return fail("Usage: terminals add <bundleid>")
    }
    var list = Defaults[.terminalAppBundleIDs]
    if !list.contains(bundleID) {
      list.append(bundleID)
      Defaults[.terminalAppBundleIDs] = list
      postChanged()
    }
    return emit(list)
  }

  private static func terminalsRemove(_ args: [String]) -> Int32 {
    guard let bundleID = args.first, !bundleID.isEmpty else {
      return fail("Usage: terminals remove <bundleid>")
    }
    var list = Defaults[.terminalAppBundleIDs]
    list.removeAll { $0 == bundleID }
    Defaults[.terminalAppBundleIDs] = list
    postChanged()
    return emit(list)
  }

  // MARK: Input

  // Resolves the rule JSON payload from `--json '<…>'`, `--file <path>`, or, when
  // neither flag is present, stdin.
  private static func readInput(_ args: [String]) throws -> Data {
    var iterator = args.makeIterator()
    while let arg = iterator.next() {
      switch arg {
      case "--json":
        guard let value = iterator.next() else { throw CLIError("Missing value after --json.") }
        return Data(value.utf8)
      case "--file":
        guard let path = iterator.next() else { throw CLIError("Missing path after --file.") }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
          return try Data(contentsOf: url)
        } catch {
          throw CLIError("Could not read file \(path): \(error.localizedDescription)")
        }
      default:
        break
      }
    }
    let stdin = FileHandle.standardInput.readDataToEndOfFile()
    guard !stdin.isEmpty else {
      throw CLIError("No input. Provide --json '<…>', --file <path>, or pipe JSON via stdin.")
    }
    return stdin
  }

  // MARK: Decoding + default-filling

  // Decode a single rule, overlaying the partial JSON onto a default `ActionRule`
  // (and each action onto a default `ActionConfig`) so omitted fields take struct
  // defaults — Swift's synthesized Codable does NOT apply property defaults for
  // missing keys. Then generate any missing ids; `forcingID` overrides the rule id.
  private static func normalizedRule(from data: Data, forcingID: UUID?) throws -> ActionRule {
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CLIError("Expected a JSON object for a rule.")
    }
    // For `update` the rule id is dictated by the path arg, so drop any (possibly
    // malformed) body id rather than let it block the decode it would only overwrite.
    if forcingID != nil { object["id"] = nil }
    var rule = try decodeRule(overlaying: object)
    if let forcingID { rule.id = forcingID }
    return rule
  }

  // Decode a full array of rules (for `import`), applying defaults per element.
  private static func normalizedRules(from data: Data) throws -> [ActionRule] {
    guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      throw CLIError("Expected a JSON array of rules.")
    }
    return try array.map { try decodeRule(overlaying: $0) }
  }

  // Overlay a partial rule object onto the encoded defaults, then decode. The new
  // schema is `{provider, params}`: a default `ActionConfig()` encodes to
  // {"id": …, "provider": "builtin.openURL", "params": {}} and a default
  // `ActionRule()` to {…, "schemaVersion": 3, "conditions": [], "actions": []}.
  // `provider` and `params` are ordinary stored properties, so they merge through
  // the generic per-key overlay with no special-casing — only the "actions" array
  // (whose elements overlay onto a default ActionConfig) is handled specially.
  // Fresh ids are generated for the rule and any action that omitted one.
  private static func decodeRule(overlaying overlay: [String: Any]) throws -> ActionRule {
    let baseRule = try jsonObject(of: ActionRule())
    let baseAction = try jsonObject(of: ActionConfig(provider: "builtin.openURL"))

    var merged = baseRule
    let suppliesID = overlay["id"] != nil
    for (key, value) in overlay where key != "actions" {
      merged[key] = value
    }
    if !suppliesID { merged["id"] = UUID().uuidString }

    if let actions = overlay["actions"] {
      guard let actionObjects = actions as? [[String: Any]] else {
        throw CLIError("Rule 'actions' must be a JSON array of action objects.")
      }
      merged["actions"] = actionObjects.map { action -> [String: Any] in
        var m = baseAction
        let actionHasID = action["id"] != nil
        for (key, value) in action { m[key] = value }
        if !actionHasID { m["id"] = UUID().uuidString }
        return m
      }
    }

    let data = try JSONSerialization.data(withJSONObject: merged)
    do {
      return try JSONDecoder().decode(ActionRule.self, from: data)
    } catch {
      throw CLIError("Invalid rule: \(describe(error))")
    }
  }

  private static func jsonObject<T: Encodable>(of value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CLIError("Internal error: could not normalize defaults.")
    }
    return object
  }

  // MARK: Validation

  // Validates a rule before any write: provider ids must resolve in the registry,
  // and any per-action shortcut must parse. ParamSpec-level checks are the
  // provider's concern at run time, so no per-type required-field checks remain.
  // `ProviderRegistry` is @MainActor; the CLI has no run loop, so enter the actor
  // synchronously (providers were registered in `run(_:)`).
  private static func validate(_ rule: ActionRule) throws {
    try MainActor.assumeIsolated {
      for condition in rule.conditions {
        guard ProviderRegistry.shared.condition(condition.provider) != nil else {
          throw CLIError("Invalid rule: unknown condition provider \"\(condition.provider)\"")
        }
      }
      for action in rule.actions {
        guard ProviderRegistry.shared.action(action.provider) != nil else {
          throw CLIError("Invalid rule: unknown action provider \"\(action.provider)\"")
        }
        if let spec = action.shortcut, ShortcutSpec.parse(spec) == nil {
          throw CLIError("Invalid rule: unparseable shortcut \"\(spec)\"")
        }
      }
    }
  }

  // MARK: Output

  @discardableResult
  private static func emit<T: Encodable>(_ value: T) -> Int32 {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      let data = try encoder.encode(value)
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data("\n".utf8))
      return 0
    } catch {
      return fail("Failed to encode output: \(describe(error))")
    }
  }

  private static func emitJSONObject(_ object: [String: Any]) -> Int32 {
    do {
      let data = try JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data("\n".utf8))
      return 0
    } catch {
      return fail("Failed to encode catalog: \(describe(error))")
    }
  }

  @discardableResult
  private static func fail(_ message: String) -> Int32 {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    return 1
  }

  private static func describe(_ error: Error) -> String {
    if let cliError = error as? CLIError { return cliError.message }
    if let decoding = error as? DecodingError {
      switch decoding {
      case .keyNotFound(let key, _):
        return "Missing required field '\(key.stringValue)'."
      case .typeMismatch(_, let context), .valueNotFound(_, let context),
           .dataCorrupted(let context):
        return context.debugDescription
      @unknown default:
        return "\(decoding)"
      }
    }
    return error.localizedDescription
  }

  // MARK: Live reload

  private static func postChanged() {
    DistributedNotificationCenter.default().postNotificationName(
      .init(rulesChangedNotification), object: nil, userInfo: nil, deliverImmediately: true)
  }

  private struct CLIError: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }
}
