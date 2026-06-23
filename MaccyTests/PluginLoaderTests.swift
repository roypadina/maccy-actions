import XCTest
@testable import Maccy

/// Tests for PluginLoader: scanning a temp folder containing valid declarative /
/// JS plugin directories, verifying registration, and verifying that a folder
/// with a malformed manifest is skipped without aborting the remaining load.
@MainActor
final class PluginLoaderTests: XCTestCase {

  // ---- helpers -----------------------------------------------------------

  /// Build a temp directory with a single declarative action plugin.
  /// Returns the folder URL so the caller can pass it as an extra folder.
  private func makeDeclarativePlugin(id: String, in root: URL) throws -> URL {
    let pluginDir = root.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

    // plugin.json for a declarative action that uppercases its input.
    // The "case upper" op is the simplest deterministic transform.
    let manifest: [String: Any] = [
      "id": id,
      "name": "Test Upper",
      "version": "1.0.0",
      "description": "Uppercases the input text for testing",
      "kind": "action",
      "engine": "declarative",
      "declarative": [
        "transform": [
          ["op": "case", "value": "upper"]
        ]
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: pluginDir.appendingPathComponent("plugin.json"))
    return pluginDir
  }

  /// Build a temp directory with a single JavaScript condition plugin.
  /// The JS returns true when the input contains the substring "hello".
  private func makeJSPlugin(id: String, in root: URL) throws -> URL {
    let pluginDir = root.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

    let manifest: [String: Any] = [
      "id": id,
      "name": "Test Hello Condition",
      "version": "1.0.0",
      "description": "Returns true when the clipboard text contains hello",
      "kind": "condition",
      "engine": "javascript",
      "entry": "main.js"
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: pluginDir.appendingPathComponent("plugin.json"))

    let js = "function matches(input) { return input.indexOf('hello') !== -1; }"
    try js.data(using: .utf8)!.write(to: pluginDir.appendingPathComponent("main.js"))
    return pluginDir
  }

  /// Build a temp directory that contains a malformed plugin.json (missing required fields).
  private func makeMalformedPlugin(id: String, in root: URL) throws -> URL {
    let pluginDir = root.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    let bad = "{\"not\": \"a valid manifest\"}"
    try bad.data(using: .utf8)!.write(to: pluginDir.appendingPathComponent("plugin.json"))
    return pluginDir
  }

  // ---- tests -------------------------------------------------------------

  func testLoadDeclarativeActionPlugin() throws {
    let registry = ProviderRegistry()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PluginLoaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try makeDeclarativePlugin(id: "test.upper", in: root)

    PluginLoader.loadAll(into: registry, extraFolders: [root])

    // The action should be registered under id "test.upper"
    let action = registry.action("test.upper")
    XCTAssertNotNil(action, "Declarative action plugin should be registered")

    let descriptor = action!.descriptor
    XCTAssertEqual(descriptor.id, "test.upper")
    XCTAssertEqual(descriptor.kind, .action)
    XCTAssertEqual(descriptor.engine, .declarative)
  }

  func testDeclarativeActionRunsTransform() async throws {
    let registry = ProviderRegistry()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PluginLoaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try makeDeclarativePlugin(id: "test.upper2", in: root)
    PluginLoader.loadAll(into: registry, extraFolders: [root])

    let action = try XCTUnwrap(registry.action("test.upper2"))
    let input = PluginInput(string: "hello world", kinds: [.text], sourceAppBundleID: nil, fileURLs: [])
    let outcome = try await action.run(input, params: .emptyObject)

    XCTAssertEqual(outcome, .replace("HELLO WORLD"))
  }

  func testLoadJSConditionPlugin() throws {
    let registry = ProviderRegistry()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PluginLoaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try makeJSPlugin(id: "test.hello", in: root)
    PluginLoader.loadAll(into: registry, extraFolders: [root])

    let condition = registry.condition("test.hello")
    XCTAssertNotNil(condition, "JS condition plugin should be registered")

    let descriptor = condition!.descriptor
    XCTAssertEqual(descriptor.id, "test.hello")
    XCTAssertEqual(descriptor.kind, .condition)
    XCTAssertEqual(descriptor.engine, .javascript)
  }

  func testJSConditionEvaluates() throws {
    let registry = ProviderRegistry()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PluginLoaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try makeJSPlugin(id: "test.hello2", in: root)
    PluginLoader.loadAll(into: registry, extraFolders: [root])

    let condition = try XCTUnwrap(registry.condition("test.hello2"))

    let matchingInput = PluginInput(string: "say hello there", kinds: [.text], sourceAppBundleID: nil, fileURLs: [])
    let nonMatchingInput = PluginInput(string: "no greeting here", kinds: [.text], sourceAppBundleID: nil, fileURLs: [])

    XCTAssertTrue(try condition.evaluate(matchingInput, params: .emptyObject))
    XCTAssertFalse(try condition.evaluate(nonMatchingInput, params: .emptyObject))
  }

  func testMalformedManifestIsSkipped() throws {
    let registry = ProviderRegistry()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PluginLoaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // One bad plugin + one good plugin in the same folder.
    try makeMalformedPlugin(id: "test.bad", in: root)
    try makeDeclarativePlugin(id: "test.good", in: root)

    // Should not throw; bad plugin is skipped.
    PluginLoader.loadAll(into: registry, extraFolders: [root])

    // Bad plugin absent.
    XCTAssertNil(registry.condition("test.bad"))
    XCTAssertNil(registry.action("test.bad"))

    // Good plugin present.
    XCTAssertNotNil(registry.action("test.good"))
  }

  func testLoadAllRemovesPriorFolderPluginsOnReload() throws {
    let registry = ProviderRegistry()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PluginLoaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try makeDeclarativePlugin(id: "test.removable", in: root)
    PluginLoader.loadAll(into: registry, extraFolders: [root])
    XCTAssertNotNil(registry.action("test.removable"), "Should be registered after first load")

    // Remove the plugin folder and reload.
    try FileManager.default.removeItem(at: root.appendingPathComponent("test.removable"))
    PluginLoader.loadAll(into: registry, extraFolders: [root])
    XCTAssertNil(registry.action("test.removable"), "Should be gone after reload without the folder")
  }
}
