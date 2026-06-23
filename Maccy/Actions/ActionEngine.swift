import AppKit
import Defaults
import Foundation
import KeyboardShortcuts
import Observation

extension Defaults.Keys {
  static let actionRules = Key<[ActionRule]>("actionRulesV3", default: ActionRule.presets)
  static let terminalAppBundleIDs = Key<[String]>("terminalAppBundleIDs", default: TerminalApps.defaults)
}

extension KeyboardShortcuts.Name {
  // No default binding to avoid colliding with other apps; user assigns it.
  static let runDefaultAction = Self("runDefaultAction")
}

// Evaluates rules against clipboard items and runs the resulting actions.
// Rules are read live from `Defaults` so the settings UI can edit them directly.
@MainActor
@Observable
final class ActionEngine {
  static let shared = ActionEngine()

  // Last value produced by an auto-run transform, used to swallow the clipboard
  // poller's echo so auto-run doesn't loop forever.
  private var lastAutoOutput: String?

  // Per-action shortcut Names we've already wired an onKeyDown handler for.
  // The handler re-resolves the config by id at fire time, so it survives rule
  // edits/reloads without re-registering (which would clobber other handlers).
  private var registeredActionShortcutNames = Set<String>()

  // Set once the built-in + first-party providers have been registered, so a
  // second init (or an explicit registerProviders() call) is a cheap no-op.
  private var providersRegistered = false

  private init() {
    registerProviders()
  }

  // Idempotently register the native built-in and first-party providers into
  // the shared registry. Built-ins: builtin.kind/regex/contains/sourceApp +
  // builtin.openURL/openInApp/webSearch/runShortcut. First-party:
  // com.maccay.soft-wrap/terminal-source + the six transform actions.
  func registerProviders() {
    guard !providersRegistered else { return }
    providersRegistered = true
    BuiltinProviders.registerBuiltins(into: .shared)
    FirstPartyProviders.registerFirstParty(into: .shared)
  }

  var rules: [ActionRule] { Defaults[.actionRules] }

  // Build the provider input for an item from the same primitives the old
  // switch used: primary string, all matching ValueKinds, the source app
  // bundle id, and the file URLs (for openInApp / filePath providers).
  private func makeInput(from item: HistoryItem) -> PluginInput {
    PluginInput(
      string: ValueClassifier.primaryString(of: item),
      kinds: ValueClassifier.kinds(of: item),
      sourceAppBundleID: item.application,
      fileURLs: item.fileURLs
    )
  }

  // MARK: Matching

  func matchingRules(for item: HistoryItem) -> [ActionRule] {
    let input = makeInput(from: item)
    return rules.filter { $0.enabled && matches($0, input: input) }
  }

  private func matches(_ rule: ActionRule, input: PluginInput) -> Bool {
    guard !rule.conditions.isEmpty else { return false }

    let results = rule.conditions.map { cond -> Bool in
      guard let provider = ProviderRegistry.shared.condition(cond.provider) else {
        return false
      }
      return (try? provider.evaluate(input, params: cond.params)) ?? false
    }

    return rule.matchMode == .all ? !results.contains(false) : results.contains(true)
  }

  // MARK: Resolution

  // All runnable actions for an item, in rule order then action order, deduped by
  // provider id. The first element is the default. Each item carries a `run`
  // closure that dispatches the action through the registry (`runProvider`),
  // preserving the `.replace` echo-guard ordering. Title comes from the provider
  // descriptor's name; the icon is a generic action glyph (descriptors carry no
  // system image). Surfaces the popup right-click menu, ⌃1…⌃9, and the slideout
  // Actions list.
  func resolvedActions(for item: HistoryItem) -> [RowActionItem] {
    let input = makeInput(from: item)
    var seen = Set<String>()
    var result: [RowActionItem] = []
    for rule in matchingRules(for: item) {
      for config in rule.actions {
        guard let descriptor = ProviderRegistry.shared.action(config.provider)?.descriptor else {
          continue
        }
        guard seen.insert(config.provider).inserted else { continue }
        let providerID = config.provider
        let params = config.params
        result.append(
          RowActionItem(
            id: providerID,
            title: descriptor.name,
            systemImage: "bolt"
          ) { [weak self] in
            self?.runProvider(providerID, params: params, input: input)
          }
        )
      }
    }
    return result
  }

  // MARK: Running

  // Resolve `providerID` to an ActionProvider and run it on `input`. Mirrors the
  // old run(_:on:): a detached MainActor Task, any throw swallowed with a beep.
  // A `.replace(s)` outcome is the auto-transform path — note it as the expected
  // echo (loop guard) BEFORE writing the clipboard, exactly like the old
  // TransformAction did. `.sideEffect` / `.none` write nothing.
  private func runProvider(_ providerID: String, params: JSONValue, input: PluginInput) {
    guard let provider = ProviderRegistry.shared.action(providerID) else {
      NSSound.beep()
      return
    }
    Task {
      do {
        let outcome = try await provider.run(input, params: params)
        switch outcome {
        case .replace(let value):
          ActionEngine.shared.noteAutoOutput(value)
          Clipboard.shared.copy(value)
        case .sideEffect, .none:
          break
        }
      } catch {
        NSSound.beep()
      }
    }
  }

  // Global-shortcut entry point: run the default action on the most recent item.
  // The default action is the first action of the first matching (enabled) rule.
  func runDefaultActionForCurrent() {
    guard let item = History.shared.unpinnedItems.first?.item ?? History.shared.all.first?.item else {
      NSSound.beep()
      return
    }
    let input = makeInput(from: item)
    guard let rule = matchingRules(for: item).first,
          let config = rule.actions.first else {
      NSSound.beep()
      return
    }
    runProvider(config.provider, params: config.params, input: input)
  }

  // MARK: Per-action shortcuts

  // Wire (or rewire) the per-action hotkeys from the current rules. Safe to call
  // repeatedly: each Name's handler is registered once and re-resolves its config
  // at fire time, while `setShortcut` is updated to reflect the latest binding.
  // Never calls `removeAllHandlers()` (that would clobber popup/pin/etc.).
  func registerShortcuts() {
    for rule in Defaults[.actionRules] {
      for config in rule.actions {
        let name = KeyboardShortcuts.Name("action_\(config.id.uuidString)")
        if let spec = config.shortcut, let parsed = ShortcutSpec.parse(spec) {
          KeyboardShortcuts.setShortcut(parsed, for: name)
        } else {
          KeyboardShortcuts.setShortcut(nil, for: name)
        }
        if registeredActionShortcutNames.insert(name.rawValue).inserted {
          let actionID = config.id
          KeyboardShortcuts.onKeyDown(for: name) {
            ActionEngine.shared.runSpecificActionForCurrent(actionID: actionID)
          }
        }
      }
    }
  }

  // Re-read rules from disk after a headless CLI process mutated them, then
  // rewire shortcuts. `CFPreferencesAppSynchronize` defeats the in-memory
  // UserDefaults cache so `rules` (computed from `Defaults`) sees the fresh
  // value on the next copy automatically.
  func reloadRules() {
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    registerShortcuts()
  }

  // Per-action-shortcut entry point: run one specific action unconditionally on
  // the most recent item. No rule matching, no priority, no auto-run gate.
  func runSpecificActionForCurrent(actionID: UUID) {
    guard let config = Defaults[.actionRules].flatMap(\.actions).first(where: { $0.id == actionID }),
          let item = History.shared.unpinnedItems.first?.item ?? History.shared.all.first?.item else {
      NSSound.beep()
      return
    }
    let input = makeInput(from: item)
    runProvider(config.provider, params: config.params, input: input)
  }

  // MARK: Auto-run (called from Clipboard.onNewCopy)

  func handleNewCopy(_ item: HistoryItem) {
    // Skip anything Maccy itself put on the clipboard (e.g. selecting an item to
    // paste it). Without this, pasting a URL would auto-open it and steal focus
    // from the paste target instead of pasting.
    guard !item.fromMaccy else { return }

    let text = ValueClassifier.primaryString(of: item)

    // Swallow the echo of a value we just produced via an auto transform
    // (Clipboard.copy(string) doesn't set the fromMaccy marker).
    if let last = lastAutoOutput, last == text {
      lastAutoOutput = nil
      return
    }

    let input = makeInput(from: item)
    for rule in matchingRules(for: item) where rule.autoRunDefault {
      guard let config = rule.actions.first else { continue }
      runProvider(config.provider, params: config.params, input: input)
      break // only the first matching auto-run rule
    }
  }

  func noteAutoOutput(_ value: String) {
    lastAutoOutput = value
  }
}
