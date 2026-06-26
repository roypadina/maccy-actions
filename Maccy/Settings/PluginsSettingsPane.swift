import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct PluginsSettingsPane: View {
  // Persisted local-folder marketplace paths (read for display; mutated via the store).
  @Default(.localMarketplaceFolders) private var localFolderPaths

  // Transient UI state.
  @State private var allDescriptors: [ProviderDescriptor] = []
  @State private var marketplaces: [Marketplace] = []
  @State private var failedMarketplaces: [(url: URL, message: String)] = []
  @State private var isRefreshing = false
  @State private var searchText = ""

  @State private var showingAddMarketplace = false
  @State private var newMarketplaceURL = ""
  @State private var addMarketplaceError: String?

  @State private var installError: String?

  @State private var consentEntry: MarketplaceEntry?
  @State private var consentMarketplaceID: String?
  @State private var consentCapabilities: [Capability] = []

  private let store = MarketplaceStore.shared
  private let registry = ProviderRegistry.shared
  private let capabilities = CapabilityManager.shared

  // MARK: Body

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        searchField
        builtinBox
        pluginsBox
        marketplacesBox
        availableBox
        localFoldersBox
      }
      .padding(20)
    }
    .frame(width: 760, height: 600)
    .task { await reloadEverything() }
    .sheet(isPresented: $showingAddMarketplace) { addMarketplaceSheet }
    .sheet(item: $consentEntry) { entry in consentSheet(for: entry) }
    .alert("Install failed", isPresented: Binding(
      get: { installError != nil },
      set: { if !$0 { installError = nil } }
    )) {
      Button("OK") { installError = nil }
    } message: {
      Text(installError ?? "")
    }
  }

  // MARK: Search

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("Filter providers by name or description", text: $searchText)
        .textFieldStyle(.plain)
      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
      }
    }
    .padding(8)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
  }

  // MARK: Built-in section

  private var builtinBox: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        let providers = filtered(Self.builtins(allDescriptors))
        if providers.isEmpty {
          emptyHint("No built-in providers match your search.")
        }
        ForEach(providers) { descriptor in
          ProviderRowView(descriptor: descriptor)
          if descriptor.id != providers.last?.id {
            Divider()
          }
        }
      }
      .padding(6)
    } label: {
      sectionHeader("Built-in", count: Self.builtins(allDescriptors).count,
                    help: "Core conditions and actions that ship with MaccyPlus. Always available.")
    }
  }

  // MARK: Plugins section (grouped by package)

  private var pluginsBox: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        let groups = filteredGroups(Self.groupedPlugins(allDescriptors))
        if groups.isEmpty {
          emptyHint("No plugins installed yet. Browse a marketplace below to add some.")
        }
        ForEach(groups, id: \.package.id) { group in
          PackageGroupView(group: group) {
            uninstall(package: group.package)
          }
        }
      }
      .padding(6)
    } label: {
      sectionHeader("Plugins", count: Self.groupedPlugins(allDescriptors).count,
                    help: "Providers supplied by installed plugin packages, grouped by package.")
    }
  }

  // MARK: Marketplaces section

  private var marketplacesBox: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(store.registeredMarketplaceURLs(), id: \.absoluteString) { url in
          marketplaceRow(url)
        }
        if store.registeredMarketplaceURLs().isEmpty {
          emptyHint("No marketplaces yet. Add one to browse plugins.")
        }

        Divider()

        HStack(spacing: 8) {
          Button {
            Task { await refresh() }
          } label: {
            if isRefreshing {
              ProgressView().controlSize(.small)
            } else {
              Label("Refresh", systemImage: "arrow.clockwise")
            }
          }
          .disabled(isRefreshing)

          Button {
            newMarketplaceURL = ""
            addMarketplaceError = nil
            showingAddMarketplace = true
          } label: {
            Label("Add marketplace…", systemImage: "plus")
          }

          Spacer()
        }
      }
      .padding(6)
    } label: {
      Text("Marketplaces").font(.headline)
    }
  }

  private func marketplaceRow(_ url: URL) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Image(systemName: "globe")
          .foregroundStyle(.secondary)
        Text(url.absoluteString)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
      }
      // A genuinely failing marketplace gets a compact inline warning.
      if let failure = failedMarketplaces.first(where: { $0.url == url }) {
        Label(failure.message, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(2)
      }
    }
  }

  // MARK: Available plugins section

  private var availableBox: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        let entries = filteredAvailable(availableEntries)
        if entries.isEmpty {
          emptyHint("Refresh a marketplace to see available plugins.")
        }
        ForEach(entries, id: \.entry.id) { row in
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                Text(row.entry.name)
                  .fontWeight(.medium)
                if !row.source.isVerified {
                  unverifiedBadge
                }
              }
              Text(row.entry.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            .help(row.entry.description)

            Spacer()

            if isInstalled(row.entry.id) {
              Text("Installed")
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(.secondary)
            } else {
              Button("Install") {
                install(entry: row.entry, marketplaceID: row.marketplaceID, source: row.source)
              }
            }
          }
          .padding(.vertical, 2)
        }
      }
      .padding(6)
    } label: {
      Text("Available plugins").font(.headline)
    }
  }

  // MARK: Local folders section

  private var localFoldersBox: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(localFolderPaths, id: \.self) { path in
          HStack {
            Image(systemName: "folder")
              .foregroundStyle(.secondary)
            Text(path)
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer()
            Button(role: .destructive) {
              removeLocalFolder(path)
            } label: {
              Image(systemName: "trash")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Stop loading plugins from this folder")
          }
        }
        if localFolderPaths.isEmpty {
          emptyHint("Add a folder to load plugins from disk during development.")
        }

        Divider()

        Button {
          addLocalFolder()
        } label: {
          Label("Add folder…", systemImage: "plus")
        }
      }
      .padding(6)
    } label: {
      Text("Local folders (dev)").font(.headline)
    }
  }

  // MARK: Shared row chrome

  private func sectionHeader(_ title: String, count: Int, help: String) -> some View {
    HStack(spacing: 6) {
      Text(title).font(.headline)
      Text("\(count)")
        .font(.caption)
        .fontWeight(.semibold)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Color.secondary.opacity(0.18), in: Capsule())
        .foregroundStyle(.secondary)
    }
    .help(help)
  }

  private func emptyHint(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  private var unverifiedBadge: some View {
    Text("Unverified source")
      .font(.caption2)
      .fontWeight(.semibold)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color.orange.opacity(0.2), in: Capsule())
      .foregroundStyle(.orange)
      .help("This plugin comes from a source MaccyPlus can't verify. Review its requested capabilities before installing.")
  }

  // MARK: - Add-marketplace sheet

  private var addMarketplaceSheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Add marketplace")
        .font(.headline)
      Text("Enter the URL of a marketplace.json index.")
        .font(.caption)
        .foregroundStyle(.secondary)
      TextField("https://example.com/marketplace.json", text: $newMarketplaceURL)
        .textFieldStyle(.roundedBorder)
        .frame(width: 380)
      if let addMarketplaceError {
        Text(addMarketplaceError)
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel") { showingAddMarketplace = false }
        Button("Add") { addMarketplace() }
          .keyboardShortcut(.defaultAction)
          .disabled(newMarketplaceURL.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 440)
  }

  // MARK: - Consent sheet

  private func consentSheet(for entry: MarketplaceEntry) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.shield.fill")
          .font(.title2)
          .foregroundStyle(.orange)
        Text("\"\(entry.name)\" requests permissions")
          .font(.headline)
      }
      Text("If you install this plugin, it will be able to:")
        .font(.callout)
      VStack(alignment: .leading, spacing: 6) {
        // Sorted by rawValue: grants store capabilities in unstable Set order (C3),
        // so sorting here keeps the displayed list deterministic.
        ForEach(consentCapabilities.sorted { $0.rawValue < $1.rawValue }, id: \.self) { capability in
          HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.circle")
              .foregroundStyle(.orange)
            Text(capability.consentSentence)
          }
        }
      }
      Divider()
      HStack {
        Spacer()
        Button("Cancel") {
          consentEntry = nil
        }
        Button("Install anyway") {
          confirmConsentAndInstall()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 460)
  }

  // MARK: - Testable logic

  /// True when at least one declared capability has not yet been granted for this plugin.
  /// Pure function so it can be unit-tested without a view instance.
  static func requiresConsent(
    declared: [Capability],
    source: ProviderSource,
    manager: CapabilityManager,
    pluginID: String
  ) -> Bool {
    _ = source  // source is surfaced via the unverified badge; consent keys on capabilities + grants
    guard !declared.isEmpty else { return false }
    return manager.needsConsent(pluginID: pluginID, declared: declared)
  }

  /// A plugin package (install/manage unit) collected from its providers.
  struct PluginPackage: Hashable {
    let id: String
    let name: String
    let source: ProviderSource
    var isVerified: Bool { source.isVerified }
  }

  /// One package header plus its providers (already sorted by name).
  struct PluginGroup: Hashable {
    let package: PluginPackage
    let providers: [ProviderDescriptor]
  }

  /// Core built-ins: providers with no owning package, sorted by name.
  static func builtins(_ descriptors: [ProviderDescriptor]) -> [ProviderDescriptor] {
    descriptors
      .filter { $0.pluginID == nil }
      .sorted { $0.name < $1.name }
  }

  /// Plugin-supplied providers grouped by their owning package.
  /// Packages sorted by name; providers within each package sorted by name.
  /// The package's source/verification is taken from its first provider (all
  /// providers in one package share a source).
  static func groupedPlugins(_ descriptors: [ProviderDescriptor]) -> [PluginGroup] {
    let owned = descriptors.filter { $0.pluginID != nil }
    let byPackage = Dictionary(grouping: owned) { $0.pluginID! }
    return byPackage.values.compactMap { providers -> PluginGroup? in
      guard let first = providers.first else { return nil }
      let package = PluginPackage(
        id: first.pluginID!,
        name: first.pluginName ?? first.pluginID!,
        source: first.source
      )
      return PluginGroup(
        package: package,
        providers: providers.sorted { $0.name < $1.name }
      )
    }
    .sorted { $0.package.name < $1.package.name }
  }

  // MARK: - Derived data

  private struct AvailableRow {
    let entry: MarketplaceEntry
    let marketplaceID: String
    let source: ProviderSource
  }

  private var availableEntries: [AvailableRow] {
    marketplaces.flatMap { marketplace in
      marketplace.plugins.map { entry in
        AvailableRow(
          entry: entry,
          marketplaceID: marketplace.id,
          source: .marketplace(marketplace.id)
        )
      }
    }
  }

  private func isInstalled(_ pluginID: String) -> Bool {
    allDescriptors.contains { $0.pluginID == pluginID }
  }

  // MARK: - Search filtering

  private func matches(_ descriptor: ProviderDescriptor) -> Bool {
    let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return true }
    return descriptor.name.lowercased().contains(query)
      || descriptor.description.lowercased().contains(query)
  }

  private func filtered(_ descriptors: [ProviderDescriptor]) -> [ProviderDescriptor] {
    descriptors.filter(matches)
  }

  private func filteredGroups(_ groups: [PluginGroup]) -> [PluginGroup] {
    let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return groups }
    return groups.compactMap { group in
      // Keep a package if its name matches, or any provider matches.
      if group.package.name.lowercased().contains(query) { return group }
      let kept = group.providers.filter(matches)
      return kept.isEmpty ? nil : PluginGroup(package: group.package, providers: kept)
    }
  }

  private func filteredAvailable(_ rows: [AvailableRow]) -> [AvailableRow] {
    let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return rows }
    return rows.filter {
      $0.entry.name.lowercased().contains(query)
        || $0.entry.description.lowercased().contains(query)
    }
  }

  // MARK: - Actions

  private func reloadEverything() async {
    reloadDescriptors()
    await refresh()
  }

  private func reloadDescriptors() {
    allDescriptors = registry.descriptors()
  }

  private func refresh() async {
    isRefreshing = true
    failedMarketplaces = []
    defer { isRefreshing = false }
    await store.refreshAll()
    var loaded: [Marketplace] = []
    var failures: [(url: URL, message: String)] = []
    for url in store.registeredMarketplaceURLs() {
      do {
        loaded.append(try await MarketplaceResolver.fetchIndex(url))
      } catch {
        failures.append((url, "Couldn't load this marketplace: \(error.localizedDescription)"))
      }
    }
    marketplaces = loaded
    failedMarketplaces = failures
  }

  private func addMarketplace() {
    addMarketplaceError = nil
    let trimmed = newMarketplaceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed) else {
      addMarketplaceError = "That doesn't look like a valid URL."
      return
    }
    Task {
      do {
        _ = try await store.addMarketplace(url)
        showingAddMarketplace = false
        await refresh()
      } catch {
        addMarketplaceError = error.localizedDescription
      }
    }
  }

  private func install(entry: MarketplaceEntry, marketplaceID: String, source: ProviderSource) {
    // A previously disabled (uninstalled) package is re-enabled in place — its
    // files are still on disk, so no download or consent prompt is needed.
    if store.disabledPlugins().contains(entry.id) {
      store.enablePlugin(id: entry.id)
      reloadDescriptors()
      return
    }

    let declared = capabilitiesDeclared(by: entry)
    if Self.requiresConsent(
      declared: declared,
      source: source,
      manager: capabilities,
      pluginID: entry.id
    ) {
      // Stable display order — grants persist capabilities in unstable Set order (C3).
      consentCapabilities = declared.sorted { $0.rawValue < $1.rawValue }
      consentMarketplaceID = marketplaceID
      consentEntry = entry  // triggers the .sheet(item:)
    } else {
      performInstall(entry: entry, marketplaceID: marketplaceID)
    }
  }

  private func confirmConsentAndInstall() {
    guard let entry = consentEntry, let marketplaceID = consentMarketplaceID else { return }
    capabilities.grant(consentCapabilities, pluginID: entry.id)
    consentEntry = nil
    performInstall(entry: entry, marketplaceID: marketplaceID)
  }

  private func performInstall(entry: MarketplaceEntry, marketplaceID: String) {
    Task {
      do {
        // store.install reloads providers (with the disabled set applied).
        try await store.install(entry, marketplaceID: marketplaceID)
        reloadDescriptors()
        installError = nil
      } catch {
        installError = "Install failed: \(error.localizedDescription)"
      }
    }
  }

  /// Uninstalls a package. Bundled packages live in the read-only app bundle and
  /// can't be deleted, so they're disabled (re-enabling reloads them); downloaded
  /// marketplace packages are deleted. Both paths reload providers via the store
  /// (with the disabled set applied). Local packages are managed per-folder in the
  /// Local folders section, so they have no per-package uninstall here.
  private func uninstall(package: PluginPackage) {
    switch package.source {
    case .bundled:
      store.disablePlugin(id: package.id)
    case .marketplace:
      store.remove(pluginID: package.id)
      capabilities.revokeAll(pluginID: package.id)
    case .local, .builtin:
      return
    }
    reloadDescriptors()
  }

  private func addLocalFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    store.addLocalFolder(url)
    ActionEngine.shared.reloadRules()
    reloadDescriptors()
  }

  /// Removes a local dev folder; the store reloads providers (disabled set applied).
  private func removeLocalFolder(_ path: String) {
    store.removeLocalFolder(URL(fileURLWithPath: path))
    reloadDescriptors()
  }

  /// Declared capabilities for an entry. The marketplace index doesn't always carry the
  /// capability list; it is read from the already-registered descriptor when present,
  /// otherwise treated as empty (consent will be re-checked at load time).
  private func capabilitiesDeclared(by entry: MarketplaceEntry) -> [Capability] {
    // Prefer the entry's declared capabilities (known BEFORE install, so the consent
    // sheet fires pre-download — even for a network/FS plugin from the verified
    // marketplace). Fall back to the registered descriptor for already-installed plugins.
    if let caps = entry.capabilities { return caps }
    return allDescriptors.first { $0.id == entry.id }?.capabilities ?? []
  }
}

// MARK: - Provider row

/// One provider line: name, Condition/Action chip, engine chip, secondary
/// description, and an ⓘ popover for longHelp when present.
private struct ProviderRowView: View {
  let descriptor: ProviderDescriptor
  @State private var showingLongHelp = false

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(descriptor.name)
            .fontWeight(.medium)
          kindChip
          engineChip
          if descriptor.longHelp != nil {
            Button {
              showingLongHelp.toggle()
            } label: {
              Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showingLongHelp) {
              LongHelpPopover(descriptor: descriptor)
            }
          }
        }
        Text(descriptor.description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 2)
  }

  private var kindChip: some View {
    let isCondition = descriptor.kind == .condition
    return Text(isCondition ? "Condition" : "Action")
      .font(.caption2)
      .fontWeight(.semibold)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background((isCondition ? Color.blue : Color.green).opacity(0.18), in: Capsule())
      .foregroundStyle(isCondition ? Color.blue : Color.green)
  }

  private var engineChip: some View {
    Text(engineLabel)
      .font(.caption2)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(Color.secondary.opacity(0.15), in: Capsule())
      .foregroundStyle(.secondary)
  }

  private var engineLabel: String {
    switch descriptor.engine {
    case .native:      return "Native"
    case .declarative: return "Declarative"
    case .javascript:  return "JavaScript"
    }
  }
}

// MARK: - Package group

/// A plugin package header (name + source badge + unverified badge) with its
/// providers listed beneath, plus a Remove button for removable sources.
private struct PackageGroupView: View {
  let group: PluginsSettingsPane.PluginGroup
  let onUninstall: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(group.package.name)
          .fontWeight(.semibold)
        sourceBadge
        if !group.package.isVerified {
          unverifiedBadge
        }
        Spacer()
        if showsUninstall {
          Button(role: .destructive, action: onUninstall) {
            Label("Uninstall", systemImage: "trash")
              .font(.caption)
          }
          .buttonStyle(.borderless)
        }
      }

      VStack(alignment: .leading, spacing: 4) {
        ForEach(group.providers) { descriptor in
          ProviderRowView(descriptor: descriptor)
        }
      }
      .padding(.leading, 10)
    }
    .padding(8)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
  }

  // Bundled packages disable in place; marketplace packages delete. Local
  // packages are managed per-folder in the Local folders section.
  private var showsUninstall: Bool {
    switch group.package.source {
    case .bundled, .marketplace: return true
    case .local, .builtin:       return false
    }
  }

  private var sourceBadgeLabel: String {
    switch group.package.source {
    case .bundled:     return "Bundled"
    case .marketplace: return "Installed"
    case .local:       return "Local"
    case .builtin:     return "Built-in"
    }
  }

  private var sourceBadge: some View {
    Text(sourceBadgeLabel)
      .font(.caption2)
      .fontWeight(.semibold)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(Color.accentColor.opacity(0.18), in: Capsule())
      .foregroundStyle(Color.accentColor)
  }

  private var unverifiedBadge: some View {
    Text("Unverified source")
      .font(.caption2)
      .fontWeight(.semibold)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color.orange.opacity(0.2), in: Capsule())
      .foregroundStyle(.orange)
      .help("This plugin comes from a source MaccyPlus can't verify.")
  }
}

// MARK: - Long-help popover

/// Structured popover shown when the user taps ⓘ on a provider row.
/// Renders name, kind/engine chips, short description, a divider, the full
/// longHelp text, and (if present) a capabilities line — all wrapping naturally.
private struct LongHelpPopover: View {
  let descriptor: ProviderDescriptor

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(descriptor.name)
        .font(.headline)

      HStack(spacing: 6) {
        kindChip
        engineChip
      }

      Text(descriptor.description)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Divider()

      Text(descriptor.longHelp ?? "")
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)

      if !descriptor.capabilities.isEmpty {
        let names = descriptor.capabilities.map(\.rawValue).sorted().joined(separator: ", ")
        Text("Requires: \(names)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: 340, alignment: .leading)
    .padding(14)
  }

  private var kindChip: some View {
    let isCondition = descriptor.kind == .condition
    return Text(isCondition ? "Condition" : "Action")
      .font(.caption2)
      .fontWeight(.semibold)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background((isCondition ? Color.blue : Color.green).opacity(0.18), in: Capsule())
      .foregroundStyle(isCondition ? Color.blue : Color.green)
  }

  private var engineChip: some View {
    let label: String
    switch descriptor.engine {
    case .native:      label = "Native"
    case .declarative: label = "Declarative"
    case .javascript:  label = "JavaScript"
    }
    return Text(label)
      .font(.caption2)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(Color.secondary.opacity(0.15), in: Capsule())
      .foregroundStyle(.secondary)
  }
}

#Preview {
  PluginsSettingsPane()
}
