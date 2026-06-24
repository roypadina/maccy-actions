import Foundation

// MARK: - Error

enum PluginManifestError: Error, Equatable {
  case missingField(String)
  case badEngineEntry        // engine == .javascript but entry is nil/empty
  case descriptionTooLong    // description exceeds 120 characters
}

// MARK: - ProviderSpec

/// One provider declared inside a package manifest's `providers` list.
/// Each keeps its own stable `id` (rules/presets reference provider ids).
struct ProviderSpec: Codable, Hashable {
  let id: String
  let name: String
  let description: String       // required, <= 120 chars
  let longHelp: String?
  let kind: ProviderKind
  let engine: ProviderEngine    // .declarative or .javascript (never .native in a manifest)
  let params: [ParamSpec]?
  let declarative: JSONValue?   // transform op list / predicate tree, iff engine == .declarative
  let entry: String?            // JS script file, iff engine == .javascript
  let function: String?         // named JS function to call; default transform/matches by kind
}

// MARK: - PluginManifest (PACKAGE model)

/// A package manifest: ONE folder + ONE `plugin.json` declaring a LIST of
/// providers (any mix of conditions and actions). The package id is the
/// install/manage unit; capabilities are consented once per package.
struct PluginManifest: Codable, Hashable {
  // MARK: Nested types

  struct Author: Codable, Hashable {
    let name: String
    let url: String?
  }

  // MARK: Stored properties

  let id: String                       // PACKAGE id (install/manage unit)
  let name: String
  let version: String
  let author: Author?
  let description: String              // required, <= 120 chars
  let longHelp: String?
  let minAppVersion: String?
  let capabilities: [Capability]?      // package-level (one consent per package); default []
  let providers: [ProviderSpec]

  // MARK: Validation

  /// Throws `PluginManifestError` when the package or any provider is
  /// structurally invalid. Call before constructing any provider.
  func validate() throws {
    if id.trimmingCharacters(in: .whitespaces).isEmpty {
      throw PluginManifestError.missingField("id")
    }
    if name.trimmingCharacters(in: .whitespaces).isEmpty {
      throw PluginManifestError.missingField("name")
    }
    if version.trimmingCharacters(in: .whitespaces).isEmpty {
      throw PluginManifestError.missingField("version")
    }
    if description.trimmingCharacters(in: .whitespaces).isEmpty {
      throw PluginManifestError.missingField("description")
    }
    if description.count > 120 {
      throw PluginManifestError.descriptionTooLong
    }
    // capabilities must be a subset of the known set (CaseIterable enum decoding
    // already rejects unknowns, but guard explicitly for clarity).
    if let caps = capabilities {
      let known = Set(Capability.allCases)
      for cap in caps where !known.contains(cap) {
        throw PluginManifestError.missingField("capabilities")
      }
    }
    if providers.isEmpty {
      throw PluginManifestError.missingField("providers")
    }
    for spec in providers {
      try Self.validate(spec)
    }
  }

  private static func validate(_ spec: ProviderSpec) throws {
    if spec.id.trimmingCharacters(in: .whitespaces).isEmpty {
      throw PluginManifestError.missingField("provider.id")
    }
    if spec.name.trimmingCharacters(in: .whitespaces).isEmpty {
      throw PluginManifestError.missingField("provider.name")
    }
    if spec.description.trimmingCharacters(in: .whitespaces).isEmpty {
      throw PluginManifestError.missingField("provider.description")
    }
    if spec.description.count > 120 {
      throw PluginManifestError.descriptionTooLong
    }
    switch spec.engine {
    case .native:
      // A loaded plugin cannot declare a native provider.
      throw PluginManifestError.missingField("provider.engine")
    case .declarative:
      if spec.declarative == nil {
        throw PluginManifestError.missingField("provider.declarative")
      }
    case .javascript:
      guard let e = spec.entry, !e.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw PluginManifestError.badEngineEntry
      }
    }
  }

  // MARK: Descriptor projection

  /// Builds one `ProviderDescriptor` per provider, each carrying this package's
  /// id/name/capabilities.
  func descriptors(source: ProviderSource) -> [ProviderDescriptor] {
    providers.map { spec in
      ProviderDescriptor(
        id: spec.id,
        name: spec.name,
        description: spec.description,
        longHelp: spec.longHelp,
        kind: spec.kind,
        engine: spec.engine,
        params: spec.params ?? [],
        capabilities: capabilities ?? [],
        source: source,
        pluginID: id,
        pluginName: name
      )
    }
  }
}
