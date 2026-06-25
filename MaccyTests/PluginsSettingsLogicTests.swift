import XCTest
@testable import Maccy

@MainActor
final class PluginsSettingsLogicTests: XCTestCase {
  private let probeID = "test.consent.probe"

  override func setUp() {
    super.setUp()
    CapabilityManager.shared.revokeAll(pluginID: probeID)
  }

  override func tearDown() {
    CapabilityManager.shared.revokeAll(pluginID: probeID)
    super.tearDown()
  }

  // No declared capabilities → no consent needed, regardless of source.
  func testNoCapabilitiesNeverRequiresConsent() {
    XCTAssertFalse(
      PluginsSettingsPane.requiresConsent(
        declared: [],
        source: .marketplace("some-third-party"),
        manager: CapabilityManager.shared,
        pluginID: probeID
      )
    )
  }

  // Declared capability, none granted yet → requires consent.
  func testUngrantedCapabilityRequiresConsent() {
    XCTAssertTrue(
      PluginsSettingsPane.requiresConsent(
        declared: [.network],
        source: .marketplace("some-third-party"),
        manager: CapabilityManager.shared,
        pluginID: probeID
      )
    )
  }

  // Declared capability already granted → no further consent needed.
  func testAlreadyGrantedCapabilityDoesNotRequireConsent() {
    CapabilityManager.shared.grant([.network], pluginID: probeID)
    XCTAssertFalse(
      PluginsSettingsPane.requiresConsent(
        declared: [.network],
        source: .marketplace("some-third-party"),
        manager: CapabilityManager.shared,
        pluginID: probeID
      )
    )
  }

  // A second, not-yet-granted capability still triggers consent.
  func testPartiallyGrantedCapabilitiesRequireConsent() {
    CapabilityManager.shared.grant([.network], pluginID: probeID)
    XCTAssertTrue(
      PluginsSettingsPane.requiresConsent(
        declared: [.network, .fileRead],
        source: .marketplace("some-third-party"),
        manager: CapabilityManager.shared,
        pluginID: probeID
      )
    )
  }

  // MARK: - Grouping helpers

  // A core built-in (no owning package).
  private func builtin(_ id: String, _ name: String, kind: ProviderKind = .condition) -> ProviderDescriptor {
    ProviderDescriptor(
      id: id, name: name, description: "d", longHelp: nil,
      kind: kind, engine: .native, params: [], capabilities: [],
      source: .builtin
    )
  }

  // A plugin-supplied provider belonging to a package.
  private func pluginProvider(
    _ id: String, _ name: String,
    packageID: String, packageName: String,
    kind: ProviderKind = .action,
    source: ProviderSource = .bundled
  ) -> ProviderDescriptor {
    ProviderDescriptor(
      id: id, name: name, description: "d", longHelp: nil,
      kind: kind, engine: .declarative, params: [], capabilities: [],
      source: source, pluginID: packageID, pluginName: packageName
    )
  }

  // builtins() keeps only providers with no owning package, sorted by name.
  func testBuiltinsKeepsOnlyPackagelessProviders() {
    let descriptors = [
      builtin("builtin.regex", "Matches regex"),
      pluginProvider("com.maccay.trim", "Trim", packageID: "com.maccay.text-transforms", packageName: "Text transforms"),
      builtin("builtin.kind", "Is a kind of value")
    ]
    let result = PluginsSettingsPane.builtins(descriptors)
    XCTAssertEqual(result.map(\.id), ["builtin.kind", "builtin.regex"])
  }

  // groupedPlugins() excludes core built-ins entirely.
  func testGroupedPluginsExcludesBuiltins() {
    let descriptors = [
      builtin("builtin.regex", "Matches regex"),
      pluginProvider("com.maccay.trim", "Trim", packageID: "com.maccay.text-transforms", packageName: "Text transforms")
    ]
    let groups = PluginsSettingsPane.groupedPlugins(descriptors)
    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(groups.first?.package.id, "com.maccay.text-transforms")
    XCTAssertFalse(groups.flatMap(\.providers).contains { $0.id == "builtin.regex" })
  }

  // Providers sharing a pluginID land under one package; providers within sorted by name.
  func testGroupedPluginsGroupsByPackage() {
    let descriptors = [
      pluginProvider("com.maccay.unwrap", "Unwrap", packageID: "com.maccay.unwrap-terminal", packageName: "Unwrap terminal", kind: .action),
      pluginProvider("com.maccay.terminal-source", "Terminal source", packageID: "com.maccay.unwrap-terminal", packageName: "Unwrap terminal", kind: .condition),
      pluginProvider("com.maccay.soft-wrap", "Soft-wrapped text", packageID: "com.maccay.unwrap-terminal", packageName: "Unwrap terminal", kind: .condition),
      pluginProvider("com.maccay.trim", "Trim", packageID: "com.maccay.text-transforms", packageName: "Text transforms")
    ]
    let groups = PluginsSettingsPane.groupedPlugins(descriptors)
    // Two packages, sorted by package name ("Text transforms" < "Unwrap terminal").
    XCTAssertEqual(groups.map(\.package.name), ["Text transforms", "Unwrap terminal"])
    let unwrap = groups.first { $0.package.id == "com.maccay.unwrap-terminal" }
    XCTAssertEqual(unwrap?.providers.count, 3)
    // Providers within a package sorted by name.
    XCTAssertEqual(unwrap?.providers.map(\.name), ["Soft-wrapped text", "Terminal source", "Unwrap"])
  }

  // The package badge reflects source + isVerified from its providers.
  func testGroupedPluginsPackageBadgeReflectsSource() {
    let bundled = [
      pluginProvider("p.a", "A", packageID: "pkg.bundled", packageName: "Bundled Pkg", source: .bundled)
    ]
    let bundledGroup = PluginsSettingsPane.groupedPlugins(bundled).first
    XCTAssertEqual(bundledGroup?.package.source, .bundled)
    XCTAssertTrue(bundledGroup?.package.isVerified ?? false)

    let local = [
      pluginProvider("p.b", "B", packageID: "pkg.local", packageName: "Local Pkg", source: .local("/tmp/x"))
    ]
    let localGroup = PluginsSettingsPane.groupedPlugins(local).first
    XCTAssertEqual(localGroup?.package.source, .local("/tmp/x"))
    XCTAssertFalse(localGroup?.package.isVerified ?? true)

    let thirdParty = [
      pluginProvider("p.c", "C", packageID: "pkg.mkt", packageName: "Mkt Pkg", source: .marketplace("some-third-party"))
    ]
    let thirdPartyGroup = PluginsSettingsPane.groupedPlugins(thirdParty).first
    XCTAssertFalse(thirdPartyGroup?.package.isVerified ?? true)
  }
}
