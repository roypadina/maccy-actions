import AppKit
import Foundation

// The detected nature of a clipboard value. A single item may match several
// kinds (e.g. a URL is also plain text).
enum ValueKind: String, Codable, CaseIterable, Identifiable {
  case url
  case email
  case phone
  case filePath
  case colorHex
  case image
  case text

  var id: String { rawValue }

  var label: String {
    switch self {
    case .url: return "URL"
    case .email: return "Email"
    case .phone: return "Phone number"
    case .filePath: return "File path"
    case .colorHex: return "Color hex"
    case .image: return "Image"
    case .text: return "Plain text"
    }
  }

  var systemImage: String {
    switch self {
    case .url: return "link"
    case .email: return "envelope"
    case .phone: return "phone"
    case .filePath: return "folder"
    case .colorHex: return "paintpalette"
    case .image: return "photo"
    case .text: return "text.alignleft"
    }
  }
}

// Classifies a `HistoryItem` into the set of `ValueKind`s it matches and
// exposes the canonical string used by actions.
enum ValueClassifier {
  private static let linkDetector = try? NSDataDetector(
    types: NSTextCheckingResult.CheckingType.link.rawValue
  )
  private static let phoneDetector = try? NSDataDetector(
    types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue
  )
  private static let emailRegex = try? NSRegularExpression(
    pattern: #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#,
    options: [.caseInsensitive]
  )
  private static let colorHexRegex = try? NSRegularExpression(
    pattern: #"^#?([0-9A-Fa-f]{8}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})$"#
  )

  static func kinds(of item: HistoryItem) -> Set<ValueKind> {
    var result: Set<ValueKind> = []

    if item.hasImageData {
      result.insert(.image)
    }

    if !item.fileURLs.isEmpty {
      result.insert(.filePath)
    }

    let raw = primaryString(of: item)
    guard !raw.isEmpty else {
      if result.isEmpty { result.insert(.text) }
      return result
    }

    let range = NSRange(raw.startIndex..., in: raw)

    if emailRegex?.firstMatch(in: raw, range: range) != nil {
      result.insert(.email)
    }

    if colorHexRegex?.firstMatch(in: raw, range: range) != nil {
      result.insert(.colorHex)
    }

    if let match = linkDetector?.firstMatch(in: raw, range: range),
       match.range == range, let url = match.url, url.scheme != "mailto" {
      result.insert(.url)
    }

    if let match = phoneDetector?.firstMatch(in: raw, range: range), match.range == range {
      result.insert(.phone)
    }

    if raw.hasPrefix("/") || raw.hasPrefix("~/") {
      result.insert(.filePath)
    }

    // Anything with textual content is also plain text.
    result.insert(.text)
    return result
  }

  static func primaryString(of item: HistoryItem) -> String {
    item.previewableText.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
