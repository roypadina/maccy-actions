import XCTest
import Defaults
@testable import Maccy

@MainActor
final class CapabilityManagerTests: XCTestCase {

  // Save and restore Defaults so tests are isolated.
  private var savedGrants: [String: [Capability]] = [:]

  override func setUp() async throws {
    try await super.setUp()
    savedGrants = Defaults[.pluginCapabilityGrants]
    Defaults[.pluginCapabilityGrants] = [:]
  }

  override func tearDown() async throws {
    Defaults[.pluginCapabilityGrants] = savedGrants
    try await super.tearDown()
  }

  // MARK: - grantedCapabilities

  func testGrantedCapabilitiesEmptyByDefault() {
    let cm = CapabilityManager()
    XCTAssertEqual(cm.grantedCapabilities(pluginID: "com.example.plugin"), [])
  }

  func testGrantedCapabilitiesAfterGrant() {
    let cm = CapabilityManager()
    cm.grant([.network, .fileRead], pluginID: "com.example.plugin")
    let result = cm.grantedCapabilities(pluginID: "com.example.plugin")
    XCTAssertEqual(Set(result), Set([Capability.network, Capability.fileRead]))
  }

  func testGrantedCapabilitiesIsolatedByPluginID() {
    let cm = CapabilityManager()
    cm.grant([.network], pluginID: "com.example.a")
    cm.grant([.storage], pluginID: "com.example.b")
    XCTAssertEqual(cm.grantedCapabilities(pluginID: "com.example.a"), [.network])
    XCTAssertEqual(cm.grantedCapabilities(pluginID: "com.example.b"), [.storage])
  }

  // MARK: - needsConsent

  func testNeedsConsentTrueWhenNoneGranted() {
    let cm = CapabilityManager()
    XCTAssertTrue(cm.needsConsent(pluginID: "com.example.plugin", declared: [.network]))
  }

  func testNeedsConsentFalseWhenAllGranted() {
    let cm = CapabilityManager()
    cm.grant([.network, .fileRead], pluginID: "com.example.plugin")
    XCTAssertFalse(cm.needsConsent(pluginID: "com.example.plugin", declared: [.network, .fileRead]))
  }

  func testNeedsConsentTrueWhenPartiallyGranted() {
    let cm = CapabilityManager()
    cm.grant([.network], pluginID: "com.example.plugin")
    XCTAssertTrue(cm.needsConsent(pluginID: "com.example.plugin", declared: [.network, .fileRead]))
  }

  func testNeedsConsentFalseForEmptyDeclared() {
    let cm = CapabilityManager()
    XCTAssertFalse(cm.needsConsent(pluginID: "com.example.plugin", declared: []))
  }

  // MARK: - revokeAll

  func testRevokeAllClearsPlugin() {
    let cm = CapabilityManager()
    cm.grant([.network, .storage], pluginID: "com.example.plugin")
    cm.revokeAll(pluginID: "com.example.plugin")
    XCTAssertEqual(cm.grantedCapabilities(pluginID: "com.example.plugin"), [])
  }

  func testRevokeAllDoesNotAffectOtherPlugins() {
    let cm = CapabilityManager()
    cm.grant([.network], pluginID: "com.example.a")
    cm.grant([.storage], pluginID: "com.example.b")
    cm.revokeAll(pluginID: "com.example.a")
    XCTAssertEqual(cm.grantedCapabilities(pluginID: "com.example.a"), [])
    XCTAssertEqual(cm.grantedCapabilities(pluginID: "com.example.b"), [.storage])
  }

  func testRevokeAllOnUnknownPluginIsNoOp() {
    let cm = CapabilityManager()
    // Must not crash.
    cm.revokeAll(pluginID: "com.example.unknown")
    XCTAssertEqual(cm.grantedCapabilities(pluginID: "com.example.unknown"), [])
  }

  // MARK: - grant persistence

  func testGrantPersistsThroughDefaults() {
    let cm = CapabilityManager()
    cm.grant([.fileWrite], pluginID: "com.example.plugin")
    // A fresh instance reads from the same Defaults store.
    let cm2 = CapabilityManager()
    XCTAssertEqual(cm2.grantedCapabilities(pluginID: "com.example.plugin"), [.fileWrite])
  }

  // MARK: - isUnverified

  func testIsUnverifiedFalseForBuiltin() {
    let cm = CapabilityManager()
    XCTAssertFalse(cm.isUnverified(.builtin))
  }

  func testIsUnverifiedFalseForBundled() {
    let cm = CapabilityManager()
    XCTAssertFalse(cm.isUnverified(.bundled))
  }

  func testIsUnverifiedFalseForOfficialMarketplace() {
    let cm = CapabilityManager()
    XCTAssertFalse(cm.isUnverified(.marketplace("maccay-official")))
  }

  func testIsUnverifiedTrueForUnknownMarketplace() {
    let cm = CapabilityManager()
    XCTAssertTrue(cm.isUnverified(.marketplace("com.third-party.random")))
  }

  func testIsUnverifiedTrueForLocalFolder() {
    let cm = CapabilityManager()
    XCTAssertTrue(cm.isUnverified(.local("/Users/me/MyPlugin")))
  }
}
