import Foundation
import Defaults

// Declares Defaults.Serializable for Capability so [String: [Capability]] can be stored.
// Capability is Codable + RawRepresentable(String); Defaults uses RawRepresentableCodableBridge
// (Defaults+Extensions.swift line 97) when this conformance is declared — no body needed.
extension Capability: Defaults.Serializable {}

/// Persists per-plugin capability grants and answers consent / trust queries.
@MainActor final class CapabilityManager {

  static let shared = CapabilityManager()

  // MARK: - Public API

  /// Returns the capabilities the user has explicitly granted to `pluginID`.
  func grantedCapabilities(pluginID: String) -> [Capability] {
    Defaults[.pluginCapabilityGrants][pluginID] ?? []
  }

  /// Returns `true` if any capability in `declared` has not yet been granted
  /// for `pluginID`. An empty `declared` list always returns `false`.
  func needsConsent(pluginID: String, declared: [Capability]) -> Bool {
    guard !declared.isEmpty else { return false }
    let granted = Set(grantedCapabilities(pluginID: pluginID))
    return !declared.allSatisfy { granted.contains($0) }
  }

  /// Records that the user has granted `caps` to `pluginID`.
  /// Merges with any previously granted capabilities (does not revoke others).
  func grant(_ caps: [Capability], pluginID: String) {
    var grants = Defaults[.pluginCapabilityGrants]
    let existing = grants[pluginID] ?? []
    let merged = Array(Set(existing + caps))
    grants[pluginID] = merged
    Defaults[.pluginCapabilityGrants] = grants
  }

  /// Removes all granted capabilities for `pluginID`.
  func revokeAll(pluginID: String) {
    var grants = Defaults[.pluginCapabilityGrants]
    grants.removeValue(forKey: pluginID)
    Defaults[.pluginCapabilityGrants] = grants
  }

  /// Returns `true` when the plugin source is not considered verified.
  /// Builtin and bundled sources are always verified. `marketplace("maccay-official")`
  /// is the single verified remote marketplace. Local-folder and all other marketplace
  /// sources are unverified and trigger the "Unverified source" badge in the GUI.
  func isUnverified(_ source: ProviderSource) -> Bool {
    !source.isVerified
  }
}
