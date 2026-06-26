import XCTest
@testable import Maccy

final class PluginCoreTests: XCTestCase {

  // MARK: - JSONValue round-trip

  func testJSONValueRoundTrip() throws {
    let original = JSONValue.object([
      "a": .number(1),
      "b": .array([.bool(true), .null, .string("x")])
    ])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    XCTAssertEqual(decoded, original)
  }

  func testJSONValueSubscriptAndAccessors() throws {
    let v = JSONValue.object([
      "count": .number(42),
      "name": .string("hello"),
      "flag": .bool(true)
    ])
    XCTAssertEqual(v["count"]?.intValue, 42)
    XCTAssertEqual(v["name"]?.stringValue, "hello")
    XCTAssertEqual(v["flag"]?.boolValue, true)
    XCTAssertNil(v["missing"])
  }

  // MARK: - ProviderSource.isVerified truth table

  func testProviderSourceIsVerified() {
    XCTAssertTrue(ProviderSource.builtin.isVerified)
    XCTAssertTrue(ProviderSource.bundled.isVerified)
    XCTAssertTrue(ProviderSource.marketplace("maccyplus-official").isVerified)
    XCTAssertFalse(ProviderSource.marketplace("some-other-marketplace").isVerified)
    XCTAssertFalse(ProviderSource.local("/Users/alice/plugins/myplugin").isVerified)
  }

  // MARK: - ProviderSource Codable round-trip

  func testProviderSourceCodableBuiltin() throws {
    let v = ProviderSource.builtin
    let data = try JSONEncoder().encode(v)
    let decoded = try JSONDecoder().decode(ProviderSource.self, from: data)
    XCTAssertEqual(decoded, v)
  }

  func testProviderSourceCodableBundled() throws {
    let v = ProviderSource.bundled
    let data = try JSONEncoder().encode(v)
    let decoded = try JSONDecoder().decode(ProviderSource.self, from: data)
    XCTAssertEqual(decoded, v)
  }

  func testProviderSourceCodableMarketplace() throws {
    let v = ProviderSource.marketplace("maccyplus-official")
    let data = try JSONEncoder().encode(v)
    let decoded = try JSONDecoder().decode(ProviderSource.self, from: data)
    XCTAssertEqual(decoded, v)
  }

  func testProviderSourceCodableLocal() throws {
    let v = ProviderSource.local("/tmp/my-plugin")
    let data = try JSONEncoder().encode(v)
    let decoded = try JSONDecoder().decode(ProviderSource.self, from: data)
    XCTAssertEqual(decoded, v)
  }

  func testProviderSourceCodableMarketplaceOther() throws {
    let v = ProviderSource.marketplace("community-plugins")
    let data = try JSONEncoder().encode(v)
    let decoded = try JSONDecoder().decode(ProviderSource.self, from: data)
    XCTAssertEqual(decoded, v)
  }

  // MARK: - Capability.consentSentence non-empty + network mentions passwords

  func testCapabilityConsentSentenceNonEmpty() {
    for cap in Capability.allCases {
      XCTAssertFalse(cap.consentSentence.isEmpty, "\(cap.rawValue) has empty consentSentence")
    }
  }

  func testNetworkConsentSentenceMentionsPasswords() {
    XCTAssertTrue(
      Capability.network.consentSentence.localizedCaseInsensitiveContains("password"),
      "network consentSentence must mention passwords"
    )
  }
}
