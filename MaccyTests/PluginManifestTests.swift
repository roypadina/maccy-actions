import XCTest
@testable import Maccy

// MARK: - Helpers

private extension PluginManifest {
  /// Decode a package manifest from a JSON literal string.
  static func from(_ json: String) throws -> PluginManifest {
    let data = Data(json.utf8)
    return try JSONDecoder().decode(PluginManifest.self, from: data)
  }
}

// MARK: - Tests

final class PluginManifestTests: XCTestCase {

  // MARK: - Valid package decoding

  func testDecodeMinimalSingleProviderPackage() throws {
    let json = """
    {
      "id": "com.example.trim-pkg",
      "name": "Trim package",
      "version": "1.0.0",
      "description": "A package with one trim action.",
      "providers": [
        {
          "id": "com.example.trim",
          "name": "Trim Whitespace",
          "description": "Trims leading and trailing whitespace from the clipboard text.",
          "kind": "action",
          "engine": "declarative",
          "declarative": { "transform": [ { "op": "trim" } ] }
        }
      ]
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertEqual(manifest.id, "com.example.trim-pkg")
    XCTAssertEqual(manifest.name, "Trim package")
    XCTAssertEqual(manifest.version, "1.0.0")
    XCTAssertNil(manifest.author)
    XCTAssertNil(manifest.capabilities)
    XCTAssertEqual(manifest.providers.count, 1)

    let spec = manifest.providers[0]
    XCTAssertEqual(spec.id, "com.example.trim")
    XCTAssertEqual(spec.kind, .action)
    XCTAssertEqual(spec.engine, .declarative)
    XCTAssertNil(spec.entry)
    XCTAssertNil(spec.function)
    XCTAssertNotNil(spec.declarative)
  }

  func testDecodeMultiProviderPackageWithAllFields() throws {
    let json = """
    {
      "id": "com.example.unwrap-terminal",
      "name": "Unwrap terminal command",
      "version": "2.1.0",
      "author": { "name": "Alice", "url": "https://alice.dev" },
      "description": "Detect terminal-wrapped text and unwrap it.",
      "longHelp": "Two conditions and one action.",
      "minAppVersion": "2.6.0",
      "capabilities": ["network"],
      "providers": [
        {
          "id": "com.example.terminal-source",
          "name": "From terminal",
          "description": "Matches text copied from a terminal app.",
          "kind": "condition",
          "engine": "declarative",
          "declarative": { "predicate": { "sourceApp": "com.apple.Terminal" } }
        },
        {
          "id": "com.example.soft-wrap",
          "name": "Soft-wrapped text",
          "description": "Matches soft-wrapped text.",
          "kind": "condition",
          "engine": "javascript",
          "entry": "main.js",
          "function": "matchesSoftWrap"
        },
        {
          "id": "com.example.unwrap",
          "name": "Unwrap",
          "description": "Unwraps soft-wrapped text.",
          "kind": "action",
          "engine": "javascript",
          "entry": "main.js",
          "function": "transformUnwrap",
          "params": [
            { "key": "joiner", "label": "Joiner", "kind": "text", "placeholder": " " }
          ]
        }
      ]
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertEqual(manifest.author?.name, "Alice")
    XCTAssertEqual(manifest.author?.url, "https://alice.dev")
    XCTAssertEqual(manifest.longHelp, "Two conditions and one action.")
    XCTAssertEqual(manifest.minAppVersion, "2.6.0")
    XCTAssertEqual(manifest.capabilities, [.network])
    XCTAssertEqual(manifest.providers.count, 3)

    XCTAssertEqual(manifest.providers[1].function, "matchesSoftWrap")
    XCTAssertEqual(manifest.providers[2].function, "transformUnwrap")
    XCTAssertEqual(manifest.providers[2].entry, "main.js")
    XCTAssertEqual(manifest.providers[2].params?.first?.key, "joiner")
  }

  func testDecodeAuthorWithoutURL() throws {
    let json = """
    {
      "id": "com.example.upper-pkg",
      "name": "Uppercase package",
      "version": "1.0.0",
      "author": { "name": "Bob" },
      "description": "Converts the clipboard text to uppercase.",
      "providers": [
        {
          "id": "com.example.upper",
          "name": "Uppercase",
          "description": "Converts the clipboard text to uppercase.",
          "kind": "action",
          "engine": "declarative",
          "declarative": { "transform": [ { "op": "case", "value": "upper" } ] }
        }
      ]
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertEqual(manifest.author?.name, "Bob")
    XCTAssertNil(manifest.author?.url)
  }

  // MARK: - validate() — passing cases

  func testValidatePassesForValidDeclarativePackage() throws {
    let manifest = try PluginManifest.from(Self.declarativePackage())
    XCTAssertNoThrow(try manifest.validate())
  }

  func testValidatePassesForValidJSPackage() throws {
    let json = """
    {
      "id": "com.example.reverse-pkg",
      "name": "Reverse package",
      "version": "1.0.0",
      "description": "Reverses the text.",
      "providers": [
        {
          "id": "com.example.reverse",
          "name": "Reverse",
          "description": "Reverses the text.",
          "kind": "condition",
          "engine": "javascript",
          "entry": "main.js"
        }
      ]
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertNoThrow(try manifest.validate())
  }

  func testValidatePassesWhenDescriptionIsExactly120Chars() throws {
    let desc = String(repeating: "a", count: 120)
    let json = """
    {
      "id": "com.example.x",
      "name": "X",
      "version": "1.0.0",
      "description": "\(desc)",
      "providers": [
        {
          "id": "com.example.x.p",
          "name": "P",
          "description": "short",
          "kind": "action",
          "engine": "declarative",
          "declarative": { "transform": [] }
        }
      ]
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertNoThrow(try manifest.validate())
  }

  // MARK: - validate() — package-level missing fields

  func testValidateThrowsMissingFieldForEmptyID() throws {
    let manifest = try PluginManifest.from(Self.declarativePackage(id: ""))
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .missingField("id"))
    }
  }

  func testValidateThrowsMissingFieldForWhitespaceOnlyID() throws {
    let manifest = try PluginManifest.from(Self.declarativePackage(id: "   "))
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .missingField("id"))
    }
  }

  func testValidateThrowsMissingFieldForEmptyName() throws {
    let manifest = try PluginManifest.from(Self.declarativePackage(name: ""))
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .missingField("name"))
    }
  }

  func testValidateThrowsMissingFieldForEmptyVersion() throws {
    let manifest = try PluginManifest.from(Self.declarativePackage(version: ""))
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .missingField("version"))
    }
  }

  func testValidateThrowsMissingFieldForEmptyDescription() throws {
    let manifest = try PluginManifest.from(Self.declarativePackage(description: ""))
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .missingField("description"))
    }
  }

  func testValidateThrowsDescriptionTooLongFor121Chars() throws {
    let desc = String(repeating: "a", count: 121)
    let manifest = try PluginManifest.from(Self.declarativePackage(description: desc))
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .descriptionTooLong)
    }
  }

  func testValidateThrowsMissingFieldForEmptyProviders() throws {
    let json = """
    {
      "id": "com.example.empty",
      "name": "Empty",
      "version": "1.0.0",
      "description": "No providers at all.",
      "providers": []
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .missingField("providers"))
    }
  }

  // MARK: - validate() — per-provider failures

  func testValidateThrowsMissingFieldForEmptyProviderID() throws {
    let manifest = try PluginManifest.from(Self.declarativePackage(providerID: ""))
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .missingField("provider.id"))
    }
  }

  func testValidateThrowsMissingFieldForEmptyProviderName() throws {
    let manifest = try PluginManifest.from(Self.declarativePackage(providerName: ""))
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .missingField("provider.name"))
    }
  }

  func testValidateThrowsMissingFieldForEmptyProviderDescription() throws {
    let manifest = try PluginManifest.from(Self.declarativePackage(providerDescription: ""))
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .missingField("provider.description"))
    }
  }

  func testValidateThrowsDescriptionTooLongForProviderOver120() throws {
    let desc = String(repeating: "a", count: 121)
    let manifest = try PluginManifest.from(Self.declarativePackage(providerDescription: desc))
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .descriptionTooLong)
    }
  }

  func testValidateThrowsMissingFieldForNativeProviderEngine() throws {
    let json = """
    {
      "id": "com.example.bad-pkg",
      "name": "Bad",
      "version": "1.0.0",
      "description": "Has a native provider, which is illegal.",
      "providers": [
        {
          "id": "com.example.bad",
          "name": "Bad",
          "description": "Native is not allowed.",
          "kind": "action",
          "engine": "native"
        }
      ]
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .missingField("provider.engine"))
    }
  }

  func testValidateThrowsMissingFieldWhenDeclarativeProviderHasNoSpec() throws {
    let json = """
    {
      "id": "com.example.nodec-pkg",
      "name": "No declarative",
      "version": "1.0.0",
      "description": "Declarative provider missing its spec.",
      "providers": [
        {
          "id": "com.example.nodec",
          "name": "No declarative",
          "description": "Missing declarative spec.",
          "kind": "action",
          "engine": "declarative"
        }
      ]
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .missingField("provider.declarative"))
    }
  }

  func testValidateThrowsBadEngineEntryWhenJSProviderHasNoEntry() throws {
    let json = """
    {
      "id": "com.example.noentry-pkg",
      "name": "No entry",
      "version": "1.0.0",
      "description": "JS provider missing its entry.",
      "providers": [
        {
          "id": "com.example.noentry",
          "name": "No entry",
          "description": "Missing entry.",
          "kind": "condition",
          "engine": "javascript"
        }
      ]
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .badEngineEntry)
    }
  }

  func testValidateThrowsBadEngineEntryWhenJSProviderHasWhitespaceEntry() throws {
    let json = """
    {
      "id": "com.example.wsentry-pkg",
      "name": "Whitespace entry",
      "version": "1.0.0",
      "description": "JS provider entry is whitespace.",
      "providers": [
        {
          "id": "com.example.wsentry",
          "name": "Whitespace entry",
          "description": "Whitespace entry.",
          "kind": "condition",
          "engine": "javascript",
          "entry": "   "
        }
      ]
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .badEngineEntry)
    }
  }

  // A declarative provider does NOT need an entry field.
  func testValidateDoesNotRequireEntryForDeclarativeProvider() throws {
    let manifest = try PluginManifest.from(Self.declarativePackage())
    XCTAssertNoThrow(try manifest.validate())
  }

  // MARK: - descriptors(source:)

  func testDescriptorsBuiltFromDeclarativePackage() throws {
    let json = """
    {
      "id": "com.example.trim-pkg",
      "name": "Trim package",
      "version": "1.0.0",
      "description": "Trims whitespace package.",
      "providers": [
        {
          "id": "com.example.trim",
          "name": "Trim Whitespace",
          "description": "Trims leading and trailing whitespace.",
          "longHelp": "Also removes non-breaking spaces.",
          "kind": "action",
          "engine": "declarative",
          "declarative": { "transform": [ { "op": "trim" } ] }
        }
      ]
    }
    """
    let manifest = try PluginManifest.from(json)
    let descriptors = manifest.descriptors(source: .bundled)
    XCTAssertEqual(descriptors.count, 1)

    let descriptor = descriptors[0]
    XCTAssertEqual(descriptor.id, "com.example.trim")
    XCTAssertEqual(descriptor.name, "Trim Whitespace")
    XCTAssertEqual(descriptor.description, "Trims leading and trailing whitespace.")
    XCTAssertEqual(descriptor.longHelp, "Also removes non-breaking spaces.")
    XCTAssertEqual(descriptor.kind, .action)
    XCTAssertEqual(descriptor.engine, .declarative)
    XCTAssertEqual(descriptor.source, .bundled)
    XCTAssertTrue(descriptor.params.isEmpty)
    XCTAssertTrue(descriptor.capabilities.isEmpty)
    XCTAssertTrue(descriptor.isVerified)
    // package membership
    XCTAssertEqual(descriptor.pluginID, "com.example.trim-pkg")
    XCTAssertEqual(descriptor.pluginName, "Trim package")
  }

  func testDescriptorsCarryPackageCapabilitiesAndParams() throws {
    let json = """
    {
      "id": "com.example.reverse-pkg",
      "name": "Reverse package",
      "version": "1.0.0",
      "description": "A reverse package.",
      "capabilities": ["fileRead"],
      "providers": [
        {
          "id": "com.example.reverse",
          "name": "Reverse Text",
          "description": "Reverses every character.",
          "kind": "condition",
          "engine": "javascript",
          "entry": "main.js",
          "params": [
            { "key": "pattern", "label": "Pattern", "kind": "text", "placeholder": ".*" }
          ]
        }
      ]
    }
    """
    let manifest = try PluginManifest.from(json)
    let descriptor = manifest.descriptors(source: .marketplace("maccay-official"))[0]
    XCTAssertEqual(descriptor.id, "com.example.reverse")
    XCTAssertEqual(descriptor.kind, .condition)
    XCTAssertEqual(descriptor.engine, .javascript)
    XCTAssertEqual(descriptor.source, .marketplace("maccay-official"))
    XCTAssertTrue(descriptor.isVerified)
    XCTAssertEqual(descriptor.capabilities, [.fileRead])   // package-level
    XCTAssertEqual(descriptor.params.count, 1)
    XCTAssertEqual(descriptor.params.first?.key, "pattern")
  }

  func testDescriptorsForMultiProviderPackage() throws {
    let manifest = try PluginManifest.from(Self.multiProviderPackage())
    let descriptors = manifest.descriptors(source: .local("/Users/alice/plugins/multi"))
    XCTAssertEqual(descriptors.count, 2)
    XCTAssertEqual(Set(descriptors.map(\.id)), ["com.example.cond", "com.example.act"])
    // both carry the same package membership and are unverified (local source)
    for descriptor in descriptors {
      XCTAssertEqual(descriptor.pluginID, "com.example.multi")
      XCTAssertEqual(descriptor.pluginName, "Multi package")
      XCTAssertFalse(descriptor.isVerified)
    }
  }

  // MARK: - PluginManifestError Equatable

  func testPluginManifestErrorEquatable() {
    XCTAssertEqual(PluginManifestError.missingField("id"), .missingField("id"))
    XCTAssertNotEqual(PluginManifestError.missingField("id"), .missingField("name"))
    XCTAssertEqual(PluginManifestError.badEngineEntry, .badEngineEntry)
    XCTAssertEqual(PluginManifestError.descriptionTooLong, .descriptionTooLong)
    XCTAssertNotEqual(PluginManifestError.badEngineEntry, .descriptionTooLong)
  }

  // MARK: - Fixtures

  /// A single-provider declarative package with overridable fields, used by the
  /// validation tests to vary one field at a time.
  private static func declarativePackage(
    id: String = "com.example.trim-pkg",
    name: String = "Trim package",
    version: String = "1.0.0",
    description: String = "A trim package.",
    providerID: String = "com.example.trim",
    providerName: String = "Trim",
    providerDescription: String = "Trims whitespace."
  ) -> String {
    """
    {
      "id": "\(id)",
      "name": "\(name)",
      "version": "\(version)",
      "description": "\(description)",
      "providers": [
        {
          "id": "\(providerID)",
          "name": "\(providerName)",
          "description": "\(providerDescription)",
          "kind": "action",
          "engine": "declarative",
          "declarative": { "transform": [ { "op": "trim" } ] }
        }
      ]
    }
    """
  }

  private static func multiProviderPackage() -> String {
    """
    {
      "id": "com.example.multi",
      "name": "Multi package",
      "version": "1.0.0",
      "description": "A package with one condition and one action.",
      "providers": [
        {
          "id": "com.example.cond",
          "name": "Cond",
          "description": "A condition.",
          "kind": "condition",
          "engine": "declarative",
          "declarative": { "predicate": { "contains": "x" } }
        },
        {
          "id": "com.example.act",
          "name": "Act",
          "description": "An action.",
          "kind": "action",
          "engine": "declarative",
          "declarative": { "transform": [ { "op": "trim" } ] }
        }
      ]
    }
    """
  }
}
