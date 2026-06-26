import Foundation
import Defaults

// The official MaccyPlus plugin marketplace index, served as raw marketplace.json over HTTPS.
let kMaccyPlusOfficialMarketplaceURL = URL(
  string: "https://raw.githubusercontent.com/roypadina/MaccyPlus-Plugins/main/marketplace.json"
)!

// Manages the set of registered marketplace URLs and local plugin folders.
// All state that needs to survive app restarts is persisted via Defaults.
// The in-memory `cache` stores the last successfully fetched Marketplace index
// for each URL, keyed by the marketplace's `id` field. It is populated by
// `addMarketplace` and `refreshAll`; it is NOT persisted (re-fetched on launch).
@MainActor
final class MarketplaceStore {

  static let shared = MarketplaceStore()

  // In-memory cache: marketplace id → (Marketplace, source URL).
  // Populated lazily by addMarketplace / refreshAll.
  private var cache: [String: (marketplace: Marketplace, url: URL)] = [:]

  // MARK: - Registered marketplace URLs

  /// Returns all registered marketplace URLs: the official URL is always first,
  /// followed by user-added URLs from Defaults. The official URL is never
  /// duplicated even if the user stored it in Defaults.
  func registeredMarketplaceURLs() -> [URL] {
    let stored = Defaults[.installedMarketplaces].compactMap { URL(string: $0) }
    // Prepend official, deduplicate by absolute string.
    var seen = Set<String>()
    seen.insert(kMaccyPlusOfficialMarketplaceURL.absoluteString)
    var result: [URL] = [kMaccyPlusOfficialMarketplaceURL]
    for url in stored where seen.insert(url.absoluteString).inserted {
      result.append(url)
    }
    return result
  }

  // MARK: - Add / remove marketplaces

  /// Downloads the index at `url`, validates it is a valid Marketplace, stores
  /// the URL in Defaults, caches the result, and returns the Marketplace.
  /// Throws if the network request fails or the index cannot be parsed.
  func addMarketplace(_ url: URL) async throws -> Marketplace {
    let mp = try await MarketplaceResolver.fetchIndex(url)
    // Persist URL (avoid duplicates).
    var stored = Defaults[.installedMarketplaces]
    let urlString = url.absoluteString
    if !stored.contains(urlString) {
      stored.append(urlString)
      Defaults[.installedMarketplaces] = stored
    }
    cache[mp.id] = (mp, url)
    return mp
  }

  /// Removes the marketplace with the given id from the cache and from Defaults.
  func removeMarketplace(id: String) {
    guard let (_, url) = cache[id] else { return }
    cache.removeValue(forKey: id)
    removeURL(url)
  }

  /// Removes the marketplace whose source URL matches `url` from Defaults and the cache.
  func removeMarketplace(url: URL) {
    let urlString = url.absoluteString
    // Remove from cache (any entry whose URL matches).
    let keysToRemove = cache.compactMap { (key, value) -> String? in
      value.url.absoluteString == urlString ? key : nil
    }
    for key in keysToRemove { cache.removeValue(forKey: key) }
    removeURL(url)
  }

  // MARK: - Refresh

  /// Re-fetches all registered marketplace URLs in parallel and updates the cache.
  /// Failures are silently ignored so a single broken marketplace does not block the rest.
  func refreshAll() async {
    let urls = registeredMarketplaceURLs()
    await withTaskGroup(of: Void.self) { group in
      for url in urls {
        group.addTask {
          if let mp = try? await MarketplaceResolver.fetchIndex(url) {
            await MainActor.run {
              self.cache[mp.id] = (mp, url)
            }
          }
        }
      }
    }
  }

  // MARK: - Install / remove plugins

  /// Downloads, verifies, and installs a plugin entry from a marketplace.
  /// The plugin is extracted into the shared installed-plugins directory.
  func install(_ entry: MarketplaceEntry, marketplaceID: String) async throws {
    let dir = PluginLoader.installedPluginsURL()
    _ = try await MarketplaceResolver.install(entry, marketplaceID: marketplaceID, into: dir)
    ActionEngine.shared.reloadRules()
  }

  /// Removes the installed plugin folder for `pluginID` from Application Support.
  /// Silently does nothing if no folder exists for that id.
  func remove(pluginID: String) {
    let dir = PluginLoader.installedPluginsURL().appendingPathComponent(pluginID)
    guard FileManager.default.fileExists(atPath: dir.path) else { return }
    try? FileManager.default.removeItem(at: dir)
    ActionEngine.shared.reloadRules()
  }

  // MARK: - Enable / disable plugins

  /// Package ids the user has disabled. Bundled packages cannot be deleted (they
  /// live in the read-only app bundle), so "uninstalling" one disables it: the
  /// loader skips any package whose id is in this set.
  func disabledPlugins() -> [String] {
    Defaults[.disabledPlugins]
  }

  /// Disables (uninstalls) the package with `id` and reloads so it stops loading.
  /// No-op if already disabled.
  func disablePlugin(id: String) {
    var ids = Defaults[.disabledPlugins]
    guard !ids.contains(id) else { return }
    ids.append(id)
    Defaults[.disabledPlugins] = ids
    ActionEngine.shared.reloadRules()
  }

  /// Re-enables (reinstalls) a previously disabled package by `id` and reloads.
  /// No-op if not currently disabled.
  func enablePlugin(id: String) {
    let ids = Defaults[.disabledPlugins]
    guard ids.contains(id) else { return }
    Defaults[.disabledPlugins] = ids.filter { $0 != id }
    ActionEngine.shared.reloadRules()
  }

  // MARK: - Local folders

  /// Returns the local plugin folder URLs stored in Defaults.
  func localFolders() -> [URL] {
    Defaults[.localMarketplaceFolders].map { URL(fileURLWithPath: $0) }
  }

  /// Adds a local folder URL to Defaults (deduplicated by path).
  func addLocalFolder(_ url: URL) {
    var stored = Defaults[.localMarketplaceFolders]
    let path = url.path
    guard !stored.contains(path) else { return }
    stored.append(path)
    Defaults[.localMarketplaceFolders] = stored
  }

  /// Removes a local folder from Defaults (by path) and reloads so its plugins
  /// stop loading. Silently does nothing if the folder isn't registered.
  func removeLocalFolder(_ url: URL) {
    let path = url.path
    let stored = Defaults[.localMarketplaceFolders]
    guard stored.contains(path) else { return }
    Defaults[.localMarketplaceFolders] = stored.filter { $0 != path }
    ActionEngine.shared.reloadRules()
  }

  // MARK: - Testing support

  // These two methods exist solely to let unit tests inject state without
  // triggering network requests. They are NOT part of the public API surface
  // consumed by the GUI or the plugin loader.

  /// Injects a pre-built `Marketplace` + its source URL into the cache.
  /// Used by `MarketplaceStoreTests` to test remove/lookup without a network call.
  func injectForTesting(marketplace: Marketplace, url: URL) {
    cache[marketplace.id] = (marketplace, url)
  }

  /// Returns the cached Marketplace for `id`, or nil if not cached.
  /// Used by `MarketplaceStoreTests` to assert cache state after mutations.
  func cachedMarketplace(id: String) -> Marketplace? {
    cache[id]?.marketplace
  }

  // MARK: - Private helpers

  private func removeURL(_ url: URL) {
    let urlString = url.absoluteString
    Defaults[.installedMarketplaces] = Defaults[.installedMarketplaces].filter {
      $0 != urlString
    }
  }
}
