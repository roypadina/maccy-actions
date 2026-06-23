import XCTest
@testable import Maccy

final class JSPluginRuntimeTests: XCTestCase {
  // MARK: - Happy path

  func testCallTransformReturnsTransformedString() throws {
    let runtime = try JSPluginRuntime(script: "function transform(input) { return input.toUpperCase(); }")
    XCTAssertEqual(try runtime.callTransform("abc"), "ABC")
  }

  func testCallMatchesReturnsBool() throws {
    let runtime = try JSPluginRuntime(script: "function matches(input) { return input.length > 3; }")
    XCTAssertTrue(try runtime.callMatches("hello"))
    XCTAssertFalse(try runtime.callMatches("hi"))
  }

  // MARK: - Compile failure

  func testCompileFailedThrowsOnSyntaxError() {
    XCTAssertThrowsError(try JSPluginRuntime(script: "function transform(input) { return")) { error in
      guard case JSPluginError.compileFailed = error else {
        return XCTFail("expected .compileFailed, got \(error)")
      }
    }
  }

  // MARK: - Missing entry

  func testCallTransformThrowsMissingEntryWhenAbsent() throws {
    let runtime = try JSPluginRuntime(script: "var x = 1;")
    XCTAssertThrowsError(try runtime.callTransform("abc")) { error in
      XCTAssertEqual(error as? JSPluginError, .missingEntry("transform"))
    }
  }

  func testCallMatchesThrowsMissingEntryWhenAbsent() throws {
    let runtime = try JSPluginRuntime(script: "var x = 1;")
    XCTAssertThrowsError(try runtime.callMatches("abc")) { error in
      XCTAssertEqual(error as? JSPluginError, .missingEntry("matches"))
    }
  }

  // MARK: - Wrong return type

  func testCallTransformThrowsWrongReturnTypeWhenNotString() throws {
    let runtime = try JSPluginRuntime(script: "function transform(input) { return 42; }")
    XCTAssertThrowsError(try runtime.callTransform("abc")) { error in
      XCTAssertEqual(error as? JSPluginError, .wrongReturnType)
    }
  }

  func testCallMatchesThrowsWrongReturnTypeWhenNotBool() throws {
    let runtime = try JSPluginRuntime(script: "function matches(input) { return 'nope'; }")
    XCTAssertThrowsError(try runtime.callMatches("abc")) { error in
      XCTAssertEqual(error as? JSPluginError, .wrongReturnType)
    }
  }

  // MARK: - Thrown JS error

  func testCallTransformThrowsThrewOnJSException() throws {
    let runtime = try JSPluginRuntime(script: "function transform(input) { throw new Error('boom'); }")
    XCTAssertThrowsError(try runtime.callTransform("abc")) { error in
      guard case JSPluginError.threw = error else {
        return XCTFail("expected .threw, got \(error)")
      }
    }
  }

  // MARK: - Watchdog / timeout

  func testWatchdogTimesOutOnInfiniteLoop() throws {
    let runtime = try JSPluginRuntime(script: "function transform(input) { while (true) {} return input; }",
                                      timeLimitSeconds: 0.1)
    XCTAssertThrowsError(try runtime.callTransform("abc")) { error in
      XCTAssertEqual(error as? JSPluginError, .timedOut)
    }
  }

  // MARK: - Bridge-less sandbox (nothing injected)

  func testSandboxFetchUndefined() throws {
    let runtime = try JSPluginRuntime(script: "function transform(input) { return typeof fetch; }")
    XCTAssertEqual(try runtime.callTransform("x"), "undefined")
  }

  func testSandboxRequireUndefined() throws {
    let runtime = try JSPluginRuntime(script: "function transform(input) { return typeof require; }")
    XCTAssertEqual(try runtime.callTransform("x"), "undefined")
  }

  func testSandboxXMLHttpRequestUndefined() throws {
    let runtime = try JSPluginRuntime(script: "function transform(input) { return typeof XMLHttpRequest; }")
    XCTAssertEqual(try runtime.callTransform("x"), "undefined")
  }

  func testSandboxSetTimeoutUndefined() throws {
    let runtime = try JSPluginRuntime(script: "function transform(input) { return typeof setTimeout; }")
    XCTAssertEqual(try runtime.callTransform("x"), "undefined")
  }

  func testSandboxProcessUndefined() throws {
    let runtime = try JSPluginRuntime(script: "function transform(input) { return typeof process; }")
    XCTAssertEqual(try runtime.callTransform("x"), "undefined")
  }
}
