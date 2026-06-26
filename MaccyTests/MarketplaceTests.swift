import XCTest
import CryptoKit
@testable import Maccy

@MainActor
final class MarketplaceTests: XCTestCase {
  // Saved copy of the injectable fetch hook so each test can restore the default.
  private var savedFetch: ((URL) async throws -> (Data, Int))!

  override func setUp() {
    super.setUp()
    savedFetch = MarketplaceResolver.fetch
  }

  override func tearDown() {
    // Always restore the real network fetch so a stub from one test
    // never leaks into another.
    MarketplaceResolver.fetch = savedFetch
    super.tearDown()
  }

  // MARK: - Helpers

  /// Loads the bundled marketplace.json fixture as Data.
  private func marketplaceFixtureData() throws -> Data {
    let bundle = Bundle(for: type(of: self))
    let url = try XCTUnwrap(
      bundle.url(forResource: "marketplace", withExtension: "json"),
      "marketplace.json fixture not found in test bundle"
    )
    return try Data(contentsOf: url)
  }

  /// SHA-256 hex of an arbitrary string's UTF-8 bytes (oracle for tests).
  private func sha256(_ string: String) -> String {
    let digest = SHA256.hash(data: Data(string.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - Decoding the marketplace index

  func testDecodeMarketplaceFixture() throws {
    let data = try marketplaceFixtureData()
    let marketplace = try JSONDecoder().decode(Marketplace.self, from: data)

    XCTAssertEqual(marketplace.id, "maccyplus-official")
    XCTAssertEqual(marketplace.name, "MaccyPlus Official")
    XCTAssertEqual(marketplace.version, "1")
    XCTAssertEqual(marketplace.plugins.count, 2)

    let base64 = try XCTUnwrap(marketplace.plugins.first { $0.id == "example-base64" })
    XCTAssertEqual(base64.name, "Base64 encode")
    XCTAssertEqual(base64.kind, .action)
    XCTAssertEqual(base64.sha256, "abc123")
    // github source decoded with all fields.
    guard case let .github(repo, ref, path) = base64.source else {
      return XCTFail("expected github source, got \(base64.source)")
    }
    XCTAssertEqual(repo, "royp/MaccyPlus-Plugins")
    XCTAssertEqual(ref, "main")
    XCTAssertEqual(path, "plugins/example-base64")

    let reverse = try XCTUnwrap(marketplace.plugins.first { $0.id == "example-reverse" })
    XCTAssertEqual(reverse.kind, .condition)
    // url source decoded.
    guard case let .url(string) = reverse.source else {
      return XCTFail("expected url source, got \(reverse.source)")
    }
    XCTAssertEqual(string, "https://plugins.example.com/example-reverse")
  }

  // MARK: - PluginSource Codable round-trip

  func testPluginSourceGithubRoundTrip() throws {
    let original = PluginSource.github(repo: "royp/MaccyPlus-Plugins", ref: "v1.2.0", path: "plugins/foo")
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(PluginSource.self, from: data)
    XCTAssertEqual(decoded, original)
  }

  func testPluginSourceURLRoundTrip() throws {
    let original = PluginSource.url("https://example.com/plugins/bar")
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(PluginSource.self, from: data)
    XCTAssertEqual(decoded, original)
  }

  func testPluginSourceGithubNilPathRoundTrip() throws {
    let original = PluginSource.github(repo: "royp/MaccyPlus-Plugins", ref: "main", path: nil)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(PluginSource.self, from: data)
    XCTAssertEqual(decoded, original)
  }

  // MARK: - sha256Hex known vector

  func testSHA256HexKnownVector() {
    // Standard test vector: SHA-256("abc").
    let data = Data("abc".utf8)
    XCTAssertEqual(
      MarketplaceResolver.sha256Hex(data),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
  }

  func testSHA256HexEmpty() {
    XCTAssertEqual(
      MarketplaceResolver.sha256Hex(Data()),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
  }

  // MARK: - fetchIndex

  func testFetchIndexParsesMarketplace() async throws {
    let fixture = try marketplaceFixtureData()
    MarketplaceResolver.fetch = { _ in (fixture, 200) }

    let marketplace = try await MarketplaceResolver.fetchIndex(
      URL(string: "https://plugins.example.com/marketplace.json")!
    )
    XCTAssertEqual(marketplace.id, "maccyplus-official")
    XCTAssertEqual(marketplace.plugins.count, 2)
  }

  func testFetchIndexThrowsHTTPError() async {
    MarketplaceResolver.fetch = { _ in (Data(), 404) }
    do {
      _ = try await MarketplaceResolver.fetchIndex(
        URL(string: "https://plugins.example.com/marketplace.json")!
      )
      XCTFail("expected httpError to be thrown")
    } catch {
      XCTAssertEqual(error as? MarketplaceError, .httpError(404))
    }
  }

  // MARK: - download checksum verification

  func testDownloadThrowsChecksumMismatch() async {
    // The fetched plugin.json bytes won't match the declared (bogus) sha256.
    let manifestBytes = Data(#"{"id":"example-base64"}"#.utf8)
    MarketplaceResolver.fetch = { _ in (manifestBytes, 200) }

    let entry = MarketplaceEntry(
      id: "example-base64",
      name: "Base64 encode",
      description: "Base64-encode the text",
      version: "1.0.0",
      minAppVersion: nil,
      kind: .action,
      tags: nil,
      source: .url("https://plugins.example.com/example-base64"),
      sha256: "deadbeef"  // deliberately wrong
    )

    do {
      _ = try await MarketplaceResolver.download(entry)
      XCTFail("expected checksumMismatch to be thrown")
    } catch {
      XCTAssertEqual(error as? MarketplaceError, .checksumMismatch)
    }
  }

  func testDownloadSucceedsWhenChecksumMatches() async throws {
    let manifest = #"{"id":"example-base64","engine":"declarative"}"#
    let manifestBytes = Data(manifest.utf8)
    MarketplaceResolver.fetch = { _ in (manifestBytes, 200) }

    let entry = MarketplaceEntry(
      id: "example-base64",
      name: "Base64 encode",
      description: "Base64-encode the text",
      version: "1.0.0",
      minAppVersion: nil,
      kind: .action,
      tags: nil,
      source: .url("https://plugins.example.com/example-base64"),
      sha256: sha256(manifest)
    )

    let data = try await MarketplaceResolver.download(entry)
    XCTAssertEqual(data, manifestBytes)
  }

  // MARK: - install writes the folder

  func testInstallDeclarativeWritesPluginJSON() async throws {
    let manifest = #"{"id":"example-base64","name":"Base64 encode","version":"1.0.0","description":"b64","providers":[{"id":"example-base64","name":"Base64 encode","description":"b64","kind":"action","engine":"declarative","declarative":{"transform":[]}}]}"#
    let manifestBytes = Data(manifest.utf8)
    MarketplaceResolver.fetch = { _ in (manifestBytes, 200) }

    let entry = MarketplaceEntry(
      id: "example-base64",
      name: "Base64 encode",
      description: "b64",
      version: "1.0.0",
      minAppVersion: nil,
      kind: .action,
      tags: nil,
      source: .github(repo: "royp/MaccyPlus-Plugins", ref: "main", path: "plugins/example-base64"),
      sha256: sha256(manifest)
    )

    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("MarketplaceTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let folder = try await MarketplaceResolver.install(
      entry, marketplaceID: "maccyplus-official", into: dir
    )

    XCTAssertEqual(folder.lastPathComponent, "example-base64")
    let pluginJSON = folder.appendingPathComponent("plugin.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: pluginJSON.path))
    let written = try Data(contentsOf: pluginJSON)
    XCTAssertEqual(written, manifestBytes)
  }

  func testInstallJavaScriptWritesEntryFile() async throws {
    // engine == javascript with entry "main.js": install must fetch+write both
    // plugin.json and main.js. The stub returns the manifest first, then the JS.
    let manifest = #"{"id":"example-reverse","name":"Reverse","version":"1.0.0","description":"rev","providers":[{"id":"example-reverse","name":"Reverse","description":"rev","kind":"condition","engine":"javascript","entry":"main.js"}]}"#
    let manifestBytes = Data(manifest.utf8)
    let jsBytes = Data("function matches(s){return true;}".utf8)

    // First call (plugin.json) returns the manifest; second call (main.js) returns the JS.
    var callCount = 0
    MarketplaceResolver.fetch = { _ in
      defer { callCount += 1 }
      return callCount == 0 ? (manifestBytes, 200) : (jsBytes, 200)
    }

    let entry = MarketplaceEntry(
      id: "example-reverse",
      name: "Reverse",
      description: "rev",
      version: "1.0.0",
      minAppVersion: nil,
      kind: .condition,
      tags: nil,
      source: .url("https://plugins.example.com/example-reverse"),
      sha256: sha256(manifest)
    )

    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("MarketplaceTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let folder = try await MarketplaceResolver.install(
      entry, marketplaceID: "maccyplus-official", into: dir
    )

    let pluginJSON = folder.appendingPathComponent("plugin.json")
    let mainJS = folder.appendingPathComponent("main.js")
    XCTAssertTrue(FileManager.default.fileExists(atPath: pluginJSON.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: mainJS.path))
    XCTAssertEqual(try Data(contentsOf: mainJS), jsBytes)
  }
}
