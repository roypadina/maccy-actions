import XCTest
@testable import Maccy

// Verifies the two bundled first-party packages (unwrap-terminal, text-transforms)
// behave EXACTLY like the Swift reference oracles they were ported from
// (TextUnwrap, KeyboardLayoutFixer). This file replaces the behavioral coverage
// that lived in the deleted native FirstPartyProvidersTests.
@MainActor
final class BundledFirstPartyPluginsTests: XCTestCase {

  // Resolve the BundledPlugins dir from the source tree via #filePath, so the
  // test runs without a packaged app bundle (same pattern as BundledPluginsTests).
  private static let bundledPluginsURL: URL = {
    let thisFile = URL(fileURLWithPath: #filePath)       // .../MaccyTests/BundledFirstPartyPluginsTests.swift
    let testsDir = thisFile.deletingLastPathComponent()  // .../MaccyTests/
    let repoRoot = testsDir.deletingLastPathComponent()  // .../MaccyPlus/
    return repoRoot
      .appendingPathComponent("Maccy")
      .appendingPathComponent("Resources")
      .appendingPathComponent("BundledPlugins")
  }()

  override func setUp() async throws {
    try await super.setUp()
    ProviderRegistry.shared.reset()
    PluginLoader.loadAll(into: .shared, extraFolders: [Self.bundledPluginsURL])
  }

  override func tearDown() async throws {
    ProviderRegistry.shared.reset()
    try await super.tearDown()
  }

  // MARK: - Helpers

  private func input(_ string: String, sourceApp: String? = nil) -> PluginInput {
    PluginInput(string: string, kinds: [.text], sourceAppBundleID: sourceApp, fileURLs: [])
  }

  // Representative inputs covering: wrapped, not-wrapped, single line, trailing newline,
  // CRLF, short interior lines, exactly-min-width.
  private var softWrapSamples: [String] {
    let w40 = String(repeating: "a", count: 40)
    let w42 = String(repeating: "b", count: 42)
    return [
      w42 + "\n" + "hello",                       // wrapped (2 lines, last shorter)
      w40 + "\n" + w40 + "\n" + "short",          // wrapped (3 lines)
      w40 + "\n" + w40 + "\n" + "short" + "\n",   // wrapped + trailing newline
      "line one\nline two",                       // not wrapped (short lines)
      "short\nlines\nhere",                       // not wrapped
      "single line no newline",                   // single line
      w42 + "\r\n" + "hello",                     // CRLF wrapped
      String(repeating: "c", count: 39) + "\n" + "x", // interior width < 40 → not wrapped
      "",                                          // empty
    ]
  }

  // MARK: - soft-wrap condition (JS port) == TextUnwrap.isSoftWrapped

  func testSoftWrapMatchesSwiftOracle() throws {
    let condition = try XCTUnwrap(ProviderRegistry.shared.condition("com.maccyplus.soft-wrap"))
    for sample in softWrapSamples {
      let jsResult = try condition.evaluate(input(sample), params: .emptyObject)
      let swiftResult = TextUnwrap.isSoftWrapped(sample)
      XCTAssertEqual(jsResult, swiftResult, "soft-wrap mismatch for input: \(sample.debugDescription)")
    }
  }

  // MARK: - unwrap action (JS port) == .replace(TextUnwrap.unwrap)

  func testUnwrapMatchesSwiftOracle() async throws {
    let action = try XCTUnwrap(ProviderRegistry.shared.action("com.maccyplus.unwrap"))
    // The empty string would throw noValue in JS too; skip it for the action path.
    for sample in softWrapSamples where !sample.isEmpty {
      let outcome = try await action.run(input(sample), params: .emptyObject)
      XCTAssertEqual(outcome, .replace(TextUnwrap.unwrap(sample)),
                     "unwrap mismatch for input: \(sample.debugDescription)")
    }
  }

  // MARK: - fix-keyboard-layout action (JS port) == .replace(KeyboardLayoutFixer.fix)

  func testFixKeyboardLayoutMatchesSwiftOracle() async throws {
    let action = try XCTUnwrap(ProviderRegistry.shared.action("com.maccyplus.fix-keyboard-layout"))
    let samples = [
      "akuo",                 // EN→HE → "שלום"
      "שלום",                  // HE→EN → "akuo"
      "Hello World",          // mostly Latin → EN→HE
      "שלום עולם",            // Hebrew → HE→EN
      "hello (world)",        // bracket pairs
      "abc[def]ghi",          // bracket swap
      "MixEd CaSe",
      "12345",                // digits pass through unchanged
      "a",                    // single char
    ]
    for sample in samples {
      let outcome = try await action.run(input(sample), params: .emptyObject)
      XCTAssertEqual(outcome, .replace(KeyboardLayoutFixer.fix(sample)),
                     "fix-keyboard-layout mismatch for input: \(sample.debugDescription)")
    }
  }

  func testFixKeyboardLayoutKnownPairs() async throws {
    let action = try XCTUnwrap(ProviderRegistry.shared.action("com.maccyplus.fix-keyboard-layout"))
    let enToHe = try await action.run(input("akuo"), params: .emptyObject)
    XCTAssertEqual(enToHe, .replace("שלום"))
    let heToEn = try await action.run(input("שלום"), params: .emptyObject)
    XCTAssertEqual(heToEn, .replace("akuo"))
  }

  // MARK: - terminal-source condition (declarative)

  func testTerminalSourceTrueForKnownApp() throws {
    let condition = try XCTUnwrap(ProviderRegistry.shared.condition("com.maccyplus.terminal-source"))
    for bundleID in TerminalApps.defaults {
      XCTAssertTrue(
        try condition.evaluate(input("anything", sourceApp: bundleID), params: .emptyObject),
        "terminal-source should match \(bundleID)"
      )
    }
  }

  func testTerminalSourceFalseForUnknownApp() throws {
    let condition = try XCTUnwrap(ProviderRegistry.shared.condition("com.maccyplus.terminal-source"))
    XCTAssertFalse(
      try condition.evaluate(input("anything", sourceApp: "com.example.NotATerminal"), params: .emptyObject)
    )
  }

  func testTerminalSourceFalseForNilApp() throws {
    let condition = try XCTUnwrap(ProviderRegistry.shared.condition("com.maccyplus.terminal-source"))
    XCTAssertFalse(
      try condition.evaluate(input("anything", sourceApp: nil), params: .emptyObject)
    )
  }

  // MARK: - text-transforms declarative actions

  func testTrimAction() async throws {
    let action = try XCTUnwrap(ProviderRegistry.shared.action("com.maccyplus.trim"))
    let outcome = try await action.run(input("  hello world  "), params: .emptyObject)
    XCTAssertEqual(outcome, .replace("hello world"))
  }

  func testUppercaseAction() async throws {
    let action = try XCTUnwrap(ProviderRegistry.shared.action("com.maccyplus.uppercase"))
    let outcome = try await action.run(input("hello"), params: .emptyObject)
    XCTAssertEqual(outcome, .replace("HELLO"))
  }

  func testLowercaseAction() async throws {
    let action = try XCTUnwrap(ProviderRegistry.shared.action("com.maccyplus.lowercase"))
    let outcome = try await action.run(input("HELLO"), params: .emptyObject)
    XCTAssertEqual(outcome, .replace("hello"))
  }

  func testStripFormattingAction() async throws {
    let action = try XCTUnwrap(ProviderRegistry.shared.action("com.maccyplus.strip-formatting"))
    let outcome = try await action.run(input("hello"), params: .emptyObject)
    XCTAssertEqual(outcome, .replace("hello"))
  }

  // MARK: - Package membership (descriptor.pluginID == owning package)

  func testUnwrapTerminalPackageMembership() {
    let ids = ["com.maccyplus.terminal-source", "com.maccyplus.soft-wrap"]
    for id in ids {
      let descriptor = ProviderRegistry.shared.condition(id)?.descriptor
      XCTAssertEqual(descriptor?.pluginID, "com.maccyplus.unwrap-terminal", "wrong pluginID for \(id)")
    }
    let unwrap = ProviderRegistry.shared.action("com.maccyplus.unwrap")?.descriptor
    XCTAssertEqual(unwrap?.pluginID, "com.maccyplus.unwrap-terminal")
  }

  func testTextTransformsPackageMembership() {
    let ids = [
      "com.maccyplus.trim", "com.maccyplus.uppercase", "com.maccyplus.lowercase",
      "com.maccyplus.strip-formatting", "com.maccyplus.fix-keyboard-layout",
    ]
    for id in ids {
      let descriptor = ProviderRegistry.shared.action(id)?.descriptor
      XCTAssertEqual(descriptor?.pluginID, "com.maccyplus.text-transforms", "wrong pluginID for \(id)")
    }
  }
}
