import Foundation
import CryptoKit

// MARK: - Models

/// A marketplace index, decoded from a repo's `marketplace.json`.
struct Marketplace: Codable, Hashable, Identifiable {
  let id: String
  let name: String
  let version: String
  let description: String?
  let maintainer: String?
  let plugins: [MarketplaceEntry]
}

/// One installable plugin listed in a marketplace index.
struct MarketplaceEntry: Codable, Hashable, Identifiable {
  let id: String
  let name: String
  let description: String
  let version: String
  let minAppVersion: String?
  let kind: ProviderKind
  let tags: [String]?
  let capabilities: [Capability]?   // opt-in; nil/[] = pure transform (no net/FS)
  let source: PluginSource
  let sha256: String

  init(
    id: String,
    name: String,
    description: String,
    version: String,
    minAppVersion: String?,
    kind: ProviderKind,
    tags: [String]?,
    capabilities: [Capability]? = nil,
    source: PluginSource,
    sha256: String
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.version = version
    self.minAppVersion = minAppVersion
    self.kind = kind
    self.tags = tags
    self.capabilities = capabilities
    self.source = source
    self.sha256 = sha256
  }
}

/// Where a plugin's files live. Type-tagged in JSON via the `type` discriminator:
///   {"type":"github","repo":"owner/repo","ref":"main","path":"plugins/foo"}
///   {"type":"url","url":"https://example.com/plugins/foo"}
enum PluginSource: Codable, Hashable {
  case github(repo: String, ref: String, path: String?)
  case url(String)

  private enum CodingKeys: String, CodingKey {
    case type, repo, ref, path, url
  }

  private enum Kind: String, Codable {
    case github, url
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .type)
    switch kind {
    case .github:
      let repo = try container.decode(String.self, forKey: .repo)
      let ref = try container.decode(String.self, forKey: .ref)
      let path = try container.decodeIfPresent(String.self, forKey: .path)
      self = .github(repo: repo, ref: ref, path: path)
    case .url:
      let url = try container.decode(String.self, forKey: .url)
      self = .url(url)
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .github(repo, ref, path):
      try container.encode(Kind.github, forKey: .type)
      try container.encode(repo, forKey: .repo)
      try container.encode(ref, forKey: .ref)
      try container.encodeIfPresent(path, forKey: .path)
    case let .url(url):
      try container.encode(Kind.url, forKey: .type)
      try container.encode(url, forKey: .url)
    }
  }
}

enum MarketplaceError: Error, Equatable {
  case badIndex
  case checksumMismatch
  case unsupportedSource
  case httpError(Int)
}

// MARK: - Resolver

/// Stateless network + verification helper. Fetching is funneled through the
/// injectable `fetch` hook so tests can stub the network without a server.
@MainActor
enum MarketplaceResolver {
  /// (data, httpStatusCode). Default implementation uses URLSession.
  /// Tests overwrite this and restore it in tearDown.
  static var fetch: (URL) async throws -> (Data, Int) = { url in
    let (data, response) = try await URLSession.shared.data(from: url)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    return (data, status)
  }

  // MARK: sha256

  /// Lowercase hex SHA-256 of `data` (CryptoKit).
  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: index

  /// Fetches and decodes a marketplace index from its `marketplace.json` URL.
  static func fetchIndex(_ marketplaceURL: URL) async throws -> Marketplace {
    let (data, status) = try await fetch(marketplaceURL)
    guard status == 200 else { throw MarketplaceError.httpError(status) }
    do {
      return try JSONDecoder().decode(Marketplace.self, from: data)
    } catch {
      throw MarketplaceError.badIndex
    }
  }

  // MARK: download

  /// V1 NO-UNZIP: fetches the entry's `plugin.json`, verifies its sha256 against
  /// the entry's declared checksum, and returns the verified manifest bytes.
  /// Throws `.checksumMismatch` if the hashes differ, `.httpError` on non-200.
  static func download(_ entry: MarketplaceEntry) async throws -> Data {
    let manifestURL = try pluginFileURL(entry, file: "plugin.json")
    let (data, status) = try await fetch(manifestURL)
    guard status == 200 else { throw MarketplaceError.httpError(status) }
    guard sha256Hex(data) == entry.sha256.lowercased() else {
      throw MarketplaceError.checksumMismatch
    }
    return data
  }

  // MARK: install

  /// Installs the verified plugin into `dir/<entry.id>/`:
  ///   1. download() (verifies plugin.json sha256), write it atomically;
  ///   2. if engine == javascript, fetch + write the manifest's `entry` .js file.
  /// Returns the created plugin folder URL.
  static func install(
    _ entry: MarketplaceEntry,
    marketplaceID: String,
    into dir: URL
  ) async throws -> URL {
    // 1. Verified manifest bytes.
    let manifestData = try await download(entry)

    // 2. Create the plugin folder.
    let folder = dir.appendingPathComponent(entry.id, isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)

    // 3. Write plugin.json atomically.
    let manifestURL = folder.appendingPathComponent("plugin.json")
    try manifestData.write(to: manifestURL, options: .atomic)

    // 4. Fetch + write every distinct JS entry script declared by the package's
    //    providers, alongside plugin.json.
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
    let entryFiles = Set(manifest.providers.compactMap { spec -> String? in
      spec.engine == .javascript ? spec.entry : nil
    })
    for entryFile in entryFiles {
      let scriptURL = try pluginFileURL(entry, file: entryFile)
      let (scriptData, status) = try await fetch(scriptURL)
      guard status == 200 else { throw MarketplaceError.httpError(status) }
      let destination = folder.appendingPathComponent(entryFile)
      try scriptData.write(to: destination, options: .atomic)
    }

    return folder
  }

  // MARK: URL construction

  /// Resolves the absolute URL of a single file (`plugin.json`, `main.js`, …)
  /// within a plugin's source folder.
  ///  - github → raw.githubusercontent.com/<repo>/<ref>/<path>/<file>
  ///  - url    → <baseURL>/<file>
  private static func pluginFileURL(_ entry: MarketplaceEntry, file: String) throws -> URL {
    switch entry.source {
    case let .github(repo, ref, path):
      var components = ["https://raw.githubusercontent.com", repo, ref]
      if let path, !path.isEmpty {
        components.append(path)
      }
      components.append(file)
      guard let url = URL(string: components.joined(separator: "/")) else {
        throw MarketplaceError.unsupportedSource
      }
      return url
    case let .url(base):
      let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
      guard let url = URL(string: "\(trimmed)/\(file)") else {
        throw MarketplaceError.unsupportedSource
      }
      return url
    }
  }
}
