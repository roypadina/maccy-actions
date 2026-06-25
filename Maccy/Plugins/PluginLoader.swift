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
  /// Pass `MarketplaceStore.shared.localFolders()` as `extraFolders`.
  /// `disabledPluginIDs` are package ids the user has uninstalled: any package
  /// whose manifest id is in the set is skipped (used for bundled packages that
  /// can't be deleted from the read-only app bundle).
  static func loadAll(
    into registry: ProviderRegistry,
    extraFolders: [URL],
    disabledPluginIDs: Set<String> = []
  ) {
    // Remove every provider that came from a folder source so stale plugins
    // from a previous load cycle cannot linger after their folder is deleted.
    // .builtin providers (registered by BuiltinProviders) are left in place —
    // they are not folder-loaded and must not be cleared. The former native
    // first-party providers now ship as .bundled package plugins and ARE
    // reloaded by this rescan.
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
      scanFolder(folder, into: registry, disabledPluginIDs: disabledPluginIDs)
    }
  }

  // MARK: - Per-folder scan

  /// Enumerates immediate subdirectories of `folder`; each subdirectory that
  /// contains a `plugin.json` is treated as one plugin.
  private static func scanFolder(
    _ folder: URL,
    into registry: ProviderRegistry,
    disabledPluginIDs: Set<String> = []
  ) {
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
        _ = try loadPlugin(at: entry, source: source, into: registry, disabledPluginIDs: disabledPluginIDs)
      } catch {
        print("[PluginLoader] Skipping plugin at \(entry.lastPathComponent): \(error)")
      }
    }
  }

  // MARK: - Single plugin load

  /// Parses `plugin.json` in `folder`, validates the manifest, builds the
  /// appropriate provider, registers it into `ProviderRegistry.shared`, and
  /// returns its descriptor.
  ///
  /// Throws if the manifest is missing, malformed, fails `validate()`, or if the
  /// engine-specific setup fails (e.g., a JS syntax error).
  @discardableResult
  static func loadPlugin(at folder: URL, source: ProviderSource) throws -> [ProviderDescriptor] {
    return try loadPlugin(at: folder, source: source, into: .shared)
  }

  // Internal variant used by loadAll: parses the PACKAGE manifest, builds one
  // provider per ProviderSpec, registers them, and returns their descriptors.
  //
  // Failure isolation:
  //  - an invalid package manifest (bad JSON / failed validate()) throws, so the
  //    whole package is skipped + logged by the caller;
  //  - a single bad provider (engine setup failure) is skipped + logged here, but
  //    its siblings still load.
  @discardableResult
  private static func loadPlugin(
    at folder: URL,
    source: ProviderSource,
    into registry: ProviderRegistry,
    disabledPluginIDs: Set<String> = []
  ) throws -> [ProviderDescriptor] {
    let manifestURL = folder.appendingPathComponent("plugin.json")
    let data = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
    try manifest.validate()

    // A package the user has uninstalled (disabled) is parsed but not registered.
    // It stays on disk; re-enabling reloads it.
    if disabledPluginIDs.contains(manifest.id) {
      return []
    }

    let descriptors = manifest.descriptors(source: source)

    // Compile one JS runtime per distinct entry file in the package, reused by
    // every JS provider that names that entry.
    var runtimes: [String: JSPluginRuntime] = [:]
    func runtime(forEntry entry: String) throws -> JSPluginRuntime {
      if let existing = runtimes[entry] { return existing }
      let scriptURL = folder.appendingPathComponent(entry)
      let script = try String(contentsOf: scriptURL, encoding: .utf8)
      let runtime = try JSPluginRuntime(script: script)
      runtimes[entry] = runtime
      return runtime
    }

    var registered: [ProviderDescriptor] = []
    for (spec, descriptor) in zip(manifest.providers, descriptors) {
      do {
        switch spec.engine {
        case .native:
          // Defensive: validate() already rejects native; never reached.
          throw PluginManifestError.missingField("provider.engine")

        case .declarative:
          let built = DeclarativeEngine.makeProvider(spec: spec, descriptor: descriptor)
          if let action = built.action {
            registry.register(action: action)
          } else if let condition = built.condition {
            registry.register(condition: condition)
          } else {
            throw PluginManifestError.missingField("provider.declarative")
          }

        case .javascript:
          guard let entry = spec.entry else {
            throw PluginManifestError.missingField("provider.entry")
          }
          let rt = try runtime(forEntry: entry)
          switch spec.kind {
          case .condition:
            let fn = spec.function ?? "matches"
            registry.register(condition: JSConditionProvider(descriptor: descriptor, runtime: rt, function: fn))
          case .action:
            let fn = spec.function ?? "transform"
            registry.register(action: JSActionProvider(descriptor: descriptor, runtime: rt, function: fn))
          }
        }
        registered.append(descriptor)
      } catch {
        // One bad provider is skipped + logged; siblings still load.
        print("[PluginLoader] Skipping provider \(spec.id) in package \(manifest.id): \(error)")
      }
    }

    return registered
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
