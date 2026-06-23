import XCTest
@testable import Maccy

final class KeyboardLayoutTests: XCTestCase {
  // Latin-majority input → EN→HE. "akuo" on a Hebrew layout is "שלום".
  func testEnglishKeystrokesToHebrew() {
    XCTAssertEqual(KeyboardLayout.fix("akuo"), "שלום")
  }

  // Hebrew-majority input → HE→EN, the inverse of the above.
  func testHebrewKeystrokesToEnglish() {
    XCTAssertEqual(KeyboardLayout.fix("שלום"), "akuo")
  }

  // Letters round-trip cleanly through both tables.
  func testLetterRoundTrip() {
    let original = "hello"
    let hebrew = KeyboardLayout.fix(original)   // EN→HE
    XCTAssertEqual(KeyboardLayout.fix(hebrew), original) // HE→EN
  }

  // Hebrew geresh/gershayim (U+05F3 / U+05F4) map to w / W.
  func testGereshAndGershayim() {
    XCTAssertEqual(KeyboardLayout.fix("\u{05F3}"), "w")
    XCTAssertEqual(KeyboardLayout.fix("\u{05F4}"), "W")
  }

  // Digits and spaces are identical across layouts → pass through.
  func testDigitsAndSpacePassThrough() {
    XCTAssertEqual(KeyboardLayout.fix("12345 67890"), "12345 67890")
  }

  // Empty input returns empty.
  func testEmptyInput() {
    XCTAssertEqual(KeyboardLayout.fix(""), "")
  }
}
