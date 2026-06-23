import Foundation

// Scans plugin folders, parses plugin.json manifests, builds typed providers
// via DeclarativeEngine / JSPluginRuntime, and registers them in a
// ProviderRegistry.  Per-plugin errors are caught and printed so one bad
// plugin cannot prevent the rest from loading.
@MainActor
enum PluginLoader {

  // MARK: - Folder resolution

  /// The `BundledPlugins` directory that Xcode copies into the app bundle.
  /// Returns nil when running in a unit-test host that has no bundle resource dir.
  static func bundledPluginsURL() -> URL? {
    Bundle.main.url(forResource: "BundledPlugins", withExtension: nil)
  }

  /// `~/Library/Application Support/Maccay/Plugins` — created on demand.
  static func installedPluginsURL() -> URL {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

    let dir = appSupport
      .appendingPathComponent("Maccay", isDirectory: true)
      .appendingPathComponent("Plugins", isDirectory: true)

    if !FileManager.default.fileExists(atPath: dir.path) {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return dir
  }

  // MARK: - Bulk load

  /// Removes any previously folder-loaded providers, then rescans every source
  /// folder (bundled dir, installed dir, and `extraFolders`) and registers the
  /// resulting providers into `registry`.
  ///
  /// Call at app startup and again from `ActionEngine.reloadRules()`.
  /// Pass `MarketplaceStore.shared.localFolders()` as `extraFolders` once C2 lands;
  /// for now pass `[]`.
  static func loadAll(into registry: ProviderRegistry, extraFolders: [URL]) {
    // Remove every provider that came from a folder source so stale plugins
    // from a previous load cycle cannot linger after their folder is deleted.
    // .builtin providers (registered by BuiltinProviders / FirstPartyProviders)
    // are left in place — they are not folder-loaded and must not be cleared.
    registry.removeAll { source in
      switch source {
      case .bundled, .marketplace, .local: return true
      case .builtin: return false
      }
    }

    // Build the ordered list of folders to scan.
    var folders: [URL] = []
    if let bundled = bundledPluginsURL() {
      folders.append(bundled)
    }
    folders.append(installedPluginsURL())
    folders.append(contentsOf: extraFolders)

    for folder in folders {
      scanFolder(folder, into: registry)
    }
  }

  // MARK: - Per-folder scan

  /// Enumerates immediate subdirectories of `folder`; each subdirectory that
  /// contains a `plugin.json` is treated as one plugin.
  private static func scanFolder(_ folder: URL, into registry: ProviderRegistry) {
    guard FileManager.default.fileExists(atPath: folder.path) else { return }

    let contents: [URL]
    do {
      contents = try FileManager.default.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      print("[PluginLoader] Cannot read folder \(folder.lastPathComponent): \(error)")
      return
    }

    // Determine the ProviderSource for this folder.
    let source = providerSource(for: folder)

    for entry in contents {
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir),
            isDir.boolValue else { continue }

      let manifestURL = entry.appendingPathComponent("plugin.json")
      guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }

      do {
        _ = try loadPlugin(at: entry, source: source, into: registry)
      } catch {
        print("[PluginLoader] Skipping plugin at \(entry.lastPathComponent): \(error)")
      }
    }
  }

  // MARK: - Single plugin load

  /// Parses `plugin.json` in `folder`, validates the manifest, builds the
  /// appropriate provider, and returns its descriptor — without registering anywhere.
  /// Use this when you only need the descriptor (e.g., for preview / validation).
  ///
  /// Throws if the manifest is missing, malformed, fails `validate()`, or if the
  /// engine-specific setup fails (e.g., a JS syntax error).
  @discardableResult
  static func loadPlugin(at folder: URL, source: ProviderSource) throws -> [ProviderDescriptor] {
    let scratch = ProviderRegistry()
    return try loadPlugin(at: folder, source: source, into: scratch)
  }

  // Internal variant used by loadAll: parses, builds, registers, and returns
  // the descriptor so the caller can log it.
  @discardableResult
  private static func loadPlugin(
    at folder: URL,
    source: ProviderSource,
    into registry: ProviderRegistry
  ) throws -> [ProviderDescriptor] {
    let manifestURL = folder.appendingPathComponent("plugin.json")
    let data = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
    try manifest.validate()

    let descriptor = manifest.descriptor(source: source)

    switch manifest.engine {
    case .native:
      // A manifest claiming engine=native is rejected; native providers are
      // code-only and cannot be loaded from a folder plugin.
      throw PluginManifestError.badEngineEntry

    case .declarative:
      guard let spec = manifest.declarative else {
        throw PluginManifestError.missingField("declarative")
      }
      switch manifest.kind {
      case .action:
        let provider = DeclarativeActionProvider(descriptor: descriptor, spec: spec)
        registry.register(action: provider)
      case .condition:
        let provider = DeclarativeConditionProvider(descriptor: descriptor, spec: spec)
        registry.register(condition: provider)
      }

    case .javascript:
      guard let entryFilename = manifest.entry else {
        throw PluginManifestError.missingField("entry")
      }
      let scriptURL = folder.appendingPathComponent(entryFilename)
      let script = try String(contentsOf: scriptURL, encoding: .utf8)
      let runtime = try JSPluginRuntime(script: script)

      switch manifest.kind {
      case .condition:
        let provider = JSConditionProvider(descriptor: descriptor, runtime: runtime)
        registry.register(condition: provider)
      case .action:
        let provider = JSActionProvider(descriptor: descriptor, runtime: runtime)
        registry.register(action: provider)
      }
    }

    return [descriptor]
  }

  // MARK: - Source inference

  /// Maps a folder URL to the appropriate `ProviderSource`.
  private static func providerSource(for folder: URL) -> ProviderSource {
    if let bundled = bundledPluginsURL(), folder.path.hasPrefix(bundled.path) {
      return .bundled
    }
    let installed = installedPluginsURL()
    if folder.path.hasPrefix(installed.path) {
      return .marketplace("user-installed")
    }
    return .local(folder.path)
  }
}
