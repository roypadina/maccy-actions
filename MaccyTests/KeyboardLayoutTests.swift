import XCTest
@testable import Maccy

final class KeyboardLayoutTests: XCTestCase {
  // Latin-majority input → EN→HE. "akuo" on a Hebrew layout is "שלום".
  func testEnglishKeystrokesToHebrew() {
    XCTAssertEqual(KeyboardLayoutFixer.fix("akuo"), "שלום")
  }

  // Hebrew-majority input → HE→EN, the inverse of the above.
  func testHebrewKeystrokesToEnglish() {
    XCTAssertEqual(KeyboardLayoutFixer.fix("שלום"), "akuo")
  }

  // Letters round-trip cleanly through both tables.
  func testLetterRoundTrip() {
    let original = "hello"
    let hebrew = KeyboardLayoutFixer.fix(original)   // EN→HE
    XCTAssertEqual(KeyboardLayoutFixer.fix(hebrew), original) // HE→EN
  }

  // Hebrew geresh/gershayim (U+05F3 / U+05F4) map to w / W.
  func testGereshAndGershayim() {
    XCTAssertEqual(KeyboardLayoutFixer.fix("\u{05F3}"), "w")
    XCTAssertEqual(KeyboardLayoutFixer.fix("\u{05F4}"), "W")
  }

  // Digits and spaces are identical across layouts → pass through.
  func testDigitsAndSpacePassThrough() {
    XCTAssertEqual(KeyboardLayoutFixer.fix("12345 67890"), "12345 67890")
  }

  // Empty input returns empty.
  func testEmptyInput() {
    XCTAssertEqual(KeyboardLayoutFixer.fix(""), "")
  }

  // Was: asserted TransformKind.allCases — the layout fixer is now a registry provider.
  @MainActor
  func testFixKeyboardLayoutProviderRegistered() {
    ProviderRegistry.shared.reset()
    BuiltinProviders.registerBuiltins(into: .shared)
    FirstPartyProviders.registerFirstParty(into: .shared)
    let provider = ProviderRegistry.shared.action("com.maccay.fix-keyboard-layout")
    XCTAssertNotNil(provider)
    XCTAssertEqual(provider?.descriptor.id, "com.maccay.fix-keyboard-layout")
  }
}
