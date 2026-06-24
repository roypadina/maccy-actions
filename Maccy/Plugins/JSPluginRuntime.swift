import Foundation
import JavaScriptCore

// MARK: - JavaScriptCore watchdog C API (private header, public symbol)
//
// `JSContextGroupSetExecutionTimeLimit` / `JSContextGroupClearExecutionTimeLimit`
// are stable, long-shipping JavaScriptCore functions that enforce a wall-clock
// execution-time limit (the only robust way to defeat `while(true){}`). They are
// declared in JSC's private `JSContextRefPrivate.h`, which Apple does NOT vend in
// the macOS SDK's public Headers, so `import JavaScriptCore` doesn't surface them.
// The symbols ARE exported by the framework (present in JavaScriptCore.tbd), so we
// bind to them by their unmangled C symbol names via `@_silgen_name`. The public
// `JSContextGroupRef` / `JSContextRef` opaque types come from `import JavaScriptCore`.
@_silgen_name("JSContextGroupSetExecutionTimeLimit")
private func JSContextGroupSetExecutionTimeLimit(
  _ group: JSContextGroupRef?,
  _ limit: Double,
  _ callback: @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool,
  _ context: UnsafeMutableRawPointer?
)

@_silgen_name("JSContextGroupClearExecutionTimeLimit")
private func JSContextGroupClearExecutionTimeLimit(_ group: JSContextGroupRef?)

enum JSPluginError: Error, Equatable {
  case compileFailed(String)
  case missingEntry(String)
  case timedOut
  case wrongReturnType
  case threw(String)
}

/// Bridge-less JavaScriptCore runtime: a bare `JSContext` with NOTHING injected
/// (no fetch/require/XMLHttpRequest/setTimeout/process — only ECMAScript built-ins),
/// guarded by a wall-clock watchdog via `JSContextGroupSetExecutionTimeLimit`.
/// Not `@MainActor`: pure compute, callable off the main actor.
final class JSPluginRuntime {
  private let context: JSContext
  private let timeLimitSeconds: Double

  /// The most recent exception captured by `context.exceptionHandler`.
  /// Read + cleared around every evaluation/call.
  private var lastException: JSValue?

  init(script: String, timeLimitSeconds: Double = 0.25) throws {
    self.timeLimitSeconds = timeLimitSeconds

    guard let context = JSContext() else {
      throw JSPluginError.compileFailed("could not create JSContext")
    }
    self.context = context

    // Capture every JS exception instead of letting JSC swallow it.
    context.exceptionHandler = { [weak self] _, exception in
      self?.lastException = exception
    }

    // Arm the watchdog on the context's group. The callback returns `true`
    // to terminate when the wall-clock limit is exceeded; JSC then raises a
    // JS exception that our exceptionHandler captures.
    if let globalRef = context.jsGlobalContextRef {
      let group = JSContextGetGroup(globalRef)
      JSContextGroupSetExecutionTimeLimit(group, timeLimitSeconds, { _, _ in true }, nil)
    }

    // Compile + evaluate the script body (defines transform/matches globals).
    lastException = nil
    context.evaluateScript(script)
    if let exception = lastException {
      lastException = nil
      throw JSPluginError.compileFailed(Self.message(of: exception))
    }
  }

  deinit {
    if let globalRef = context.jsGlobalContextRef {
      let group = JSContextGetGroup(globalRef)
      JSContextGroupClearExecutionTimeLimit(group)
    }
  }

  /// Calls the named global transform function (default `transform`); expects a String back.
  /// Multiple providers can share one runtime and call different functions on it.
  func callTransform(function: String = "transform", _ input: String) throws -> String {
    let result = try call(function, argument: input)
    guard result.isString else { throw JSPluginError.wrongReturnType }
    return result.toString()
  }

  /// Calls the named global predicate function (default `matches`); expects a Bool back.
  func callMatches(function: String = "matches", _ input: String) throws -> Bool {
    let result = try call(function, argument: input)
    guard result.isBoolean else { throw JSPluginError.wrongReturnType }
    return result.toBool()
  }

  // MARK: - Private

  private func call(_ entry: String, argument: String) throws -> JSValue {
    guard let fn = context.objectForKeyedSubscript(entry),
          !fn.isUndefined,
          fn.isObject else {
      throw JSPluginError.missingEntry(entry)
    }

    lastException = nil
    let result = fn.call(withArguments: [argument])

    if let exception = lastException {
      lastException = nil
      let text = Self.message(of: exception)
      // The watchdog termination surfaces as a JS exception whose message
      // mentions "terminated". Map that specific case to .timedOut.
      if text.localizedCaseInsensitiveContains("terminated") {
        throw JSPluginError.timedOut
      }
      throw JSPluginError.threw(text)
    }

    guard let result = result else {
      throw JSPluginError.threw("call returned no value")
    }
    return result
  }

  private static func message(of exception: JSValue) -> String {
    if let message = exception.objectForKeyedSubscript("message"),
       !message.isUndefined,
       let text = message.toString(),
       !text.isEmpty {
      return text
    }
    return exception.toString() ?? "unknown JS exception"
  }
}

/// `@MainActor` ConditionProvider wrapper around a JS runtime's predicate function.
/// `function` defaults to `matches`; multiple providers may share one runtime.
@MainActor
struct JSConditionProvider: ConditionProvider {
  let descriptor: ProviderDescriptor
  let runtime: JSPluginRuntime
  var function: String = "matches"

  func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool {
    try runtime.callMatches(function: function, input.string)
  }
}

/// `@MainActor` ActionProvider wrapper around a JS runtime's transform function.
/// `function` defaults to `transform`; multiple providers may share one runtime.
@MainActor
struct JSActionProvider: ActionProvider {
  let descriptor: ProviderDescriptor
  let runtime: JSPluginRuntime
  var function: String = "transform"

  func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome {
    .replace(try runtime.callTransform(function: function, input.string))
  }
}
