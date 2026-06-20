import Defaults
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

struct ActionsSettingsPane: View {
  @Default(.actionRules) private var rules
  @State private var selection: ActionRule.ID?
  @State private var showingTerminalApps = false

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
      detail
    }
    .frame(width: 760, height: 520)
    .sheet(isPresented: $showingTerminalApps) {
      TerminalAppsEditor()
    }
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      List(selection: $selection) {
        ForEach(rules) { rule in
          HStack {
            Image(systemName: rule.enabled ? "circle.fill" : "circle")
              .font(.system(size: 7))
              .foregroundStyle(rule.enabled ? Color.accentColor : Color.secondary)
            Text(rule.name).lineLimit(1)
          }
          .tag(rule.id)
        }
        .onMove { from, to in rules.move(fromOffsets: from, toOffset: to) }
      }
      Divider()
      HStack(spacing: 4) {
        Button(action: addRule) { Image(systemName: "plus") }
        Button(action: removeSelected) { Image(systemName: "minus") }
          .disabled(selection == nil)
        Spacer()
        Button("Terminal apps…") { showingTerminalApps = true }
          .font(.caption)
      }
      .buttonStyle(.borderless)
      .padding(6)
    }
    .frame(width: 220)
  }

  @ViewBuilder
  private var detail: some View {
    if let binding = selectedBinding {
      RuleEditor(rule: binding)
        .id(binding.wrappedValue.id)
    } else {
      VStack(spacing: 8) {
        Image(systemName: "bolt.badge.clock")
          .font(.largeTitle)
          .foregroundStyle(.secondary)
        Text("Select a rule, or add one.")
          .foregroundStyle(.secondary)
        Text("""
        Actions run on clipboard values that match a rule — from the popup’s \
        right-click menu, a global shortcut, or automatically on copy.
        """)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var selectedBinding: Binding<ActionRule>? {
    guard let id = selection, let index = rules.firstIndex(where: { $0.id == id }) else {
      return nil
    }
    return Binding(
      get: { rules[index] },
      set: { rules[index] = $0 }
    )
  }

  private func addRule() {
    var rule = ActionRule()
    rule.conditions = [.kind(.url)]
    rule.actions = [ActionConfig(type: .openURL)]
    rules.append(rule)
    selection = rule.id
  }

  private func removeSelected() {
    guard let id = selection else { return }
    rules.removeAll { $0.id == id }
    selection = nil
  }
}

// MARK: - Rule editor

private struct RuleEditor: View {
  @Binding var rule: ActionRule

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          TextField("Rule name", text: $rule.name)
            .textFieldStyle(.roundedBorder)
          Toggle("Enabled", isOn: $rule.enabled)
        }

        conditionsBox
        actionsBox

        Toggle(
          "Run the default action automatically when a matching value is copied",
          isOn: $rule.autoRunDefault
        )

        Divider()

        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("Global shortcut for default action:")
            KeyboardShortcuts.Recorder(for: .runDefaultAction)
            Spacer()
          }
          Text("Runs the first matching rule’s default action on the most recently copied item.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(20)
    }
  }

  private var conditionsBox: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        Picker("", selection: $rule.matchMode) {
          ForEach(MatchMode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        ForEach($rule.conditions) { $condition in
          ConditionRow(condition: $condition) {
            rule.conditions.removeAll { $0.id == condition.id }
          }
        }

        Button {
          rule.conditions.append(.kind(.url))
        } label: {
          Label("Add condition", systemImage: "plus")
        }
        .buttonStyle(.borderless)
      }
      .padding(6)
    } label: {
      Text("Conditions").font(.headline)
    }
  }

  private var actionsBox: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        if rule.actions.isEmpty {
          Text("No actions yet.").foregroundStyle(.secondary)
        }

        ForEach(rule.actions.indices, id: \.self) { index in
          ActionRow(
            action: $rule.actions[index],
            isDefault: index == 0,
            onMakeDefault: { moveActionToFront(rule.actions[index].id) },
            onDelete: { deleteAction(rule.actions[index].id) }
          )
          if index < rule.actions.count - 1 {
            Divider()
          }
        }

        Button {
          rule.actions.append(ActionConfig(type: .openURL))
        } label: {
          Label("Add action", systemImage: "plus")
        }
        .buttonStyle(.borderless)
      }
      .padding(6)
    } label: {
      Text("Actions  (top = default)").font(.headline)
    }
  }

  private func moveActionToFront(_ id: ActionConfig.ID) {
    guard let index = rule.actions.firstIndex(where: { $0.id == id }) else { return }
    let item = rule.actions.remove(at: index)
    rule.actions.insert(item, at: 0)
  }

  private func deleteAction(_ id: ActionConfig.ID) {
    rule.actions.removeAll { $0.id == id }
  }
}

// MARK: - Condition row

private struct ConditionRow: View {
  @Binding var condition: RuleCondition
  var onDelete: () -> Void
  @State private var showingTerminalApps = false

  private enum CondType: String, CaseIterable, Identifiable {
    case kind, regex, contains, sourceApp, softWrapped, terminalSource
    var id: String { rawValue }
    var label: String {
      switch self {
      case .kind: return "Kind"
      case .regex: return "Regex"
      case .contains: return "Contains"
      case .sourceApp: return "Source app"
      case .softWrapped: return "Soft-wrapped"
      case .terminalSource: return "From terminal"
      }
    }
  }

  var body: some View {
    HStack {
      Picker("", selection: typeBinding) {
        ForEach(CondType.allCases) { Text($0.label).tag($0) }
      }
      .labelsHidden()
      .frame(width: 120)

      switch condition {
      case .kind:
        Picker("", selection: kindBinding) {
          ForEach(ValueKind.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden()
      case .regex:
        TextField("pattern", text: stringBinding).textFieldStyle(.roundedBorder)
      case .contains:
        TextField("text", text: stringBinding).textFieldStyle(.roundedBorder)
      case .sourceApp:
        TextField("bundle id", text: stringBinding).textFieldStyle(.roundedBorder)
        Button("Choose…") {
          if let bundleID = AppPicker.choose() { condition = .sourceApp(bundleID) }
        }
      case .softWrapped:
        Text("Copy looks like a wrapped terminal command").foregroundStyle(.secondary)
      case .terminalSource:
        Text("Copied from a configured terminal app").foregroundStyle(.secondary)
        Button("Manage…") { showingTerminalApps = true }
          .buttonStyle(.borderless)
          .font(.caption)
      }

      Button(action: onDelete) { Image(systemName: "trash") }
        .buttonStyle(.borderless)
    }
    .sheet(isPresented: $showingTerminalApps) {
      TerminalAppsEditor()
    }
  }

  private var typeBinding: Binding<CondType> {
    Binding(
      get: {
        switch condition {
        case .kind: return .kind
        case .regex: return .regex
        case .contains: return .contains
        case .sourceApp: return .sourceApp
        case .softWrapped: return .softWrapped
        case .terminalSource: return .terminalSource
        }
      },
      set: { newType in
        switch newType {
        case .kind: condition = .kind(.url)
        case .regex: condition = .regex("")
        case .contains: condition = .contains("")
        case .sourceApp: condition = .sourceApp("")
        case .softWrapped: condition = .softWrapped
        case .terminalSource: condition = .terminalSource
        }
      }
    )
  }

  private var kindBinding: Binding<ValueKind> {
    Binding(
      get: { if case .kind(let kind) = condition { return kind } else { return .url } },
      set: { condition = .kind($0) }
    )
  }

  private var stringBinding: Binding<String> {
    Binding(
      get: {
        switch condition {
        case .regex(let value), .contains(let value), .sourceApp(let value): return value
        default: return ""
        }
      },
      set: { newValue in
        switch condition {
        case .regex: condition = .regex(newValue)
        case .contains: condition = .contains(newValue)
        case .sourceApp: condition = .sourceApp(newValue)
        default: break
        }
      }
    )
  }
}

// MARK: - Action row

private struct ActionRow: View {
  @Binding var action: ActionConfig
  var isDefault: Bool
  var onMakeDefault: () -> Void
  var onDelete: () -> Void

  private var shortcutName: KeyboardShortcuts.Name {
    KeyboardShortcuts.Name("action_\(action.id.uuidString)")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        if isDefault {
          Text("DEFAULT")
            .font(.caption2).bold()
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.2), in: Capsule())
        }
        Picker("", selection: $action.type) {
          ForEach(ActionType.available) { type in
            Label(type.label, systemImage: type.systemImage).tag(type)
          }
        }
        .labelsHidden()
        .frame(width: 170)

        Spacer()

        if !isDefault {
          Button("Make default", action: onMakeDefault)
            .buttonStyle(.borderless)
            .font(.caption)
        }
        Button(action: onDelete) { Image(systemName: "trash") }
          .buttonStyle(.borderless)
      }

      params
      shortcutRow
    }
    .onAppear { syncRecorder() }
  }

  private var shortcutRow: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text("Shortcut:")
        KeyboardShortcuts.Recorder(for: shortcutName) { newShortcut in
          action.shortcut = newShortcut.flatMap(ShortcutSpec.format)
          ActionEngine.shared.registerShortcuts()
        }
      }
      Text("Runs this action on the current clip, regardless of rules.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // Push the stored spec into the KeyboardShortcuts store so a freshly opened
  // editor displays the saved value. registerShortcuts() already does this at
  // launch; this just reflects current state for this action's Recorder.
  private func syncRecorder() {
    if let spec = action.shortcut, let parsed = ShortcutSpec.parse(spec) {
      KeyboardShortcuts.setShortcut(parsed, for: shortcutName)
    } else {
      KeyboardShortcuts.setShortcut(nil, for: shortcutName)
    }
  }

  @ViewBuilder
  private var params: some View {
    switch action.type {
    case .openInApp:
      HStack {
        TextField("application bundle id", text: bundleBinding).textFieldStyle(.roundedBorder)
        Button("Choose…") {
          if let id = AppPicker.choose() { action.appBundleID = id }
        }
      }
    case .webSearch:
      TextField("search URL with {query}", text: templateBinding).textFieldStyle(.roundedBorder)
    case .transform:
      Picker("", selection: transformBinding) {
        ForEach(TransformKind.allCases) { Text($0.label).tag($0) }
      }
      .labelsHidden()
      .frame(width: 220)
    case .runShortcut:
      TextField("Shortcut name (from Shortcuts.app)", text: shortcutBinding)
        .textFieldStyle(.roundedBorder)
    default:
      EmptyView()
    }
  }

  private var bundleBinding: Binding<String> {
    Binding(get: { action.appBundleID ?? "" }, set: { action.appBundleID = $0 })
  }
  private var templateBinding: Binding<String> {
    Binding(get: { action.searchTemplate ?? WebSearchTemplate.google }, set: { action.searchTemplate = $0 })
  }
  private var transformBinding: Binding<TransformKind> {
    Binding(get: { action.transform ?? .trim }, set: { action.transform = $0 })
  }
  private var shortcutBinding: Binding<String> {
    Binding(get: { action.shortcutName ?? "" }, set: { action.shortcutName = $0 })
  }
}

// MARK: - Terminal apps editor

private struct TerminalAppsEditor: View {
  @Default(.terminalAppBundleIDs) private var bundleIDs
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Terminal apps").font(.headline)
      Text("Copies from these apps count as coming from a terminal (the “From terminal” condition).")
        .font(.caption)
        .foregroundStyle(.secondary)

      List {
        if bundleIDs.isEmpty {
          Text("No terminal apps configured.").foregroundStyle(.secondary)
        }
        ForEach(bundleIDs, id: \.self) { bundleID in
          HStack {
            Text(ActionConfig.appName(for: bundleID))
            Spacer()
            Button(action: { bundleIDs.removeAll { $0 == bundleID } }) {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
          }
        }
      }
      .frame(height: 220)

      HStack {
        Button {
          if let id = AppPicker.choose(), !bundleIDs.contains(id) {
            bundleIDs.append(id)
          }
        } label: {
          Label("Add…", systemImage: "plus")
        }
        Button("Reset to defaults") { bundleIDs = TerminalApps.defaults }
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 420)
  }
}

// MARK: - App picker

enum AppPicker {
  @MainActor
  static func choose() -> String? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    guard panel.runModal() == .OK,
          let url = panel.url,
          let bundle = Bundle(url: url),
          let id = bundle.bundleIdentifier else {
      return nil
    }
    return id
  }
}
