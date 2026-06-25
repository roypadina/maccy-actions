import XCTest
@testable import Maccy

/// Tests for PluginLoader: scanning a temp folder containing valid declarative /
/// JS plugin directories, verifying registration, and verifying that a folder
/// with a malformed manifest is skipped without aborting the remaining load.
@MainActor
final class PluginLoaderTests: XCTestCase {

  // ---- helpers -----------------------------------------------------------

  /// Build a temp directory with a single-provider declarative action package.
  /// The package id derives from the provider id (`<id>.pkg`); the provider keeps `id`.
  /// Returns the folder URL so the caller can pass it as an extra folder.
  private func makeDeclarativePlugin(id: String, in root: URL) throws -> URL {
    let pluginDir = root.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

    // A declarative action that uppercases its input ("case upper").
    let manifest: [String: Any] = [
      "id": "\(id).pkg",
      "name": "Test Upper package",
      "version": "1.0.0",
      "description": "Uppercases the input text for testing",
      "providers": [
        [
          "id": id,
          "name": "Test Upper",
          "description": "Uppercases the input text for testing",
          "kind": "action",
          "engine": "declarative",
          "declarative": ["transform": [["op": "case", "value": "upper"]]]
        ]
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: pluginDir.appendingPathComponent("plugin.json"))
    return pluginDir
  }

  /// Build a temp directory with a single-provider JavaScript condition package.
  /// The JS returns true when the input contains the substring "hello".
  private func makeJSPlugin(id: String, in root: URL) throws -> URL {
    let pluginDir = root.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

    let manifest: [String: Any] = [
      "id": "\(id).pkg",
      "name": "Test Hello package",
      "version": "1.0.0",
      "description": "Returns true when the clipboard text contains hello",
      "providers": [
        [
          "id": id,
          "name": "Test Hello Condition",
          "description": "Returns true when the clipboard text contains hello",
          "kind": "condition",
          "engine": "javascript",
          "entry": "main.js"
        ]
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: pluginDir.appendingPathComponent("plugin.json"))

    let js = "function matches(input) { return input.indexOf('hello') !== -1; }"
    try js.data(using: .utf8)!.write(to: pluginDir.appendingPathComponent("main.js"))
    return pluginDir
  }

  /// Build a temp directory with ONE package declaring multiple providers:
  /// a declarative condition + a JS action that share the package, plus a
  /// second JS condition reusing the same entry file with a different function.
  private func makeMultiProviderPackage(
    packageID: String,
    conditionID: String,
    actionID: String,
    jsConditionID: String,
    in root: URL
  ) throws -> URL {
    let pluginDir = root.appendingPathComponent(packageID)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

    let manifest: [String: Any] = [
      "id": packageID,
      "name": "Multi provider package",
      "version": "1.0.0",
      "description": "One condition + one action + one JS condition in one package.",
      "providers": [
        [
          "id": conditionID,
          "name": "Has foo",
          "description": "True when the text contains foo.",
          "kind": "condition",
          "engine": "declarative",
          "declarative": ["predicate": ["contains": "foo"]]
        ],
        [
          "id": actionID,
          "name": "Shout it",
          "description": "Uppercases the text via JS.",
          "kind": "action",
          "engine": "javascript",
          "entry": "main.js",
          "function": "shout"
        ],
        [
          "id": jsConditionID,
          "name": "Is long",
          "description": "True when the text is longer than 3 chars.",
          "kind": "condition",
          "engine": "javascript",
          "entry": "main.js",
          "function": "isLong"
        ]
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: pluginDir.appendingPathComponent("plugin.json"))

    let js = """
    function shout(input) { return input.toUpperCase(); }
    function isLong(input) { return input.length > 3; }
    """
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

  // A package whose id is in the disabled set is parsed but not registered;
  // clearing the set re-registers it. (Uninstall = disable for bundled packages.)
  func testDisabledPackageIsSkipped() throws {
    let registry = ProviderRegistry()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PluginLoaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try makeDeclarativePlugin(id: "test.disabled", in: root)

    // Disabled by package id ("<id>.pkg") → provider is not registered.
    PluginLoader.loadAll(into: registry, extraFolders: [root], disabledPluginIDs: ["test.disabled.pkg"])
    XCTAssertNil(registry.action("test.disabled"), "Disabled package must not register its providers")

    // Re-enable (empty disabled set) → provider registers normally.
    PluginLoader.loadAll(into: registry, extraFolders: [root])
    XCTAssertNotNil(registry.action("test.disabled"), "Re-enabled package should register again")
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

  // MARK: - Multi-provider package (P0)

  func testMultiProviderPackageRegistersAllProviders() async throws {
    let registry = ProviderRegistry()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PluginLoaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let packageID = "com.test.multi"
    try makeMultiProviderPackage(
      packageID: packageID,
      conditionID: "com.test.has-foo",
      actionID: "com.test.shout",
      jsConditionID: "com.test.is-long",
      in: root
    )

    PluginLoader.loadAll(into: registry, extraFolders: [root])

    // All three providers register, each resolvable by its own id.
    let cond = try XCTUnwrap(registry.condition("com.test.has-foo"), "declarative condition should register")
    let action = try XCTUnwrap(registry.action("com.test.shout"), "JS action should register")
    let jsCond = try XCTUnwrap(registry.condition("com.test.is-long"), "second JS condition should register")

    // Each descriptor carries the owning package's id + name.
    for descriptor in [cond.descriptor, action.descriptor, jsCond.descriptor] {
      XCTAssertEqual(descriptor.pluginID, packageID)
      XCTAssertEqual(descriptor.pluginName, "Multi provider package")
    }

    // Behavior: the declarative condition matches "foo".
    let fooInput = PluginInput(string: "a foo bar", kinds: [.text], sourceAppBundleID: nil, fileURLs: [])
    XCTAssertTrue(try cond.evaluate(fooInput, params: .emptyObject))

    // Behavior: the JS action runs the named `shout` function on the SHARED runtime.
    let outcome = try await action.run(fooInput, params: .emptyObject)
    XCTAssertEqual(outcome, .replace("A FOO BAR"))

    // Behavior: the second JS provider runs the named `isLong` function on the
    // SAME shared runtime (one entry file, two functions).
    XCTAssertTrue(try jsCond.evaluate(fooInput, params: .emptyObject))
    let shortInput = PluginInput(string: "ab", kinds: [.text], sourceAppBundleID: nil, fileURLs: [])
    XCTAssertFalse(try jsCond.evaluate(shortInput, params: .emptyObject))
  }
}
