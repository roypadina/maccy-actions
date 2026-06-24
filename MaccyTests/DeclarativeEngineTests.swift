import XCTest
@testable import Maccy

final class DeclarativeEngineTests: XCTestCase {

  // MARK: - Fixtures

  @MainActor
  private func makeInput(
    _ string: String,
    kinds: Set<ValueKind> = [.text],
    sourceApp: String? = nil,
    fileURLs: [URL] = []
  ) -> PluginInput {
    PluginInput(string: string, kinds: kinds, sourceAppBundleID: sourceApp, fileURLs: fileURLs)
  }

  private func actionDescriptor(id: String = "test.action") -> ProviderDescriptor {
    ProviderDescriptor(
      id: id,
      name: "Test Action",
      description: "A test declarative action",
      longHelp: nil,
      kind: .action,
      engine: .declarative,
      params: [],
      capabilities: [],
      source: .bundled
    )
  }

  private func conditionDescriptor(id: String = "test.condition") -> ProviderDescriptor {
    ProviderDescriptor(
      id: id,
      name: "Test Condition",
      description: "A test declarative condition",
      longHelp: nil,
      kind: .condition,
      engine: .declarative,
      params: [],
      capabilities: [],
      source: .bundled
    )
  }

  // MARK: - Action: individual ops

  @MainActor
  func testTrimOp() async throws {
    let spec: JSONValue = .object(["transform": .array([.object(["op": .string("trim")])])])
    let provider = DeclarativeActionProvider(descriptor: actionDescriptor(), spec: spec)
    let outcome = try await provider.run(makeInput("  hello  "), params: .emptyObject)
    XCTAssertEqual(outcome, .replace("hello"))
  }

  @MainActor
  func testCaseUpperOp() async throws {
    let spec: JSONValue = .object(["transform": .array([
      .object(["op": .string("case"), "value": .string("upper")])
    ])])
    let provider = DeclarativeActionProvider(descriptor: actionDescriptor(), spec: spec)
    let outcome = try await provider.run(makeInput("hello"), params: .emptyObject)
    XCTAssertEqual(outcome, .replace("HELLO"))
  }

  @MainActor
  func testCaseLowerOp() async throws {
    let spec: JSONValue = .object(["transform": .array([
      .object(["op": .string("case"), "value": .string("lower")])
    ])])
    let provider = DeclarativeActionProvider(descriptor: actionDescriptor(), spec: spec)
    let outcome = try await provider.run(makeInput("HeLLo"), params: .emptyObject)
    XCTAssertEqual(outcome, .replace("hello"))
  }

  @MainActor
  func testPrependOp() async throws {
    let spec: JSONValue = .object(["transform": .array([
      .object(["op": .string("prepend"), "text": .string(">> ")])
    ])])
    let provider = DeclarativeActionProvider(descriptor: actionDescriptor(), spec: spec)
    let outcome = try await provider.run(makeInput("hello"), params: .emptyObject)
    XCTAssertEqual(outcome, .replace(">> hello"))
  }

  @MainActor
  func testAppendOp() async throws {
    let spec: JSONValue = .object(["transform": .array([
      .object(["op": .string("append"), "text": .string("!")])
    ])])
    let provider = DeclarativeActionProvider(descriptor: actionDescriptor(), spec: spec)
    let outcome = try await provider.run(makeInput("hello"), params: .emptyObject)
    XCTAssertEqual(outcome, .replace("hello!"))
  }

  @MainActor
  func testRegexReplaceOp() async throws {
    let spec: JSONValue = .object(["transform": .array([
      .object([
        "op": .string("regexReplace"),
        "pattern": .string("[0-9]+"),
        "replacement": .string("#")
      ])
    ])])
    let provider = DeclarativeActionProvider(descriptor: actionDescriptor(), spec: spec)
    let outcome = try await provider.run(makeInput("a12b345c"), params: .emptyObject)
    XCTAssertEqual(outcome, .replace("a#b#c"))
  }

  @MainActor
  func testRegexReplaceWithCaptureGroup() async throws {
    // NSRegularExpression template uses $1 for capture group 1.
    let spec: JSONValue = .object(["transform": .array([
      .object([
        "op": .string("regexReplace"),
        "pattern": .string("(\\w+)@(\\w+)"),
        "replacement": .string("$2.$1")
      ])
    ])])
    let provider = DeclarativeActionProvider(descriptor: actionDescriptor(), spec: spec)
    let outcome = try await provider.run(makeInput("user@host"), params: .emptyObject)
    XCTAssertEqual(outcome, .replace("host.user"))
  }

  @MainActor
  func testRegexReplaceFlagI() async throws {
    // With flags:"i" the pattern "hello" matches "HELLO" (case-insensitive).
    let specWithFlag: JSONValue = .object(["transform": .array([
      .object([
        "op": .string("regexReplace"),
        "pattern": .string("hello"),
        "flags": .string("i"),
        "replacement": .string("X")
      ])
    ])])
    let provider = DeclarativeActionProvider(descriptor: actionDescriptor(), spec: specWithFlag)
    let outcome = try await provider.run(makeInput("HELLO world"), params: .emptyObject)
    XCTAssertEqual(outcome, .replace("X world"))

    // Without flags the same pattern does NOT match the differently-cased input.
    let specNoFlag: JSONValue = .object(["transform": .array([
      .object([
        "op": .string("regexReplace"),
        "pattern": .string("hello"),
        "replacement": .string("X")
      ])
    ])])
    let providerNoFlag = DeclarativeActionProvider(descriptor: actionDescriptor(), spec: specNoFlag)
    let outcomeNoFlag = try await providerNoFlag.run(makeInput("HELLO world"), params: .emptyObject)
    XCTAssertEqual(outcomeNoFlag, .replace("HELLO world"))
  }

  // MARK: - Action: op chaining (fold order)

  @MainActor
  func testOpChainAppliesInOrder() async throws {
    // trim -> upper -> prepend "[" -> append "]"
    let spec: JSONValue = .object(["transform": .array([
      .object(["op": .string("trim")]),
      .object(["op": .string("case"), "value": .string("upper")]),
      .object(["op": .string("prepend"), "text": .string("[")]),
      .object(["op": .string("append"), "text": .string("]")])
    ])])
    let provider = DeclarativeActionProvider(descriptor: actionDescriptor(), spec: spec)
    let outcome = try await provider.run(makeInput("  abc  "), params: .emptyObject)
    XCTAssertEqual(outcome, .replace("[ABC]"))
  }

  @MainActor
  func testEmptyTransformReturnsInputUnchanged() async throws {
    let spec: JSONValue = .object(["transform": .array([])])
    let provider = DeclarativeActionProvider(descriptor: actionDescriptor(), spec: spec)
    let outcome = try await provider.run(makeInput("unchanged"), params: .emptyObject)
    XCTAssertEqual(outcome, .replace("unchanged"))
  }

  // MARK: - Action: error paths

  @MainActor
  func testUnknownOpThrows() async {
    let spec: JSONValue = .object(["transform": .array([
      .object(["op": .string("explode")])
    ])])
    let provider = DeclarativeActionProvider(descriptor: actionDescriptor(), spec: spec)
    do {
      _ = try await provider.run(makeInput("hello"), params: .emptyObject)
      XCTFail("expected unknownOp to throw")
    } catch let error as DeclarativeError {
      XCTAssertEqual(error, .unknownOp("explode"))
    } catch {
      XCTFail("expected DeclarativeError.unknownOp, got \(error)")
    }
  }

  @MainActor
  func testActionMissingTransformKeyThrowsBadSpec() async {
    let spec: JSONValue = .object(["predicate": .object([:])])  // wrong shape for an action
    let provider = DeclarativeActionProvider(descriptor: actionDescriptor(), spec: spec)
    do {
      _ = try await provider.run(makeInput("hello"), params: .emptyObject)
      XCTFail("expected badSpec to throw")
    } catch let error as DeclarativeError {
      XCTAssertEqual(error, .badSpec)
    } catch {
      XCTFail("expected DeclarativeError.badSpec, got \(error)")
    }
  }

  // MARK: - Condition: leaves

  @MainActor
  func testConditionRegexLeafMatches() throws {
    let spec: JSONValue = .object(["predicate": .object(["regex": .string("^https?://")])])
    let provider = DeclarativeConditionProvider(descriptor: conditionDescriptor(), spec: spec)
    XCTAssertTrue(try provider.evaluate(makeInput("https://example.com"), params: .emptyObject))
    XCTAssertFalse(try provider.evaluate(makeInput("ftp://example.com"), params: .emptyObject))
  }

  @MainActor
  func testConditionContainsLeafIsCaseInsensitive() throws {
    let spec: JSONValue = .object(["predicate": .object(["contains": .string("FOO")])])
    let provider = DeclarativeConditionProvider(descriptor: conditionDescriptor(), spec: spec)
    XCTAssertTrue(try provider.evaluate(makeInput("a foo bar"), params: .emptyObject))
    XCTAssertFalse(try provider.evaluate(makeInput("a bar baz"), params: .emptyObject))
  }

  @MainActor
  func testConditionKindLeaf() throws {
    let spec: JSONValue = .object(["predicate": .object(["kind": .string("url")])])
    let provider = DeclarativeConditionProvider(descriptor: conditionDescriptor(), spec: spec)
    XCTAssertTrue(try provider.evaluate(makeInput("x", kinds: [.url, .text]), params: .emptyObject))
    XCTAssertFalse(try provider.evaluate(makeInput("x", kinds: [.text]), params: .emptyObject))
  }

  @MainActor
  func testConditionSourceAppLeaf() throws {
    let spec: JSONValue = .object(["predicate": .object(["sourceApp": .string("com.apple.Safari")])])
    let provider = DeclarativeConditionProvider(descriptor: conditionDescriptor(), spec: spec)
    XCTAssertTrue(try provider.evaluate(makeInput("x", sourceApp: "com.apple.Safari"), params: .emptyObject))
    XCTAssertFalse(try provider.evaluate(makeInput("x", sourceApp: "com.apple.Terminal"), params: .emptyObject))
    XCTAssertFalse(try provider.evaluate(makeInput("x", sourceApp: nil), params: .emptyObject))
  }

  // MARK: - Condition: nodes

  @MainActor
  func testConditionAllNode() throws {
    let spec: JSONValue = .object(["predicate": .object(["all": .array([
      .object(["contains": .string("foo")]),
      .object(["contains": .string("bar")])
    ])])])
    let provider = DeclarativeConditionProvider(descriptor: conditionDescriptor(), spec: spec)
    XCTAssertTrue(try provider.evaluate(makeInput("foo and bar"), params: .emptyObject))
    XCTAssertFalse(try provider.evaluate(makeInput("foo only"), params: .emptyObject))
  }

  @MainActor
  func testConditionAnyNode() throws {
    let spec: JSONValue = .object(["predicate": .object(["any": .array([
      .object(["contains": .string("foo")]),
      .object(["contains": .string("bar")])
    ])])])
    let provider = DeclarativeConditionProvider(descriptor: conditionDescriptor(), spec: spec)
    XCTAssertTrue(try provider.evaluate(makeInput("only bar"), params: .emptyObject))
    XCTAssertFalse(try provider.evaluate(makeInput("neither"), params: .emptyObject))
  }

  @MainActor
  func testConditionNotNode() throws {
    let spec: JSONValue = .object(["predicate": .object(["not":
      .object(["contains": .string("foo")])
    ])])
    let provider = DeclarativeConditionProvider(descriptor: conditionDescriptor(), spec: spec)
    XCTAssertTrue(try provider.evaluate(makeInput("bar"), params: .emptyObject))
    XCTAssertFalse(try provider.evaluate(makeInput("foo"), params: .emptyObject))
  }

  @MainActor
  func testConditionNestedTree() throws {
    // all[ kind==url, not(contains "internal"), any[sourceApp Safari, sourceApp Chrome] ]
    let spec: JSONValue = .object(["predicate": .object(["all": .array([
      .object(["kind": .string("url")]),
      .object(["not": .object(["contains": .string("internal")])]),
      .object(["any": .array([
        .object(["sourceApp": .string("com.apple.Safari")]),
        .object(["sourceApp": .string("com.google.Chrome")])
      ])])
    ])])])
    let provider = DeclarativeConditionProvider(descriptor: conditionDescriptor(), spec: spec)
    XCTAssertTrue(try provider.evaluate(
      makeInput("https://public.example.com", kinds: [.url, .text], sourceApp: "com.apple.Safari"),
      params: .emptyObject
    ))
    // fails because contains "internal"
    XCTAssertFalse(try provider.evaluate(
      makeInput("https://internal.example.com", kinds: [.url, .text], sourceApp: "com.apple.Safari"),
      params: .emptyObject
    ))
    // fails because wrong source app
    XCTAssertFalse(try provider.evaluate(
      makeInput("https://public.example.com", kinds: [.url, .text], sourceApp: "com.apple.Terminal"),
      params: .emptyObject
    ))
  }

  // MARK: - Condition: error paths

  @MainActor
  func testConditionMissingPredicateKeyThrowsBadSpec() {
    let spec: JSONValue = .object(["transform": .array([])])  // wrong shape for a condition
    let provider = DeclarativeConditionProvider(descriptor: conditionDescriptor(), spec: spec)
    XCTAssertThrowsError(try provider.evaluate(makeInput("x"), params: .emptyObject)) { error in
      XCTAssertEqual(error as? DeclarativeError, .badSpec)
    }
  }

  @MainActor
  func testConditionUnrecognizedLeafThrowsBadSpec() {
    let spec: JSONValue = .object(["predicate": .object(["bogusLeaf": .string("x")])])
    let provider = DeclarativeConditionProvider(descriptor: conditionDescriptor(), spec: spec)
    XCTAssertThrowsError(try provider.evaluate(makeInput("x"), params: .emptyObject)) { error in
      XCTAssertEqual(error as? DeclarativeError, .badSpec)
    }
  }

  // MARK: - makeProvider(spec:descriptor:)

  @MainActor
  func testMakeProviderBuildsAction() async throws {
    let spec = ProviderSpec(
      id: "com.test.base64ish",
      name: "Wrap Brackets",
      description: "Wraps text in brackets",
      longHelp: nil,
      kind: .action,
      engine: .declarative,
      params: nil,
      declarative: .object(["transform": .array([
        .object(["op": .string("prepend"), "text": .string("[")]),
        .object(["op": .string("append"), "text": .string("]")])
      ])]),
      entry: nil,
      function: nil
    )
    let built = DeclarativeEngine.makeProvider(spec: spec, descriptor: actionDescriptor(id: spec.id))
    XCTAssertNil(built.condition)
    let action = try XCTUnwrap(built.action)
    XCTAssertEqual(action.descriptor.id, "com.test.base64ish")
    let outcome = try await action.run(makeInput("x"), params: .emptyObject)
    XCTAssertEqual(outcome, .replace("[x]"))
  }

  @MainActor
  func testMakeProviderBuildsCondition() throws {
    let spec = ProviderSpec(
      id: "com.test.isurl",
      name: "Is URL",
      description: "True when the text looks like a URL",
      longHelp: nil,
      kind: .condition,
      engine: .declarative,
      params: nil,
      declarative: .object(["predicate": .object(["regex": .string("^https?://")])]),
      entry: nil,
      function: nil
    )
    let built = DeclarativeEngine.makeProvider(spec: spec, descriptor: conditionDescriptor(id: spec.id))
    XCTAssertNil(built.action)
    let condition = try XCTUnwrap(built.condition)
    XCTAssertEqual(condition.descriptor.id, "com.test.isurl")
    XCTAssertTrue(try condition.evaluate(makeInput("https://x.com"), params: .emptyObject))
    XCTAssertFalse(try condition.evaluate(makeInput("not a url"), params: .emptyObject))
  }

  @MainActor
  func testMakeProviderWithNilDeclarativeReturnsEmpty() {
    let spec = ProviderSpec(
      id: "com.test.broken",
      name: "Broken",
      description: "No declarative spec",
      longHelp: nil,
      kind: .action,
      engine: .declarative,
      params: nil,
      declarative: nil,
      entry: nil,
      function: nil
    )
    let built = DeclarativeEngine.makeProvider(spec: spec, descriptor: actionDescriptor(id: spec.id))
    XCTAssertNil(built.condition)
    XCTAssertNil(built.action)
  }
}
