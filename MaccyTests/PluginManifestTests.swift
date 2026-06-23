import XCTest
@testable import Maccy

// MARK: - Helpers

private extension PluginManifest {
  /// Decode a manifest from a JSON literal string. Crashes the test on decode failure.
  static func from(_ json: String) throws -> PluginManifest {
    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    return try decoder.decode(PluginManifest.self, from: data)
  }
}

// MARK: - Tests

final class PluginManifestTests: XCTestCase {

  // MARK: - Valid manifest decoding

  func testDecodeMinimalDeclarativeManifest() throws {
    let json = """
    {
      "id": "com.example.trim",
      "name": "Trim Whitespace",
      "version": "1.0.0",
      "description": "Trims leading and trailing whitespace from the clipboard text.",
      "kind": "action",
      "engine": "declarative",
      "declarative": { "transform": [ { "op": "trim" } ] }
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertEqual(manifest.id, "com.example.trim")
    XCTAssertEqual(manifest.name, "Trim Whitespace")
    XCTAssertEqual(manifest.version, "1.0.0")
    XCTAssertNil(manifest.author)
    XCTAssertEqual(manifest.kind, .action)
    XCTAssertEqual(manifest.engine, .declarative)
    XCTAssertNil(manifest.entry)
    XCTAssertNil(manifest.capabilities)
    XCTAssertNil(manifest.params)
    XCTAssertNotNil(manifest.declarative)
  }

  func testDecodeJSManifestWithAllFields() throws {
    let json = """
    {
      "id": "com.example.reverse",
      "name": "Reverse Text",
      "version": "2.1.0",
      "author": { "name": "Alice", "url": "https://alice.dev" },
      "description": "Reverses every character in the clipboard string.",
      "longHelp": "Uses JS split/reverse/join. Works on emoji clusters.",
      "kind": "condition",
      "engine": "javascript",
      "entry": "main.js",
      "capabilities": ["network"],
      "params": [
        { "key": "caseSensitive", "label": "Case sensitive", "kind": "text", "placeholder": "true" }
      ],
      "minAppVersion": "2.6.0"
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertEqual(manifest.id, "com.example.reverse")
    XCTAssertEqual(manifest.author?.name, "Alice")
    XCTAssertEqual(manifest.author?.url, "https://alice.dev")
    XCTAssertEqual(manifest.kind, .condition)
    XCTAssertEqual(manifest.engine, .javascript)
    XCTAssertEqual(manifest.entry, "main.js")
    XCTAssertEqual(manifest.capabilities, [.network])
    XCTAssertEqual(manifest.params?.count, 1)
    XCTAssertEqual(manifest.params?.first?.key, "caseSensitive")
    XCTAssertEqual(manifest.params?.first?.kind, .text)
    XCTAssertEqual(manifest.minAppVersion, "2.6.0")
    XCTAssertEqual(manifest.longHelp, "Uses JS split/reverse/join. Works on emoji clusters.")
  }

  func testDecodeAuthorWithoutURL() throws {
    let json = """
    {
      "id": "com.example.upper",
      "name": "Uppercase",
      "version": "1.0.0",
      "author": { "name": "Bob" },
      "description": "Converts the clipboard text to uppercase.",
      "kind": "action",
      "engine": "declarative"
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertEqual(manifest.author?.name, "Bob")
    XCTAssertNil(manifest.author?.url)
  }

  // MARK: - validate() — passing cases

  func testValidatePassesForValidDeclarativeManifest() throws {
    let json = """
    {
      "id": "com.example.trim",
      "name": "Trim",
      "version": "1.0.0",
      "description": "Trims whitespace.",
      "kind": "action",
      "engine": "declarative"
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertNoThrow(try manifest.validate())
  }

  func testValidatePassesForValidJSManifest() throws {
    let json = """
    {
      "id": "com.example.reverse",
      "name": "Reverse",
      "version": "1.0.0",
      "description": "Reverses the text.",
      "kind": "condition",
      "engine": "javascript",
      "entry": "main.js"
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertNoThrow(try manifest.validate())
  }

  func testValidatePassesWhenDescriptionIsExactly120Chars() throws {
    // 120 'a' characters — should pass
    let desc = String(repeating: "a", count: 120)
    let json = """
    {
      "id": "com.example.x",
      "name": "X",
      "version": "1.0.0",
      "description": "\(desc)",
      "kind": "action",
      "engine": "declarative"
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertNoThrow(try manifest.validate())
  }

  // MARK: - validate() — missingField("id")

  func testValidateThrowsMissingFieldForEmptyID() throws {
    let json = """
    {
      "id": "",
      "name": "Trim",
      "version": "1.0.0",
      "description": "Trims whitespace.",
      "kind": "action",
      "engine": "declarative"
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .missingField("id"))
    }
  }

  func testValidateThrowsMissingFieldForWhitespaceOnlyID() throws {
    let json = """
    {
      "id": "   ",
      "name": "Trim",
      "version": "1.0.0",
      "description": "Trims whitespace.",
      "kind": "action",
      "engine": "declarative"
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .missingField("id"))
    }
  }

  // MARK: - validate() — missingField("name")

  func testValidateThrowsMissingFieldForEmptyName() throws {
    let json = """
    {
      "id": "com.example.trim",
      "name": "",
      "version": "1.0.0",
      "description": "Trims whitespace.",
      "kind": "action",
      "engine": "declarative"
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .missingField("name"))
    }
  }

  // MARK: - validate() — missingField("version")

  func testValidateThrowsMissingFieldForEmptyVersion() throws {
    let json = """
    {
      "id": "com.example.trim",
      "name": "Trim",
      "version": "",
      "description": "Trims whitespace.",
      "kind": "action",
      "engine": "declarative"
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .missingField("version"))
    }
  }

  // MARK: - validate() — missingField("description")

  func testValidateThrowsMissingFieldForEmptyDescription() throws {
    let json = """
    {
      "id": "com.example.trim",
      "name": "Trim",
      "version": "1.0.0",
      "description": "",
      "kind": "action",
      "engine": "declarative"
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .missingField("description"))
    }
  }

  // MARK: - validate() — descriptionTooLong

  func testValidateThrowsDescriptionTooLongFor121Chars() throws {
    // 121 'a' characters — exceeds limit
    let desc = String(repeating: "a", count: 121)
    let json = """
    {
      "id": "com.example.trim",
      "name": "Trim",
      "version": "1.0.0",
      "description": "\(desc)",
      "kind": "action",
      "engine": "declarative"
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .descriptionTooLong)
    }
  }

  // MARK: - validate() — missingField("engine") for .native

  func testValidateThrowsMissingFieldForNativeEngine() throws {
    // engine == .native is not a valid value in a manifest; encode it manually
    // via a raw string since ProviderEngine.native would be rejected by the
    // manifest's domain logic (a loaded plugin cannot be native).
    let json = """
    {
      "id": "com.example.bad",
      "name": "Bad",
      "version": "1.0.0",
      "description": "Should not pass validation.",
      "kind": "action",
      "engine": "native"
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .missingField("engine"))
    }
  }

  // MARK: - validate() — badEngineEntry

  func testValidateThrowsBadEngineEntryWhenJSHasNoEntry() throws {
    let json = """
    {
      "id": "com.example.reverse",
      "name": "Reverse",
      "version": "1.0.0",
      "description": "Reverses the text.",
      "kind": "condition",
      "engine": "javascript"
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .badEngineEntry)
    }
  }

  func testValidateThrowsBadEngineEntryWhenJSHasEmptyEntry() throws {
    let json = """
    {
      "id": "com.example.reverse",
      "name": "Reverse",
      "version": "1.0.0",
      "description": "Reverses the text.",
      "kind": "condition",
      "engine": "javascript",
      "entry": ""
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .badEngineEntry)
    }
  }

  func testValidateThrowsBadEngineEntryWhenJSHasWhitespaceEntry() throws {
    let json = """
    {
      "id": "com.example.reverse",
      "name": "Reverse",
      "version": "1.0.0",
      "description": "Reverses the text.",
      "kind": "condition",
      "engine": "javascript",
      "entry": "   "
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertThrowsError(try manifest.validate()) { error in
      XCTAssertEqual(error as? PluginManifestError, .badEngineEntry)
    }
  }

  // A declarative manifest does NOT need an entry field — this must not throw.
  func testValidateDoesNotRequireEntryForDeclarativeManifest() throws {
    let json = """
    {
      "id": "com.example.trim",
      "name": "Trim",
      "version": "1.0.0",
      "description": "Trims the text.",
      "kind": "action",
      "engine": "declarative"
    }
    """
    let manifest = try PluginManifest.from(json)
    XCTAssertNoThrow(try manifest.validate())
  }

  // MARK: - descriptor(source:)

  func testDescriptorBuiltFromDeclarativeManifest() throws {
    let json = """
    {
      "id": "com.example.trim",
      "name": "Trim Whitespace",
      "version": "1.0.0",
      "description": "Trims leading and trailing whitespace.",
      "longHelp": "Also removes non-breaking spaces.",
      "kind": "action",
      "engine": "declarative"
    }
    """
    let manifest = try PluginManifest.from(json)
    let descriptor = manifest.descriptor(source: .bundled)

    XCTAssertEqual(descriptor.id, "com.example.trim")
    XCTAssertEqual(descriptor.name, "Trim Whitespace")
    XCTAssertEqual(descriptor.description, "Trims leading and trailing whitespace.")
    XCTAssertEqual(descriptor.longHelp, "Also removes non-breaking spaces.")
    XCTAssertEqual(descriptor.kind, .action)
    XCTAssertEqual(descriptor.engine, .declarative)
    XCTAssertEqual(descriptor.source, .bundled)
    XCTAssertTrue(descriptor.params.isEmpty)
    XCTAssertTrue(descriptor.capabilities.isEmpty)
    XCTAssertTrue(descriptor.isVerified)   // bundled => verified
  }

  func testDescriptorBuiltFromJSManifestWithParams() throws {
    let json = """
    {
      "id": "com.example.reverse",
      "name": "Reverse Text",
      "version": "1.0.0",
      "description": "Reverses every character.",
      "kind": "condition",
      "engine": "javascript",
      "entry": "main.js",
      "capabilities": ["fileRead"],
      "params": [
        { "key": "pattern", "label": "Pattern", "kind": "text", "placeholder": ".*" }
      ]
    }
    """
    let manifest = try PluginManifest.from(json)
    let descriptor = manifest.descriptor(source: .marketplace("maccay-official"))

    XCTAssertEqual(descriptor.id, "com.example.reverse")
    XCTAssertEqual(descriptor.kind, .condition)
    XCTAssertEqual(descriptor.engine, .javascript)
    XCTAssertEqual(descriptor.source, .marketplace("maccay-official"))
    XCTAssertTrue(descriptor.isVerified)   // maccay-official => verified
    XCTAssertEqual(descriptor.capabilities, [.fileRead])
    XCTAssertEqual(descriptor.params.count, 1)
    XCTAssertEqual(descriptor.params.first?.key, "pattern")
    XCTAssertEqual(descriptor.params.first?.label, "Pattern")
    XCTAssertEqual(descriptor.params.first?.placeholder, ".*")
  }

  func testDescriptorFromLocalSourceIsUnverified() throws {
    let json = """
    {
      "id": "com.example.local",
      "name": "Local Plugin",
      "version": "1.0.0",
      "description": "A locally installed plugin.",
      "kind": "action",
      "engine": "declarative"
    }
    """
    let manifest = try PluginManifest.from(json)
    let descriptor = manifest.descriptor(source: .local("/Users/alice/plugins/local-plugin"))

    XCTAssertFalse(descriptor.isVerified)   // local => not verified
    XCTAssertEqual(descriptor.source, .local("/Users/alice/plugins/local-plugin"))
  }

  func testDescriptorIDMatchesManifestID() throws {
    let json = """
    {
      "id": "io.example.my-plugin",
      "name": "My Plugin",
      "version": "3.0.1",
      "description": "Does something useful with your clipboard.",
      "kind": "action",
      "engine": "declarative"
    }
    """
    let manifest = try PluginManifest.from(json)
    let descriptor = manifest.descriptor(source: .builtin)
    XCTAssertEqual(descriptor.id, manifest.id)
  }

  // MARK: - PluginManifestError Equatable

  func testPluginManifestErrorEquatable() {
    XCTAssertEqual(PluginManifestError.missingField("id"), .missingField("id"))
    XCTAssertNotEqual(PluginManifestError.missingField("id"), .missingField("name"))
    XCTAssertEqual(PluginManifestError.badEngineEntry, .badEngineEntry)
    XCTAssertEqual(PluginManifestError.descriptionTooLong, .descriptionTooLong)
    XCTAssertNotEqual(PluginManifestError.badEngineEntry, .descriptionTooLong)
  }
}
