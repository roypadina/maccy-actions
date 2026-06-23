import XCTest
@testable import Maccy

@MainActor
final class ActionEngineRegistryTests: XCTestCase {

  override func setUp() async throws {
    try await super.setUp()
    ProviderRegistry.shared.reset()
    BuiltinProviders.registerBuiltins(into: .shared)
    FirstPartyProviders.registerFirstParty(into: .shared)
  }

  // MARK: - testKindConditionMatchesViaRegistry

  func testKindConditionMatchesViaRegistry() throws {
    let input = PluginInput(
      string: "https://example.com",
      kinds: [.url],
      sourceAppBundleID: nil,
      fileURLs: []
    )
    let result = try XCTUnwrap(
      ProviderRegistry.shared.condition("builtin.kind")
    ).evaluate(input, params: .object(["kind": .string("url")]))
    XCTAssertTrue(result)
  }

  // MARK: - testUnwrapTransformReturnsReplaceViaRegistry

  func testUnwrapTransformReturnsReplaceViaRegistry() async throws {
    // Build a soft-wrapped string: two lines of equal length >= 40, last line shorter.
    let line = String(repeating: "a", count: 40)
    let theString = line + "\n" + line + "\n" + "short"
    let input = PluginInput(
      string: theString,
      kinds: [.text],
      sourceAppBundleID: nil,
      fileURLs: []
    )
    let provider = try XCTUnwrap(ProviderRegistry.shared.action("com.maccay.unwrap"))
    let outcome = try await provider.run(input, params: .emptyObject)
    XCTAssertEqual(outcome, .replace(TextUnwrap.unwrap(theString)))
  }

  // MARK: - testNewSchemaRoundTrips

  func testNewSchemaRoundTrips() throws {
    let condition = RuleCondition(
      provider: "builtin.kind",
      params: .object(["kind": .string("url")])
    )
    let action = ActionConfig(
      provider: "builtin.openURL",
      params: .emptyObject,
      shortcut: nil
    )
    let rule = ActionRule(
      name: "Round-trip rule",
      enabled: true,
      matchMode: .all,
      conditions: [condition],
      actions: [action],
      autoRunDefault: false
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(rule)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(ActionRule.self, from: data)

    XCTAssertEqual(decoded.schemaVersion, 3)
    XCTAssertEqual(decoded.name, "Round-trip rule")
    XCTAssertEqual(decoded.matchMode, .all)
    XCTAssertEqual(decoded.conditions.count, 1)
    XCTAssertEqual(decoded.conditions[0].provider, "builtin.kind")
    XCTAssertEqual(decoded.conditions[0].params, .object(["kind": .string("url")]))
    XCTAssertEqual(decoded.actions.count, 1)
    XCTAssertEqual(decoded.actions[0].provider, "builtin.openURL")
    XCTAssertNil(decoded.actions[0].shortcut)
  }
}
