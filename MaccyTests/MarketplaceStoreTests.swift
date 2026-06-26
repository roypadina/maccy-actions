import XCTest
import Defaults
@testable import Maccy

@MainActor
final class MarketplaceStoreTests: XCTestCase {

  // Save and restore Defaults keys around every test so tests are isolated.
  private var savedMarketplaces: [String] = []
  private var savedLocalFolders: [String] = []
  private var savedDisabled: [String] = []

  override func setUp() async throws {
    try await super.setUp()
    savedMarketplaces = Defaults[.installedMarketplaces]
    savedLocalFolders = Defaults[.localMarketplaceFolders]
    savedDisabled = Defaults[.disabledPlugins]
    Defaults[.installedMarketplaces] = []
    Defaults[.localMarketplaceFolders] = []
    Defaults[.disabledPlugins] = []
  }

  override func tearDown() async throws {
    Defaults[.installedMarketplaces] = savedMarketplaces
    Defaults[.localMarketplaceFolders] = savedLocalFolders
    Defaults[.disabledPlugins] = savedDisabled
    try await super.tearDown()
  }

  // MARK: - registeredMarketplaceURLs

  func testRegisteredMarketplaceURLsAlwaysPrependsOfficial() {
    // Even with no user-added marketplaces the official URL is returned first.
    let store = MarketplaceStore()
    let urls = store.registeredMarketplaceURLs()
    XCTAssertFalse(urls.isEmpty)
    XCTAssertEqual(urls.first, kMaccyPlusOfficialMarketplaceURL)
  }

  func testRegisteredMarketplaceURLsIncludesUserAdded() {
    let store = MarketplaceStore()
    let extra = URL(string: "https://example.com/marketplace.json")!
    Defaults[.installedMarketplaces] = [extra.absoluteString]
    let urls = store.registeredMarketplaceURLs()
    XCTAssertTrue(urls.contains(extra))
  }

  func testRegisteredMarketplaceURLsOfficialNotDuplicatedWhenUserAddsIt() {
    // If the user somehow stores the official URL in Defaults it must not appear twice.
    let store = MarketplaceStore()
    Defaults[.installedMarketplaces] = [kMaccyPlusOfficialMarketplaceURL.absoluteString]
    let urls = store.registeredMarketplaceURLs()
    let officialCount = urls.filter { $0 == kMaccyPlusOfficialMarketplaceURL }.count
    XCTAssertEqual(officialCount, 1)
  }

  // MARK: - removeMarketplace(id:)

  func testRemoveMarketplaceByIDRemovesFromCache() async {
    let store = MarketplaceStore()
    // Inject a cached marketplace directly (bypassing network).
    let mp = Marketplace(
      id: "test.mp",
      name: "Test",
      version: "1.0",
      description: nil,
      maintainer: nil,
      plugins: []
    )
    store.injectForTesting(marketplace: mp,
                           url: URL(string: "https://example.com/mp.json")!)
    store.removeMarketplace(id: "test.mp")
    XCTAssertNil(store.cachedMarketplace(id: "test.mp"))
  }

  func testRemoveMarketplaceByIDRemovesURLFromDefaults() async {
    let store = MarketplaceStore()
    let url = URL(string: "https://example.com/mp2.json")!
    let mp = Marketplace(
      id: "test.mp2",
      name: "Test2",
      version: "1.0",
      description: nil,
      maintainer: nil,
      plugins: []
    )
    store.injectForTesting(marketplace: mp, url: url)
    Defaults[.installedMarketplaces] = [url.absoluteString]
    store.removeMarketplace(id: "test.mp2")
    XCTAssertFalse(Defaults[.installedMarketplaces].contains(url.absoluteString))
  }

  // MARK: - removeMarketplace(url:)

  func testRemoveMarketplaceByURLRemovesFromDefaults() {
    let store = MarketplaceStore()
    let url = URL(string: "https://example.com/mp3.json")!
    Defaults[.installedMarketplaces] = [url.absoluteString]
    store.removeMarketplace(url: url)
    XCTAssertFalse(Defaults[.installedMarketplaces].contains(url.absoluteString))
  }

  // MARK: - localFolders / addLocalFolder

  func testLocalFoldersEmptyByDefault() {
    let store = MarketplaceStore()
    XCTAssertTrue(store.localFolders().isEmpty)
  }

  func testAddLocalFolderPersists() {
    let store = MarketplaceStore()
    let url = URL(fileURLWithPath: "/tmp/my-plugins")
    store.addLocalFolder(url)
    XCTAssertTrue(Defaults[.localMarketplaceFolders].contains(url.path))
    XCTAssertTrue(store.localFolders().contains(url))
  }

  func testAddLocalFolderDeduplicates() {
    let store = MarketplaceStore()
    let url = URL(fileURLWithPath: "/tmp/my-plugins")
    store.addLocalFolder(url)
    store.addLocalFolder(url)
    XCTAssertEqual(Defaults[.localMarketplaceFolders].filter { $0 == url.path }.count, 1)
  }

  func testLocalFoldersReturnsURLsFromDefaults() {
    let store = MarketplaceStore()
    let path = "/tmp/pluginfolder"
    Defaults[.localMarketplaceFolders] = [path]
    let folders = store.localFolders()
    XCTAssertEqual(folders, [URL(fileURLWithPath: path)])
  }

  // MARK: - remove(pluginID:)

  func testRemovePluginIDRemovesFromInstalledPluginsDirectory() throws {
    let store = MarketplaceStore()
    // Create a fake plugin folder in the installed-plugins directory.
    let pluginsDir = PluginLoader.installedPluginsURL()
    let pluginDir = pluginsDir.appendingPathComponent("com.example.fakeplugin")
    try FileManager.default.createDirectory(at: pluginDir,
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: pluginDir) }

    store.remove(pluginID: "com.example.fakeplugin")
    XCTAssertFalse(FileManager.default.fileExists(atPath: pluginDir.path))
  }

  func testRemovePluginIDSilentlySucceedsForNonexistentPlugin() {
    let store = MarketplaceStore()
    // Should not throw or crash.
    store.remove(pluginID: "com.example.does-not-exist")
  }

  // MARK: - Enable / disable plugins

  func testDisablePluginPersistsID() {
    let store = MarketplaceStore()
    store.disablePlugin(id: "com.example.bundled")
    XCTAssertTrue(store.disabledPlugins().contains("com.example.bundled"))
    XCTAssertTrue(Defaults[.disabledPlugins].contains("com.example.bundled"))
  }

  func testDisablePluginDeduplicates() {
    let store = MarketplaceStore()
    store.disablePlugin(id: "com.example.bundled")
    store.disablePlugin(id: "com.example.bundled")
    XCTAssertEqual(Defaults[.disabledPlugins].filter { $0 == "com.example.bundled" }.count, 1)
  }

  func testEnablePluginRemovesID() {
    let store = MarketplaceStore()
    store.disablePlugin(id: "com.example.bundled")
    store.enablePlugin(id: "com.example.bundled")
    XCTAssertFalse(store.disabledPlugins().contains("com.example.bundled"))
  }

  func testEnablePluginNoOpWhenNotDisabled() {
    let store = MarketplaceStore()
    // Should not crash or add anything.
    store.enablePlugin(id: "com.example.never-disabled")
    XCTAssertFalse(store.disabledPlugins().contains("com.example.never-disabled"))
  }

  // MARK: - removeLocalFolder

  func testRemoveLocalFolderRemovesFromDefaults() {
    let store = MarketplaceStore()
    let url = URL(fileURLWithPath: "/tmp/dev-plugins")
    Defaults[.localMarketplaceFolders] = [url.path]
    store.removeLocalFolder(url)
    XCTAssertFalse(Defaults[.localMarketplaceFolders].contains(url.path))
  }

  func testRemoveLocalFolderSilentlySucceedsForUnknownFolder() {
    let store = MarketplaceStore()
    // Should not throw or crash.
    store.removeLocalFolder(URL(fileURLWithPath: "/tmp/not-registered"))
  }

  // MARK: - kMaccyPlusOfficialMarketplaceURL

  func testOfficialMarketplaceURLIsHTTPS() {
    XCTAssertEqual(kMaccyPlusOfficialMarketplaceURL.scheme, "https")
  }
}
