import Foundation

enum ActionError: Error {
  case invalidURL
  case missingApp
  case missingShortcut
  case noValue
}

// Builds an openable URL from arbitrary clipboard text: respects an existing
// scheme, turns bare emails into mailto:, otherwise assumes https.
func makeURL(from string: String) -> URL? {
  let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
  if let url = URL(string: trimmed), url.scheme != nil { return url }
  if trimmed.contains("@"), let url = URL(string: "mailto:\(trimmed)") { return url }
  return URL(string: "https://\(trimmed)")
}
