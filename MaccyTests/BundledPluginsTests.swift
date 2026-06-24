import XCTest
@testable import Maccy

@MainActor
final class BundledPluginsTests: XCTestCase {

  // Resolve BundledPlugins from the source tree so the test works without
  // a running bundle. #filePath always points to the source file on disk
  // during a local build, even when tests are invoked via xcodebuild.
  private static let bundledPluginsURL: URL = {
    let thisFile = URL(fileURLWithPath: #filePath)       // .../MaccyTests/BundledPluginsTests.swift
    let testsDir = thisFile.deletingLastPathComponent()  // .../MaccyTests/
    let repoRoot = testsDir.deletingLastPathComponent()  // .../Maccay/
    return repoRoot
      .appendingPathComponent("Maccy")
      .appendingPathComponent("Resources")
      .appendingPathComponent("BundledPlugins")
  }()

  override func setUp() async throws {
    try await super.setUp()
    // Reset the shared registry so each test run starts clean.
    ProviderRegistry.shared.reset()
    let shoutURL = Self.bundledPluginsURL.appendingPathComponent("example-shout")
    let hasURLURL = Self.bundledPluginsURL.appendingPathComponent("example-has-url")
    _ = try PluginLoader.loadPlugin(at: shoutURL, source: .bundled)
    _ = try PluginLoader.loadPlugin(at: hasURLURL, source: .bundled)
  }

  override func tearDown() async throws {
    ProviderRegistry.shared.reset()
    try await super.tearDown()
  }

  // MARK: - example-shout (declarative action)

  func testShoutActionRegistered() {
    XCTAssertNotNil(ProviderRegistry.shared.action("com.maccay.example.shout"))
  }

  func testShoutActionTransformsHiToSHOUT() async throws {
    let action = try XCTUnwrap(ProviderRegistry.shared.action("com.maccay.example.shout"))
    let input = PluginInput(
      string: "hi",
      kinds: [.text],
      sourceAppBundleID: nil,
      fileURLs: []
    )
    let outcome = try await action.run(input, params: .emptyObject)
    XCTAssertEqual(outcome, .replace("SHOUT: HI"))
  }

  func testShoutDescriptor() {
    let descriptor = ProviderRegistry.shared.action("com.maccay.example.shout")?.descriptor
    XCTAssertEqual(descriptor?.id, "com.maccay.example.shout")
    XCTAssertEqual(descriptor?.engine, .declarative)
    XCTAssertEqual(descriptor?.kind, .action)
    XCTAssertTrue(descriptor?.isVerified == true)
    // Package membership: provider belongs to its owning package.
    XCTAssertEqual(descriptor?.pluginID, "com.maccay.example-shout")
    XCTAssertEqual(descriptor?.pluginName, "Shout")
  }

  // MARK: - example-has-url (JS condition)

  func testHasURLConditionRegistered() {
    XCTAssertNotNil(ProviderRegistry.shared.condition("com.maccay.example.has-url"))
  }

  func testHasURLConditionTrueForHTTPS() throws {
    let condition = try XCTUnwrap(ProviderRegistry.shared.condition("com.maccay.example.has-url"))
    let input = PluginInput(
      string: "Visit https://example.com for details",
      kinds: [.text],
      sourceAppBundleID: nil,
      fileURLs: []
    )
    XCTAssertTrue(try condition.evaluate(input, params: .emptyObject))
  }

  func testHasURLConditionTrueForHTTP() throws {
    let condition = try XCTUnwrap(ProviderRegistry.shared.condition("com.maccay.example.has-url"))
    let input = PluginInput(
      string: "http://insecure.example.org",
      kinds: [.text],
      sourceAppBundleID: nil,
      fileURLs: []
    )
    XCTAssertTrue(try condition.evaluate(input, params: .emptyObject))
  }

  func testHasURLConditionFalseForPlainText() throws {
    let condition = try XCTUnwrap(ProviderRegistry.shared.condition("com.maccay.example.has-url"))
    let input = PluginInput(
      string: "just some plain text",
      kinds: [.text],
      sourceAppBundleID: nil,
      fileURLs: []
    )
    XCTAssertFalse(try condition.evaluate(input, params: .emptyObject))
  }

  func testHasURLDescriptor() {
    let descriptor = ProviderRegistry.shared.condition("com.maccay.example.has-url")?.descriptor
    XCTAssertEqual(descriptor?.id, "com.maccay.example.has-url")
    XCTAssertEqual(descriptor?.engine, .javascript)
    XCTAssertEqual(descriptor?.kind, .condition)
    XCTAssertTrue(descriptor?.isVerified == true)
    // Package membership: provider belongs to its owning package.
    XCTAssertEqual(descriptor?.pluginID, "com.maccay.example-has-url")
    XCTAssertEqual(descriptor?.pluginName, "Has URL")
  }
}
