import AppKit
import Defaults
import Foundation
import KeyboardShortcuts
import Observation

extension Defaults.Keys {
  static let actionRules = Key<[ActionRule]>("actionRules", default: ActionRule.presets)
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

  private init() {}

  var rules: [ActionRule] { Defaults[.actionRules] }

  // MARK: Matching

  func matchingRules(for item: HistoryItem) -> [ActionRule] {
    let kinds = ValueClassifier.kinds(of: item)
    let text = ValueClassifier.primaryString(of: item)
    let app = item.application
    return rules.filter { $0.enabled && matches($0, kinds: kinds, text: text, app: app) }
  }

  private func matches(_ rule: ActionRule, kinds: Set<ValueKind>, text: String, app: String?) -> Bool {
    guard !rule.conditions.isEmpty else { return false }

    let results = rule.conditions.map { condition -> Bool in
      switch condition {
      case .kind(let kind):
        return kinds.contains(kind)
      case .sourceApp(let bundle):
        return app == bundle
      case .contains(let needle):
        return !needle.isEmpty && text.localizedCaseInsensitiveContains(needle)
      case .regex(let pattern):
        guard !pattern.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else {
          return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
      }
    }

    return rule.matchMode == .all ? !results.contains(false) : results.contains(true)
  }

  // MARK: Resolution

  // All runnable actions for an item, in rule order then action order, deduped.
  // The first element is the default action.
  func resolvedActions(for item: HistoryItem) -> [ClipboardAction] {
    var seen = Set<String>()
    var result: [ClipboardAction] = []
    for rule in matchingRules(for: item) {
      for config in rule.actions {
        guard let action = ActionFactory.make(config), action.canRun(on: item) else { continue }
        if seen.insert(action.id).inserted {
          result.append(action)
        }
      }
    }
    // Always offer "Send to Phone" on any clip (incl. files/images) when a phone is
    // connected — no rule needed. Appended last so it never becomes the default
    // action, and never auto-runs (auto-run is rule-driven, this isn't a rule).
    let sendToPhone = SendToAndroidAction()
    if sendToPhone.canRun(on: item), seen.insert(sendToPhone.id).inserted {
      result.append(sendToPhone)
    }
    return result
  }

  func defaultAction(for item: HistoryItem) -> ClipboardAction? {
    resolvedActions(for: item).first
  }

  // MARK: Running

  func run(_ action: ClipboardAction, on item: HistoryItem) {
    Task {
      do {
        try await action.run(on: item)
      } catch {
        NSSound.beep()
      }
    }
  }

  func runDefault(for item: HistoryItem) {
    guard let action = defaultAction(for: item) else {
      NSSound.beep()
      return
    }
    run(action, on: item)
  }

  // Global-shortcut entry point: run the default action on the most recent item.
  func runDefaultActionForCurrent() {
    guard let item = History.shared.unpinnedItems.first?.item ?? History.shared.all.first?.item else {
      NSSound.beep()
      return
    }
    runDefault(for: item)
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

    for rule in matchingRules(for: item) where rule.autoRunDefault {
      guard let config = rule.actions.first,
            let action = ActionFactory.make(config),
            action.canRun(on: item) else { continue }
      run(action, on: item)
      break // only the first matching auto-run rule
    }
  }

  func noteAutoOutput(_ value: String) {
    lastAutoOutput = value
  }
}
