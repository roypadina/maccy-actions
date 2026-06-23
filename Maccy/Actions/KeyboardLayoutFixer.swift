import Foundation

// Repairs text typed in the wrong active keyboard layout by re-mapping it
// between US-QWERTY and Israeli SI-1452. Direction is auto-detected by script
// count. Ported from the standalone KeyLayoutSwitcher engine; dumb +
// deterministic, with no per-word plausibility scoring.
extension KeyboardLayout {
  // English-typed character -> Hebrew character the user intended.
  static let enToHe: [Character: Character] = [
    // letters lowercase
    "q": "/", "w": "'", "e": "ק", "r": "ר", "t": "א", "y": "ט", "u": "ו",
    "i": "ן", "o": "ם", "p": "פ",
    "a": "ש", "s": "ד", "d": "ג", "f": "כ", "g": "ע", "h": "י", "j": "ח",
    "k": "ל", "l": "ך",
    "z": "ז", "x": "ס", "c": "ב", "v": "ה", "b": "נ", "n": "מ", "m": "צ",
    // letters uppercase (Hebrew has no case)
    "Q": "/", "W": "'", "E": "ק", "R": "ר", "T": "א", "Y": "ט", "U": "ו",
    "I": "ן", "O": "ם", "P": "פ",
    "A": "ש", "S": "ד", "D": "ג", "F": "כ", "G": "ע", "H": "י", "J": "ח",
    "K": "ל", "L": "ך",
    "Z": "ז", "X": "ס", "C": "ב", "V": "ה", "B": "נ", "N": "מ", "M": "צ",
    // punctuation unshifted
    "`": ";", "[": "]", "]": "[",
    ";": "ף", "'": ",",
    ",": "ת", ".": "ץ", "/": ".",
    // shifted symbols that DIFFER between layouts (RTL swaps)
    "(": ")", ")": "(",
    "{": "}", "}": "{",
    "<": ">", ">": "<",
  ]

  // Hebrew-typed character -> English character the user intended.
  static let heToEn: [Character: Character] = [
    // hebrew letters
    "ש": "a", "ד": "s", "ג": "d", "כ": "f", "ע": "g", "י": "h", "ח": "j",
    "ל": "k", "ך": "l",
    "ז": "z", "ס": "x", "ב": "c", "ה": "v", "נ": "b", "מ": "n", "צ": "m",
    "ק": "e", "ר": "r", "א": "t", "ט": "y", "ו": "u", "ן": "i", "ם": "o",
    "פ": "p",
    "ף": ";", "ת": ",", "ץ": ".",
    // Hebrew-block punctuation some Hebrew layouts produce on the w-key
    // instead of ASCII apostrophe/quote.
    "׳": "w",  // U+05F3 HEBREW PUNCTUATION GERESH
    "״": "W",  // U+05F4 HEBREW PUNCTUATION GERSHAYIM (shift+w)
    // hebrew layout punctuation outputs
    "/": "q", "'": "w", ";": "`",
    "]": "[", "[": "]",
    ",": "'", ".": "/",
    // shifted swaps
    "(": ")", ")": "(",
    "{": "}", "}": "{",
    "<": ">", ">": "<",
  ]

  /// Re-map `text` to the layout the user meant. Direction auto-detected: more
  /// Hebrew letters than Latin → HE→EN, otherwise (incl. tie / all-Latin) →
  /// EN→HE. Unmapped characters pass through unchanged.
  static func fix(_ text: String) -> String {
    guard !text.isEmpty else { return text }
    let table = countHebrew(text) > countLatin(text) ? heToEn : enToHe
    var out = String()
    out.reserveCapacity(text.count)
    for ch in text { out.append(table[ch] ?? ch) }
    return out
  }

  private static func countHebrew(_ text: String) -> Int {
    text.unicodeScalars.reduce(0) { (0x0590...0x05FF).contains($1.value) ? $0 + 1 : $0 }
  }

  private static func countLatin(_ text: String) -> Int {
    text.unicodeScalars.reduce(0) {
      (0x41...0x5A).contains($1.value) || (0x61...0x7A).contains($1.value) ? $0 + 1 : $0
    }
  }
}
