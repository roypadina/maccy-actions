import Foundation

// MARK: - Error

enum PluginManifestError: Error, Equatable {
  case missingField(String)
  case badEngineEntry        // engine == .javascript but entry is nil/empty
  case descriptionTooLong    // description exceeds 120 characters
}

// MARK: - PluginManifest

struct PluginManifest: Codable, Hashable {
  // MARK: Nested types

  struct Author: Codable, Hashable {
    let name: String
    let url: String?
  }

  // MARK: Stored properties

  let id: String
  let name: String
  let version: String
  let author: Author?
  let description: String      // required, <= 120 chars
  let longHelp: String?
  let kind: ProviderKind
  let engine: ProviderEngine   // .declarative or .javascript (never .native in a manifest)
  let params: [ParamSpec]?
  let entry: String?           // required iff engine == .javascript
  let capabilities: [Capability]?
  let minAppVersion: String?
  let declarative: JSONValue?  // transform op list / predicate tree, iff engine == .declarative

  // MARK: Validation

  /// Throws `PluginManifestError` when the manifest is structurally invalid.
  /// Call before constructing any provider from this manifest.
  func validate() throws {
    // id must be non-empty
    if id.trimmingCharacters(in: .whitespaces).isEmpty {
      throw PluginManifestError.missingField("id")
    }
    // name must be non-empty
    if name.trimmingCharacters(in: .whitespaces).isEmpty {
      throw PluginManifestError.missingField("name")
    }
    // version must be non-empty
    if version.trimmingCharacters(in: .whitespaces).isEmpty {
      throw PluginManifestError.missingField("version")
    }
    // description must be non-empty and at most 120 characters
    if description.trimmingCharacters(in: .whitespaces).isEmpty {
      throw PluginManifestError.missingField("description")
    }
    if description.count > 120 {
      throw PluginManifestError.descriptionTooLong
    }
    // engine must not be .native (manifests are loaded plugins, never built-in)
    if engine == .native {
      throw PluginManifestError.missingField("engine")
    }
    // JavaScript plugins require a non-empty entry point
    if engine == .javascript {
      guard let e = entry, !e.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw PluginManifestError.badEngineEntry
      }
    }
  }

  // MARK: Descriptor projection

  /// Builds a `ProviderDescriptor` suitable for registering this manifest's provider.
  /// - Parameter source: where this plugin came from (bundled, marketplace, local folder).
  func descriptor(source: ProviderSource) -> ProviderDescriptor {
    ProviderDescriptor(
      id: id,
      name: name,
      description: description,
      longHelp: longHelp,
      kind: kind,
      engine: engine,
      params: params ?? [],
      capabilities: capabilities ?? [],
      source: source
    )
  }
}
