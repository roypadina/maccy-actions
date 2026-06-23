# Maccay Plugin System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Maccay's hardcoded clipboard conditions and actions into a registry-backed plugin system so anyone can add new ones via folder-loaded plugins (declarative JSON or JavaScript) distributed through GitHub-repo and local-folder marketplaces — without rebuilding the app — each carrying a GUI-visible description.

**Architecture:** Replace the closed `RuleCondition`/`ActionType`/`TransformKind` enums + `switch` dispatch with a single `ProviderRegistry`. Every condition and action — native built-ins, native first-party providers, and folder-loaded plugins — is a `Provider` keyed by a stable string id. Rules reference providers by `{provider, params}`. Two plugin engines: a `DeclarativeEngine` (data-only) and a `JSPluginRuntime` (bridge-less JavaScriptCore + watchdog). Plugins install from marketplaces (a git repo serving `marketplace.json`, or a local folder), verified by `sha256`. The GUI pickers, the `rules describe` CLI catalog, and the description tooltips all derive from `ProviderRegistry.descriptors()`.

**Tech Stack:** Swift 5 / SwiftUI, macOS app (sandboxed, notarized), `Defaults` library (sindresorhus), `KeyboardShortcuts` library, JavaScriptCore (system framework), XCTest.

## Global Constraints

Every task's requirements implicitly include this section. Values copied verbatim from the codebase.

- **Branch:** all work on `feat/plugin-system` (already created). Commit after every task. Do NOT push (net-new push needs explicit approval).
- **Build target / scheme:** `Maccy`. App target source build phase UUID `DAEE383F1E3DBEB100DD2966`; test target build phase UUID `DA360DAC1E3DF137005C6F6B`; the flat source group is `DAEE38451E3DBEB100DD2966 /* Maccy */` (`path = Maccy`); test group has `path = MaccyTests`.
- **Test command (unit only):**
  ```sh
  xcodebuild test -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj -scheme Maccy -destination 'platform=macOS' -only-testing:MaccyTests
  ```
  (XcodeBuildMCP `test_macos` is an equivalent alternative; load its schema via `ToolSearch select:mcp__XcodeBuildMCP__test_macos` first.)
- **Test framework:** XCTest only. Every test file: `import XCTest` + `@testable import Maccy`. Class `final class <Name>Tests: XCTestCase`; methods `func test<What>()`; `XCTAssertEqual`/`XCTAssertTrue`. No Swift Testing.
- **pbxproj registration (NOT a synchronized group — every new `.swift` needs 4 manual edits):** for a file under `Maccy/Plugins/`, follow the existing `Maccy/Actions/` precedent — files sit **flat in the `Maccy` group** with the subfolder encoded in the `path` field; there is no nested group. Generate two 24-hex UUIDs per file (`uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'`). Add: (1) `PBXBuildFile` `<bf> /* X.swift in Sources */ = {isa = PBXBuildFile; fileRef = <fr> /* X.swift */; };`; (2) `PBXFileReference` `<fr> /* X.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Plugins/X.swift; sourceTree = "<group>"; };`; (3) `<fr>` into the `DAEE38451E3DBEB100DD2966 /* Maccy */` group `children`; (4) `<bf>` into `DAEE383F1E3DBEB100DD2966 /* Sources */` `files`. Test files use `path = MaccyTests/X.swift`-style refs added to the MaccyTests group + `DA360DAC1E3DF137005C6F6B` build phase. A `.swift` file not in pbxproj is silently NOT compiled.
- **AUTHORITATIVE (pbxproj groups) — overrides any per-task wording:** there is NO nested `Plugins` PBXGroup at any point in this plan. EVERY `Maccy/Plugins/*.swift` file, in EVERY task (A1–C4), is registered **flat** in `DAEE38451E3DBEB100DD2966 /* Maccy */` with `path = Plugins/<File>.swift`. Wherever a task says a `Plugins` group “was created in A1”/“by B1–B4” or uses a bare `path = <File>.swift` for a `Plugins/` file, IGNORE it — use `path = Plugins/<File>.swift` and add the fileRef to the `Maccy` group. (Test files are the only exception: they sit in the MaccyTests group with `path = <File>.swift`.)
- **Defaults keys:** declare as `static let foo = Key<T>("foo", default: …)` in `extension Defaults.Keys` (file `Maccy/Extensions/Defaults.Keys+Names.swift`), `T: Defaults.Serializable`. Read `Defaults[.foo]`, write `Defaults[.foo] = v`.
- **Entitlements** (`Maccy/Maccy.entitlements`) already include `com.apple.security.app-sandbox=true`, `com.apple.security.network.client=true`, `com.apple.security.cs.disable-library-validation=true`, `com.apple.security.files.user-selected.read-only=true`. **No new entitlement is needed** — JavaScriptCore needs none; network.client already present.
- **Bundle id / container:** `com.royp.MaccayActions`.
- **Distributed-notification reload:** name `"com.royp.MaccayActions.rulesChanged"` (declared `ActionsCLI.rulesChangedNotification`), posted by CLI mutations, observed in `AppDelegate` → `ActionEngine.shared.reloadRules()`.
- **macOS floor:** unchanged (do not raise the deployment target).
- **No placeholders:** every code step shows complete code; every test step shows the real test and the exact run command + expected result.

## Scope decisions (v1) — read before implementing

These bound v1 so it ships safely and fully delivers "anyone can add conditions/actions as plugins." Flagged to and accepted by the owner.

1. **Existing logic stays as NATIVE providers, not folder plugins.** `kind/regex/contains/sourceApp` (conditions) and `openURL/openInApp/webSearch/runShortcut` (actions) are **built-in** native providers. `soft-wrap`, `terminal-source`, and the six transforms (`trim/uppercase/lowercase/stripFormatting/unwrap/fixKeyboardLayout`) become **first-party** native providers (registry entries with stable plugin-style ids + descriptions/tooltips, behavior byte-for-byte preserved by calling the existing `TextUnwrap`/`KeyboardLayoutFixer`/etc.). They are no longer enum-special-cased. Re-authoring them as repo JS/declarative plugins served from the official marketplace is a **post-v1** follow-up.
2. **The declarative + JavaScript engines and the marketplace path are proven by example plugins**, not by reimplementing the existing logic: one bundled declarative example action + one bundled JS example condition, plus install-from-local-folder and install-from-GitHub flows, all under test.
3. **Capability bridges (actual network/FS execution from a plugin) are DEFERRED to v1.1.** v1 ships the full capability *UX*: manifest `capabilities` declaration, the plain-language consent sheet for capability-declaring plugins, persisted grants, and the sticky "Unverified source" badge. The bridge-less runtime is the only execution path in v1, so a capability a plugin declares is surfaced/consented but not yet functional. This honors the "allow all + warn" policy decision while keeping v1 exfiltration-proof by construction.
4. **The `maccay-plugins` GitHub repo (net-new repo + first push) is gated** on explicit owner approval (Milestone D) per repo-creation rules.
5. **Migration is a hard cut via a new Defaults key.** The rule store moves from key `"actionRules"` to `"actionRulesV3"` with new-shape presets; old data is abandoned (no users). No back-compat decoder.

## Known v1 limitations (deferred by design — not gaps)

The plan deliberately does NOT implement these in v1; they are listed so they are not mistaken for omissions:
- **Capability bridges are not executable in v1** (scope decision #3): network/FS capabilities are declared, consented, and badged, but the bridge-less JS runtime cannot yet perform network/FS. A declared capability is surfaced and consented, not functional.
- **Marketplace refresh niceties (C1/C2):** v1 fetches `marketplace.json` directly. Web→`raw.githubusercontent.com` URL rewrite, ETag/`If-None-Match`/304 caching, the 24h refresh cadence + ⌘R wiring, and a persisted offline index are deferred to v1.x; refresh re-fetches unconditionally.
- **Integrity = `plugin.json` sha256 (C1):** v1 is NO-UNZIP (per-file fetch) and verifies the `plugin.json` bytes against the entry `sha256`. Full plugin-tree hashing and a signed revocation list are deferred.
- **Install atomicity (C1):** v1 writes into `dir/<id>/`; the “keep old version until new validates” swap + rollback is deferred to v1.x.
- **JS watchdog `.timedOut` (B3):** maps the JSC termination exception by message substring; a callback-flag approach is the v1.x hardening.
- **Trojan-update re-consent (C3):** v1 re-prompts when a plugin declares a NEW capability; an explicit capability-diff + `revokeAll`-on-version-change step is deferred.

## File structure

**New (`Maccy/Plugins/`):**
- `PluginCore.swift` — value types + protocols: `JSONValue`, `PluginInput`, `ActionOutcome`, `Capability`, `ProviderKind`, `ProviderEngine`, `ProviderSource`, `ParamKind`, `ParamSpec`, `ProviderDescriptor`, `protocol ConditionProvider`, `protocol ActionProvider`. The shared vocabulary every other file consumes.
- `ProviderRegistry.swift` — `@MainActor final class ProviderRegistry`: register/lookup/descriptors/remove-by-source. The single dispatch table.
- `BuiltinProviders.swift` — native condition providers (`builtin.kind/regex/contains/sourceApp`) + native action providers (`builtin.openURL/openInApp/webSearch/runShortcut`). Ports the deleted `ClipboardAction` conformers' logic.
- `FirstPartyProviders.swift` — native first-party providers: conditions `com.maccay.soft-wrap`, `com.maccay.terminal-source`; actions `com.maccay.trim/uppercase/lowercase/strip-formatting/unwrap/fix-keyboard-layout`. Wrap `TextUnwrap`/`KeyboardLayoutFixer`/`Defaults[.terminalAppBundleIDs]`.
- `PluginManifest.swift` — `struct PluginManifest: Codable` + `validate()`; parses `plugin.json`.
- `DeclarativeEngine.swift` — `DeclarativeConditionProvider` / `DeclarativeActionProvider` built from a manifest; transform-op list + predicate-tree interpreter.
- `JSPluginRuntime.swift` — `JSPluginRuntime` (bridge-less `JSContext` + `JSContextGroupSetExecutionTimeLimit` watchdog) + `JSConditionProvider`/`JSActionProvider`.
- `PluginLoader.swift` — scans bundled dir + Application Support + local-folder marketplaces, parses manifests, builds providers via the engines, registers them; called at boot and on reload.
- `Marketplace.swift` — `struct Marketplace`/`MarketplaceEntry`/`PluginSource` Codable models + `MarketplaceResolver` (download + `sha256` verify + extract).
- `MarketplaceStore.swift` — `@MainActor final class MarketplaceStore`: registered marketplaces (Defaults), refresh, install/update/remove, local-folder marketplaces, atomic update.
- `CapabilityManager.swift` — `@MainActor final class CapabilityManager`: persisted grants, `needsConsent(pluginID:declared:)`, `grant(_:pluginID:)`, source-trust helpers.

**New (`Maccy/Settings/`):**
- `PluginsSettingsPane.swift` — marketplace browse/refresh/install/remove, add marketplace URL, add local folders, capability consent sheet, unverified badge.

**New (`Maccy/Resources/BundledPlugins/`):** `example-base64/plugin.json` (declarative action), `example-reverse/plugin.json` + `main.js` (JS condition). Copied into the app bundle as a folder reference (resource).

**Modified:**
- `Maccy/Actions/ActionRule.swift` — replace `RuleCondition` enum, `ActionType`, `TransformKind`, `ActionConfig` fields with `{provider, params}` structs; add `schemaVersion`; rewrite `presets`; delete `WebSearchTemplate`? (keep — referenced by built-in webSearch default).
- `Maccy/Actions/ActionEngine.swift` — `actionRules` key → `actionRulesV3`; `matches()`/`handleNewCopy()`/`run()`/`registerShortcuts()` to use the registry; register built-ins + first-party + load plugins at init; route `.replace` outcomes through `noteAutoOutput`.
- `Maccy/Actions/ClipboardAction.swift` — delete the `ClipboardAction` protocol conformers + `ActionFactory` (logic moves to providers); keep `ActionError` + `makeURL` helper (move to `BuiltinProviders.swift` if needed).
- `Maccy/Actions/ActionsCLI.swift` — `rulesDescribe()` emits `ProviderRegistry.descriptors()`; `decodeRule` overlay updated for the new schema.
- `Maccy/Settings/ActionsSettingsPane.swift` — provider pickers from `ProviderRegistry.descriptors(kind:)`, `.help(descriptor.description)` tooltips, ⓘ longHelp, descriptor-driven param editors (`ParamSpec`).
- `Maccy/Extensions/Defaults.Keys+Names.swift` — new keys: `installedMarketplaces`, `localMarketplaceFolders`, `pluginCapabilityGrants`.

**New (separate repo, Milestone D, gated):** `maccay-plugins` — `marketplace.json`, example plugins, `CONTRIBUTING.md`, CI.

## Interface Contract (canonical — every task uses these signatures verbatim)

`PluginCore.swift`:
```swift
import Foundation

enum JSONValue: Codable, Hashable {
  case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
  // Codable: singleValueContainer; try Bool, then Double, then String, then [JSONValue], then [String:JSONValue], else null/throw.
  var stringValue: String? { get }
  var doubleValue: Double? { get }
  var intValue: Int? { get }
  var boolValue: Bool? { get }
  var arrayValue: [JSONValue]? { get }
  var objectValue: [String: JSONValue]? { get }
  subscript(_ key: String) -> JSONValue? { get }   // object member or nil
  static var emptyObject: JSONValue { .object([:]) }
}

struct PluginInput {
  let string: String
  let kinds: Set<ValueKind>
  let sourceAppBundleID: String?
  let fileURLs: [URL]
}

enum ActionOutcome: Equatable { case replace(String), sideEffect, none }

enum Capability: String, Codable, Hashable, CaseIterable {
  case network, fileRead, fileWrite, storage
  var label: String { get }
  var consentSentence: String { get }   // plain-language, e.g. "send the text you run it on — which may include passwords — over the network"
}

enum ProviderKind: String, Codable, Hashable { case condition, action }
enum ProviderEngine: String, Codable, Hashable { case native, declarative, javascript }

enum ProviderSource: Codable, Hashable {
  case builtin, bundled
  case marketplace(String)   // marketplace id
  case local(String)         // folder path
  var isVerified: Bool { get }   // builtin/bundled => true; marketplace("maccay-official") => true; else false
}

enum ParamKind: String, Codable, Hashable { case text, valueKind, bundleID }
struct ParamSpec: Codable, Hashable, Identifiable {
  var id: String { key }
  let key: String
  let label: String
  let kind: ParamKind
  let placeholder: String?
}

struct ProviderDescriptor: Identifiable, Hashable {
  let id: String
  let name: String
  let description: String         // <= 120 chars; the GUI tooltip
  let longHelp: String?
  let kind: ProviderKind
  let engine: ProviderEngine
  let params: [ParamSpec]
  let capabilities: [Capability]
  let source: ProviderSource
  var isVerified: Bool { source.isVerified }
}

@MainActor protocol ConditionProvider {
  var descriptor: ProviderDescriptor { get }
  func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool
}
@MainActor protocol ActionProvider {
  var descriptor: ProviderDescriptor { get }
  func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome
}
```

`ProviderRegistry.swift`:
```swift
@MainActor final class ProviderRegistry {
  static let shared = ProviderRegistry()
  func register(condition: ConditionProvider)
  func register(action: ActionProvider)
  func condition(_ id: String) -> ConditionProvider?
  func action(_ id: String) -> ActionProvider?
  func descriptors(kind: ProviderKind? = nil) -> [ProviderDescriptor]   // sorted by name
  func removeAll(where predicate: (ProviderSource) -> Bool)             // for reload of folder plugins
  func reset()                                                          // tests only
}
```

New rule schema in `ActionRule.swift`:
```swift
struct RuleCondition: Codable, Identifiable, Hashable {
  var id: UUID = UUID()
  var provider: String                  // e.g. "builtin.regex"
  var params: JSONValue = .object([:])
}
struct ActionConfig: Codable, Identifiable, Hashable {
  var id: UUID = UUID()
  var provider: String                  // e.g. "builtin.openURL", "com.maccay.unwrap"
  var params: JSONValue = .object([:])
  var shortcut: String?                 // unchanged per-action shortcut grammar
}
struct ActionRule: Codable, Identifiable, Hashable, Defaults.Serializable {
  var id: UUID = UUID()
  var schemaVersion: Int = 3
  var name: String = "New rule"
  var enabled: Bool = true
  var matchMode: MatchMode = .all
  var conditions: [RuleCondition] = []
  var actions: [ActionConfig] = []
  var autoRunDefault: Bool = false
  static let presets: [ActionRule]      // provider-id form (see Task A3)
}
// MatchMode unchanged. ValueKind unchanged. WebSearchTemplate.google kept.
```

Canonical provider ids:
- Conditions: `builtin.kind`, `builtin.regex`, `builtin.contains`, `builtin.sourceApp`, `com.maccay.soft-wrap`, `com.maccay.terminal-source`.
- Actions: `builtin.openURL`, `builtin.openInApp`, `builtin.webSearch`, `builtin.runShortcut`, `com.maccay.trim`, `com.maccay.uppercase`, `com.maccay.lowercase`, `com.maccay.strip-formatting`, `com.maccay.unwrap`, `com.maccay.fix-keyboard-layout`.

`PluginManifest.swift`:
```swift
struct PluginManifest: Codable, Hashable {
  let id: String
  let name: String
  let version: String
  let author: Author?           // struct Author: Codable, Hashable { let name: String; let url: String? }
  let description: String        // required, <= 120
  let longHelp: String?
  let kind: ProviderKind
  let engine: ProviderEngine     // .declarative or .javascript (never .native/.builtin in a manifest)
  let params: [ParamSpec]?
  let entry: String?             // required iff engine == .javascript
  let capabilities: [Capability]?
  let minAppVersion: String?
  let declarative: JSONValue?    // the declarative spec (transform ops / predicate tree), iff engine == .declarative
  func validate() throws         // throws PluginManifestError on missing/contradictory fields
  func descriptor(source: ProviderSource) -> ProviderDescriptor
}
enum PluginManifestError: Error, Equatable { case missingField(String), badEngineEntry, descriptionTooLong }
```

`DeclarativeEngine.swift`:
```swift
struct DeclarativeActionProvider: ActionProvider {       // built from manifest.declarative
  let descriptor: ProviderDescriptor
  let spec: JSONValue                                    // { "transform": [ {op...}, ... ] }
  func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome  // returns .replace(transformed)
}
struct DeclarativeConditionProvider: ConditionProvider {  // built from manifest.declarative
  let descriptor: ProviderDescriptor
  let spec: JSONValue                                    // { "predicate": <tree> }
  func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool
}
enum DeclarativeError: Error, Equatable { case unknownOp(String), badSpec }
// transform ops: {"op":"regexReplace","pattern":...,"replacement":...}, {"op":"case","value":"upper"|"lower"}, {"op":"trim"}, {"op":"prepend"/"append","text":...}
// predicate leaves: {"regex":...}, {"contains":...}, {"kind":...}, {"sourceApp":...}; nodes: {"all":[...]}, {"any":[...]}, {"not":{...}}
```

`JSPluginRuntime.swift`:
```swift
final class JSPluginRuntime {                            // not @MainActor; pure compute
  init(script: String, timeLimitSeconds: Double = 0.25) throws
  func callTransform(_ input: String) throws -> String   // calls global transform(input)
  func callMatches(_ input: String) throws -> Bool       // calls global matches(input)
}
enum JSPluginError: Error, Equatable { case compileFailed(String), missingEntry(String), timedOut, wrongReturnType, threw(String) }
@MainActor struct JSConditionProvider: ConditionProvider { let descriptor: ProviderDescriptor; let runtime: JSPluginRuntime; func evaluate(...) throws -> Bool }
@MainActor struct JSActionProvider: ActionProvider { let descriptor: ProviderDescriptor; let runtime: JSPluginRuntime; func run(...) async throws -> ActionOutcome }
```

`PluginLoader.swift`:
```swift
@MainActor enum PluginLoader {
  static func bundledPluginsURL() -> URL?                              // Bundle.main BundledPlugins dir
  static func installedPluginsURL() -> URL                             // ~/Library/Application Support/Maccay/Plugins
  static func loadAll(into registry: ProviderRegistry, extraFolders: [URL])  // scan + register; removes prior folder-loaded first
  static func loadPlugin(at folder: URL, source: ProviderSource) throws -> [ProviderDescriptor]  // parse + build + register
}
```

`Marketplace.swift`:
```swift
struct Marketplace: Codable, Hashable, Identifiable { let id: String; let name: String; let version: String; let description: String?; let maintainer: String?; let plugins: [MarketplaceEntry] }
struct MarketplaceEntry: Codable, Hashable, Identifiable { let id: String; let name: String; let description: String; let version: String; let minAppVersion: String?; let kind: ProviderKind; let tags: [String]?; let capabilities: [Capability]?; let source: PluginSource; let sha256: String }
enum PluginSource: Codable, Hashable { case github(repo: String, ref: String, path: String?), url(String) }
enum MarketplaceError: Error, Equatable { case badIndex, checksumMismatch, unsupportedSource, httpError(Int) }
@MainActor enum MarketplaceResolver {
  static func fetchIndex(_ marketplaceURL: URL) async throws -> Marketplace
  static func download(_ entry: MarketplaceEntry) async throws -> Data        // verifies sha256, throws checksumMismatch
  static func install(_ entry: MarketplaceEntry, marketplaceID: String, into dir: URL) async throws -> URL  // extracts, returns folder
}
```

`MarketplaceStore.swift`:
```swift
@MainActor final class MarketplaceStore {
  static let shared = MarketplaceStore()
  func registeredMarketplaceURLs() -> [URL]            // Defaults[.installedMarketplaces], official prepended
  func addMarketplace(_ url: URL) async throws -> Marketplace
  func removeMarketplace(id: String)
  func refreshAll() async
  func install(_ entry: MarketplaceEntry, marketplaceID: String) async throws
  func remove(pluginID: String)
  func localFolders() -> [URL]                         // Defaults[.localMarketplaceFolders]
  func addLocalFolder(_ url: URL)
}
```

`CapabilityManager.swift`:
```swift
@MainActor final class CapabilityManager {
  static let shared = CapabilityManager()
  func needsConsent(pluginID: String, declared: [Capability]) -> Bool   // true if any declared capability not yet granted
  func grantedCapabilities(pluginID: String) -> [Capability]
  func grant(_ caps: [Capability], pluginID: String)
  func revokeAll(pluginID: String)
  func isUnverified(_ source: ProviderSource) -> Bool                   // !source.isVerified
}
```

New Defaults keys (`Defaults.Keys+Names.swift`):
```swift
static let installedMarketplaces    = Key<[String]>("installedMarketplaces", default: [])
static let localMarketplaceFolders  = Key<[String]>("localMarketplaceFolders", default: [])
static let pluginCapabilityGrants   = Key<[String: [Capability]]>("pluginCapabilityGrants", default: [:])
```

---

## Milestones & task list

**Milestone A — Registry core + behavior-preserving refactor.** A1–A4 are additive (compile alongside the existing enums). A5 is the **atomic swap**: it deletes the old enums/switches and rewires the schema, engine, CLI, and GUI together (they reference each other's old symbols, so the codebase cannot compile half-swapped — this lands as one reviewable unit). After A5 the app behaves exactly as today, but every condition/action flows through the registry and shows a description tooltip.
- A1: PluginCore — value types + protocols (additive)
- A2: ProviderRegistry (additive)
- A3: BuiltinProviders — native `kind/regex/contains/sourceApp` conditions + `openURL/openInApp/webSearch/runShortcut` actions (additive, ports the to-be-deleted `ClipboardAction` logic)
- A4: FirstPartyProviders — native `soft-wrap`, `terminal-source` conditions + the six transform actions (additive)
- A5: **The atomic swap** — rewrite `ActionRule` schema (`{provider, params}` + `schemaVersion`, new presets), rename Defaults key `actionRules` → `actionRulesV3`, refactor `ActionEngine` (registry dispatch + register A3/A4 providers at boot + route `.replace` through `noteAutoOutput`), delete the `ClipboardAction` conformers + `ActionFactory`, update `ActionsCLI` (`describe` from registry + overlay), rewrite `ActionsSettingsPane` (registry-driven pickers + `.help()` tooltips + ⓘ longHelp + `ParamSpec` editors). One build+test checkpoint at the end.

**Milestone B — Plugin loading + engines.** After B5 the app loads folder plugins (declarative + JS) at boot.
- B1: PluginManifest + validation
- B2: DeclarativeEngine
- B3: JSPluginRuntime (bridge-less + watchdog)
- B4: PluginLoader
- B5: Bundled example plugins + boot-time load

**Milestone C — Marketplaces + Plugins GUI + capability UX.** After C4 the user can add marketplaces/local folders and install/remove plugins, with capability consent + unverified badge.
- C1: Marketplace models + resolver (download + sha256 verify + extract)
- C2: MarketplaceStore (register/refresh/install/remove/local folders)
- C3: CapabilityManager (grants + consent + unverified)
- C4: PluginsSettingsPane (GUI)

**Milestone D — Official marketplace repo (GATED on approval).**
- D1: `maccay-plugins` repo scaffold (marketplace.json, example plugins, CONTRIBUTING, CI)

---

## Milestone A — Registry core + behavior-preserving refactor

### Task A1: PluginCore — value types + protocols

**Files:**

- **Create:** `Maccy/Plugins/PluginCore.swift`
- **Create:** `MaccyTests/PluginCoreTests.swift`
- **Modify:** `Maccy.xcodeproj/project.pbxproj` (4 entries for each new file = 8 total edits)

---

**Interfaces:**

**Consumes:** Nothing from prior tasks (this is the foundation).

**Produces** (exact signatures — every later task imports these verbatim):

```swift
// JSONValue
enum JSONValue: Codable, Hashable {
  case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
  var stringValue: String? { get }
  var doubleValue: Double? { get }
  var intValue: Int? { get }
  var boolValue: Bool? { get }
  var arrayValue: [JSONValue]? { get }
  var objectValue: [String: JSONValue]? { get }
  subscript(_ key: String) -> JSONValue? { get }
  static var emptyObject: JSONValue { .object([:]) }
}

// PluginInput
struct PluginInput {
  let string: String
  let kinds: Set<ValueKind>
  let sourceAppBundleID: String?
  let fileURLs: [URL]
}

// ActionOutcome
enum ActionOutcome: Equatable { case replace(String), sideEffect, none }

// Capability
enum Capability: String, Codable, Hashable, CaseIterable {
  case network, fileRead, fileWrite, storage
  var label: String { get }
  var consentSentence: String { get }
}

// ProviderKind / ProviderEngine
enum ProviderKind: String, Codable, Hashable { case condition, action }
enum ProviderEngine: String, Codable, Hashable { case native, declarative, javascript }

// ProviderSource
enum ProviderSource: Codable, Hashable {
  case builtin, bundled
  case marketplace(String)
  case local(String)
  var isVerified: Bool { get }
}

// ParamKind / ParamSpec
enum ParamKind: String, Codable, Hashable { case text, valueKind, bundleID }
struct ParamSpec: Codable, Hashable, Identifiable {
  var id: String { key }
  let key: String; let label: String; let kind: ParamKind; let placeholder: String?
}

// ProviderDescriptor
struct ProviderDescriptor: Identifiable, Hashable {
  let id: String; let name: String; let description: String; let longHelp: String?
  let kind: ProviderKind; let engine: ProviderEngine; let params: [ParamSpec]
  let capabilities: [Capability]; let source: ProviderSource
  var isVerified: Bool { source.isVerified }
}

// Protocols
@MainActor protocol ConditionProvider {
  var descriptor: ProviderDescriptor { get }
  func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool
}
@MainActor protocol ActionProvider {
  var descriptor: ProviderDescriptor { get }
  func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome
}
```

---

- [ ] **Step 1: Write the failing test**

  Create `MaccyTests/PluginCoreTests.swift` with the full test suite. The file references `PluginCore.swift` types that do not yet exist, so it will not compile — the build fails at the compile step (expected).

  ```swift
  import XCTest
  @testable import Maccy

  final class PluginCoreTests: XCTestCase {

    // MARK: - JSONValue round-trip

    func testJSONValueRoundTrip() throws {
      let original = JSONValue.object([
        "a": .number(1),
        "b": .array([.bool(true), .null, .string("x")])
      ])
      let data = try JSONEncoder().encode(original)
      let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
      XCTAssertEqual(decoded, original)
    }

    func testJSONValueSubscriptAndAccessors() throws {
      let v = JSONValue.object([
        "count": .number(42),
        "name": .string("hello"),
        "flag": .bool(true)
      ])
      XCTAssertEqual(v["count"]?.intValue, 42)
      XCTAssertEqual(v["name"]?.stringValue, "hello")
      XCTAssertEqual(v["flag"]?.boolValue, true)
      XCTAssertNil(v["missing"])
    }

    // MARK: - ProviderSource.isVerified truth table

    func testProviderSourceIsVerified() {
      XCTAssertTrue(ProviderSource.builtin.isVerified)
      XCTAssertTrue(ProviderSource.bundled.isVerified)
      XCTAssertTrue(ProviderSource.marketplace("maccay-official").isVerified)
      XCTAssertFalse(ProviderSource.marketplace("some-other-marketplace").isVerified)
      XCTAssertFalse(ProviderSource.local("/Users/alice/plugins/myplugin").isVerified)
    }

    // MARK: - ProviderSource Codable round-trip

    func testProviderSourceCodableBuiltin() throws {
      let v = ProviderSource.builtin
      let data = try JSONEncoder().encode(v)
      let decoded = try JSONDecoder().decode(ProviderSource.self, from: data)
      XCTAssertEqual(decoded, v)
    }

    func testProviderSourceCodableBundled() throws {
      let v = ProviderSource.bundled
      let data = try JSONEncoder().encode(v)
      let decoded = try JSONDecoder().decode(ProviderSource.self, from: data)
      XCTAssertEqual(decoded, v)
    }

    func testProviderSourceCodableMarketplace() throws {
      let v = ProviderSource.marketplace("maccay-official")
      let data = try JSONEncoder().encode(v)
      let decoded = try JSONDecoder().decode(ProviderSource.self, from: data)
      XCTAssertEqual(decoded, v)
    }

    func testProviderSourceCodableLocal() throws {
      let v = ProviderSource.local("/tmp/my-plugin")
      let data = try JSONEncoder().encode(v)
      let decoded = try JSONDecoder().decode(ProviderSource.self, from: data)
      XCTAssertEqual(decoded, v)
    }

    func testProviderSourceCodableMarketplaceOther() throws {
      let v = ProviderSource.marketplace("community-plugins")
      let data = try JSONEncoder().encode(v)
      let decoded = try JSONDecoder().decode(ProviderSource.self, from: data)
      XCTAssertEqual(decoded, v)
    }

    // MARK: - Capability.consentSentence non-empty + network mentions passwords

    func testCapabilityConsentSentenceNonEmpty() {
      for cap in Capability.allCases {
        XCTAssertFalse(cap.consentSentence.isEmpty, "\(cap.rawValue) has empty consentSentence")
      }
    }

    func testNetworkConsentSentenceMentionsPasswords() {
      XCTAssertTrue(
        Capability.network.consentSentence.localizedCaseInsensitiveContains("password"),
        "network consentSentence must mention passwords"
      )
    }
  }
  ```

- [ ] **Step 2: Register `PluginCoreTests.swift` in pbxproj (test target)**

  UUIDs for `PluginCoreTests.swift`: `fileRef = C43CD5C68E3E406A939194C9`, `buildFile = A6D548C968484249B1F46D2D`.

  **(2a) Add PBXBuildFile** — insert into the `PBXBuildFile` section:
  ```
  		A6D548C968484249B1F46D2D /* PluginCoreTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = C43CD5C68E3E406A939194C9 /* PluginCoreTests.swift */; };
  ```

  **(2b) Add PBXFileReference** — insert into the `PBXFileReference` section:
  ```
  		C43CD5C68E3E406A939194C9 /* PluginCoreTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MaccyTests/PluginCoreTests.swift; sourceTree = "<group>"; };
  ```

  **(2c) Add to MaccyTests PBXGroup children** — the group ending with `path = MaccyTests;` at line 753:
  ```
  				C43CD5C68E3E406A939194C9 /* PluginCoreTests.swift */,
  ```
  (Insert alongside the other test files, e.g. after `AA01C0DE00000000000000B1 /* KeyboardLayoutTests.swift */`.)

  **(2d) Add to `DA360DAC1E3DF137005C6F6B /* Sources */` build phase files**:
  ```
  				A6D548C968484249B1F46D2D /* PluginCoreTests.swift in Sources */,
  ```

- [ ] **Step 3: Run tests — expect FAIL (compile error)**

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests/PluginCoreTests
  ```

  **Expected: FAIL** — the build fails with "cannot find type 'JSONValue' in scope" (and similar errors for `ProviderSource`, `Capability`, etc.) because `PluginCore.swift` does not exist yet.

- [ ] **Step 4: Write the implementation**

  Create `Maccy/Plugins/PluginCore.swift`:

  ```swift
  import Foundation

  // MARK: - JSONValue

  enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
      let c = try decoder.singleValueContainer()
      if let b = try? c.decode(Bool.self) {
        self = .bool(b)
      } else if let d = try? c.decode(Double.self) {
        self = .number(d)
      } else if let s = try? c.decode(String.self) {
        self = .string(s)
      } else if let a = try? c.decode([JSONValue].self) {
        self = .array(a)
      } else if let o = try? c.decode([String: JSONValue].self) {
        self = .object(o)
      } else if c.decodeNil() {
        self = .null
      } else {
        throw DecodingError.dataCorruptedError(
          in: c, debugDescription: "Cannot decode JSONValue"
        )
      }
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.singleValueContainer()
      switch self {
      case .string(let s): try c.encode(s)
      case .number(let d): try c.encode(d)
      case .bool(let b):   try c.encode(b)
      case .array(let a):  try c.encode(a)
      case .object(let o): try c.encode(o)
      case .null:          try c.encodeNil()
      }
    }

    var stringValue: String? {
      if case .string(let s) = self { return s }
      return nil
    }

    var doubleValue: Double? {
      if case .number(let d) = self { return d }
      return nil
    }

    var intValue: Int? {
      if case .number(let d) = self { return Int(exactly: d) ?? Int(d) }
      return nil
    }

    var boolValue: Bool? {
      if case .bool(let b) = self { return b }
      return nil
    }

    var arrayValue: [JSONValue]? {
      if case .array(let a) = self { return a }
      return nil
    }

    var objectValue: [String: JSONValue]? {
      if case .object(let o) = self { return o }
      return nil
    }

    subscript(_ key: String) -> JSONValue? {
      objectValue?[key]
    }

    static var emptyObject: JSONValue { .object([:]) }
  }

  // MARK: - PluginInput

  struct PluginInput {
    let string: String
    let kinds: Set<ValueKind>
    let sourceAppBundleID: String?
    let fileURLs: [URL]
  }

  // MARK: - ActionOutcome

  enum ActionOutcome: Equatable {
    case replace(String)
    case sideEffect
    case none
  }

  // MARK: - Capability

  enum Capability: String, Codable, Hashable, CaseIterable {
    case network
    case fileRead
    case fileWrite
    case storage

    var label: String {
      switch self {
      case .network:   return "Network access"
      case .fileRead:  return "File read"
      case .fileWrite: return "File write"
      case .storage:   return "Local storage"
      }
    }

    var consentSentence: String {
      switch self {
      case .network:
        return "Send the text you run it on — which may include passwords — over the network."
      case .fileRead:
        return "Read files from your Mac."
      case .fileWrite:
        return "Write or modify files on your Mac."
      case .storage:
        return "Store data persistently on your Mac."
      }
    }
  }

  // MARK: - ProviderKind / ProviderEngine

  enum ProviderKind: String, Codable, Hashable {
    case condition
    case action
  }

  enum ProviderEngine: String, Codable, Hashable {
    case native
    case declarative
    case javascript
  }

  // MARK: - ProviderSource

  enum ProviderSource: Codable, Hashable {
    case builtin
    case bundled
    case marketplace(String)
    case local(String)

    var isVerified: Bool {
      switch self {
      case .builtin, .bundled:                    return true
      case .marketplace(let id):                  return id == "maccay-official"
      case .local:                                return false
      }
    }

    // MARK: Custom Codable using a "type" tag + payload

    private enum CodingKeys: String, CodingKey { case type, payload }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      let type = try c.decode(String.self, forKey: .type)
      switch type {
      case "builtin":
        self = .builtin
      case "bundled":
        self = .bundled
      case "marketplace":
        let payload = try c.decode(String.self, forKey: .payload)
        self = .marketplace(payload)
      case "local":
        let payload = try c.decode(String.self, forKey: .payload)
        self = .local(payload)
      default:
        throw DecodingError.dataCorruptedError(
          forKey: .type, in: c, debugDescription: "Unknown ProviderSource type: \(type)"
        )
      }
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case .builtin:
        try c.encode("builtin", forKey: .type)
      case .bundled:
        try c.encode("bundled", forKey: .type)
      case .marketplace(let id):
        try c.encode("marketplace", forKey: .type)
        try c.encode(id, forKey: .payload)
      case .local(let path):
        try c.encode("local", forKey: .type)
        try c.encode(path, forKey: .payload)
      }
    }
  }

  // MARK: - ParamKind / ParamSpec

  enum ParamKind: String, Codable, Hashable {
    case text
    case valueKind
    case bundleID
  }

  struct ParamSpec: Codable, Hashable, Identifiable {
    var id: String { key }
    let key: String
    let label: String
    let kind: ParamKind
    let placeholder: String?
  }

  // MARK: - ProviderDescriptor

  struct ProviderDescriptor: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let longHelp: String?
    let kind: ProviderKind
    let engine: ProviderEngine
    let params: [ParamSpec]
    let capabilities: [Capability]
    let source: ProviderSource

    var isVerified: Bool { source.isVerified }
  }

  // MARK: - Protocols

  @MainActor protocol ConditionProvider {
    var descriptor: ProviderDescriptor { get }
    func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool
  }

  @MainActor protocol ActionProvider {
    var descriptor: ProviderDescriptor { get }
    func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome
  }
  ```

- [ ] **Step 5: Register `PluginCore.swift` in pbxproj (app target)**

  UUIDs for `PluginCore.swift`: `fileRef = B515E7DB85154CC686EA5A41`, `buildFile = 39319FD858DF488DB233958E`.

  **(5a) Add PBXBuildFile** — insert into the `PBXBuildFile` section:
  ```
  		39319FD858DF488DB233958E /* PluginCore.swift in Sources */ = {isa = PBXBuildFile; fileRef = B515E7DB85154CC686EA5A41 /* PluginCore.swift */; };
  ```

  **(5b) Add PBXFileReference** — insert into the `PBXFileReference` section:
  ```
  		B515E7DB85154CC686EA5A41 /* PluginCore.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Plugins/PluginCore.swift; sourceTree = "<group>"; };
  ```

  **(5c) Add to `DAEE38451E3DBEB100DD2966 /* Maccy */` PBXGroup children**:
  ```
  			B515E7DB85154CC686EA5A41 /* PluginCore.swift */,
  ```
  (Insert anywhere in the children array of the Maccy group, e.g. alongside other `Actions/` and `Extensions/` entries.)

  **(5d) Add to `DAEE383F1E3DBEB100DD2966 /* Sources */` build phase files**:
  ```
  				39319FD858DF488DB233958E /* PluginCore.swift in Sources */,
  ```

  > **Note:** `Maccy/Plugins/` is a new subfolder. The plan specifies (Global Constraints) that for a file under `Maccy/Plugins/` the subfolder is encoded in the `path` field of the PBXFileReference (`path = Plugins/PluginCore.swift`), and the file is placed **flat in the `DAEE38451E3DBEB100DD2966 /* Maccy */` group** — no new nested PBXGroup is required for a single file. All later `Plugins/` files use this same flat pattern (subfolder in `path`, fileRef in the `Maccy` group) — no nested `Plugins` group is ever created.

- [ ] **Step 6: Run tests — expect PASS**

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests/PluginCoreTests
  ```

  **Expected: PASS** — all 9 test methods pass.

- [ ] **Step 7: Run the full unit suite to confirm no regressions**

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests
  ```

  **Expected: PASS** — all existing tests continue to pass; `PluginCoreTests` adds 9 new passing tests.

- [ ] **Step 8: Commit**

  ```sh
  git add \
    Maccy/Plugins/PluginCore.swift \
    MaccyTests/PluginCoreTests.swift \
    Maccy.xcodeproj/project.pbxproj && \
  git commit -m "feat(plugins): add PluginCore value types + protocols (Task A1)"
  ```

---

### Task A2: ProviderRegistry

**Files:**
- Create: `Maccy/Plugins/ProviderRegistry.swift`
- Create: `MaccyTests/ProviderRegistryTests.swift`
- Modify: `Maccy.xcodeproj/project.pbxproj` (4 entries for each new file)

---

**Interfaces:**

*Consumes (from A1 — `PluginCore.swift`):*
```swift
@MainActor protocol ConditionProvider { var descriptor: ProviderDescriptor { get }; func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool }
@MainActor protocol ActionProvider { var descriptor: ProviderDescriptor { get }; func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome }
struct ProviderDescriptor: Identifiable, Hashable { let id: String; let name: String; let kind: ProviderKind; let source: ProviderSource }
enum ProviderKind: String, Codable, Hashable { case condition, action }
enum ProviderSource: Codable, Hashable { case builtin, bundled; case marketplace(String); case local(String) }
```

*Produces (what A3, A4, A5, PluginLoader, and tests rely on — exact contract signatures):*
```swift
@MainActor final class ProviderRegistry {
    static let shared = ProviderRegistry()
    func register(condition: ConditionProvider)
    func register(action: ActionProvider)
    func condition(_ id: String) -> ConditionProvider?
    func action(_ id: String) -> ActionProvider?
    func descriptors(kind: ProviderKind? = nil) -> [ProviderDescriptor]   // sorted by name
    func removeAll(where predicate: (ProviderSource) -> Bool)
    func reset()
}
```

---

- [ ] **Step 1: Write the failing test**

  Create `MaccyTests/ProviderRegistryTests.swift` with the full test suite. All tests will fail because `ProviderRegistry` does not exist yet.

  ```swift
  import XCTest
  @testable import Maccy

  // MARK: - Stubs

  private final class StubConditionBuiltin: ConditionProvider {
      let descriptor: ProviderDescriptor
      init() {
          descriptor = ProviderDescriptor(
              id: "stub.condition.builtin", name: "Stub Condition Builtin",
              description: "A stub builtin condition for tests", longHelp: nil,
              kind: .condition, engine: .native, params: [], capabilities: [], source: .builtin
          )
      }
      func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool { return true }
  }

  private final class StubConditionLocal: ConditionProvider {
      let descriptor: ProviderDescriptor
      init() {
          descriptor = ProviderDescriptor(
              id: "stub.condition.local", name: "Stub Condition Local",
              description: "A stub local condition for tests", longHelp: nil,
              kind: .condition, engine: .native, params: [], capabilities: [],
              source: .local("/tmp/stub-plugin")
          )
      }
      func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool { return false }
  }

  private final class StubActionBuiltin: ActionProvider {
      let descriptor: ProviderDescriptor
      init() {
          descriptor = ProviderDescriptor(
              id: "stub.action.builtin", name: "Stub Action Builtin",
              description: "A stub builtin action for tests", longHelp: nil,
              kind: .action, engine: .native, params: [], capabilities: [], source: .builtin
          )
      }
      func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome { return .none }
  }

  // MARK: - Tests

  @MainActor
  final class ProviderRegistryTests: XCTestCase {
      private var registry: ProviderRegistry!

      override func setUp() {
          super.setUp()
          registry = ProviderRegistry()
          registry.reset()
      }

      override func tearDown() {
          registry.reset()
          registry = nil
          super.tearDown()
      }

      func testRegisterAndLookupCondition() {
          registry.register(condition: StubConditionBuiltin())
          let found = registry.condition("stub.condition.builtin")
          XCTAssertNotNil(found)
          XCTAssertEqual(found?.descriptor.id, "stub.condition.builtin")
      }

      func testRegisterAndLookupAction() {
          registry.register(action: StubActionBuiltin())
          let found = registry.action("stub.action.builtin")
          XCTAssertNotNil(found)
          XCTAssertEqual(found?.descriptor.id, "stub.action.builtin")
      }

      func testUnknownConditionIdReturnsNil() {
          XCTAssertNil(registry.condition("nonexistent.id"))
      }

      func testUnknownActionIdReturnsNil() {
          XCTAssertNil(registry.action("nonexistent.id"))
      }

      func testDescriptorsKindConditionReturnsOnlyConditions() {
          registry.register(condition: StubConditionBuiltin())
          registry.register(action: StubActionBuiltin())
          let result = registry.descriptors(kind: .condition)
          XCTAssertEqual(result.count, 1)
          XCTAssertEqual(result[0].id, "stub.condition.builtin")
      }

      func testDescriptorsNilKindReturnsBothSortedByName() {
          registry.register(condition: StubConditionBuiltin())
          registry.register(action: StubActionBuiltin())
          let result = registry.descriptors(kind: nil)
          XCTAssertEqual(result.count, 2)
          XCTAssertEqual(result[0].name, "Stub Action Builtin")
          XCTAssertEqual(result[1].name, "Stub Condition Builtin")
      }

      func testRemoveAllDropsLocalSourceButKeepsBuiltin() {
          registry.register(condition: StubConditionBuiltin())
          registry.register(condition: StubConditionLocal())
          registry.removeAll(where: { source in
              if case .local = source { return true } else { return false }
          })
          XCTAssertNotNil(registry.condition("stub.condition.builtin"))
          XCTAssertNil(registry.condition("stub.condition.local"))
      }

      func testResetEmptiesAllProviders() {
          registry.register(condition: StubConditionBuiltin())
          registry.register(action: StubActionBuiltin())
          registry.reset()
          XCTAssertNil(registry.condition("stub.condition.builtin"))
          XCTAssertNil(registry.action("stub.action.builtin"))
          XCTAssertTrue(registry.descriptors().isEmpty)
      }

      func testSharedSingletonExists() {
          XCTAssertNotNil(ProviderRegistry.shared)
      }
  }
  ```

- [ ] **Step 2: Register `ProviderRegistryTests.swift` in pbxproj**

  Generate two UUIDs (`<TFR>`, `<TBF>`) and make 4 edits:
  ```
  # (1) PBXBuildFile section:
  <TBF> /* ProviderRegistryTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <TFR> /* ProviderRegistryTests.swift */; };
  # (2) PBXFileReference section (test files sit in the MaccyTests group → path is the filename only):
  <TFR> /* ProviderRegistryTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProviderRegistryTests.swift; sourceTree = "<group>"; };
  # (3) add into the MaccyTests PBXGroup (path = MaccyTests;) children:
  <TFR> /* ProviderRegistryTests.swift */,
  # (4) add into the DA360DAC1E3DF137005C6F6B /* Sources */ (MaccyTests) build phase files:
  <TBF> /* ProviderRegistryTests.swift in Sources */,
  ```

- [ ] **Step 3: Run the test — expect FAIL**

- [ ] **Step 4: Write the minimal implementation**

  Create `Maccy/Plugins/ProviderRegistry.swift`:

  ```swift
  import Foundation

  @MainActor final class ProviderRegistry {
      static let shared = ProviderRegistry()

      private var conditions: [String: ConditionProvider] = [:]
      private var actions: [String: ActionProvider] = [:]

      func register(condition: ConditionProvider) { conditions[condition.descriptor.id] = condition }
      func register(action: ActionProvider) { actions[action.descriptor.id] = action }
      func condition(_ id: String) -> ConditionProvider? { conditions[id] }
      func action(_ id: String) -> ActionProvider? { actions[id] }

      func descriptors(kind: ProviderKind? = nil) -> [ProviderDescriptor] {
          let all: [ProviderDescriptor]
          switch kind {
          case .condition: all = conditions.values.map(\.descriptor)
          case .action:    all = actions.values.map(\.descriptor)
          case nil:        all = conditions.values.map(\.descriptor) + actions.values.map(\.descriptor)
          }
          return all.sorted { $0.name < $1.name }
      }

      func removeAll(where predicate: (ProviderSource) -> Bool) {
          conditions = conditions.filter { !predicate($0.value.descriptor.source) }
          actions = actions.filter { !predicate($0.value.descriptor.source) }
      }

      func reset() {
          conditions.removeAll()
          actions.removeAll()
      }
  }
  ```

- [ ] **Step 5: Register `ProviderRegistry.swift` in pbxproj (app target) — 4 entries**

  Generate two UUIDs (`<AFR>`, `<ABF>`) and make 4 edits (flat layout, per Global Constraints):
  ```
  # (1) PBXBuildFile section:
  <ABF> /* ProviderRegistry.swift in Sources */ = {isa = PBXBuildFile; fileRef = <AFR> /* ProviderRegistry.swift */; };
  # (2) PBXFileReference section:
  <AFR> /* ProviderRegistry.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Plugins/ProviderRegistry.swift; sourceTree = "<group>"; };
  # (3) add into the DAEE38451E3DBEB100DD2966 /* Maccy */ group children:
  <AFR> /* ProviderRegistry.swift */,
  # (4) add into the DAEE383F1E3DBEB100DD2966 /* Sources */ build phase files:
  <ABF> /* ProviderRegistry.swift in Sources */,
  ```

- [ ] **Step 6: Run the test — expect PASS**

- [ ] **Step 7: Run the full unit test suite — expect no regressions**

- [ ] **Step 8: Commit**

  ```sh
  git add Maccy/Plugins/ProviderRegistry.swift MaccyTests/ProviderRegistryTests.swift Maccy.xcodeproj/project.pbxproj
  git commit -m "feat(registry): add ProviderRegistry with register/lookup/descriptors/removeAll/reset"
  ```

---



### Task A3: BuiltinProviders — native conditions + launch actions

**What this task does:** Creates `Maccy/Plugins/BuiltinProviders.swift` (new file, additive — does NOT change any existing file). Registers eight native providers into `ProviderRegistry`: four condition providers (`builtin.kind`, `builtin.regex`, `builtin.contains`, `builtin.sourceApp`) and four action providers (`builtin.openURL`, `builtin.openInApp`, `builtin.webSearch`, `builtin.runShortcut`). The logic is ported verbatim from the concrete `ClipboardAction` conformers in `ClipboardAction.swift`, which remain untouched until A5. The global `makeURL(from:)` and `ActionError` in `ClipboardAction.swift` are referenced directly — they survive until A5.

**Pre-condition:** A1 (PluginCore.swift) and A2 (ProviderRegistry.swift) are committed. Per Global Constraints there is no nested `Plugins` group — register `BuiltinProviders.swift` flat in the `Maccy` group with `path = Plugins/BuiltinProviders.swift` (4-entry recipe).

---

- [ ] **Step 1: Write `MaccyTests/BuiltinProvidersTests.swift` (failing — file not in pbxproj yet, add it in Step 2)**

  Create the file at `MaccyTests/BuiltinProvidersTests.swift` (the test target folder). The tests will fail to compile until Step 4 adds `BuiltinProviders.swift`.

  ```swift
  import XCTest
  @testable import Maccy

  @MainActor
  final class BuiltinProvidersTests: XCTestCase {

    override func setUp() async throws {
      try await super.setUp()
      ProviderRegistry.shared.reset()
      BuiltinProviders.registerBuiltins(into: ProviderRegistry.shared)
    }

    // MARK: - Registry population

    func testRegisterBuiltinsPopulatesConditions() {
      let ids = ProviderRegistry.shared
        .descriptors(kind: .condition)
        .map(\.id)
      XCTAssertTrue(ids.contains("builtin.kind"))
      XCTAssertTrue(ids.contains("builtin.regex"))
      XCTAssertTrue(ids.contains("builtin.contains"))
      XCTAssertTrue(ids.contains("builtin.sourceApp"))
    }

    func testRegisterBuiltinsPopulatesActions() {
      let ids = ProviderRegistry.shared
        .descriptors(kind: .action)
        .map(\.id)
      XCTAssertTrue(ids.contains("builtin.openURL"))
      XCTAssertTrue(ids.contains("builtin.openInApp"))
      XCTAssertTrue(ids.contains("builtin.webSearch"))
      XCTAssertTrue(ids.contains("builtin.runShortcut"))
    }

    func testDescriptorsAreSortedByName() {
      let names = ProviderRegistry.shared.descriptors().map(\.name)
      XCTAssertEqual(names, names.sorted())
    }

    func testAllDescriptorsHaveNativeEngine() {
      for d in ProviderRegistry.shared.descriptors() {
        XCTAssertEqual(d.engine, .native, "Provider \(d.id) should have engine .native")
      }
    }

    func testAllDescriptorsAreBuiltinSource() {
      for d in ProviderRegistry.shared.descriptors() {
        XCTAssertEqual(d.source, .builtin, "Provider \(d.id) should have source .builtin")
      }
    }

    func testAllDescriptorsAreVerified() {
      for d in ProviderRegistry.shared.descriptors() {
        XCTAssertTrue(d.isVerified, "Provider \(d.id) should be verified")
      }
    }

    func testDescriptionsAreShorterThan121Chars() {
      for d in ProviderRegistry.shared.descriptors() {
        XCTAssertLessThanOrEqual(
          d.description.count, 120,
          "Provider \(d.id) description is \(d.description.count) chars (max 120)"
        )
      }
    }

    func testAllDescriptorsHaveEmptyCapabilities() {
      for d in ProviderRegistry.shared.descriptors() {
        XCTAssertTrue(
          d.capabilities.isEmpty,
          "Builtin provider \(d.id) should declare no capabilities"
        )
      }
    }

    // MARK: - KindCondition

    func testKindConditionDescriptor() {
      let d = ProviderRegistry.shared.condition("builtin.kind")!.descriptor
      XCTAssertEqual(d.id, "builtin.kind")
      XCTAssertEqual(d.kind, .condition)
      XCTAssertEqual(d.params.count, 1)
      XCTAssertEqual(d.params[0].key, "kind")
      XCTAssertEqual(d.params[0].kind, .valueKind)
    }

    func testKindConditionMatchesURL() throws {
      let provider = ProviderRegistry.shared.condition("builtin.kind")!
      let input = PluginInput(
        string: "https://example.com",
        kinds: [.url, .text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      let result = try provider.evaluate(input, params: .object(["kind": .string("url")]))
      XCTAssertTrue(result)
    }

    func testKindConditionNoMatchForWrongKind() throws {
      let provider = ProviderRegistry.shared.condition("builtin.kind")!
      let input = PluginInput(
        string: "hello world",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      let result = try provider.evaluate(input, params: .object(["kind": .string("url")]))
      XCTAssertFalse(result)
    }

    func testKindConditionMissingParamThrows() {
      let provider = ProviderRegistry.shared.condition("builtin.kind")!
      let input = PluginInput(
        string: "x",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      XCTAssertThrowsError(try provider.evaluate(input, params: .object([:])))
    }

    func testKindConditionUnknownKindThrows() {
      let provider = ProviderRegistry.shared.condition("builtin.kind")!
      let input = PluginInput(
        string: "x",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      XCTAssertThrowsError(
        try provider.evaluate(input, params: .object(["kind": .string("notARealKind")]))
      )
    }

    // MARK: - RegexCondition

    func testRegexConditionDescriptor() {
      let d = ProviderRegistry.shared.condition("builtin.regex")!.descriptor
      XCTAssertEqual(d.id, "builtin.regex")
      XCTAssertEqual(d.kind, .condition)
      XCTAssertEqual(d.params.count, 1)
      XCTAssertEqual(d.params[0].key, "pattern")
      XCTAssertEqual(d.params[0].kind, .text)
    }

    func testRegexConditionMatches() throws {
      let provider = ProviderRegistry.shared.condition("builtin.regex")!
      let input = PluginInput(
        string: "hello world",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      let result = try provider.evaluate(
        input,
        params: .object(["pattern": .string("^hello")])
      )
      XCTAssertTrue(result)
    }

    func testRegexConditionNoMatch() throws {
      let provider = ProviderRegistry.shared.condition("builtin.regex")!
      let input = PluginInput(
        string: "hello world",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      let result = try provider.evaluate(
        input,
        params: .object(["pattern": .string("^goodbye")])
      )
      XCTAssertFalse(result)
    }

    func testRegexConditionEmptyPatternReturnsFalse() throws {
      let provider = ProviderRegistry.shared.condition("builtin.regex")!
      let input = PluginInput(
        string: "hello",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      let result = try provider.evaluate(input, params: .object(["pattern": .string("")]))
      XCTAssertFalse(result)
    }

    func testRegexConditionInvalidPatternReturnsFalse() throws {
      let provider = ProviderRegistry.shared.condition("builtin.regex")!
      let input = PluginInput(
        string: "hello",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      // "[" is an invalid regex pattern
      let result = try provider.evaluate(input, params: .object(["pattern": .string("[")]))
      XCTAssertFalse(result)
    }

    func testRegexConditionMissingPatternReturnsFalse() throws {
      let provider = ProviderRegistry.shared.condition("builtin.regex")!
      let input = PluginInput(
        string: "hello",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      let result = try provider.evaluate(input, params: .object([:]))
      XCTAssertFalse(result)
    }

    // MARK: - ContainsCondition

    func testContainsConditionDescriptor() {
      let d = ProviderRegistry.shared.condition("builtin.contains")!.descriptor
      XCTAssertEqual(d.id, "builtin.contains")
      XCTAssertEqual(d.kind, .condition)
      XCTAssertEqual(d.params.count, 1)
      XCTAssertEqual(d.params[0].key, "needle")
      XCTAssertEqual(d.params[0].kind, .text)
    }

    func testContainsConditionMatches() throws {
      let provider = ProviderRegistry.shared.condition("builtin.contains")!
      let input = PluginInput(
        string: "Hello World",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      // case-insensitive per the existing engine
      let result = try provider.evaluate(
        input,
        params: .object(["needle": .string("world")])
      )
      XCTAssertTrue(result)
    }

    func testContainsConditionNoMatch() throws {
      let provider = ProviderRegistry.shared.condition("builtin.contains")!
      let input = PluginInput(
        string: "Hello World",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      let result = try provider.evaluate(
        input,
        params: .object(["needle": .string("goodbye")])
      )
      XCTAssertFalse(result)
    }

    func testContainsConditionEmptyNeedleReturnsFalse() throws {
      let provider = ProviderRegistry.shared.condition("builtin.contains")!
      let input = PluginInput(
        string: "hello",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      let result = try provider.evaluate(input, params: .object(["needle": .string("")]))
      XCTAssertFalse(result)
    }

    func testContainsConditionMissingNeedleReturnsFalse() throws {
      let provider = ProviderRegistry.shared.condition("builtin.contains")!
      let input = PluginInput(
        string: "hello",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      let result = try provider.evaluate(input, params: .object([:]))
      XCTAssertFalse(result)
    }

    // MARK: - SourceAppCondition

    func testSourceAppConditionDescriptor() {
      let d = ProviderRegistry.shared.condition("builtin.sourceApp")!.descriptor
      XCTAssertEqual(d.id, "builtin.sourceApp")
      XCTAssertEqual(d.kind, .condition)
      XCTAssertEqual(d.params.count, 1)
      XCTAssertEqual(d.params[0].key, "bundleID")
      XCTAssertEqual(d.params[0].kind, .bundleID)
    }

    func testSourceAppConditionMatchesExactBundle() throws {
      let provider = ProviderRegistry.shared.condition("builtin.sourceApp")!
      let input = PluginInput(
        string: "text",
        kinds: [.text],
        sourceAppBundleID: "com.apple.Safari",
        fileURLs: []
      )
      let result = try provider.evaluate(
        input,
        params: .object(["bundleID": .string("com.apple.Safari")])
      )
      XCTAssertTrue(result)
    }

    func testSourceAppConditionNoMatchDifferentBundle() throws {
      let provider = ProviderRegistry.shared.condition("builtin.sourceApp")!
      let input = PluginInput(
        string: "text",
        kinds: [.text],
        sourceAppBundleID: "com.apple.Safari",
        fileURLs: []
      )
      let result = try provider.evaluate(
        input,
        params: .object(["bundleID": .string("com.apple.Chrome")])
      )
      XCTAssertFalse(result)
    }

    func testSourceAppConditionNoMatchNilSource() throws {
      let provider = ProviderRegistry.shared.condition("builtin.sourceApp")!
      let input = PluginInput(
        string: "text",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      let result = try provider.evaluate(
        input,
        params: .object(["bundleID": .string("com.apple.Safari")])
      )
      XCTAssertFalse(result)
    }

    func testSourceAppConditionMissingParamReturnsFalse() throws {
      let provider = ProviderRegistry.shared.condition("builtin.sourceApp")!
      let input = PluginInput(
        string: "text",
        kinds: [.text],
        sourceAppBundleID: "com.apple.Safari",
        fileURLs: []
      )
      let result = try provider.evaluate(input, params: .object([:]))
      XCTAssertFalse(result)
    }

    // MARK: - OpenURLProvider

    func testOpenURLDescriptor() {
      let d = ProviderRegistry.shared.action("builtin.openURL")!.descriptor
      XCTAssertEqual(d.id, "builtin.openURL")
      XCTAssertEqual(d.kind, .action)
      XCTAssertTrue(d.params.isEmpty)
    }

    func testOpenURLReturnsSideEffect() async throws {
      let provider = ProviderRegistry.shared.action("builtin.openURL")!
      let input = PluginInput(
        string: "https://example.com",
        kinds: [.url, .text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      let outcome = try await provider.run(input, params: .emptyObject)
      XCTAssertEqual(outcome, .sideEffect)
    }

    func testOpenURLThrowsForNonURL() async {
      let provider = ProviderRegistry.shared.action("builtin.openURL")!
      let input = PluginInput(
        string: "not a url at all with spaces",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      do {
        _ = try await provider.run(input, params: .emptyObject)
        XCTFail("Expected throw for invalid URL")
      } catch {
        // Any error is acceptable; the point is it throws
      }
    }

    // MARK: - OpenInAppProvider

    func testOpenInAppDescriptor() {
      let d = ProviderRegistry.shared.action("builtin.openInApp")!.descriptor
      XCTAssertEqual(d.id, "builtin.openInApp")
      XCTAssertEqual(d.kind, .action)
      XCTAssertEqual(d.params.count, 1)
      XCTAssertEqual(d.params[0].key, "bundleID")
      XCTAssertEqual(d.params[0].kind, .bundleID)
    }

    // MARK: - WebSearchProvider

    func testWebSearchDescriptor() {
      let d = ProviderRegistry.shared.action("builtin.webSearch")!.descriptor
      XCTAssertEqual(d.id, "builtin.webSearch")
      XCTAssertEqual(d.kind, .action)
      XCTAssertEqual(d.params.count, 1)
      XCTAssertEqual(d.params[0].key, "template")
      XCTAssertEqual(d.params[0].kind, .text)
    }

    func testWebSearchReturnsSideEffect() async throws {
      let provider = ProviderRegistry.shared.action("builtin.webSearch")!
      let input = PluginInput(
        string: "swift programming",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      let outcome = try await provider.run(
        input,
        params: .object(["template": .string("https://example.com/search?q={query}")])
      )
      XCTAssertEqual(outcome, .sideEffect)
    }

    func testWebSearchThrowsForEmptyString() async {
      let provider = ProviderRegistry.shared.action("builtin.webSearch")!
      let input = PluginInput(
        string: "",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      do {
        _ = try await provider.run(
          input,
          params: .object(["template": .string("https://example.com/search?q={query}")])
        )
        XCTFail("Expected throw for empty input")
      } catch {
        // expected
      }
    }

    func testBuildSearchURLSubstitutesQuery() {
      let url = WebSearchProvider.buildSearchURL(
        template: "https://example.com/search?q={query}",
        query: "hello world"
      )
      XCTAssertNotNil(url)
      XCTAssertTrue(
        url!.absoluteString.contains("hello%20world") ||
        url!.absoluteString.contains("hello+world")
      )
    }

    func testBuildSearchURLReturnsNilForBadTemplate() {
      let url = WebSearchProvider.buildSearchURL(
        template: "not a url {query}",
        query: "test"
      )
      XCTAssertNil(url)
    }

    // MARK: - RunShortcutProvider

    func testRunShortcutDescriptor() {
      let d = ProviderRegistry.shared.action("builtin.runShortcut")!.descriptor
      XCTAssertEqual(d.id, "builtin.runShortcut")
      XCTAssertEqual(d.kind, .action)
      XCTAssertEqual(d.params.count, 1)
      XCTAssertEqual(d.params[0].key, "shortcutName")
      XCTAssertEqual(d.params[0].kind, .text)
    }

    func testRunShortcutReturnsSideEffect() async throws {
      let provider = ProviderRegistry.shared.action("builtin.runShortcut")!
      let input = PluginInput(
        string: "some text",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      let outcome = try await provider.run(
        input,
        params: .object(["shortcutName": .string("My Shortcut")])
      )
      XCTAssertEqual(outcome, .sideEffect)
    }

    func testRunShortcutThrowsForMissingName() async {
      let provider = ProviderRegistry.shared.action("builtin.runShortcut")!
      let input = PluginInput(
        string: "some text",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      do {
        _ = try await provider.run(input, params: .object([:]))
        XCTFail("Expected throw for missing shortcut name")
      } catch {
        // expected
      }
    }

    func testRunShortcutThrowsForEmptyName() async {
      let provider = ProviderRegistry.shared.action("builtin.runShortcut")!
      let input = PluginInput(
        string: "some text",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      do {
        _ = try await provider.run(input, params: .object(["shortcutName": .string("")]))
        XCTFail("Expected throw for empty shortcut name")
      } catch {
        // expected
      }
    }

    // MARK: - ProviderSource verified flag

    func testBuiltinSourceIsVerified() {
      XCTAssertTrue(ProviderSource.builtin.isVerified)
    }
  }
  ```

- [ ] **Step 2: Register `BuiltinProvidersTests.swift` in `project.pbxproj` (test target)**

  Generate two UUIDs:
  ```sh
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # → TEST_FR (fileRef)
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # → TEST_BF (buildFile)
  ```

  **Edit 1 — Add `PBXBuildFile` entry** (in the `/* Begin PBXBuildFile section */` block):
  ```
  <TEST_BF> /* BuiltinProvidersTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <TEST_FR> /* BuiltinProvidersTests.swift */; };
  ```

  **Edit 2 — Add `PBXFileReference` entry** (in the `/* Begin PBXFileReference section */` block):
  ```
  <TEST_FR> /* BuiltinProvidersTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BuiltinProvidersTests.swift; sourceTree = "<group>"; };
  ```

  **Edit 3 — Add `<TEST_FR>` to the MaccyTests PBXGroup `children`** (the group with `path = MaccyTests;`):
  ```
  <TEST_FR> /* BuiltinProvidersTests.swift */,
  ```

  **Edit 4 — Add `<TEST_BF>` to the `DA360DAC1E3DF137005C6F6B /* Sources */` build phase `files`**:
  ```
  <TEST_BF> /* BuiltinProvidersTests.swift in Sources */,
  ```

- [ ] **Step 3: Run tests — expect COMPILE FAILURE**

  The test file references `BuiltinProviders`, `KindCondition`, `RegexCondition`, `ContainsCondition`, `SourceAppCondition`, `OpenURLProvider`, `OpenInAppProvider`, `WebSearchProvider`, `RunShortcutProvider` — none of which exist yet. The build must fail with "use of unresolved identifier" errors.

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests/BuiltinProvidersTests \
    2>&1 | grep -E "error:|Build FAILED"
  ```

  Expected: `Build FAILED` with `error: use of unresolved identifier 'BuiltinProviders'` (and similar for the other types).

- [ ] **Step 4: Write `Maccy/Plugins/BuiltinProviders.swift`**

  ```swift
  import AppKit
  import Defaults
  import Foundation

  // MARK: - Condition providers

  /// Matches when the clipboard value is classified as the specified ValueKind.
  struct KindCondition: ConditionProvider {

    let descriptor = ProviderDescriptor(
      id: "builtin.kind",
      name: "Value kind",
      description: "Matches when the clipboard value is the given kind: URL, email, phone, file path, color hex, image, or plain text.",
      longHelp: "Uses NSDataDetector and content inspection to classify the clipboard value. Select the kind from the picker. A single item can match multiple kinds — for example, a URL also matches 'text'.",
      kind: .condition,
      engine: .native,
      params: [
        ParamSpec(
          key: "kind",
          label: "Kind",
          kind: .valueKind,
          placeholder: "url"
        )
      ],
      capabilities: [],
      source: .builtin
    )

    func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool {
      guard let kindString = params["kind"]?.stringValue else {
        throw BuiltinProviderError.missingParam("kind")
      }
      guard let kind = ValueKind(rawValue: kindString) else {
        throw BuiltinProviderError.invalidParam("kind", value: kindString)
      }
      return input.kinds.contains(kind)
    }
  }

  /// Matches when the clipboard text matches a regular expression pattern.
  struct RegexCondition: ConditionProvider {

    let descriptor = ProviderDescriptor(
      id: "builtin.regex",
      name: "Regex match",
      description: "Matches when the clipboard text matches the given regular expression (ICU, case-sensitive).",
      longHelp: "Uses NSRegularExpression (ICU syntax). An empty or invalid pattern never matches. The match is applied to the full text — use anchors (^ $) to constrain position.",
      kind: .condition,
      engine: .native,
      params: [
        ParamSpec(
          key: "pattern",
          label: "Pattern",
          kind: .text,
          placeholder: "^https?://"
        )
      ],
      capabilities: [],
      source: .builtin
    )

    func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool {
      guard let pattern = params["pattern"]?.stringValue, !pattern.isEmpty else {
        return false
      }
      guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return false
      }
      let range = NSRange(input.string.startIndex..., in: input.string)
      return regex.firstMatch(in: input.string, range: range) != nil
    }
  }

  /// Matches when the clipboard text contains a substring (case-insensitive).
  struct ContainsCondition: ConditionProvider {

    let descriptor = ProviderDescriptor(
      id: "builtin.contains",
      name: "Contains text",
      description: "Matches when the clipboard text contains the given substring (case-insensitive, locale-aware).",
      longHelp: "Uses localizedCaseInsensitiveContains. An empty needle never matches.",
      kind: .condition,
      engine: .native,
      params: [
        ParamSpec(
          key: "needle",
          label: "Text",
          kind: .text,
          placeholder: "search term"
        )
      ],
      capabilities: [],
      source: .builtin
    )

    func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool {
      guard let needle = params["needle"]?.stringValue, !needle.isEmpty else {
        return false
      }
      return input.string.localizedCaseInsensitiveContains(needle)
    }
  }

  /// Matches when the clipboard was copied from the specified application (by bundle ID).
  struct SourceAppCondition: ConditionProvider {

    let descriptor = ProviderDescriptor(
      id: "builtin.sourceApp",
      name: "Source application",
      description: "Matches when the clipboard was copied from the application with the given bundle identifier.",
      longHelp: "Compares the bundle ID of the frontmost app at copy time. A missing or empty bundle ID never matches. Use the bundle identifier exactly as it appears in the app's Info.plist.",
      kind: .condition,
      engine: .native,
      params: [
        ParamSpec(
          key: "bundleID",
          label: "Bundle ID",
          kind: .bundleID,
          placeholder: "com.apple.Safari"
        )
      ],
      capabilities: [],
      source: .builtin
    )

    func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool {
      guard let bundleID = params["bundleID"]?.stringValue, !bundleID.isEmpty else {
        return false
      }
      return input.sourceAppBundleID == bundleID
    }
  }

  // MARK: - Action providers

  /// Opens the clipboard text as a URL in the default browser or associated app.
  struct OpenURLProvider: ActionProvider {

    let descriptor = ProviderDescriptor(
      id: "builtin.openURL",
      name: "Open as URL",
      description: "Opens the clipboard text as a URL. Bare text gets https://, emails get mailto:. No parameters required.",
      longHelp: "Builds an openable URL from the clipboard text: if a scheme is already present it is used as-is; text containing '@' becomes a mailto: URL; otherwise https:// is prepended. Fails if the text contains spaces or cannot form a valid URL.",
      kind: .action,
      engine: .native,
      params: [],
      capabilities: [],
      source: .builtin
    )

    func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome {
      guard let url = makeURL(from: input.string) else {
        throw ActionError.invalidURL
      }
      NSWorkspace.shared.open(url)
      return .sideEffect
    }
  }

  /// Opens the clipboard content in a specific application identified by bundle ID.
  struct OpenInAppProvider: ActionProvider {

    let descriptor = ProviderDescriptor(
      id: "builtin.openInApp",
      name: "Open in app",
      description: "Opens the clipboard content in the application with the given bundle ID. Works with URLs and file paths.",
      longHelp: "Resolves the application URL via NSWorkspace. If the clipboard contains file URLs they are opened directly; otherwise the text is converted to a URL and passed to the app. Fails if the application is not installed.",
      kind: .action,
      engine: .native,
      params: [
        ParamSpec(
          key: "bundleID",
          label: "Application",
          kind: .bundleID,
          placeholder: "com.apple.Safari"
        )
      ],
      capabilities: [],
      source: .builtin
    )

    func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome {
      guard let bundleID = params["bundleID"]?.stringValue, !bundleID.isEmpty else {
        throw ActionError.missingApp
      }
      guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        throw ActionError.missingApp
      }
      let urls: [URL]
      if !input.fileURLs.isEmpty {
        urls = input.fileURLs
      } else if let url = makeURL(from: input.string) {
        urls = [url]
      } else {
        throw ActionError.noValue
      }
      _ = try await NSWorkspace.shared.open(
        urls,
        withApplicationAt: appURL,
        configuration: NSWorkspace.OpenConfiguration()
      )
      return .sideEffect
    }
  }

  /// Performs a web search for the clipboard text using a configurable URL template.
  struct WebSearchProvider: ActionProvider {

    let descriptor = ProviderDescriptor(
      id: "builtin.webSearch",
      name: "Web search",
      description: "Searches the clipboard text using a URL template. Use {query} as the placeholder for the percent-encoded search term.",
      longHelp: "Percent-encodes the clipboard text and substitutes it into the template at {query}, then opens the resulting URL. The default template is Google search. Fails if the clipboard text is empty.",
      kind: .action,
      engine: .native,
      params: [
        ParamSpec(
          key: "template",
          label: "Search URL",
          kind: .text,
          placeholder: WebSearchTemplate.google
        )
      ],
      capabilities: [],
      source: .builtin
    )

    /// Builds the final search URL by percent-encoding `query` and substituting
    /// it into `template` at the `{query}` placeholder. Returns `nil` when the
    /// resulting string cannot be parsed as a URL.
    static func buildSearchURL(template: String, query: String) -> URL? {
      let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
      return URL(string: template.replacingOccurrences(of: "{query}", with: encoded))
    }

    func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome {
      guard !input.string.isEmpty else { throw ActionError.noValue }
      let template = params["template"]?.stringValue ?? WebSearchTemplate.google
      guard let url = WebSearchProvider.buildSearchURL(template: template, query: input.string) else {
        throw ActionError.invalidURL
      }
      NSWorkspace.shared.open(url)
      return .sideEffect
    }
  }

  /// Runs a named Apple Shortcut with the clipboard text as input.
  struct RunShortcutProvider: ActionProvider {

    let descriptor = ProviderDescriptor(
      id: "builtin.runShortcut",
      name: "Run Shortcut",
      description: "Runs the named shortcut from Shortcuts.app, passing the clipboard text as plain-text input.",
      longHelp: "Opens the shortcuts://run-shortcut URL with the shortcut name and clipboard text. The shortcut must exist in Shortcuts.app. The clipboard is not modified by this action.",
      kind: .action,
      engine: .native,
      params: [
        ParamSpec(
          key: "shortcutName",
          label: "Shortcut name",
          kind: .text,
          placeholder: "My Shortcut"
        )
      ],
      capabilities: [],
      source: .builtin
    )

    func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome {
      guard let name = params["shortcutName"]?.stringValue, !name.isEmpty else {
        throw ActionError.missingShortcut
      }
      var components = URLComponents()
      components.scheme = "shortcuts"
      components.host = "run-shortcut"
      components.queryItems = [
        URLQueryItem(name: "name", value: name),
        URLQueryItem(name: "input", value: "text"),
        URLQueryItem(name: "text", value: input.string)
      ]
      guard let url = components.url else { throw ActionError.missingShortcut }
      NSWorkspace.shared.open(url)
      return .sideEffect
    }
  }

  // MARK: - Registration

  enum BuiltinProviders {
    /// Registers all eight built-in native providers into `registry`.
    /// Call once at boot (from `ActionEngine.init`) before any rule evaluation.
    @MainActor
    static func registerBuiltins(into registry: ProviderRegistry) {
      registry.register(condition: KindCondition())
      registry.register(condition: RegexCondition())
      registry.register(condition: ContainsCondition())
      registry.register(condition: SourceAppCondition())
      registry.register(action: OpenURLProvider())
      registry.register(action: OpenInAppProvider())
      registry.register(action: WebSearchProvider())
      registry.register(action: RunShortcutProvider())
    }
  }

  // MARK: - Internal errors

  enum BuiltinProviderError: Error, Equatable {
    case missingParam(String)
    case invalidParam(String, value: String)
  }
  ```

- [ ] **Step 5: Register `BuiltinProviders.swift` in `project.pbxproj` (app target)**

  The `Maccy/Plugins/` PBXGroup was created during A1's pbxproj step. If the group is already present, only file-level entries are needed. If somehow the group was not created by A1, create it now following the "Adding a brand-new group" recipe from the code facts.

  Generate two UUIDs for `BuiltinProviders.swift`:
  ```sh
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # → APP_FR
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # → APP_BF
  ```

  **Edit 1 — Add `PBXBuildFile` entry** (in the `/* Begin PBXBuildFile section */` block):
  ```
  <APP_BF> /* BuiltinProviders.swift in Sources */ = {isa = PBXBuildFile; fileRef = <APP_FR> /* BuiltinProviders.swift */; };
  ```

  **Edit 2 — Add `PBXFileReference` entry** (in the `/* Begin PBXFileReference section */` block).

  If the `Plugins/` PBXGroup was created by A1 (nested group; `BuiltinProviders.swift` sits inside it), the path is the filename only:
  ```
  <APP_FR> /* BuiltinProviders.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BuiltinProviders.swift; sourceTree = "<group>"; };
  ```

  If no nested `Plugins` group exists (flat layout like `Actions/`), encode the subfolder in the path:
  ```
  <APP_FR> /* BuiltinProviders.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Plugins/BuiltinProviders.swift; sourceTree = "<group>"; };
  ```

  **Edit 3 — Add `<APP_FR>` to the `Plugins` group `children`** (if a nested Plugins group exists, add there; otherwise add to `DAEE38451E3DBEB100DD2966 /* Maccy */` children):
  ```
  <APP_FR> /* BuiltinProviders.swift */,
  ```

  **Edit 4 — Add `<APP_BF>` to the `DAEE383F1E3DBEB100DD2966 /* Sources */` build phase `files`**:
  ```
  <APP_BF> /* BuiltinProviders.swift in Sources */,
  ```

- [ ] **Step 6: Run tests — expect PASS**

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests/BuiltinProvidersTests \
    2>&1 | tail -20
  ```

  Expected: `** TEST SUCCEEDED **` — all test methods in `BuiltinProvidersTests` pass. No regressions in the existing test classes (the new file is additive; nothing existing was changed).

- [ ] **Step 7: Run the full unit test suite — expect no regressions**

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests \
    2>&1 | tail -20
  ```

  Expected: `** TEST SUCCEEDED **`. If any pre-existing test fails, it is a pre-existing failure unrelated to this task — document it and do not attempt to fix it here.

- [ ] **Step 8: Commit**

  ```sh
  git add Maccy/Plugins/BuiltinProviders.swift \
          MaccyTests/BuiltinProvidersTests.swift \
          Maccy.xcodeproj/project.pbxproj
  git commit -m "$(cat <<'EOF'
  A3: BuiltinProviders — native condition + launch action providers

  Adds Maccy/Plugins/BuiltinProviders.swift with eight native providers:
  conditions builtin.kind/regex/contains/sourceApp and actions
  builtin.openURL/openInApp/webSearch/runShortcut. Logic ported verbatim
  from the ClipboardAction conformers; makeURL/ActionError remain in
  ClipboardAction.swift until the A5 swap. Includes BuiltinProvidersTests
  covering descriptor shape, evaluate/run correctness, and edge cases.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```


---

### Task A4: FirstPartyProviders — soft-wrap, terminal-source, 6 transforms

> **Prerequisites:** A1 (`PluginCore.swift` + its pbxproj entries) and A2 (`ProviderRegistry.swift` + its pbxproj entries) are committed and the project compiles. This task is purely additive — it creates one new source file and one new test file. The existing `TransformKind`, `RuleCondition.softWrapped/terminalSource`, `TransformAction`, `TextUnwrap`, `KeyboardLayoutFixer`, and `Defaults[.terminalAppBundleIDs]` are **not touched**; they are called from the new providers and will be deleted in A5.

---

- [ ] **Step 1: Write the failing test file — `MaccyTests/FirstPartyProvidersTests.swift`**

  Create `MaccyTests/FirstPartyProvidersTests.swift` with the full content below. It will not compile yet because `FirstPartyProviders` does not exist. That is expected and intentional for TDD.

  ```swift
  import XCTest
  @testable import Maccy

  @MainActor
  final class FirstPartyProvidersTests: XCTestCase {

    // MARK: - Helpers

    private func input(
      _ string: String,
      sourceApp: String? = nil
    ) -> PluginInput {
      PluginInput(string: string, kinds: [], sourceAppBundleID: sourceApp, fileURLs: [])
    }

    // A wrapped input: two lines of width >= 40, last line shorter.
    private var wrappedInput: PluginInput {
      let line = String(repeating: "a", count: 42)
      let text = line + "\n" + "hello"
      return input(text)
    }

    private var notWrappedInput: PluginInput {
      input("short\nlines\nhere")
    }

    // MARK: - SoftWrapCondition

    func testSoftWrapTrueForWrappedText() throws {
      let provider = SoftWrapCondition()
      XCTAssertTrue(try provider.evaluate(wrappedInput, params: .emptyObject))
    }

    func testSoftWrapFalseForShortLines() throws {
      let provider = SoftWrapCondition()
      XCTAssertFalse(try provider.evaluate(notWrappedInput, params: .emptyObject))
    }

    func testSoftWrapDescriptor() {
      let d = SoftWrapCondition().descriptor
      XCTAssertEqual(d.id, "com.maccay.soft-wrap")
      XCTAssertEqual(d.kind, .condition)
      XCTAssertEqual(d.engine, .native)
      XCTAssertEqual(d.source, .builtin)
      XCTAssertTrue(d.params.isEmpty)
    }

    // MARK: - TerminalSourceCondition

    func testTerminalSourceTrueForKnownApp() throws {
      let provider = TerminalSourceCondition()
      // "com.apple.Terminal" is in TerminalApps.defaults
      let inp = input("anything", sourceApp: "com.apple.Terminal")
      XCTAssertTrue(try provider.evaluate(inp, params: .emptyObject))
    }

    func testTerminalSourceFalseForUnknownApp() throws {
      let provider = TerminalSourceCondition()
      let inp = input("anything", sourceApp: "com.example.NotATerminal")
      XCTAssertFalse(try provider.evaluate(inp, params: .emptyObject))
    }

    func testTerminalSourceFalseForNilApp() throws {
      let provider = TerminalSourceCondition()
      let inp = input("anything", sourceApp: nil)
      XCTAssertFalse(try provider.evaluate(inp, params: .emptyObject))
    }

    func testTerminalSourceDescriptor() {
      let d = TerminalSourceCondition().descriptor
      XCTAssertEqual(d.id, "com.maccay.terminal-source")
      XCTAssertEqual(d.kind, .condition)
      XCTAssertEqual(d.engine, .native)
      XCTAssertEqual(d.source, .builtin)
      XCTAssertTrue(d.params.isEmpty)
    }

    // MARK: - TrimAction

    func testTrimReturnsReplace() async throws {
      let outcome = try await TrimAction().run(input("  hello  "), params: .emptyObject)
      XCTAssertEqual(outcome, .replace("hello"))
    }

    func testTrimPreservesInnerWhitespace() async throws {
      let outcome = try await TrimAction().run(input("  hello world  "), params: .emptyObject)
      XCTAssertEqual(outcome, .replace("hello world"))
    }

    func testTrimThrowsOnEmpty() async {
      do {
        _ = try await TrimAction().run(input(""), params: .emptyObject)
        XCTFail("Expected ActionError.noValue")
      } catch ActionError.noValue {
        // expected
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }

    func testTrimDescriptor() {
      let d = TrimAction().descriptor
      XCTAssertEqual(d.id, "com.maccay.trim")
      XCTAssertEqual(d.kind, .action)
      XCTAssertEqual(d.engine, .native)
      XCTAssertEqual(d.source, .builtin)
      XCTAssertTrue(d.params.isEmpty)
    }

    // MARK: - UppercaseAction

    func testUppercaseReturnsReplace() async throws {
      let outcome = try await UppercaseAction().run(input("hello"), params: .emptyObject)
      XCTAssertEqual(outcome, .replace("HELLO"))
    }

    func testUppercaseThrowsOnEmpty() async {
      do {
        _ = try await UppercaseAction().run(input(""), params: .emptyObject)
        XCTFail("Expected ActionError.noValue")
      } catch ActionError.noValue {
        // expected
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }

    func testUppercaseDescriptor() {
      let d = UppercaseAction().descriptor
      XCTAssertEqual(d.id, "com.maccay.uppercase")
      XCTAssertEqual(d.kind, .action)
    }

    // MARK: - LowercaseAction

    func testLowercaseReturnsReplace() async throws {
      let outcome = try await LowercaseAction().run(input("HELLO"), params: .emptyObject)
      XCTAssertEqual(outcome, .replace("hello"))
    }

    func testLowercaseThrowsOnEmpty() async {
      do {
        _ = try await LowercaseAction().run(input(""), params: .emptyObject)
        XCTFail("Expected ActionError.noValue")
      } catch ActionError.noValue {
        // expected
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }

    func testLowercaseDescriptor() {
      let d = LowercaseAction().descriptor
      XCTAssertEqual(d.id, "com.maccay.lowercase")
      XCTAssertEqual(d.kind, .action)
    }

    // MARK: - StripFormattingAction

    func testStripFormattingReturnsReplaceWithSameString() async throws {
      // stripFormatting on a plain string returns the same string unchanged
      let outcome = try await StripFormattingAction().run(input("hello"), params: .emptyObject)
      XCTAssertEqual(outcome, .replace("hello"))
    }

    func testStripFormattingThrowsOnEmpty() async {
      do {
        _ = try await StripFormattingAction().run(input(""), params: .emptyObject)
        XCTFail("Expected ActionError.noValue")
      } catch ActionError.noValue {
        // expected
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }

    func testStripFormattingDescriptor() {
      let d = StripFormattingAction().descriptor
      XCTAssertEqual(d.id, "com.maccay.strip-formatting")
      XCTAssertEqual(d.kind, .action)
    }

    // MARK: - UnwrapAction

    func testUnwrapJoinsWrappedLines() async throws {
      let line = String(repeating: "a", count: 42)
      let text = line + "\n" + "hello"
      let outcome = try await UnwrapAction().run(input(text), params: .emptyObject)
      // isSoftWrapped → delete newlines
      XCTAssertEqual(outcome, .replace(line + "hello"))
    }

    func testUnwrapCollapsesSoftNewlinesOnNonWrapped() async throws {
      let outcome = try await UnwrapAction().run(input("line one\nline two"), params: .emptyObject)
      XCTAssertEqual(outcome, .replace("line one line two"))
    }

    func testUnwrapThrowsOnEmpty() async {
      do {
        _ = try await UnwrapAction().run(input(""), params: .emptyObject)
        XCTFail("Expected ActionError.noValue")
      } catch ActionError.noValue {
        // expected
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }

    func testUnwrapDescriptor() {
      let d = UnwrapAction().descriptor
      XCTAssertEqual(d.id, "com.maccay.unwrap")
      XCTAssertEqual(d.kind, .action)
    }

    // MARK: - FixKeyboardLayoutAction

    func testFixKeyboardLayoutEnToHe() async throws {
      // "akuo" typed on EN layout → "שלום" in HE
      let outcome = try await FixKeyboardLayoutAction().run(input("akuo"), params: .emptyObject)
      XCTAssertEqual(outcome, .replace("שלום"))
    }

    func testFixKeyboardLayoutHeToEn() async throws {
      // "שלום" typed on HE layout → "akuo" in EN
      let outcome = try await FixKeyboardLayoutAction().run(input("שלום"), params: .emptyObject)
      XCTAssertEqual(outcome, .replace("akuo"))
    }

    func testFixKeyboardLayoutThrowsOnEmpty() async {
      do {
        _ = try await FixKeyboardLayoutAction().run(input(""), params: .emptyObject)
        XCTFail("Expected ActionError.noValue")
      } catch ActionError.noValue {
        // expected
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }

    func testFixKeyboardLayoutDescriptor() {
      let d = FixKeyboardLayoutAction().descriptor
      XCTAssertEqual(d.id, "com.maccay.fix-keyboard-layout")
      XCTAssertEqual(d.kind, .action)
    }

    // MARK: - registerFirstParty

    func testRegisterFirstPartyRegistersAllEight() {
      let registry = ProviderRegistry()
      FirstPartyProviders.registerFirstParty(into: registry)

      // 2 conditions
      XCTAssertNotNil(registry.condition("com.maccay.soft-wrap"))
      XCTAssertNotNil(registry.condition("com.maccay.terminal-source"))

      // 6 actions
      XCTAssertNotNil(registry.action("com.maccay.trim"))
      XCTAssertNotNil(registry.action("com.maccay.uppercase"))
      XCTAssertNotNil(registry.action("com.maccay.lowercase"))
      XCTAssertNotNil(registry.action("com.maccay.strip-formatting"))
      XCTAssertNotNil(registry.action("com.maccay.unwrap"))
      XCTAssertNotNil(registry.action("com.maccay.fix-keyboard-layout"))
    }

    func testRegisterFirstPartyDescriptorCount() {
      let registry = ProviderRegistry()
      FirstPartyProviders.registerFirstParty(into: registry)
      let all = registry.descriptors()
      XCTAssertEqual(all.count, 8)
    }
  }
  ```

---

- [ ] **Step 2: Register `FirstPartyProvidersTests.swift` in `project.pbxproj` (test target)**

  Generated UUIDs for this file:
  - `fileRef_UUID` = `C9495F33A5964B54BE86BA27`
  - `buildFile_UUID` = `776E0A3A32024FECB85E2A9B`

  Open `Maccy.xcodeproj/project.pbxproj` and make **4 edits**:

  **Edit 1 — add a `PBXBuildFile` entry** in the `/* Begin PBXBuildFile section */` block:
  ```
  776E0A3A32024FECB85E2A9B /* FirstPartyProvidersTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = C9495F33A5964B54BE86BA27 /* FirstPartyProvidersTests.swift */; };
  ```

  **Edit 2 — add a `PBXFileReference` entry** in the `/* Begin PBXFileReference section */` block:
  ```
  C9495F33A5964B54BE86BA27 /* FirstPartyProvidersTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MaccyTests/FirstPartyProvidersTests.swift; sourceTree = "<group>"; };
  ```

  **Edit 3 — add the `fileRef_UUID` into the MaccyTests PBXGroup `children` array** (the group with `path = MaccyTests;`):
  ```
  C9495F33A5964B54BE86BA27 /* FirstPartyProvidersTests.swift */,
  ```

  **Edit 4 — add the `buildFile_UUID` into the `DA360DAC1E3DF137005C6F6B /* Sources */` build phase `files` array** (the MaccyTests build phase):
  ```
  776E0A3A32024FECB85E2A9B /* FirstPartyProvidersTests.swift in Sources */,
  ```

---

- [ ] **Step 3: Confirm the test target fails to compile (types not defined yet)**

  Run:
  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests/FirstPartyProvidersTests \
    2>&1 | grep -E "error:|BUILD FAILED|BUILD SUCCEEDED" | head -20
  ```

  **Expected:** `BUILD FAILED` with errors like `cannot find type 'SoftWrapCondition' in scope`, `cannot find type 'TerminalSourceCondition' in scope`, etc. This confirms the test is wired and the red bar is genuine.

---

- [ ] **Step 4: Write `Maccy/Plugins/FirstPartyProviders.swift`**

  Create the directory `Maccy/Plugins/` on disk (it does not yet exist) and create the file:

  ```swift
  import Defaults
  import Foundation

  // MARK: - Condition providers

  /// Evaluates whether the clipboard text shows a fixed-width soft-wrap signature.
  /// Wraps `TextUnwrap.isSoftWrapped(_:)` byte-for-byte.
  @MainActor
  struct SoftWrapCondition: ConditionProvider {
    let descriptor = ProviderDescriptor(
      id: "com.maccay.soft-wrap",
      name: "Soft-wrapped text",
      description: "Matches when the text looks like a terminal's fixed-width line wrap (all lines same length ≥ 40, last line shorter).",
      longHelp: "Uses the same heuristic as the built-in Unwrap action: every line except the last must share the same character count L ≥ 40, and the last line must be non-empty and no longer than L. Designed for auto-unwrapping pasted terminal commands.",
      kind: .condition,
      engine: .native,
      params: [],
      capabilities: [],
      source: .builtin
    )

    func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool {
      TextUnwrap.isSoftWrapped(input.string)
    }
  }

  /// Evaluates whether the clipboard source app is a known terminal emulator.
  /// Reads `Defaults[.terminalAppBundleIDs]` so user customisations are respected.
  @MainActor
  struct TerminalSourceCondition: ConditionProvider {
    let descriptor = ProviderDescriptor(
      id: "com.maccay.terminal-source",
      name: "Terminal source",
      description: "Matches when the text was copied from a terminal emulator (configurable list of bundle IDs in Settings → Actions → Terminal apps).",
      longHelp: "Checks the source app bundle ID against the persisted terminal-app list (Defaults key `terminalAppBundleIDs`). Defaults include Terminal, iTerm2, Warp, kitty, Alacritty, WezTerm, Ghostty, and VS Code. The list is user-editable via `maccay rules terminals`.",
      kind: .condition,
      engine: .native,
      params: [],
      capabilities: [],
      source: .builtin
    )

    func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool {
      guard let app = input.sourceAppBundleID else { return false }
      return Defaults[.terminalAppBundleIDs].contains(app)
    }
  }

  // MARK: - Transform action providers

  /// Removes leading and trailing whitespace and newlines.
  @MainActor
  struct TrimAction: ActionProvider {
    let descriptor = ProviderDescriptor(
      id: "com.maccay.trim",
      name: "Trim whitespace",
      description: "Removes leading and trailing whitespace and newlines from the clipboard text.",
      longHelp: nil,
      kind: .action,
      engine: .native,
      params: [],
      capabilities: [],
      source: .builtin
    )

    func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome {
      guard !input.string.isEmpty else { throw ActionError.noValue }
      return .replace(input.string.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  /// Converts all characters to uppercase.
  @MainActor
  struct UppercaseAction: ActionProvider {
    let descriptor = ProviderDescriptor(
      id: "com.maccay.uppercase",
      name: "UPPERCASE",
      description: "Converts the clipboard text to uppercase.",
      longHelp: nil,
      kind: .action,
      engine: .native,
      params: [],
      capabilities: [],
      source: .builtin
    )

    func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome {
      guard !input.string.isEmpty else { throw ActionError.noValue }
      return .replace(input.string.uppercased())
    }
  }

  /// Converts all characters to lowercase.
  @MainActor
  struct LowercaseAction: ActionProvider {
    let descriptor = ProviderDescriptor(
      id: "com.maccay.lowercase",
      name: "lowercase",
      description: "Converts the clipboard text to lowercase.",
      longHelp: nil,
      kind: .action,
      engine: .native,
      params: [],
      capabilities: [],
      source: .builtin
    )

    func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome {
      guard !input.string.isEmpty else { throw ActionError.noValue }
      return .replace(input.string.lowercased())
    }
  }

  /// Returns the plain-string representation (already stripped of rich formatting
  /// by the time `PluginInput.string` is populated from `ValueClassifier.primaryString`).
  @MainActor
  struct StripFormattingAction: ActionProvider {
    let descriptor = ProviderDescriptor(
      id: "com.maccay.strip-formatting",
      name: "Strip formatting",
      description: "Strips rich text formatting from the clipboard, leaving only plain text.",
      longHelp: "The clipboard string passed to the provider is already the plain-text representation extracted from HTML/RTF by Maccy's history engine. Replacing the clipboard with this value effectively strips all rich formatting.",
      kind: .action,
      engine: .native,
      params: [],
      capabilities: [],
      source: .builtin
    )

    func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome {
      guard !input.string.isEmpty else { throw ActionError.noValue }
      // input.string is already the plain-string representation; re-copying it strips formatting.
      return .replace(input.string)
    }
  }

  /// Joins soft-wrapped lines into a single line via `TextUnwrap.unwrap(_:)`.
  @MainActor
  struct UnwrapAction: ActionProvider {
    let descriptor = ProviderDescriptor(
      id: "com.maccay.unwrap",
      name: "Unwrap (join wrapped lines)",
      description: "Joins soft-wrapped terminal output into a single line. Detects fixed-width wraps and collapses all newlines; otherwise joins lines with spaces.",
      longHelp: "Uses `TextUnwrap.unwrap`: if the text passes the soft-wrap heuristic (all interior lines same length ≥ 40), newlines are deleted exactly, reconstructing the original one-liner. Otherwise each newline boundary (plus surrounding whitespace) is collapsed to a single space.",
      kind: .action,
      engine: .native,
      params: [],
      capabilities: [],
      source: .builtin
    )

    func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome {
      guard !input.string.isEmpty else { throw ActionError.noValue }
      return .replace(TextUnwrap.unwrap(input.string))
    }
  }

  /// Re-maps text between US-QWERTY and Israeli SI-1452 keyboard layouts.
  @MainActor
  struct FixKeyboardLayoutAction: ActionProvider {
    let descriptor = ProviderDescriptor(
      id: "com.maccay.fix-keyboard-layout",
      name: "Fix keyboard layout (EN ⇄ HE)",
      description: "Corrects text typed in the wrong keyboard layout by re-mapping between US-QWERTY and Israeli SI-1452. Direction is auto-detected by script count.",
      longHelp: "Counts Hebrew scalars (U+0590–U+05FF) vs Latin letters. If Hebrew > Latin the HE→EN table is applied; otherwise the EN→HE table is applied (including on ties and all-Latin input). Unmapped characters pass through unchanged. Bracket pairs that differ between LTR and RTL contexts are also swapped.",
      kind: .action,
      engine: .native,
      params: [],
      capabilities: [],
      source: .builtin
    )

    func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome {
      guard !input.string.isEmpty else { throw ActionError.noValue }
      return .replace(KeyboardLayoutFixer.fix(input.string))
    }
  }

  // MARK: - Registration

  /// Registers all first-party providers into the given registry.
  /// Called at boot time by `ActionEngine` (after A5 lands).
  enum FirstPartyProviders {
    @MainActor
    static func registerFirstParty(into registry: ProviderRegistry) {
      registry.register(condition: SoftWrapCondition())
      registry.register(condition: TerminalSourceCondition())
      registry.register(action: TrimAction())
      registry.register(action: UppercaseAction())
      registry.register(action: LowercaseAction())
      registry.register(action: StripFormattingAction())
      registry.register(action: UnwrapAction())
      registry.register(action: FixKeyboardLayoutAction())
    }
  }
  ```

---

- [ ] **Step 5: Register `FirstPartyProviders.swift` in `project.pbxproj` (app target)**

  Per Global Constraints (AUTHORITATIVE), there is no nested `Plugins` group. `FirstPartyProviders.swift` is registered **flat** in the `DAEE38451E3DBEB100DD2966 /* Maccy */` group with `path = Plugins/FirstPartyProviders.swift`.

  Generated UUIDs for this file:
  - `fileRef_UUID` = `529599662554485689514F14`
  - `buildFile_UUID` = `0AF60BD928004BF7B2AF5B8A`

  Open `Maccy.xcodeproj/project.pbxproj` and make **4 edits**:

  **Edit 1 — add a `PBXBuildFile` entry** in the `/* Begin PBXBuildFile section */` block:
  ```
  0AF60BD928004BF7B2AF5B8A /* FirstPartyProviders.swift in Sources */ = {isa = PBXBuildFile; fileRef = 529599662554485689514F14 /* FirstPartyProviders.swift */; };
  ```

  **Edit 2 — add a `PBXFileReference` entry** in the `/* Begin PBXFileReference section */` block:
  ```
  529599662554485689514F14 /* FirstPartyProviders.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Plugins/FirstPartyProviders.swift; sourceTree = "<group>"; };
  ```

  > Note: per Global Constraints there is no nested `Plugins` group — the `PBXFileReference.path` carries the subfolder (`path = Plugins/FirstPartyProviders.swift`) and the fileRef goes into the flat `Maccy` group, matching the `Actions/` precedent.

  **Edit 3 — add the `fileRef_UUID` into the `DAEE38451E3DBEB100DD2966 /* Maccy */` group `children` array** (flat, per Global Constraints):
  ```
  529599662554485689514F14 /* FirstPartyProviders.swift */,
  ```

  **Edit 4 — add the `buildFile_UUID` into the `DAEE383F1E3DBEB100DD2966 /* Sources */` build phase `files` array** (the Maccy app target build phase):
  ```
  0AF60BD928004BF7B2AF5B8A /* FirstPartyProviders.swift in Sources */,
  ```

---

- [ ] **Step 6: Run the tests — expect PASS**

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests/FirstPartyProvidersTests \
    2>&1 | grep -E "Test Suite|PASSED|FAILED|error:" | head -30
  ```

  **Expected output (all 23 test methods pass):**
  ```
  Test Suite 'FirstPartyProvidersTests' started at …
  Test Suite 'FirstPartyProvidersTests' passed at …
       Executed 23 tests, with 0 failures (0 unexpected) in … seconds
  ```

  If any test fails:
  - `testSoftWrapTrueForWrappedText` fails → verify the wrapped helper produces exactly two lines, each ≥ 40 characters, last shorter.
  - `testTerminalSourceTrueForKnownApp` fails → verify `Defaults[.terminalAppBundleIDs]` includes `"com.apple.Terminal"` (it inherits from `TerminalApps.defaults`).
  - Any `testFix*` fails → verify `KeyboardLayoutFixer.fix("akuo")` returns `"שלום"` (confirmed by the existing `KeyboardLayoutTests`).
  - Any `ThrowsOnEmpty` test fails → the guard at the top of `run` is missing or the wrong error is thrown.

---

- [ ] **Step 7: Commit**

  ```sh
  cd /Users/roypadina/Code/Padina/Maccay && \
  git add \
    Maccy/Plugins/FirstPartyProviders.swift \
    MaccyTests/FirstPartyProvidersTests.swift \
    Maccy.xcodeproj/project.pbxproj && \
  git commit -m "$(cat <<'EOF'
  A4: Add FirstPartyProviders — soft-wrap, terminal-source, 6 transform action providers

  Introduces SoftWrapCondition, TerminalSourceCondition, TrimAction, UppercaseAction,
  LowercaseAction, StripFormattingAction, UnwrapAction, and FixKeyboardLayoutAction as
  native ProviderRegistry entries with canonical com.maccay.* ids and full descriptors.
  Behaviour is byte-for-byte preserved by delegating to TextUnwrap / KeyboardLayoutFixer /
  Defaults[.terminalAppBundleIDs]. registerFirstParty(into:) wires all eight providers.
  Additive — existing TransformKind/RuleCondition enums are not touched (removed in A5).

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Tkhip6qSb9uiFxwiJQbcKX
  EOF
  )"
  ```


---

### Task A5: The atomic swap — schema + engine + delete old + CLI + GUI

> **THE ATOMIC SWAP.** A1–A4 are merged and compile alongside the old enums. This task deletes the old enums/switches and rewires schema + engine + CLI + GUI together; they reference each other's symbols, so the project does NOT compile until Part 5 lands. Exactly ONE build+test checkpoint, at the end of Part 5. Do the parts in order; commit once at the very end.

**Files:** Modify `Maccy/Actions/ActionRule.swift`, `Maccy/Actions/ClipboardAction.swift`, `Maccy/Actions/ActionEngine.swift`, `Maccy/Actions/ActionsCLI.swift`, `Maccy/Settings/ActionsSettingsPane.swift`; Create `MaccyTests/ActionEngineRegistryTests.swift`; Modify `MaccyTests/KeyboardLayoutTests.swift` (one test references the deleted `TransformKind`); Modify `Maccy.xcodeproj/project.pbxproj`.


#### Part 0 — Test scaffold

- [ ] **Step 0.1: Write `MaccyTests/ActionEngineRegistryTests.swift`**

  Create the file at `/Users/roypadina/Code/Padina/Maccay/MaccyTests/ActionEngineRegistryTests.swift` with the following complete content:

  ```swift
  import XCTest
  @testable import Maccy

  @MainActor
  final class ActionEngineRegistryTests: XCTestCase {

    override func setUp() async throws {
      try await super.setUp()
      ProviderRegistry.shared.reset()
      BuiltinProviders.registerBuiltins(into: .shared)
      FirstPartyProviders.registerFirstParty(into: .shared)
    }

    // MARK: - testKindConditionMatchesViaRegistry

    func testKindConditionMatchesViaRegistry() throws {
      let input = PluginInput(
        string: "https://example.com",
        kinds: [.url],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      let result = try XCTUnwrap(
        ProviderRegistry.shared.condition("builtin.kind")
      ).evaluate(input, params: .object(["kind": .string("url")]))
      XCTAssertTrue(result)
    }

    // MARK: - testUnwrapTransformReturnsReplaceViaRegistry

    func testUnwrapTransformReturnsReplaceViaRegistry() async throws {
      // Build a soft-wrapped string: two lines of equal length >= 40, last line shorter.
      let line = String(repeating: "a", count: 40)
      let theString = line + "\n" + line + "\n" + "short"
      let input = PluginInput(
        string: theString,
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      let provider = try XCTUnwrap(ProviderRegistry.shared.action("com.maccay.unwrap"))
      let outcome = try await provider.run(input, params: .emptyObject)
      XCTAssertEqual(outcome, .replace(TextUnwrap.unwrap(theString)))
    }

    // MARK: - testNewSchemaRoundTrips

    func testNewSchemaRoundTrips() throws {
      let condition = RuleCondition(
        provider: "builtin.kind",
        params: .object(["kind": .string("url")])
      )
      let action = ActionConfig(
        provider: "builtin.openURL",
        params: .emptyObject,
        shortcut: nil
      )
      let rule = ActionRule(
        name: "Round-trip rule",
        enabled: true,
        matchMode: .all,
        conditions: [condition],
        actions: [action],
        autoRunDefault: false
      )

      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      let data = try encoder.encode(rule)

      let decoder = JSONDecoder()
      let decoded = try decoder.decode(ActionRule.self, from: data)

      XCTAssertEqual(decoded.schemaVersion, 3)
      XCTAssertEqual(decoded.name, "Round-trip rule")
      XCTAssertEqual(decoded.matchMode, .all)
      XCTAssertEqual(decoded.conditions.count, 1)
      XCTAssertEqual(decoded.conditions[0].provider, "builtin.kind")
      XCTAssertEqual(decoded.conditions[0].params, .object(["kind": .string("url")]))
      XCTAssertEqual(decoded.actions.count, 1)
      XCTAssertEqual(decoded.actions[0].provider, "builtin.openURL")
      XCTAssertNil(decoded.actions[0].shortcut)
    }
  }
  ```

  > **Note:** This test file will not compile until Part 5 of the atomic swap is complete, because `ProviderRegistry`, `BuiltinProviders`, `FirstPartyProviders`, `PluginInput`, `ActionOutcome`, and the new `RuleCondition`/`ActionConfig`/`ActionRule` shapes do not exist yet. Register it in pbxproj now so no manual step is forgotten when the code lands.

- [ ] **Step 0.2: Register `ActionEngineRegistryTests.swift` in `project.pbxproj` (test target)**

  Generate two UUIDs:
  ```sh
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # → <FR_UUID>
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # → <BF_UUID>
  ```

  Make four edits to `/Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj/project.pbxproj`:

  **(1) Add a `PBXBuildFile` entry** (in the `/* Begin PBXBuildFile section */` block):
  ```
  <BF_UUID> /* ActionEngineRegistryTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <FR_UUID> /* ActionEngineRegistryTests.swift */; };
  ```

  **(2) Add a `PBXFileReference` entry** (in the `/* Begin PBXFileReference section */` block):
  ```
  <FR_UUID> /* ActionEngineRegistryTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MaccyTests/ActionEngineRegistryTests.swift; sourceTree = "<group>"; };
  ```

  **(3) Add `<FR_UUID>` to the MaccyTests PBXGroup children** (the group with `path = MaccyTests;`):
  ```
  <FR_UUID> /* ActionEngineRegistryTests.swift */,
  ```

  **(4) Add `<BF_UUID>` to the `DA360DAC1E3DF137005C6F6B /* Sources */` build phase `files` array**:
  ```
  <BF_UUID> /* ActionEngineRegistryTests.swift in Sources */,
  ```

---

#### Part 1 — ActionRule.swift schema region replacement

- [ ] **Step 1.1: Replace `ActionRule.swift` with the new provider-id schema**

  Replace the entire file `/Users/roypadina/Code/Padina/Maccay/Maccy/Actions/ActionRule.swift` with the following complete content. `ValueKind` is defined in `ValueKind.swift` and is not restated. `MatchMode` is kept verbatim. `WebSearchTemplate` is kept. `ActionType` and `TransformKind` are deleted (their logic moves to `BuiltinProviders`/`FirstPartyProviders`).

  ```swift
  import AppKit
  import Defaults
  import Foundation

  // MatchMode: unchanged contract.
  enum MatchMode: String, Codable, CaseIterable, Identifiable {
    case all // AND
    case any // OR

    var id: String { rawValue }
    var label: String { self == .all ? "Match ALL conditions" : "Match ANY condition" }
  }

  // A single condition referencing a provider by id.
  struct RuleCondition: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var provider: String                 // e.g. "builtin.kind", "com.maccay.soft-wrap"
    var params: JSONValue = .object([:])
  }

  // Persisted configuration for one action within a rule.
  struct ActionConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var provider: String                 // e.g. "builtin.openURL", "com.maccay.unwrap"
    var params: JSONValue = .object([:])
    var shortcut: String?                // per-action keyboard shortcut, e.g. "cmd+shift+u"

    // Display name for a bundle id. Retained from the pre-swap ActionConfig
    // because the GUI (TerminalAppsEditor / app picker, Part 5) still calls it.
    static func appName(for bundleID: String) -> String {
      if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        return url.deletingPathExtension().lastPathComponent
      }
      return bundleID
    }
  }

  // A user-defined rule: when its conditions match, its (ordered) actions become
  // available. The first action is the default.
  struct ActionRule: Codable, Identifiable, Hashable, Defaults.Serializable {
    var id: UUID = UUID()
    var schemaVersion: Int = 3
    var name: String = "New rule"
    var enabled: Bool = true
    var matchMode: MatchMode = .all
    var conditions: [RuleCondition] = []
    var actions: [ActionConfig] = []
    var autoRunDefault: Bool = false

    static let presets: [ActionRule] = [
      // Open links — kind == url → openURL or webSearch
      ActionRule(
        name: "Open links",
        conditions: [
          RuleCondition(
            provider: "builtin.kind",
            params: .object(["kind": .string("url")])
          )
        ],
        actions: [
          ActionConfig(
            provider: "builtin.openURL",
            params: .emptyObject
          ),
          ActionConfig(
            provider: "builtin.webSearch",
            params: .object(["template": .string(WebSearchTemplate.google)])
          )
        ]
      ),

      // Email address — kind == email → openURL (opens mailto:)
      ActionRule(
        name: "Email address",
        conditions: [
          RuleCondition(
            provider: "builtin.kind",
            params: .object(["kind": .string("email")])
          )
        ],
        actions: [
          ActionConfig(
            provider: "builtin.openURL",
            params: .emptyObject
          )
        ]
      ),

      // Search selected text — kind == text → webSearch
      ActionRule(
        name: "Search selected text",
        conditions: [
          RuleCondition(
            provider: "builtin.kind",
            params: .object(["kind": .string("text")])
          )
        ],
        actions: [
          ActionConfig(
            provider: "builtin.webSearch",
            params: .object(["template": .string(WebSearchTemplate.google)])
          )
        ]
      ),

      // Unwrap terminal command — terminal-source AND soft-wrap → unwrap (auto-run)
      ActionRule(
        name: "Unwrap terminal command",
        matchMode: .all,
        conditions: [
          RuleCondition(
            provider: "com.maccay.terminal-source",
            params: .emptyObject
          ),
          RuleCondition(
            provider: "com.maccay.soft-wrap",
            params: .emptyObject
          )
        ],
        actions: [
          ActionConfig(
            provider: "com.maccay.unwrap",
            params: .emptyObject
          )
        ],
        autoRunDefault: true
      )
    ]
  }

  enum WebSearchTemplate {
    static let google = "https://www.google.com/search?q={query}"
  }
  ```

  > `JSONValue` and `.emptyObject` are defined in `PluginCore.swift` (Task A1). `ActionRule.swift` does not need to import anything additional beyond `Defaults` and `Foundation`; `JSONValue` is in the same module.

---

#### Part 2 — ClipboardAction.swift reduction

- [ ] **Step 2.1: Reduce `ClipboardAction.swift` to only `ActionError` and `makeURL`**

  Replace the entire file `/Users/roypadina/Code/Padina/Maccay/Maccy/Actions/ClipboardAction.swift` with the following complete content. The `ClipboardAction` protocol, all concrete conformers (`OpenURLAction`, `OpenInAppAction`, `WebSearchAction`, `TransformAction`, `RunShortcutAction`), and `ActionFactory` are deleted. Their logic has moved to `BuiltinProviders.swift` and `FirstPartyProviders.swift` (Tasks A3 and A4). `ActionError` and `makeURL` are kept verbatim because `BuiltinProviders.swift` references them.

  ```swift
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
  ```

  > The `import AppKit` is no longer needed; `Foundation` suffices for `URL`/`Error`. The deleted conformers referenced `AppKit` (`NSWorkspace`) — that dependency moves into `BuiltinProviders.swift`.


#### Part 3 — ActionEngine.swift (registry dispatch)

> Atomic-swap part A5b. These steps rewrite `Maccy/Actions/ActionEngine.swift` so every condition/action flows through `ProviderRegistry.shared` instead of the deleted `RuleCondition`/`ActionType`/`TransformKind` enums + `ActionFactory`. The file references the new `ActionRule` schema (Part 1/A5a) and the new providers (A3 `BuiltinProviders`, A4 `FirstPartyProviders`). It will **not** compile until every part of the atomic swap (schema, engine, CLI, GUI) is in place — there is **no per-step build/test/commit here**. The single build+test checkpoint and the one swap commit happen at **Part 5**.

- [ ] **Step A5b-1: Rename the Defaults key string `"actionRules"` → `"actionRulesV3"` (keep the `.actionRules` symbol and `ActionRule.presets` default).**

  In `Maccy/Actions/ActionEngine.swift`, the top `extension Defaults.Keys` block currently reads:

  ```swift
  extension Defaults.Keys {
    static let actionRules = Key<[ActionRule]>("actionRules", default: ActionRule.presets)
    static let terminalAppBundleIDs = Key<[String]>("terminalAppBundleIDs", default: TerminalApps.defaults)
  }
  ```

  Change **only** the key-name string (symbol `.actionRules` and the `ActionRule.presets` default both stay; this is the hard-cut migration — old `"actionRules"` data is abandoned). New block:

  ```swift
  extension Defaults.Keys {
    static let actionRules = Key<[ActionRule]>("actionRulesV3", default: ActionRule.presets)
    static let terminalAppBundleIDs = Key<[String]>("terminalAppBundleIDs", default: TerminalApps.defaults)
  }
  ```

  Every reader/writer keeps using `Defaults[.actionRules]` unchanged — only the backing UserDefaults key string moved to `"actionRulesV3"`.

  _(Do not build/test/commit yet — Part 5 checkpoint.)_

- [ ] **Step A5b-2: Register providers once at engine init (guard against double-registration).**

  The current `private init() {}` (line 33) does nothing. Replace it so the engine registers the A3 built-ins and A4 first-party providers into `ProviderRegistry.shared` exactly once. Add a private flag so a second `init` (or a second `registerProviders()` call) is a no-op — `ProviderRegistry.register(...)` overwrites by id, but the guard keeps boot idempotent and avoids redundant work if the singleton is ever re-created in tests.

  Replace this:

  ```swift
    private init() {}
  ```

  with:

  ```swift
    // Set once the built-in + first-party providers have been registered, so a
    // second init (or an explicit registerProviders() call) is a cheap no-op.
    private var providersRegistered = false

    private init() {
      registerProviders()
    }

    // Idempotently register the native built-in and first-party providers into
    // the shared registry. Built-ins: builtin.kind/regex/contains/sourceApp +
    // builtin.openURL/openInApp/webSearch/runShortcut. First-party:
    // com.maccay.soft-wrap/terminal-source + the six transform actions.
    func registerProviders() {
      guard !providersRegistered else { return }
      providersRegistered = true
      BuiltinProviders.registerBuiltins(into: .shared)
      FirstPartyProviders.registerFirstParty(into: .shared)
    }
  ```

  This relies on the A3/A4 contract entry points `BuiltinProviders.registerBuiltins(into: ProviderRegistry)` and `FirstPartyProviders.registerFirstParty(into: ProviderRegistry)`, and on `ProviderRegistry.shared` being `@MainActor` (the engine is already `@MainActor`, so `.shared` resolves with no hop).

  _(Do not build/test/commit yet — Part 5 checkpoint.)_

- [ ] **Step A5b-3: Add `makeInput(from:)` to build a `PluginInput` from a `HistoryItem`.**

  Add this private helper. It is the single place every dispatch path turns a `HistoryItem` into the `PluginInput` value the providers consume. Insert it just below the `var rules` computed property (after line 35, before `// MARK: Matching`):

  ```swift
    // Build the provider input for an item from the same primitives the old
    // switch used: primary string, all matching ValueKinds, the source app
    // bundle id, and the file URLs (for openInApp / filePath providers).
    private func makeInput(from item: HistoryItem) -> PluginInput {
      PluginInput(
        string: ValueClassifier.primaryString(of: item),
        kinds: ValueClassifier.kinds(of: item),
        sourceAppBundleID: item.application,
        fileURLs: item.fileURLs
      )
    }
  ```

  (Field order matches the canonical `PluginInput` memberwise init: `string`, `kinds`, `sourceAppBundleID`, `fileURLs`.)

  _(Do not build/test/commit yet — Part 5 checkpoint.)_

- [ ] **Step A5b-4: Rewrite `matches(...)` to evaluate conditions through the registry.**

  The old `matches(_:kinds:text:app:)` switched over the deleted `RuleCondition` enum. Replace the whole method (lines 46–71) with a registry-backed version that takes the `PluginInput` directly. Each condition resolves its provider by `cond.provider`; a missing provider (`nil`) and a thrown error (`try?` → `nil`) both collapse to `false`; the per-condition `Bool`s compose by `matchMode` exactly as before (`.all` → none false; `.any` → at least one true); empty conditions still return `false`.

  Replace this entire method:

  ```swift
    private func matches(_ rule: ActionRule, kinds: Set<ValueKind>, text: String, app: String?) -> Bool {
      guard !rule.conditions.isEmpty else { return false }

      let results = rule.conditions.map { condition -> Bool in
        switch condition {
        case .kind(let kind):
          return kinds.contains(kind)
        case .sourceApp(let bundle):
          return app == bundle
        case .contains(let needle):
          return !needle.isEmpty && text.localizedCaseInsensitiveContains(needle)
        case .regex(let pattern):
          guard !pattern.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
          }
          let range = NSRange(text.startIndex..., in: text)
          return regex.firstMatch(in: text, range: range) != nil
        case .softWrapped:
          return TextUnwrap.isSoftWrapped(text)
        case .terminalSource:
          return app.map { Defaults[.terminalAppBundleIDs].contains($0) } ?? false
        }
      }

      return rule.matchMode == .all ? !results.contains(false) : results.contains(true)
    }
  ```

  with:

  ```swift
    private func matches(_ rule: ActionRule, input: PluginInput) -> Bool {
      guard !rule.conditions.isEmpty else { return false }

      let results = rule.conditions.map { cond -> Bool in
        guard let provider = ProviderRegistry.shared.condition(cond.provider) else {
          return false
        }
        return (try? provider.evaluate(input, params: cond.params)) ?? false
      }

      return rule.matchMode == .all ? !results.contains(false) : results.contains(true)
    }
  ```

  Because the signature changed, update the **only** caller, `matchingRules(for:)` (lines 39–44). Replace it:

  ```swift
    func matchingRules(for item: HistoryItem) -> [ActionRule] {
      let kinds = ValueClassifier.kinds(of: item)
      let text = ValueClassifier.primaryString(of: item)
      let app = item.application
      return rules.filter { $0.enabled && matches($0, kinds: kinds, text: text, app: app) }
    }
  ```

  with:

  ```swift
    func matchingRules(for item: HistoryItem) -> [ActionRule] {
      let input = makeInput(from: item)
      return rules.filter { $0.enabled && matches($0, input: input) }
    }
  ```

  _(Do not build/test/commit yet — Part 5 checkpoint.)_

- [ ] **Step A5b-5: Delete the `ClipboardAction`-based resolution + run helpers and add registry-based run/replace handling.**

  The old `resolvedActions(for:)`, `defaultAction(for:)`, `run(_:on:)`, and `runDefault(for:)` all trafficked in the deleted `ClipboardAction` protocol and `ActionFactory`. They are removed; their callers (`runDefaultActionForCurrent`, `runSpecificActionForCurrent`, `handleNewCopy`) are rewritten in the next steps to resolve `ActionProvider`s by id and run them. Delete this whole block (lines 73–113):

  ```swift
    // MARK: Resolution

    // All runnable actions for an item, in rule order then action order, deduped.
    // The first element is the default action.
    func resolvedActions(for item: HistoryItem) -> [ClipboardAction] {
      var seen = Set<String>()
      var result: [ClipboardAction] = []
      for rule in matchingRules(for: item) {
        for config in rule.actions {
          guard let action = ActionFactory.make(config), action.canRun(on: item) else { continue }
          if seen.insert(action.id).inserted {
            result.append(action)
          }
        }
      }
      return result
    }

    func defaultAction(for item: HistoryItem) -> ClipboardAction? {
      resolvedActions(for: item).first
    }

    // MARK: Running

    func run(_ action: ClipboardAction, on item: HistoryItem) {
      Task {
        do {
          try await action.run(on: item)
        } catch {
          NSSound.beep()
        }
      }
    }

    func runDefault(for item: HistoryItem) {
      guard let action = defaultAction(for: item) else {
        NSSound.beep()
        return
      }
      run(action, on: item)
    }
  ```

  and replace it with a single registry-based runner that resolves an `ActionProvider` by id, runs it inside the existing `Task{}` / `NSSound.beep()` error handling, and routes a `.replace(let s)` outcome through `noteAutoOutput(s)` **before** `Clipboard.shared.copy(s)` (this preserves the loop-guard ordering the old `TransformAction.run` relied on):

  ```swift
    // MARK: Running

    // Resolve `providerID` to an ActionProvider and run it on `input`. Mirrors the
    // old run(_:on:): a detached MainActor Task, any throw swallowed with a beep.
    // A `.replace(s)` outcome is the auto-transform path — note it as the expected
    // echo (loop guard) BEFORE writing the clipboard, exactly like the old
    // TransformAction did. `.sideEffect` / `.none` write nothing.
    private func runProvider(_ providerID: String, params: JSONValue, input: PluginInput) {
      guard let provider = ProviderRegistry.shared.action(providerID) else {
        NSSound.beep()
        return
      }
      Task {
        do {
          let outcome = try await provider.run(input, params: params)
          switch outcome {
          case .replace(let value):
            ActionEngine.shared.noteAutoOutput(value)
            Clipboard.shared.copy(value)
          case .sideEffect, .none:
            break
          }
        } catch {
          NSSound.beep()
        }
      }
    }
  ```

  _(Do not build/test/commit yet — Part 5 checkpoint.)_

- [ ] **Step A5b-6: Rewrite `runDefaultActionForCurrent()` to resolve+run the first action of the first matching rule for the current item.**

  The global-shortcut entry point previously went through `runDefault(for:)` → `defaultAction(for:)`. Rewrite it to fetch the current clipboard item the **same way the real code does** (`History.shared.unpinnedItems.first?.item ?? History.shared.all.first?.item`), build the `PluginInput`, take the first action of the first matching rule, and dispatch it via `runProvider`. Beep if there is no current item or no runnable default.

  Replace this (lines 115–122):

  ```swift
    // Global-shortcut entry point: run the default action on the most recent item.
    func runDefaultActionForCurrent() {
      guard let item = History.shared.unpinnedItems.first?.item ?? History.shared.all.first?.item else {
        NSSound.beep()
        return
      }
      runDefault(for: item)
    }
  ```

  with:

  ```swift
    // Global-shortcut entry point: run the default action on the most recent item.
    // The default action is the first action of the first matching (enabled) rule.
    func runDefaultActionForCurrent() {
      guard let item = History.shared.unpinnedItems.first?.item ?? History.shared.all.first?.item else {
        NSSound.beep()
        return
      }
      let input = makeInput(from: item)
      guard let rule = matchingRules(for: item).first,
            let config = rule.actions.first else {
        NSSound.beep()
        return
      }
      runProvider(config.provider, params: config.params, input: input)
    }
  ```

  _(Do not build/test/commit yet — Part 5 checkpoint.)_

- [ ] **Step A5b-7: Rewrite `runSpecificActionForCurrent(actionID:)` to resolve+run one specific action via the registry.**

  The per-action-hotkey entry point previously looked up the `ActionConfig` by id, built a `ClipboardAction` via `ActionFactory`, and checked `canRun`. Rewrite it to find the `ActionConfig` by id, fetch the current item the same way (`History.shared.unpinnedItems.first?.item ?? History.shared.all.first?.item`), and dispatch via `runProvider` (no rule matching, no auto-run gate — unchanged semantics). There is no `canRun` precheck anymore; a provider that cannot act returns `.none`/`.sideEffect` or throws, and `runProvider` handles both (a throw beeps).

  Replace this (lines 158–169):

  ```swift
    // Per-action-shortcut entry point: run one specific action unconditionally on
    // the most recent item. No rule matching, no priority, no auto-run gate.
    func runSpecificActionForCurrent(actionID: UUID) {
      guard let config = Defaults[.actionRules].flatMap(\.actions).first(where: { $0.id == actionID }),
            let action = ActionFactory.make(config),
            let item = History.shared.unpinnedItems.first?.item ?? History.shared.all.first?.item,
            action.canRun(on: item) else {
        NSSound.beep()
        return
      }
      run(action, on: item)
    }
  ```

  with:

  ```swift
    // Per-action-shortcut entry point: run one specific action unconditionally on
    // the most recent item. No rule matching, no priority, no auto-run gate.
    func runSpecificActionForCurrent(actionID: UUID) {
      guard let config = Defaults[.actionRules].flatMap(\.actions).first(where: { $0.id == actionID }),
            let item = History.shared.unpinnedItems.first?.item ?? History.shared.all.first?.item else {
        NSSound.beep()
        return
      }
      let input = makeInput(from: item)
      runProvider(config.provider, params: config.params, input: input)
    }
  ```

  _(Do not build/test/commit yet — Part 5 checkpoint.)_

- [ ] **Step A5b-8: Rewrite `handleNewCopy(_:)` preserving the `fromMaccy` skip + `lastAutoOutput` echo guard EXACTLY, resolving the first auto-run rule's first action through the registry.**

  The auto-run path must keep its two guards byte-for-byte: (1) `guard !item.fromMaccy else { return }`, and (2) the `lastAutoOutput == text` echo guard that clears `lastAutoOutput` to `nil` and returns. Only the dispatch tail changes: instead of `ActionFactory.make` + `canRun` + `run(action, on:)`, take the first matching `autoRunDefault` rule's first `ActionConfig` and dispatch it via `runProvider` (which, on a `.replace`, calls `noteAutoOutput` then `Clipboard.copy` — closing the loop with the echo guard above). Still only the first matching auto-run rule, then `break`.

  Replace this (lines 173–195):

  ```swift
    func handleNewCopy(_ item: HistoryItem) {
      // Skip anything Maccy itself put on the clipboard (e.g. selecting an item to
      // paste it). Without this, pasting a URL would auto-open it and steal focus
      // from the paste target instead of pasting.
      guard !item.fromMaccy else { return }

      let text = ValueClassifier.primaryString(of: item)

      // Swallow the echo of a value we just produced via an auto transform
      // (Clipboard.copy(string) doesn't set the fromMaccy marker).
      if let last = lastAutoOutput, last == text {
        lastAutoOutput = nil
        return
      }

      for rule in matchingRules(for: item) where rule.autoRunDefault {
        guard let config = rule.actions.first,
              let action = ActionFactory.make(config),
              action.canRun(on: item) else { continue }
        run(action, on: item)
        break // only the first matching auto-run rule
      }
    }
  ```

  with:

  ```swift
    func handleNewCopy(_ item: HistoryItem) {
      // Skip anything Maccy itself put on the clipboard (e.g. selecting an item to
      // paste it). Without this, pasting a URL would auto-open it and steal focus
      // from the paste target instead of pasting.
      guard !item.fromMaccy else { return }

      let text = ValueClassifier.primaryString(of: item)

      // Swallow the echo of a value we just produced via an auto transform
      // (Clipboard.copy(string) doesn't set the fromMaccy marker).
      if let last = lastAutoOutput, last == text {
        lastAutoOutput = nil
        return
      }

      let input = makeInput(from: item)
      for rule in matchingRules(for: item) where rule.autoRunDefault {
        guard let config = rule.actions.first else { continue }
        runProvider(config.provider, params: config.params, input: input)
        break // only the first matching auto-run rule
      }
    }
  ```

  Notes: `runProvider` is the single dispatch path, so the `.replace` → `noteAutoOutput(value)` → `Clipboard.shared.copy(value)` ordering is identical to the old `TransformAction.run`; the next clipboard-change callback hits the echo guard above and returns early, breaking the transform loop exactly as before.

  _(Do not build/test/commit yet — Part 5 checkpoint.)_

- [ ] **Step A5b-9: Confirm `registerShortcuts()`, `reloadRules()`, and `noteAutoOutput(_:)` still compile unchanged against the new schema.**

  These three members are **not edited** — they already only touch fields that survive the schema swap. Reproduced here so the engineer can confirm they compile against the new `ActionConfig` (which still has `id: UUID` and `shortcut: String?`, per Part 1/A5a) and against `Defaults[.actionRules]` (now backed by key `"actionRulesV3"`):

  ```swift
    func registerShortcuts() {
      for rule in Defaults[.actionRules] {
        for config in rule.actions {
          let name = KeyboardShortcuts.Name("action_\(config.id.uuidString)")
          if let spec = config.shortcut, let parsed = ShortcutSpec.parse(spec) {
            KeyboardShortcuts.setShortcut(parsed, for: name)
          } else {
            KeyboardShortcuts.setShortcut(nil, for: name)
          }
          if registeredActionShortcutNames.insert(name.rawValue).inserted {
            let actionID = config.id
            KeyboardShortcuts.onKeyDown(for: name) {
              ActionEngine.shared.runSpecificActionForCurrent(actionID: actionID)
            }
          }
        }
      }
    }

    func reloadRules() {
      CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
      registerShortcuts()
    }

    func noteAutoOutput(_ value: String) {
      lastAutoOutput = value
    }
  ```

  `registerShortcuts()` reads `config.id` (still `UUID`) and `config.shortcut` (still `String?`) — both retained in the new `ActionConfig`, so it is untouched. `runSpecificActionForCurrent(actionID:)` (Step A5b-7) keeps the same `(actionID: UUID)` signature the `onKeyDown` closure calls. `noteAutoOutput` is now called from `runProvider` on the `.replace` path (Step A5b-5) instead of from the deleted `TransformAction`.

  _(Do not build/test/commit yet — Part 5 checkpoint. The full file should now compile against A3/A4/A5a; the build+test+single swap commit happens at Part 5.)_

---

End-of-part summary for the integrator. After A5b the full `ActionEngine.swift` consists of: the `extension Defaults.Keys` block with key string `"actionRulesV3"`; the unchanged `extension KeyboardShortcuts.Name`; and the `ActionEngine` class with members in this order — `lastAutoOutput`, `registeredActionShortcutNames`, `providersRegistered`, `init()` + `registerProviders()`, `var rules`, `makeInput(from:)`, `matchingRules(for:)`, `matches(_:input:)`, `runProvider(_:params:input:)`, `runDefaultActionForCurrent()`, `registerShortcuts()`, `reloadRules()`, `runSpecificActionForCurrent(actionID:)`, `handleNewCopy(_:)`, `noteAutoOutput(_:)`. No `ClipboardAction`/`ActionFactory`/`resolvedActions`/`defaultAction`/`run(_:on:)`/`runDefault(for:)` references remain. Real source touched: `/Users/roypadina/Code/Padina/Maccay/Maccy/Actions/ActionEngine.swift`. No new `.swift` file is created in this part, so no pbxproj edits are needed here.


#### Part 4 — ActionsCLI.swift

> **Context (do not skip).** Part 4 is one slice of the A5 atomic swap. It does **not** build or commit on its own — `ActionsCLI.swift` references the new-shape `ActionRule`/`ActionConfig`/`RuleCondition` (Part 1), `ProviderRegistry`/`ProviderDescriptor` (Tasks A2/A1), and `BuiltinProviders`/`FirstPartyProviders` (Tasks A3/A4). Apply the edits below, then proceed to the rest of A5; the single build+test+commit checkpoint is Part 5. Each step shows the **complete** new body of the function(s) it touches plus enough surrounding context to locate the edit.
>
> The real file is `/Users/roypadina/Code/Padina/Maccay/Maccy/Actions/ActionsCLI.swift`. It is an `enum ActionsCLI` with `static` members; it imports `Defaults` and `Foundation`. It deliberately never touches `ActionEngine.shared` (that would spin up the `@MainActor` GUI singleton). The registry, however, **is** `@MainActor`, so the registration + describe steps must hop onto the main actor synchronously (`MainActor.assumeIsolated`) — the CLI process has no run loop, so this is safe and matches the `AppDelegate` reload pattern already used in the codebase.

- [ ] **Step 4.1: Register native providers at CLI start (before any `describe`/`validate`/decode reads the registry).**

  The CLI must populate `ProviderRegistry.shared` with the native providers so `rulesDescribe()` (Step 4.2) and any registry-driven validation can see them. In **Milestone A** only the two native registrars exist — `BuiltinProviders.registerBuiltins(into:)` (Task A3) and `FirstPartyProviders.registerFirstParty(into:)` (Task A4). **`PluginLoader.loadAll` does NOT exist yet in Milestone A** — do **not** call it here. (Milestones B and C add a `PluginLoader.loadAll(into:extraFolders:)` call to this same `registerProviders()` helper so the CLI's `describe` catalog also includes folder-loaded plugins; that line is added in those milestones, not now.)

  Add a `registerProviders()` helper and call it once at the top of `run(_:)`, before dispatch. Because `ProviderRegistry` is `@MainActor`, both the registration and the describe path run inside `MainActor.assumeIsolated`.

  Replace the existing `run(_:)` entry point (currently lines 17–27):

  ```swift
  // In the current file:
  //
  //   static func run(_ args: [String]) -> Int32 {
  //     guard let namespace = args.first else {
  //       return fail("Missing command. Expected 'rules' or 'terminals'.")
  //     }
  //     let rest = Array(args.dropFirst())
  //     switch namespace {
  //     case "rules": return runRules(rest)
  //     case "terminals": return runTerminals(rest)
  //     default: return fail("Unknown command: \(namespace). Expected 'rules' or 'terminals'.")
  //     }
  //   }
  ```

  with:

  ```swift
  static func run(_ args: [String]) -> Int32 {
    // Populate the provider registry before any sub-command runs: `describe`
    // emits the registry catalog, and rule decode/validate reference provider
    // ids. Native providers only in Milestone A (no PluginLoader yet).
    registerProviders()

    guard let namespace = args.first else {
      return fail("Missing command. Expected 'rules' or 'terminals'.")
    }
    let rest = Array(args.dropFirst())
    switch namespace {
    case "rules": return runRules(rest)
    case "terminals": return runTerminals(rest)
    default: return fail("Unknown command: \(namespace). Expected 'rules' or 'terminals'.")
    }
  }

  // Register the native condition/action providers into the shared registry so
  // the headless CLI's `describe` catalog (and any registry-backed validation)
  // matches the running app. `ProviderRegistry` is @MainActor; the CLI has no
  // run loop, so we enter the actor synchronously (same pattern AppDelegate uses
  // for the distributed-notification reload).
  //
  // Milestone A: native providers only. Milestones B/C add a
  // `PluginLoader.loadAll(into:extraFolders:)` call here so the CLI catalog also
  // includes folder-loaded plugins.
  private static func registerProviders() {
    MainActor.assumeIsolated {
      BuiltinProviders.registerBuiltins(into: .shared)
      FirstPartyProviders.registerFirstParty(into: .shared)
    }
  }
  ```

  > **Note for the engineer.** `ProviderRegistry.register(...)` must be idempotent-safe for the CLI (one process = one `run` call, so a single registration pass is enough). The exact `registerBuiltins(into:)` / `registerFirstParty(into:)` signatures come from Tasks A3/A4; they take a `ProviderRegistry` and register the canonical ids `builtin.kind/regex/contains/sourceApp`, `builtin.openURL/openInApp/webSearch/runShortcut`, `com.maccay.soft-wrap/terminal-source`, and `com.maccay.trim/uppercase/lowercase/strip-formatting/unwrap/fix-keyboard-layout`.

- [ ] **Step 4.2: Rewrite `rulesDescribe()` to emit the registry-derived catalog.**

  The catalog is now built from `ProviderRegistry.shared.descriptors()` instead of the deleted `ActionType`/`TransformKind` enums and the hardcoded condition array. It splits descriptors by `kind` into `conditionProviders` and `actionProviders`, each an array of `{"id","name","description","engine","params":[{"key","label","kind"}],"capabilities":[...],"verified":Bool}`. It keeps `valueKinds` and `matchModes` (now sourced from `ValueKind.allCases` / `MatchMode.allCases`), and reproduces the **unchanged** `shortcutGrammar`, `actionShortcutNote`, and `defaultTerminalApps` entries verbatim from the current file. The describe path reads the registry, so it runs inside `MainActor.assumeIsolated`; the existing `emitJSONObject(_:)` helper does the actual serialization (`[.prettyPrinted, .sortedKeys]`).

  Replace the entire current `rulesDescribe()` (lines 159–209) with:

  ```swift
  private static func rulesDescribe() -> Int32 {
    // Built from the LIVE provider registry so the catalog can't drift from the
    // installed providers. `ProviderRegistry` is @MainActor; enter synchronously
    // (the CLI has no run loop). `registerProviders()` ran in `run(_:)` first.
    let catalog: [String: Any] = MainActor.assumeIsolated {
      func encode(_ descriptors: [ProviderDescriptor]) -> [[String: Any]] {
        descriptors.map { descriptor -> [String: Any] in
          [
            "id": descriptor.id,
            "name": descriptor.name,
            "description": descriptor.description,
            "engine": descriptor.engine.rawValue,
            "params": descriptor.params.map { spec -> [String: Any] in
              [
                "key": spec.key,
                "label": spec.label,
                "kind": spec.kind.rawValue
              ]
            },
            "capabilities": descriptor.capabilities.map(\.rawValue),
            "verified": descriptor.isVerified
          ]
        }
      }

      let conditionProviders = encode(ProviderRegistry.shared.descriptors(kind: .condition))
      let actionProviders = encode(ProviderRegistry.shared.descriptors(kind: .action))

      return [
        "conditionProviders": conditionProviders,
        "actionProviders": actionProviders,
        "valueKinds": ValueKind.allCases.map(\.rawValue),
        "matchModes": MatchMode.allCases.map(\.rawValue),
        "shortcutGrammar": [
          "modifiers": [
            "cmd": ["cmd", "command", "⌘"],
            "shift": ["shift", "⇧"],
            "opt": ["opt", "option", "alt", "⌥"],
            "ctrl": ["ctrl", "control", "⌃"]
          ],
          "keys": [
            "letters a-z, digits 0-9",
            "space", "return/enter", "tab", "escape/esc",
            "delete/backspace", "f1-f12"
          ],
          "format": "modifiers and key joined by '+', case-insensitive",
          "example": "cmd+shift+u"
        ],
        "actionShortcutNote": "Optional per-action 'shortcut' field (e.g. \"cmd+shift+u\") " +
                              "runs that action unconditionally on the most recent clip.",
        "defaultTerminalApps": TerminalApps.defaults
      ]
    }

    return emitJSONObject(catalog)
  }
  ```

  > **Why these exact keys.** The GUI pickers, tooltips, and `rules describe` all derive from `ProviderRegistry.descriptors()` (plan Architecture). `descriptors(kind:)` already returns the list sorted by name (Interface Contract), so the catalog arrays are stably ordered without extra sorting. `engine.rawValue` is one of `native`/`declarative`/`javascript`; `spec.kind.rawValue` is one of `text`/`valueKind`/`bundleID`; each capability `rawValue` is one of `network`/`fileRead`/`fileWrite`/`storage`. `isVerified` is `descriptor.source.isVerified` (true for builtin/bundled/official). `shortcutGrammar`, `actionShortcutNote`, and `defaultTerminalApps` are copied byte-for-byte from the pre-swap file.

- [ ] **Step 4.3: Update `decodeRule(overlaying:)` for the new `{provider, params}` schema.**

  The overlay/default-fill mechanism is **structurally unchanged** — it still encodes a fresh `ActionRule()` and `ActionConfig()` to get default-value maps (because Swift's synthesized `Codable` does not apply property defaults for missing JSON keys), still special-cases the `"actions"` key, still auto-generates missing UUIDs, and still round-trips merged-map → `Data` → `JSONDecoder().decode(ActionRule.self)`. What changes is purely the **shape of the defaults** that fall out of encoding the new structs: a default `ActionConfig()` now encodes to `{"id": "<uuid>", "provider": "builtin.openURL", "params": {}}` (plus a `null`/absent `shortcut`), and a default `ActionRule()` now carries `schemaVersion`, `conditions` as `[{provider, params}]`, etc. Because `provider` and `params` are ordinary stored properties, they flow through the existing per-key merge with no special handling — an overlay action like `{"provider":"com.maccay.unwrap","params":{}}` merges straight onto the base action map, and a partial action like `{"provider":"builtin.webSearch"}` inherits the default `params` (`{}`) from `baseAction`.

  The function body therefore stays the same; the only edits are the comment (so it describes the new schema) and an added safety check that an overlaid `actions` element supplies a `provider`-shaped object. Replace the current `decodeRule(overlaying:)` (lines 310–342) with:

  ```swift
  // Overlay a partial rule object onto the encoded defaults, then decode. The new
  // schema is `{provider, params}`: a default `ActionConfig()` encodes to
  // {"id": …, "provider": "builtin.openURL", "params": {}} and a default
  // `ActionRule()` to {…, "schemaVersion": 3, "conditions": [], "actions": []}.
  // `provider` and `params` are ordinary stored properties, so they merge through
  // the generic per-key overlay with no special-casing — only the "actions" array
  // (whose elements overlay onto a default ActionConfig) is handled specially.
  // Fresh ids are generated for the rule and any action that omitted one.
  private static func decodeRule(overlaying overlay: [String: Any]) throws -> ActionRule {
    let baseRule = try jsonObject(of: ActionRule())
    let baseAction = try jsonObject(of: ActionConfig())

    var merged = baseRule
    let suppliesID = overlay["id"] != nil
    for (key, value) in overlay where key != "actions" {
      merged[key] = value
    }
    if !suppliesID { merged["id"] = UUID().uuidString }

    if let actions = overlay["actions"] {
      guard let actionObjects = actions as? [[String: Any]] else {
        throw CLIError("Rule 'actions' must be a JSON array of action objects.")
      }
      merged["actions"] = actionObjects.map { action -> [String: Any] in
        var m = baseAction
        let actionHasID = action["id"] != nil
        for (key, value) in action { m[key] = value }
        if !actionHasID { m["id"] = UUID().uuidString }
        return m
      }
    }

    let data = try JSONSerialization.data(withJSONObject: merged)
    do {
      return try JSONDecoder().decode(ActionRule.self, from: data)
    } catch {
      throw CLIError("Invalid rule: \(describe(error))")
    }
  }
  ```

  > **Why `normalizedRule(from:forcingID:)` and `jsonObject(of:)` are unchanged.** `normalizedRule` only manipulates the top-level `id` key and delegates to `decodeRule`; it has no knowledge of the action shape, so it needs no edit. `jsonObject(of:)` is a generic `Encodable` → `[String:Any]` round-trip and is schema-agnostic. The `"id"`-drop-on-`forcingID` behavior (line 296, used by `update`) still works because `id` is still a top-level key of the new `ActionRule`.
  >
  > **Note on `validate(_:)` (out of scope for this part, flagged for the rest of A5).** The pre-swap `validate(_:)` (lines 355–389) switches over the deleted `ActionType` enum and pattern-matches the deleted `RuleCondition` cases (`if case .regex(let pattern) = condition`). It will not compile against the new schema and **must be rewritten as part of the A5 swap** (it should validate `action.shortcut` parsing via `ShortcutSpec.parse`, confirm `action.provider`/`condition.provider` resolve in `ProviderRegistry.shared`, and drop the old per-`ActionType` required-field checks in favor of `ParamSpec`-driven checks). It is rewritten in **Step 4.4** below so the Part 5 build has the code to apply.

- [ ] **Step 4.4: Rewrite `validate(_:)` for the new schema (replaces the pre-swap version, ActionsCLI.swift ~355–389).**
  The old `validate(_:)` switches over the deleted `ActionType` and pattern-matches deleted `RuleCondition` cases, so it will not compile. Providers are registered at CLI start (Step 4.1), so registry lookups are populated. Replace the whole function with:

  ```swift
  // Validates a rule before any write: provider ids must resolve in the registry,
  // and any per-action shortcut must parse. ParamSpec-level checks are the
  // provider's concern at run time, so no per-type required-field checks remain.
  private static func validate(_ rule: ActionRule) throws {
    for condition in rule.conditions {
      guard ProviderRegistry.shared.condition(condition.provider) != nil else {
        throw CLIError("Invalid rule: unknown condition provider \"\(condition.provider)\"")
      }
    }
    for action in rule.actions {
      guard ProviderRegistry.shared.action(action.provider) != nil else {
        throw CLIError("Invalid rule: unknown action provider \"\(action.provider)\"")
      }
      if let spec = action.shortcut, ShortcutSpec.parse(spec) == nil {
        throw CLIError("Invalid rule: unparseable shortcut \"\(spec)\"")
      }
    }
  }
  ```

Relevant file (single source touched by this part): `/Users/roypadina/Code/Padina/Maccay/Maccy/Actions/ActionsCLI.swift`. No standalone build/test/commit in Part 4 — the combined A5 checkpoint runs at Part 5 with `xcodebuild test -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj -scheme Maccy -destination 'platform=macOS' -only-testing:MaccyTests`.


#### Part 5 — ActionsSettingsPane.swift (project compiles after this)

> This is the last edit of the atomic swap (Task A5d). It rewrites the condition/action editing UI so every picker is driven by `ProviderRegistry.shared.descriptors(kind:)` and every param editor is driven by `ParamSpec`. Parts A5a (`ActionRule` schema + presets), A5b (`ActionEngine` registry dispatch + `ClipboardAction`/`ActionFactory` deletion), and A5c (`ActionsCLI`) have already landed in the working tree but the project does **not** compile yet — `ActionsSettingsPane.swift` still references the deleted `ActionType` / `TransformKind` / `RuleCondition`-enum symbols. This part removes those references; **the build is expected to fail until this whole file is replaced**, then pass. There is exactly one build+test checkpoint and one commit at the end of this part.
>
> No new `.swift` file is created here (this file is already registered in `project.pbxproj`), so there are no pbxproj edits in Part 5.

- [ ] **Step 1: Confirm the build currently fails on the un-swapped GUI (baseline RED).**
  Run the full unit-test command from Global Constraints. It is expected to FAIL at compile time, in `ActionsSettingsPane.swift`, on the now-deleted symbols (`ActionType`, `TransformKind`, `ActionConfig(type:)`, `.kind(.url)`, the `RuleCondition` enum cases, etc.). This confirms Parts A5a–A5c are in place and that this file is the only remaining un-swapped consumer.
  ```sh
  xcodebuild test -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj -scheme Maccy -destination 'platform=macOS' -only-testing:MaccyTests
  ```
  Expected: **FAIL** — compile errors confined to `Maccy/Settings/ActionsSettingsPane.swift` (e.g. `cannot find 'ActionType' in scope`, `incorrect argument label in call (have 'type:', expected ...)`, `type 'RuleCondition' has no member 'kind'`). If errors appear in other files, stop — a prior A5 part is incomplete; do not proceed.

- [ ] **Step 2: Replace `Maccy/Settings/ActionsSettingsPane.swift` in full (registry-driven editing UI).**
  Paste the ENTIRE new file below. It:
  - keeps `@Default(.actionRules)` (the key string changed to `actionRulesV3` in A5a; the `.actionRules` accessor name is unchanged), the sidebar, `selectedBinding`, the `autoRunDefault` Toggle, the global `runDefaultAction` Recorder, the per-action `KeyboardShortcuts.Recorder`, `syncRecorder()`, `TerminalAppsEditor`, and `AppPicker`;
  - deletes the private `CondType` enum, `typeBinding`, `kindBinding`, `stringBinding`, the `ActionType`/`TransformKind` pickers, and the old `bundleBinding`/`templateBinding`/`transformBinding`/`shortcutBinding`;
  - rewrites `addRule()`, the "Add condition"/"Add action" buttons, `ConditionRow`, and `ActionRow` to use provider ids + `ParamSpec`;
  - adds the shared `paramEditor(_:)` `@ViewBuilder` and the `stringParam`/`valueKindParam` `JSONValue` binding helpers (one copy in `ConditionRow`, one in `ActionRow`, since SwiftUI rows are separate types — kept identical).

  ```swift
  import Defaults
  import KeyboardShortcuts
  import SwiftUI
  import UniformTypeIdentifiers

  struct ActionsSettingsPane: View {
    @Default(.actionRules) private var rules
    @State private var selection: ActionRule.ID?
    @State private var showingTerminalApps = false

    var body: some View {
      HStack(spacing: 0) {
        sidebar
        Divider()
        detail
      }
      .frame(width: 760, height: 520)
      .sheet(isPresented: $showingTerminalApps) {
        TerminalAppsEditor()
      }
    }

    private var sidebar: some View {
      VStack(spacing: 0) {
        List(selection: $selection) {
          ForEach(rules) { rule in
            HStack {
              Image(systemName: rule.enabled ? "circle.fill" : "circle")
                .font(.system(size: 7))
                .foregroundStyle(rule.enabled ? Color.accentColor : Color.secondary)
              Text(rule.name).lineLimit(1)
            }
            .tag(rule.id)
          }
          .onMove { from, to in rules.move(fromOffsets: from, toOffset: to) }
        }
        Divider()
        HStack(spacing: 4) {
          Button(action: addRule) { Image(systemName: "plus") }
          Button(action: removeSelected) { Image(systemName: "minus") }
            .disabled(selection == nil)
          Spacer()
          Button("Terminal apps…") { showingTerminalApps = true }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .padding(6)
      }
      .frame(width: 220)
    }

    @ViewBuilder
    private var detail: some View {
      if let binding = selectedBinding {
        RuleEditor(rule: binding)
          .id(binding.wrappedValue.id)
      } else {
        VStack(spacing: 8) {
          Image(systemName: "bolt.badge.clock")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
          Text("Select a rule, or add one.")
            .foregroundStyle(.secondary)
          Text("""
          Actions run on clipboard values that match a rule — from the popup's \
          right-click menu, a global shortcut, or automatically on copy.
          """)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }

    private var selectedBinding: Binding<ActionRule>? {
      guard let id = selection, let index = rules.firstIndex(where: { $0.id == id }) else {
        return nil
      }
      return Binding(
        get: { rules[index] },
        set: { rules[index] = $0 }
      )
    }

    private func addRule() {
      var rule = ActionRule()
      rule.conditions = [RuleCondition(provider: "builtin.kind")]
      rule.actions = [ActionConfig(provider: "builtin.openURL")]
      rules.append(rule)
      selection = rule.id
    }

    private func removeSelected() {
      guard let id = selection else { return }
      rules.removeAll { $0.id == id }
      selection = nil
    }
  }

  // MARK: - Rule editor

  private struct RuleEditor: View {
    @Binding var rule: ActionRule

    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            TextField("Rule name", text: $rule.name)
              .textFieldStyle(.roundedBorder)
            Toggle("Enabled", isOn: $rule.enabled)
          }

          conditionsBox
          actionsBox

          Toggle(
            "Run the default action automatically when a matching value is copied",
            isOn: $rule.autoRunDefault
          )

          Divider()

          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text("Global shortcut for default action:")
              KeyboardShortcuts.Recorder(for: .runDefaultAction)
              Spacer()
            }
            Text("Runs the first matching rule's default action on the most recently copied item.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(20)
      }
    }

    private var conditionsBox: some View {
      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          Picker("", selection: $rule.matchMode) {
            ForEach(MatchMode.allCases) { Text($0.label).tag($0) }
          }
          .pickerStyle(.segmented)
          .labelsHidden()

          ForEach($rule.conditions) { $condition in
            ConditionRow(condition: $condition) {
              rule.conditions.removeAll { $0.id == condition.id }
            }
          }

          Button {
            rule.conditions.append(RuleCondition(provider: "builtin.kind"))
          } label: {
            Label("Add condition", systemImage: "plus")
          }
          .buttonStyle(.borderless)
        }
        .padding(6)
      } label: {
        Text("Conditions").font(.headline)
      }
    }

    private var actionsBox: some View {
      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          if rule.actions.isEmpty {
            Text("No actions yet.").foregroundStyle(.secondary)
          }

          ForEach(rule.actions.indices, id: \.self) { index in
            ActionRow(
              action: $rule.actions[index],
              isDefault: index == 0,
              onMakeDefault: { moveActionToFront(rule.actions[index].id) },
              onDelete: { deleteAction(rule.actions[index].id) }
            )
            if index < rule.actions.count - 1 {
              Divider()
            }
          }

          Button {
            rule.actions.append(ActionConfig(provider: "builtin.openURL"))
          } label: {
            Label("Add action", systemImage: "plus")
          }
          .buttonStyle(.borderless)
        }
        .padding(6)
      } label: {
        Text("Actions  (top = default)").font(.headline)
      }
    }

    private func moveActionToFront(_ id: ActionConfig.ID) {
      guard let index = rule.actions.firstIndex(where: { $0.id == id }) else { return }
      let item = rule.actions.remove(at: index)
      rule.actions.insert(item, at: 0)
    }

    private func deleteAction(_ id: ActionConfig.ID) {
      rule.actions.removeAll { $0.id == id }
    }
  }

  // MARK: - Condition row

  private struct ConditionRow: View {
    @Binding var condition: RuleCondition
    var onDelete: () -> Void
    @State private var showingLongHelp = false

    private var descriptors: [ProviderDescriptor] {
      ProviderRegistry.shared.descriptors(kind: .condition)
    }

    private var selectedDescriptor: ProviderDescriptor? {
      descriptors.first { $0.id == condition.provider }
    }

    var body: some View {
      HStack(alignment: .top) {
        Picker("", selection: $condition.provider) {
          ForEach(descriptors) { d in
            Text(d.name).tag(d.id)
          }
        }
        .labelsHidden()
        .frame(width: 160)
        .help(selectedDescriptor?.description ?? "")
        .onChange(of: condition.provider) { _, _ in
          condition.params = .object([:])
        }

        if let d = selectedDescriptor, let longHelp = d.longHelp {
          Button {
            showingLongHelp.toggle()
          } label: {
            Image(systemName: "info.circle")
          }
          .buttonStyle(.borderless)
          .popover(isPresented: $showingLongHelp) {
            Text(longHelp)
              .padding()
              .frame(maxWidth: 320)
          }
        }

        if let d = selectedDescriptor {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(d.params) { spec in
              paramEditor(spec)
            }
          }
        }

        Spacer(minLength: 0)

        Button(action: onDelete) { Image(systemName: "trash") }
          .buttonStyle(.borderless)
      }
    }

    @ViewBuilder
    private func paramEditor(_ spec: ParamSpec) -> some View {
      switch spec.kind {
      case .text:
        TextField(spec.placeholder ?? spec.label, text: stringParam($condition.params, spec.key))
          .textFieldStyle(.roundedBorder)
      case .valueKind:
        Picker("", selection: valueKindParam($condition.params, spec.key)) {
          ForEach(ValueKind.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden()
      case .bundleID:
        HStack {
          TextField(spec.placeholder ?? spec.label, text: stringParam($condition.params, spec.key))
            .textFieldStyle(.roundedBorder)
          Button("Choose…") {
            if let id = AppPicker.choose() {
              stringParam($condition.params, spec.key).wrappedValue = id
            }
          }
        }
      }
    }

    private func stringParam(_ params: Binding<JSONValue>, _ key: String) -> Binding<String> {
      Binding(
        get: { params.wrappedValue[key]?.stringValue ?? "" },
        set: { newValue in
          var object = params.wrappedValue.objectValue ?? [:]
          object[key] = .string(newValue)
          params.wrappedValue = .object(object)
        }
      )
    }

    private func valueKindParam(_ params: Binding<JSONValue>, _ key: String) -> Binding<ValueKind> {
      Binding(
        get: {
          if let raw = params.wrappedValue[key]?.stringValue, let kind = ValueKind(rawValue: raw) {
            return kind
          }
          return .url
        },
        set: { newValue in
          var object = params.wrappedValue.objectValue ?? [:]
          object[key] = .string(newValue.rawValue)
          params.wrappedValue = .object(object)
        }
      )
    }
  }

  // MARK: - Action row

  private struct ActionRow: View {
    @Binding var action: ActionConfig
    var isDefault: Bool
    var onMakeDefault: () -> Void
    var onDelete: () -> Void
    @State private var showingLongHelp = false

    private var shortcutName: KeyboardShortcuts.Name {
      KeyboardShortcuts.Name("action_\(action.id.uuidString)")
    }

    private var descriptors: [ProviderDescriptor] {
      ProviderRegistry.shared.descriptors(kind: .action)
    }

    private var selectedDescriptor: ProviderDescriptor? {
      descriptors.first { $0.id == action.provider }
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          if isDefault {
            Text("DEFAULT")
              .font(.caption2).bold()
              .padding(.horizontal, 5).padding(.vertical, 1)
              .background(Color.accentColor.opacity(0.2), in: Capsule())
          }
          Picker("", selection: $action.provider) {
            ForEach(descriptors) { d in
              Text(d.name).tag(d.id)
            }
          }
          .labelsHidden()
          .frame(width: 200)
          .help(selectedDescriptor?.description ?? "")
          .onChange(of: action.provider) { _, _ in
            action.params = .object([:])
          }

          if let d = selectedDescriptor, let longHelp = d.longHelp {
            Button {
              showingLongHelp.toggle()
            } label: {
              Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showingLongHelp) {
              Text(longHelp)
                .padding()
                .frame(maxWidth: 320)
            }
          }

          Spacer()

          if !isDefault {
            Button("Make default", action: onMakeDefault)
              .buttonStyle(.borderless)
              .font(.caption)
          }
          Button(action: onDelete) { Image(systemName: "trash") }
            .buttonStyle(.borderless)
        }

        if let d = selectedDescriptor {
          ForEach(d.params) { spec in
            paramEditor(spec)
          }
        }

        shortcutRow
      }
      .onAppear { syncRecorder() }
    }

    private var shortcutRow: some View {
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text("Shortcut:")
          KeyboardShortcuts.Recorder(for: shortcutName) { newShortcut in
            action.shortcut = newShortcut.flatMap(ShortcutSpec.format)
            ActionEngine.shared.registerShortcuts()
          }
        }
        Text("Runs this action on the current clip, regardless of rules.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }

    // Push the stored spec into the KeyboardShortcuts store so a freshly opened
    // editor displays the saved value. registerShortcuts() already does this at
    // launch; this just reflects current state for this action's Recorder.
    private func syncRecorder() {
      if let spec = action.shortcut, let parsed = ShortcutSpec.parse(spec) {
        KeyboardShortcuts.setShortcut(parsed, for: shortcutName)
      } else {
        KeyboardShortcuts.setShortcut(nil, for: shortcutName)
      }
    }

    @ViewBuilder
    private func paramEditor(_ spec: ParamSpec) -> some View {
      switch spec.kind {
      case .text:
        TextField(spec.placeholder ?? spec.label, text: stringParam($action.params, spec.key))
          .textFieldStyle(.roundedBorder)
      case .valueKind:
        Picker("", selection: valueKindParam($action.params, spec.key)) {
          ForEach(ValueKind.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden()
      case .bundleID:
        HStack {
          TextField(spec.placeholder ?? spec.label, text: stringParam($action.params, spec.key))
            .textFieldStyle(.roundedBorder)
          Button("Choose…") {
            if let id = AppPicker.choose() {
              stringParam($action.params, spec.key).wrappedValue = id
            }
          }
        }
      }
    }

    private func stringParam(_ params: Binding<JSONValue>, _ key: String) -> Binding<String> {
      Binding(
        get: { params.wrappedValue[key]?.stringValue ?? "" },
        set: { newValue in
          var object = params.wrappedValue.objectValue ?? [:]
          object[key] = .string(newValue)
          params.wrappedValue = .object(object)
        }
      )
    }

    private func valueKindParam(_ params: Binding<JSONValue>, _ key: String) -> Binding<ValueKind> {
      Binding(
        get: {
          if let raw = params.wrappedValue[key]?.stringValue, let kind = ValueKind(rawValue: raw) {
            return kind
          }
          return .url
        },
        set: { newValue in
          var object = params.wrappedValue.objectValue ?? [:]
          object[key] = .string(newValue.rawValue)
          params.wrappedValue = .object(object)
        }
      )
    }
  }

  // MARK: - Terminal apps editor

  private struct TerminalAppsEditor: View {
    @Default(.terminalAppBundleIDs) private var bundleIDs
    @Environment(\.dismiss) private var dismiss

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        Text("Terminal apps").font(.headline)
        Text("Copies from these apps count as coming from a terminal (the “From terminal” condition).")
          .font(.caption)
          .foregroundStyle(.secondary)

        List {
          if bundleIDs.isEmpty {
            Text("No terminal apps configured.").foregroundStyle(.secondary)
          }
          ForEach(bundleIDs, id: \.self) { bundleID in
            HStack {
              Text(ActionConfig.appName(for: bundleID))
              Spacer()
              Button(action: { bundleIDs.removeAll { $0 == bundleID } }) {
                Image(systemName: "trash")
              }
              .buttonStyle(.borderless)
            }
          }
        }
        .frame(height: 220)

        HStack {
          Button {
            if let id = AppPicker.choose(), !bundleIDs.contains(id) {
              bundleIDs.append(id)
            }
          } label: {
            Label("Add…", systemImage: "plus")
          }
          Button("Reset to defaults") { bundleIDs = TerminalApps.defaults }
          Spacer()
          Button("Done") { dismiss() }
            .keyboardShortcut(.defaultAction)
        }
      }
      .padding(20)
      .frame(width: 420)
    }
  }

  // MARK: - App picker

  enum AppPicker {
    @MainActor
    static func choose() -> String? {
      let panel = NSOpenPanel()
      panel.allowedContentTypes = [.application]
      panel.allowsMultipleSelection = false
      panel.canChooseDirectories = false
      panel.canChooseFiles = true
      panel.directoryURL = URL(fileURLWithPath: "/Applications")
      guard panel.runModal() == .OK,
            let url = panel.url,
            let bundle = Bundle(url: url),
            let id = bundle.bundleIdentifier else {
        return nil
      }
      return id
    }
  }
  ```

  > Notes the engineer must honor while pasting:
  > - `ActionConfig.appName(for:)` is referenced by `TerminalAppsEditor`. A5a (Part 1) retains it as a static display helper on the new `ActionConfig` and adds `import AppKit` for `NSWorkspace` — so this call site compiles unchanged.
  > - `ProviderRegistry.shared.descriptors(kind:)` is `@MainActor`; `ConditionRow`/`ActionRow`/`ActionsSettingsPane` are SwiftUI `View`s (already main-actor-isolated in this codebase), so the `.shared` access compiles without extra annotation.
  > - The `.onChange(of:) { _, _ in }` two-parameter closure is the current-macOS signature already used elsewhere in this project; if the project's deployment target predates it, switch to the single-parameter `.onChange(of:) { _ in }` form — do not change anything else.
  > - `paramEditor`/`stringParam`/`valueKindParam` are intentionally duplicated in both `ConditionRow` and `ActionRow` (separate `View` types bound to different `params` keypaths). Keeping them identical is deliberate; do not try to share via a protocol in this part.

- [ ] **Step 2b: Fix the pre-existing `MaccyTests/KeyboardLayoutTests.swift` (it references the deleted `TransformKind`).**
  The shipping `testTransformKindRegistered` asserts `TransformKind.allCases.contains(.fixKeyboardLayout)` and `TransformKind.fixKeyboardLayout.label`. `TransformKind` is deleted by A5 Part 1, so the `MaccyTests` target will not compile at the checkpoint below. Replace ONLY that test method (leave `testEnglishKeystrokesToHebrew` untouched) with a registry-based check:

  ```swift
  // Was: asserted TransformKind.allCases — the layout fixer is now a registry provider.
  @MainActor
  func testFixKeyboardLayoutProviderRegistered() {
    ProviderRegistry.shared.reset()
    BuiltinProviders.registerBuiltins(into: .shared)
    FirstPartyProviders.registerFirstParty(into: .shared)
    let provider = ProviderRegistry.shared.action("com.maccay.fix-keyboard-layout")
    XCTAssertNotNil(provider)
    XCTAssertEqual(provider?.descriptor.id, "com.maccay.fix-keyboard-layout")
  }
  ```
  No pbxproj change (`KeyboardLayoutTests.swift` is already registered in the test target).

- [ ] **Step 3: Build + run the FULL unit-test suite (GREEN checkpoint for the entire atomic swap).**
  This is the single verification gate for Task A5. Run the exact command from Global Constraints:
  ```sh
  xcodebuild test -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj -scheme Maccy -destination 'platform=macOS' -only-testing:MaccyTests
  ```
  Expected: **build succeeds** and **all `MaccyTests` pass** — both the pre-existing `KeyboardLayoutTests` (`testEnglishKeystrokesToHebrew`, and the registry-rewritten `testTransformKindRegistered` / its A5 replacement) and the new `ActionEngineRegistryTests` added earlier in A5. `** TEST SUCCEEDED **` must appear. If anything fails, fix forward (do not commit a red tree); compile errors at this point are almost certainly a typo in the pasted file or a leftover reference to a deleted symbol — grep the file for `ActionType`, `TransformKind`, `CondType`, `.kind(`, `.transform`, `searchTemplate`, `appBundleID`, `shortcutName` to confirm none remain.

- [ ] **Step 4: Commit the atomic swap.**
  Stage everything changed across A5a–A5d (schema, engine, deleted `ClipboardAction.swift` conformers/`ActionFactory`, CLI, this GUI file, and the renamed Defaults key) and make ONE commit. This is the only commit for Task A5.
  ```sh
  git -C /Users/roypadina/Code/Padina/Maccay add -A
  git -C /Users/roypadina/Code/Padina/Maccay commit -m "feat(plugins): registry-backed conditions/actions (atomic swap)

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Tkhip6qSb9uiFxwiJQbcKX"
  ```
  Expected: commit created on `feat/plugin-system`. Do NOT push (net-new push needs explicit owner approval per Global Constraints).

---

Authored markdown for Part 5 returned above. Real file replaced is `/Users/roypadina/Code/Padina/Maccay/Maccy/Settings/ActionsSettingsPane.swift`. No new `.swift` files and therefore no pbxproj edits in this part. The single build+test checkpoint uses the verbatim Global-Constraints command and the one commit message `feat(plugins): registry-backed conditions/actions (atomic swap)`.


## Milestone B — Plugin loading + engines

### Task B1: PluginManifest + validation

**Pre-condition:** Tasks A1–A4 (PluginCore, ProviderRegistry, BuiltinProviders, FirstPartyProviders) are
committed. `Maccy/Plugins/` exists on disk and the Plugins files from A1–A4 are already in the pbxproj
under the flat `DAEE38451E3DBEB100DD2966 /* Maccy */` group with `path = Plugins/FileName.swift`.

**What this task delivers:**
- `Maccy/Plugins/PluginManifest.swift` — `struct PluginManifest: Codable, Hashable` with nested `Author`,
  `enum PluginManifestError`, `validate()`, and `descriptor(source:) -> ProviderDescriptor`.
- `MaccyTests/PluginManifestTests.swift` — XCTest suite covering every validation rule and the descriptor
  projection.
- Two pbxproj registrations (one app file, one test file).

---

- [ ] **Step 1: Write `Maccy/Plugins/PluginManifest.swift` (the failing-test target)**

  Create the file at `Maccy/Plugins/PluginManifest.swift` with this exact content:

  ```swift
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
  ```

---

- [ ] **Step 2: Register `PluginManifest.swift` in the pbxproj (app target)**

  Generate two UUIDs:
  ```sh
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # → fileRef UUID, e.g. B1MANFST000000000000FR01
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # → buildFile UUID, e.g. B1MANFST000000000000BF01
  ```

  In `Maccy.xcodeproj/project.pbxproj`, make these four edits (substitute your generated UUIDs):

  **Edit 1 — add a `PBXBuildFile` entry** (anywhere in the `/* Begin PBXBuildFile section */` block):
  ```
  B1MANFST000000000000BF01 /* PluginManifest.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1MANFST000000000000FR01 /* PluginManifest.swift */; };
  ```

  **Edit 2 — add a `PBXFileReference` entry** (anywhere in the `/* Begin PBXFileReference section */` block):
  ```
  B1MANFST000000000000FR01 /* PluginManifest.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Plugins/PluginManifest.swift; sourceTree = "<group>"; };
  ```

  **Edit 3 — add the fileRef to the `DAEE38451E3DBEB100DD2966 /* Maccy */` group's `children` array**
  (alongside the other `Plugins/` file refs already added in A1):
  ```
  B1MANFST000000000000FR01 /* PluginManifest.swift */,
  ```

  **Edit 4 — add the buildFile to the `DAEE383F1E3DBEB100DD2966 /* Sources */` build phase `files` array**:
  ```
  B1MANFST000000000000BF01 /* PluginManifest.swift in Sources */,
  ```

---

- [ ] **Step 3: Write `MaccyTests/PluginManifestTests.swift` (failing tests)**

  Create the file at `MaccyTests/PluginManifestTests.swift` with this exact content:

  ```swift
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
  ```

---

- [ ] **Step 4: Verify tests FAIL before implementation is added to the build**

  The tests reference `PluginManifest`, `PluginManifestError`, `ProviderDescriptor`, `ProviderKind`,
  `ProviderEngine`, `ProviderSource`, `Capability`, `ParamSpec` — all of which come from A1 (`PluginCore`)
  plus the new `PluginManifest.swift`. At this point `PluginManifest.swift` is on disk but NOT yet in the
  pbxproj, so the build will fail with "cannot find type 'PluginManifest' in scope". That is the expected
  failing state.

  Expected result: **build error** (not a test failure) because `PluginManifest` is not compiled yet.

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests/PluginManifestTests \
    2>&1 | tail -20
  ```

---

- [ ] **Step 5: Register `PluginManifestTests.swift` in the pbxproj (test target)**

  Generate two UUIDs:
  ```sh
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # → fileRef UUID, e.g. B1MANFST000000000000FR02
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # → buildFile UUID, e.g. B1MANFST000000000000BF02
  ```

  In `Maccy.xcodeproj/project.pbxproj`, make these four edits:

  **Edit 1 — add a `PBXBuildFile` entry** (in the `/* Begin PBXBuildFile section */` block):
  ```
  B1MANFST000000000000BF02 /* PluginManifestTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1MANFST000000000000FR02 /* PluginManifestTests.swift */; };
  ```

  **Edit 2 — add a `PBXFileReference` entry** (in the `/* Begin PBXFileReference section */` block):
  ```
  B1MANFST000000000000FR02 /* PluginManifestTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MaccyTests/PluginManifestTests.swift; sourceTree = "<group>"; };
  ```

  **Edit 3 — add the fileRef to the MaccyTests PBXGroup's `children` array**
  (the group with `path = MaccyTests;`, currently containing `ClipboardTests.swift`,
  `KeyboardLayoutTests.swift`, etc.):
  ```
  B1MANFST000000000000FR02 /* PluginManifestTests.swift */,
  ```

  **Edit 4 — add the buildFile to the `DA360DAC1E3DF137005C6F6B /* Sources */` build phase `files` array**
  (the MaccyTests build phase):
  ```
  B1MANFST000000000000BF02 /* PluginManifestTests.swift in Sources */,
  ```

---

- [ ] **Step 6: Complete pbxproj registration for `PluginManifest.swift` (Step 2) and run tests — expect PASS**

  After both pbxproj registrations are complete (Steps 2 and 5), run the test class:

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests/PluginManifestTests \
    2>&1 | grep -E 'TEST|PASS|FAIL|error:|Build succeeded|Build FAILED'
  ```

  **Expected:** `Build succeeded` followed by all 19 test methods reporting `passed`.
  Any `FAIL` or `error:` lines indicate a mistake in the implementation or the JSON literals.

---

- [ ] **Step 7: Run the full unit test suite to confirm no regressions**

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests \
    2>&1 | grep -E 'TEST|PASS|FAIL|error:|Build succeeded|Build FAILED'
  ```

  **Expected:** `Build succeeded`, zero `FAIL` lines, all pre-existing tests still pass.

---

- [ ] **Step 8: Commit**

  ```sh
  git add \
    Maccy/Plugins/PluginManifest.swift \
    MaccyTests/PluginManifestTests.swift \
    Maccy.xcodeproj/project.pbxproj

  git commit -m "B1: PluginManifest — struct, validate(), descriptor(source:), + tests"
  ```


---

### Task B2: DeclarativeEngine

> **Depends on:** A1 (PluginCore — `JSONValue`, `PluginInput`, `ActionOutcome`, `ProviderDescriptor`, `ProviderSource`, `ConditionProvider`, `ActionProvider`), A2 (`ProviderRegistry`), B1 (`PluginManifest` + `descriptor(source:)`). All already compiled and registered in pbxproj.
>
> **Deliverable:** `Maccy/Plugins/DeclarativeEngine.swift` — `DeclarativeActionProvider` (transform-op fold over `input.string`), `DeclarativeConditionProvider` (predicate-tree evaluator), `DeclarativeError`, and `static func makeProviders(manifest:source:)`. Plus `MaccyTests/DeclarativeEngineTests.swift`.
>
> **Test command (from Global Constraints):**
> ```sh
> xcodebuild test -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj -scheme Maccy -destination 'platform=macOS' -only-testing:MaccyTests
> ```
> Scope to this class while iterating with `-only-testing:MaccyTests/DeclarativeEngineTests`.

- [ ] **Step 1: Create the failing test file `MaccyTests/DeclarativeEngineTests.swift`**

  Write the complete test file. It exercises the action transform fold (`regexReplace`, `case` upper/lower, `trim`, `prepend`, `append`, op chaining, unknown-op throw) and the condition predicate tree (`regex`, `contains`, `kind`, `sourceApp` leaves; `all`/`any`/`not` nodes, nesting, bad-spec throw), plus `makeProviders(manifest:source:)` end-to-end. `ConditionProvider`/`ActionProvider` are `@MainActor` protocols, so every test method that touches a provider is `@MainActor`. `run(...)` is `async throws`, so action tests are `async`.

  ```swift
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

    // MARK: - makeProviders(manifest:source:)

    @MainActor
    func testMakeProvidersBuildsAction() async throws {
      let manifest = PluginManifest(
        id: "com.test.base64ish",
        name: "Wrap Brackets",
        version: "1.0.0",
        author: nil,
        description: "Wraps text in brackets",
        longHelp: nil,
        kind: .action,
        engine: .declarative,
        params: nil,
        entry: nil,
        capabilities: nil,
        minAppVersion: nil,
        declarative: .object(["transform": .array([
          .object(["op": .string("prepend"), "text": .string("[")]),
          .object(["op": .string("append"), "text": .string("]")])
        ])])
      )
      let (conditions, actions) = DeclarativeEngine.makeProviders(manifest: manifest, source: .bundled)
      XCTAssertTrue(conditions.isEmpty)
      XCTAssertEqual(actions.count, 1)
      XCTAssertEqual(actions.first?.descriptor.id, "com.test.base64ish")
      let outcome = try await actions[0].run(makeInput("x"), params: .emptyObject)
      XCTAssertEqual(outcome, .replace("[x]"))
    }

    @MainActor
    func testMakeProvidersBuildsCondition() throws {
      let manifest = PluginManifest(
        id: "com.test.isurl",
        name: "Is URL",
        version: "1.0.0",
        author: nil,
        description: "True when the text looks like a URL",
        longHelp: nil,
        kind: .condition,
        engine: .declarative,
        params: nil,
        entry: nil,
        capabilities: nil,
        minAppVersion: nil,
        declarative: .object(["predicate": .object(["regex": .string("^https?://")])])
      )
      let (conditions, actions) = DeclarativeEngine.makeProviders(manifest: manifest, source: .bundled)
      XCTAssertTrue(actions.isEmpty)
      XCTAssertEqual(conditions.count, 1)
      XCTAssertEqual(conditions.first?.descriptor.id, "com.test.isurl")
      XCTAssertTrue(try conditions[0].evaluate(makeInput("https://x.com"), params: .emptyObject))
      XCTAssertFalse(try conditions[0].evaluate(makeInput("not a url"), params: .emptyObject))
    }

    @MainActor
    func testMakeProvidersWithNilDeclarativeReturnsEmpty() {
      let manifest = PluginManifest(
        id: "com.test.broken",
        name: "Broken",
        version: "1.0.0",
        author: nil,
        description: "No declarative spec",
        longHelp: nil,
        kind: .action,
        engine: .declarative,
        params: nil,
        entry: nil,
        capabilities: nil,
        minAppVersion: nil,
        declarative: nil
      )
      let (conditions, actions) = DeclarativeEngine.makeProviders(manifest: manifest, source: .bundled)
      XCTAssertTrue(conditions.isEmpty)
      XCTAssertTrue(actions.isEmpty)
    }
  }
  ```

  > Note: the `PluginManifest(...)` memberwise initializer arguments above mirror the canonical B1 struct field order (`id, name, version, author, description, longHelp, kind, engine, params, entry, capabilities, minAppVersion, declarative`). If B1's synthesized init differs, fix the call sites here, not the contract.

- [ ] **Step 2: Register the test file in pbxproj (4 entries — MaccyTests group + test build phase)**

  Generate two fresh UUIDs:
  ```sh
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # -> fileRef_UUID (call it TFR)
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # -> buildFile_UUID (call it TBF)
  ```

  (1) Add a `PBXBuildFile` line in the `/* Begin PBXBuildFile section */` block:
  ```
  <TBF> /* DeclarativeEngineTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <TFR> /* DeclarativeEngineTests.swift */; };
  ```

  (2) Add a `PBXFileReference` line in the `/* Begin PBXFileReference section */` block:
  ```
  <TFR> /* DeclarativeEngineTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MaccyTests/DeclarativeEngineTests.swift; sourceTree = "<group>"; };
  ```

  (3) Insert `<TFR>` into the MaccyTests `PBXGroup` `children` (the group with `path = MaccyTests;`), next to the other test file refs:
  ```
  <TFR> /* DeclarativeEngineTests.swift */,
  ```

  (4) Insert `<TBF>` into the MaccyTests `PBXSourcesBuildPhase` (`DA360DAC1E3DF137005C6F6B /* Sources */`) `files` array:
  ```
  <TBF> /* DeclarativeEngineTests.swift in Sources */,
  ```

- [ ] **Step 3: Run the test — expect a BUILD FAILURE (symbols not yet defined)**

  ```sh
  xcodebuild test -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj -scheme Maccy -destination 'platform=macOS' -only-testing:MaccyTests/DeclarativeEngineTests
  ```
  Expected: build fails — `cannot find 'DeclarativeActionProvider' in scope`, `cannot find 'DeclarativeConditionProvider' in scope`, `cannot find 'DeclarativeError' in scope`, `cannot find 'DeclarativeEngine' in scope`. This confirms the test is wired in and compiled (the failure is missing implementation, not a missing test file).

- [ ] **Step 4: Create the implementation `Maccy/Plugins/DeclarativeEngine.swift`**

  Write the complete file. `DeclarativeActionProvider` folds the `transform` op list over `input.string`; unknown `op` throws `.unknownOp`, malformed spec throws `.badSpec`. `DeclarativeConditionProvider` walks the `predicate` tree recursively; an unrecognized leaf/node shape throws `.badSpec`. `regexReplace` uses `NSRegularExpression` with an NSRange spanning the whole string and `stringByReplacingMatches` (template supports `$1` capture refs). The predicate `regex` leaf uses `firstMatch` for membership; `contains` is case-insensitive via `localizedCaseInsensitiveContains`; `kind` parses the string into a `ValueKind` and checks `input.kinds`; `sourceApp` compares `input.sourceAppBundleID`. `makeProviders` reads `manifest.declarative` and the manifest's `descriptor(source:)`, returning one provider on the matching side.

  ```swift
  import Foundation

  enum DeclarativeError: Error, Equatable {
    case unknownOp(String)
    case badSpec
  }

  // MARK: - Action provider (transform-op fold)

  struct DeclarativeActionProvider: ActionProvider {
    let descriptor: ProviderDescriptor
    let spec: JSONValue   // { "transform": [ { "op": ... }, ... ] }

    func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome {
      guard let ops = spec["transform"]?.arrayValue else {
        throw DeclarativeError.badSpec
      }
      var current = input.string
      for op in ops {
        current = try Self.apply(op, to: current)
      }
      return .replace(current)
    }

    private static func apply(_ op: JSONValue, to text: String) throws -> String {
      guard let name = op["op"]?.stringValue else {
        throw DeclarativeError.badSpec
      }
      switch name {
      case "regexReplace":
        guard let pattern = op["pattern"]?.stringValue,
              let replacement = op["replacement"]?.stringValue else {
          throw DeclarativeError.badSpec
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
          throw DeclarativeError.badSpec
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
          in: text, range: range, withTemplate: replacement
        )

      case "case":
        guard let value = op["value"]?.stringValue else {
          throw DeclarativeError.badSpec
        }
        switch value {
        case "upper": return text.uppercased()
        case "lower": return text.lowercased()
        default:      throw DeclarativeError.badSpec
        }

      case "trim":
        return text.trimmingCharacters(in: .whitespacesAndNewlines)

      case "prepend":
        guard let prefix = op["text"]?.stringValue else {
          throw DeclarativeError.badSpec
        }
        return prefix + text

      case "append":
        guard let suffix = op["text"]?.stringValue else {
          throw DeclarativeError.badSpec
        }
        return text + suffix

      default:
        throw DeclarativeError.unknownOp(name)
      }
    }
  }

  // MARK: - Condition provider (predicate-tree evaluator)

  struct DeclarativeConditionProvider: ConditionProvider {
    let descriptor: ProviderDescriptor
    let spec: JSONValue   // { "predicate": <tree> }

    func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool {
      guard let predicate = spec["predicate"] else {
        throw DeclarativeError.badSpec
      }
      return try Self.eval(predicate, input: input)
    }

    private static func eval(_ node: JSONValue, input: PluginInput) throws -> Bool {
      guard let object = node.objectValue else {
        throw DeclarativeError.badSpec
      }

      // Logical nodes.
      if let children = object["all"]?.arrayValue {
        for child in children where try !eval(child, input: input) {
          return false
        }
        return true
      }
      if let children = object["any"]?.arrayValue {
        for child in children where try eval(child, input: input) {
          return true
        }
        return false
      }
      if let child = object["not"] {
        return try !eval(child, input: input)
      }

      // Leaves.
      if let pattern = object["regex"]?.stringValue {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
          throw DeclarativeError.badSpec
        }
        let range = NSRange(input.string.startIndex..., in: input.string)
        return regex.firstMatch(in: input.string, range: range) != nil
      }
      if let needle = object["contains"]?.stringValue {
        return !needle.isEmpty && input.string.localizedCaseInsensitiveContains(needle)
      }
      if let rawKind = object["kind"]?.stringValue {
        guard let kind = ValueKind(rawValue: rawKind) else {
          throw DeclarativeError.badSpec
        }
        return input.kinds.contains(kind)
      }
      if let bundleID = object["sourceApp"]?.stringValue {
        return input.sourceAppBundleID == bundleID
      }

      throw DeclarativeError.badSpec
    }
  }

  // MARK: - Factory

  enum DeclarativeEngine {
    /// Builds the declarative provider(s) declared by a manifest.
    /// Returns one provider on the side matching `manifest.kind`; empty if the
    /// manifest carries no `declarative` spec.
    static func makeProviders(
      manifest: PluginManifest,
      source: ProviderSource
    ) -> (conditions: [ConditionProvider], actions: [ActionProvider]) {
      guard let spec = manifest.declarative else {
        return (conditions: [], actions: [])
      }
      let descriptor = manifest.descriptor(source: source)
      switch manifest.kind {
      case .condition:
        let provider = DeclarativeConditionProvider(descriptor: descriptor, spec: spec)
        return (conditions: [provider], actions: [])
      case .action:
        let provider = DeclarativeActionProvider(descriptor: descriptor, spec: spec)
        return (conditions: [], actions: [provider])
      }
    }
  }
  ```

  > `DeclarativeActionProvider` and `DeclarativeConditionProvider` are structs conforming to `@MainActor protocol ActionProvider`/`ConditionProvider`; conformance carries the `@MainActor` isolation onto their methods, so no explicit `@MainActor` annotation is needed on the types. `makeProviders` calls `descriptor(source:)` and constructs those providers — keep it un-isolated (it allocates value types only and is called from the `@MainActor` `PluginLoader` in B4).

- [ ] **Step 5: Register the implementation file in pbxproj (4 entries — Maccy group + app build phase)**

  Generate two fresh UUIDs:
  ```sh
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # -> fileRef_UUID (call it FR)
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # -> buildFile_UUID (call it BF)
  ```

  (1) `PBXBuildFile` line in `/* Begin PBXBuildFile section */`:
  ```
  <BF> /* DeclarativeEngine.swift in Sources */ = {isa = PBXBuildFile; fileRef = <FR> /* DeclarativeEngine.swift */; };
  ```

  (2) `PBXFileReference` line in `/* Begin PBXFileReference section */` — `path` carries the `Plugins/` subfolder (flat-group / `Actions/` precedent; there is no nested `Plugins` PBXGroup):
  ```
  <FR> /* DeclarativeEngine.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Plugins/DeclarativeEngine.swift; sourceTree = "<group>"; };
  ```

  (3) Insert `<FR>` into the `DAEE38451E3DBEB100DD2966 /* Maccy */` group `children` array:
  ```
  <FR> /* DeclarativeEngine.swift */,
  ```

  (4) Insert `<BF>` into the `DAEE383F1E3DBEB100DD2966 /* Sources */` (app target) build phase `files` array:
  ```
  <BF> /* DeclarativeEngine.swift in Sources */,
  ```

- [ ] **Step 6: Run the test — expect PASS**

  ```sh
  xcodebuild test -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj -scheme Maccy -destination 'platform=macOS' -only-testing:MaccyTests/DeclarativeEngineTests
  ```
  Expected: `** TEST SUCCEEDED **`; all `DeclarativeEngineTests` methods green. Then run the full unit suite to confirm no regressions:
  ```sh
  xcodebuild test -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj -scheme Maccy -destination 'platform=macOS' -only-testing:MaccyTests
  ```
  Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

  ```sh
  git add Maccy/Plugins/DeclarativeEngine.swift MaccyTests/DeclarativeEngineTests.swift Maccy.xcodeproj/project.pbxproj
  git commit -m "$(cat <<'EOF'
  B2: DeclarativeEngine — transform-op action fold + predicate-tree condition evaluator

  DeclarativeActionProvider folds {regexReplace,case,trim,prepend,append} over
  input.string (unknown op throws .unknownOp); DeclarativeConditionProvider walks
  an all/any/not predicate tree with regex/contains/kind/sourceApp leaves.
  DeclarativeEngine.makeProviders(manifest:source:) builds the matching-side provider.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Tkhip6qSb9uiFxwiJQbcKX
  EOF
  )"
  ```

---

Relevant file paths produced by this task:
- `/Users/roypadina/Code/Padina/Maccay/Maccy/Plugins/DeclarativeEngine.swift` (new)
- `/Users/roypadina/Code/Padina/Maccay/MaccyTests/DeclarativeEngineTests.swift` (new)
- `/Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj/project.pbxproj` (8 entries added: 4 per new file)

Two interface assumptions the engineer must confirm against the already-landed A1/B1 (and fix the call-site, not the contract, if they differ): (1) `PluginInput`'s memberwise init parameter labels are `string:kinds:sourceAppBundleID:fileURLs:`; (2) `PluginManifest`'s synthesized memberwise init field order matches the B1 canonical struct used in `testMakeProviders*`.


---

### Task B3: JSPluginRuntime (bridge-less + watchdog)

**Files:** Create `Maccy/Plugins/JSPluginRuntime.swift`, `MaccyTests/JSPluginRuntimeTests.swift`; modify `Maccy.xcodeproj/project.pbxproj`.

- [ ] **Step B3.1: Generate the four pbxproj UUIDs for the two new files**

Run `uuidgen` four times (two per file: one `fileRef`, one `buildFile`). The values below are placeholders — substitute the real generated UUIDs everywhere they appear in steps B3.2 and B3.7.

```sh
echo "JSPluginRuntime.swift  fileRef : $(uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]')"
echo "JSPluginRuntime.swift  buildFile: $(uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]')"
echo "JSPluginRuntimeTests.swift fileRef : $(uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]')"
echo "JSPluginRuntimeTests.swift buildFile: $(uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]')"
```

Record them as, e.g.:
- `RUNTIME_FR` = JSPluginRuntime.swift fileRef
- `RUNTIME_BF` = JSPluginRuntime.swift buildFile
- `RUNTIMETESTS_FR` = JSPluginRuntimeTests.swift fileRef
- `RUNTIMETESTS_BF` = JSPluginRuntimeTests.swift buildFile

---

- [ ] **Step B3.2: Register `JSPluginRuntime.swift` in `project.pbxproj` (4 edits) BEFORE writing the file**

The file must be in pbxproj or it is silently not compiled. Per Global Constraints, files under `Maccy/Plugins/` sit **flat in the `Maccy` group** with the subfolder encoded in `path` (Actions precedent) — there is no nested `Plugins` PBXGroup.

Edit 1 — add a `PBXBuildFile` line in the `/* Begin PBXBuildFile section */` block (alongside the existing ones, e.g. near `PluginCore.swift in Sources`):

```
RUNTIME_BF /* JSPluginRuntime.swift in Sources */ = {isa = PBXBuildFile; fileRef = RUNTIME_FR /* JSPluginRuntime.swift */; };
```

Edit 2 — add a `PBXFileReference` line in the `/* Begin PBXFileReference section */` block (note `path = Plugins/JSPluginRuntime.swift` — subfolder in the path because the parent group's `path = Maccy`):

```
RUNTIME_FR /* JSPluginRuntime.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Plugins/JSPluginRuntime.swift; sourceTree = "<group>"; };
```

Edit 3 — add `RUNTIME_FR` to the `children` array of the `DAEE38451E3DBEB100DD2966 /* Maccy */` group (next to the other `Plugins/*` fileRefs created in A1/B1/B2):

```
				RUNTIME_FR /* JSPluginRuntime.swift */,
```

Edit 4 — add `RUNTIME_BF` to the `files` array of the `DAEE383F1E3DBEB100DD2966 /* Sources */` build phase (the app target):

```
				RUNTIME_BF /* JSPluginRuntime.swift in Sources */,
```

> Note: JavaScriptCore is a macOS system framework. `import JavaScriptCore` auto-links it; no `PBXFrameworksBuildPhase` / link-flags edit is required, and no new entitlement is needed (per Global Constraints).

---

- [ ] **Step B3.3: Write the failing test file `MaccyTests/JSPluginRuntimeTests.swift`**

This test exercises B3's behavior before the implementation exists. `JSPluginRuntime` is **not** `@MainActor` (pure compute), so these test methods need no `@MainActor`. Create the file:

```swift
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
```

---

- [ ] **Step B3.4: Register `JSPluginRuntimeTests.swift` in `project.pbxproj` (4 edits)**

Test files go in the `MaccyTests` group and the `DA360DAC1E3DF137005C6F6B` (MaccyTests) build phase.

Edit 1 — `PBXBuildFile` line:

```
RUNTIMETESTS_BF /* JSPluginRuntimeTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = RUNTIMETESTS_FR /* JSPluginRuntimeTests.swift */; };
```

Edit 2 — `PBXFileReference` line (path uses the `MaccyTests/` prefix, matching the existing test-file refs):

```
RUNTIMETESTS_FR /* JSPluginRuntimeTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MaccyTests/JSPluginRuntimeTests.swift; sourceTree = "<group>"; };
```

Edit 3 — add `RUNTIMETESTS_FR` to the `children` array of the `MaccyTests` group (locate it by `path = MaccyTests;`):

```
				RUNTIMETESTS_FR /* JSPluginRuntimeTests.swift */,
```

Edit 4 — add `RUNTIMETESTS_BF` to the `files` array of the `DA360DAC1E3DF137005C6F6B /* Sources */` build phase (the test target):

```
				RUNTIMETESTS_BF /* JSPluginRuntimeTests.swift in Sources */,
```

---

- [ ] **Step B3.5: Run the test suite and expect a COMPILE FAILURE (red)**

`JSPluginRuntime` / `JSPluginError` / `JSConditionProvider` / `JSActionProvider` do not exist yet, so `JSPluginRuntimeTests` fails to compile. Run:

```sh
xcodebuild test -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj -scheme Maccy -destination 'platform=macOS' -only-testing:MaccyTests
```

Expected: build/test FAILS with errors like `cannot find 'JSPluginRuntime' in scope` and `cannot find 'JSPluginError' in scope`. This confirms the test is wired and exercises code that doesn't exist yet.

---

- [ ] **Step B3.6: Write the implementation `Maccy/Plugins/JSPluginRuntime.swift` (full file)**

Bridge-less: a bare `JSContext` is created with **nothing injected** — no `fetch`, `require`, `XMLHttpRequest`, `setTimeout`, `process`, etc. (JSC's bare global object provides only ECMAScript built-ins, so those are naturally `undefined`). The watchdog uses the JSC C API on the context's group: `JSContextGetGroup(context.jsGlobalContextRef)` then `JSContextGroupSetExecutionTimeLimit(group, limit, callback, nil)`. When the limit is exceeded JSC terminates execution and surfaces a JS exception, which our `exceptionHandler` captures into `lastException`; we map that to `.timedOut`. All other captured exceptions map to `.threw`.

Create the file with this complete content:

```swift
import Foundation
import JavaScriptCore

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

  /// Calls the global `transform(input)`; expects a String back.
  func callTransform(_ input: String) throws -> String {
    let result = try call("transform", argument: input)
    guard result.isString else { throw JSPluginError.wrongReturnType }
    return result.toString()
  }

  /// Calls the global `matches(input)`; expects a Bool back.
  func callMatches(_ input: String) throws -> Bool {
    let result = try call("matches", argument: input)
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

/// `@MainActor` ConditionProvider wrapper around a JS runtime's `matches(input)`.
@MainActor
struct JSConditionProvider: ConditionProvider {
  let descriptor: ProviderDescriptor
  let runtime: JSPluginRuntime

  func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool {
    try runtime.callMatches(input.string)
  }
}

/// `@MainActor` ActionProvider wrapper around a JS runtime's `transform(input)`.
@MainActor
struct JSActionProvider: ActionProvider {
  let descriptor: ProviderDescriptor
  let runtime: JSPluginRuntime

  func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome {
    .replace(try runtime.callTransform(input.string))
  }
}
```

---

- [ ] **Step B3.7: Run the test suite and expect PASS (green)**

Run the same command:

```sh
xcodebuild test -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj -scheme Maccy -destination 'platform=macOS' -only-testing:MaccyTests
```

Expected: build succeeds and **all** `JSPluginRuntimeTests` methods pass — happy-path `callTransform`/`callMatches`, `compileFailed`, both `missingEntry` cases, both `wrongReturnType` cases, the `.threw` case, the watchdog `.timedOut` case (within ~0.1s + JSC slack), and all five sandbox `typeof … === "undefined"` assertions. If the watchdog test instead hangs, the `JSContextGroupSetExecutionTimeLimit` callback or the `jsGlobalContextRef` group lookup is wrong — fix before proceeding.

---

- [ ] **Step B3.8: Commit**

```sh
git add -A && git commit -m "B3: JSPluginRuntime — bridge-less JavaScriptCore + execution-time-limit watchdog

Add JSPluginRuntime (bare JSContext, nothing injected; compile via
evaluateScript with exceptionHandler capture; watchdog via
JSContextGetGroup + JSContextGroupSetExecutionTimeLimit) and the
@MainActor JSConditionProvider/JSActionProvider wrappers. Exceptions map
to .compileFailed/.missingEntry/.timedOut/.wrongReturnType/.threw.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Tkhip6qSb9uiFxwiJQbcKX"
```

---

Notes for the implementing engineer (verified facts, not part of the plan body):
- Both new files require pbxproj registration (the project is NOT a synchronized group): `/Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj/project.pbxproj`. There is currently no `Plugins` PBXGroup — files go flat in `DAEE38451E3DBEB100DD2966 /* Maccy */` with `path = Plugins/JSPluginRuntime.swift`, per the Actions precedent in Global Constraints.
- Implementation file path: `/Users/roypadina/Code/Padina/Maccay/Maccy/Plugins/JSPluginRuntime.swift`. Test file path: `/Users/roypadina/Code/Padina/Maccay/MaccyTests/JSPluginRuntimeTests.swift`.
- `JSConditionProvider`/`JSActionProvider` depend on `ConditionProvider`/`ActionProvider`/`ProviderDescriptor`/`PluginInput`/`JSONValue`/`ActionOutcome` from A1's `PluginCore.swift` (already landed before B3). `JSPluginRuntime` itself is not `@MainActor` per the contract; the two provider wrappers are `@MainActor` per the contract and protocol isolation, so their bodies call the non-isolated runtime synchronously — fine.
- The watchdog-termination → `.timedOut` mapping keys off the JSC termination exception message containing "terminated". This is the documented JSC behavior: `JSContextGroupSetExecutionTimeLimit`'s callback returning `true` terminates the script and raises a JS exception captured by `exceptionHandler`.


---

### Task B4: PluginLoader

**Goal:** `PluginLoader` scans the bundled-plugins directory and the Application Support plugins folder (plus any extra folders supplied by the caller), parses each subfolder's `plugin.json` manifest, builds typed providers via `DeclarativeEngine` or `JSPluginRuntime`, registers them in `ProviderRegistry`, and returns the resulting descriptors. Per-plugin failures are caught and logged so one bad plugin never prevents the rest from loading. `ActionEngine` calls `PluginLoader.loadAll` at startup and on every `reloadRules()`.

**Prerequisites:** Tasks B1 (`PluginCore.swift`), B2 (`DeclarativeEngine.swift`), and B3 (`JSPluginRuntime.swift`) are already on branch and compiled.

---

- [ ] **Step 1: Generate UUIDs for `PluginLoader.swift` and `PluginLoaderTests.swift`**

  Run these four commands and record the output — you will paste the UUIDs into every code block and pbxproj edit below.

  ```sh
  # fileRef UUID for PluginLoader.swift
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'
  # buildFile UUID for PluginLoader.swift (app target)
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'
  # fileRef UUID for PluginLoaderTests.swift
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'
  # buildFile UUID for PluginLoaderTests.swift (test target)
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'
  ```

  Throughout these steps the placeholders `<PLfr>`, `<PLbf>`, `<PLTfr>`, `<PLTbf>` stand for those four UUIDs in order. Substitute the real hex strings everywhere they appear.

---

- [ ] **Step 2: Write the failing test `MaccyTests/PluginLoaderTests.swift`**

  Create `MaccyTests/PluginLoaderTests.swift` with the content below. It will not compile yet because `PluginLoader` does not exist.

  ```swift
  import XCTest
  @testable import Maccy

  /// Tests for PluginLoader: scanning a temp folder containing valid declarative /
  /// JS plugin directories, verifying registration, and verifying that a folder
  /// with a malformed manifest is skipped without aborting the remaining load.
  @MainActor
  final class PluginLoaderTests: XCTestCase {

    // ---- helpers -----------------------------------------------------------

    /// Build a temp directory with a single declarative action plugin.
    /// Returns the folder URL so the caller can pass it as an extra folder.
    private func makeDeclarativePlugin(id: String, in root: URL) throws -> URL {
      let pluginDir = root.appendingPathComponent(id)
      try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

      // plugin.json for a declarative action that uppercases its input.
      // The "case upper" op is the simplest deterministic transform.
      let manifest: [String: Any] = [
        "id": id,
        "name": "Test Upper",
        "version": "1.0.0",
        "description": "Uppercases the input text for testing",
        "kind": "action",
        "engine": "declarative",
        "declarative": [
          "transform": [
            ["op": "case", "value": "upper"]
          ]
        ]
      ]
      let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: pluginDir.appendingPathComponent("plugin.json"))
      return pluginDir
    }

    /// Build a temp directory with a single JavaScript condition plugin.
    /// The JS returns true when the input contains the substring "hello".
    private func makeJSPlugin(id: String, in root: URL) throws -> URL {
      let pluginDir = root.appendingPathComponent(id)
      try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

      let manifest: [String: Any] = [
        "id": id,
        "name": "Test Hello Condition",
        "version": "1.0.0",
        "description": "Returns true when the clipboard text contains hello",
        "kind": "condition",
        "engine": "javascript",
        "entry": "main.js"
      ]
      let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: pluginDir.appendingPathComponent("plugin.json"))

      let js = "function matches(input) { return input.indexOf('hello') !== -1; }"
      try js.data(using: .utf8)!.write(to: pluginDir.appendingPathComponent("main.js"))
      return pluginDir
    }

    /// Build a temp directory that contains a malformed plugin.json (missing required fields).
    private func makeMalformedPlugin(id: String, in root: URL) throws -> URL {
      let pluginDir = root.appendingPathComponent(id)
      try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
      let bad = "{\"not\": \"a valid manifest\"}"
      try bad.data(using: .utf8)!.write(to: pluginDir.appendingPathComponent("plugin.json"))
      return pluginDir
    }

    // ---- tests -------------------------------------------------------------

    func testLoadDeclarativeActionPlugin() throws {
      let registry = ProviderRegistry()
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PluginLoaderTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }

      try makeDeclarativePlugin(id: "test.upper", in: root)

      PluginLoader.loadAll(into: registry, extraFolders: [root])

      // The action should be registered under id "test.upper"
      let action = registry.action("test.upper")
      XCTAssertNotNil(action, "Declarative action plugin should be registered")

      let descriptor = action!.descriptor
      XCTAssertEqual(descriptor.id, "test.upper")
      XCTAssertEqual(descriptor.kind, .action)
      XCTAssertEqual(descriptor.engine, .declarative)
    }

    func testDeclarativeActionRunsTransform() async throws {
      let registry = ProviderRegistry()
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PluginLoaderTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }

      try makeDeclarativePlugin(id: "test.upper2", in: root)
      PluginLoader.loadAll(into: registry, extraFolders: [root])

      let action = try XCTUnwrap(registry.action("test.upper2"))
      let input = PluginInput(string: "hello world", kinds: [.text], sourceAppBundleID: nil, fileURLs: [])
      let outcome = try await action.run(input, params: .emptyObject)

      XCTAssertEqual(outcome, .replace("HELLO WORLD"))
    }

    func testLoadJSConditionPlugin() throws {
      let registry = ProviderRegistry()
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PluginLoaderTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }

      try makeJSPlugin(id: "test.hello", in: root)
      PluginLoader.loadAll(into: registry, extraFolders: [root])

      let condition = registry.condition("test.hello")
      XCTAssertNotNil(condition, "JS condition plugin should be registered")

      let descriptor = condition!.descriptor
      XCTAssertEqual(descriptor.id, "test.hello")
      XCTAssertEqual(descriptor.kind, .condition)
      XCTAssertEqual(descriptor.engine, .javascript)
    }

    func testJSConditionEvaluates() throws {
      let registry = ProviderRegistry()
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PluginLoaderTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }

      try makeJSPlugin(id: "test.hello2", in: root)
      PluginLoader.loadAll(into: registry, extraFolders: [root])

      let condition = try XCTUnwrap(registry.condition("test.hello2"))

      let matchingInput = PluginInput(string: "say hello there", kinds: [.text], sourceAppBundleID: nil, fileURLs: [])
      let nonMatchingInput = PluginInput(string: "no greeting here", kinds: [.text], sourceAppBundleID: nil, fileURLs: [])

      XCTAssertTrue(try condition.evaluate(matchingInput, params: .emptyObject))
      XCTAssertFalse(try condition.evaluate(nonMatchingInput, params: .emptyObject))
    }

    func testMalformedManifestIsSkipped() throws {
      let registry = ProviderRegistry()
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PluginLoaderTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }

      // One bad plugin + one good plugin in the same folder.
      try makeMalformedPlugin(id: "test.bad", in: root)
      try makeDeclarativePlugin(id: "test.good", in: root)

      // Should not throw; bad plugin is skipped.
      PluginLoader.loadAll(into: registry, extraFolders: [root])

      // Bad plugin absent.
      XCTAssertNil(registry.condition("test.bad"))
      XCTAssertNil(registry.action("test.bad"))

      // Good plugin present.
      XCTAssertNotNil(registry.action("test.good"))
    }

    func testLoadAllRemovesPriorFolderPluginsOnReload() throws {
      let registry = ProviderRegistry()
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PluginLoaderTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }

      try makeDeclarativePlugin(id: "test.removable", in: root)
      PluginLoader.loadAll(into: registry, extraFolders: [root])
      XCTAssertNotNil(registry.action("test.removable"), "Should be registered after first load")

      // Remove the plugin folder and reload.
      try FileManager.default.removeItem(at: root.appendingPathComponent("test.removable"))
      PluginLoader.loadAll(into: registry, extraFolders: [root])
      XCTAssertNil(registry.action("test.removable"), "Should be gone after reload without the folder")
    }
  }
  ```

---

- [ ] **Step 3: Run the tests — expect compile failure**

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests/PluginLoaderTests \
    2>&1 | grep -E "error:|PluginLoader"
  ```

  **Expected:** compile errors referencing `PluginLoader` — the type does not exist yet. This confirms the test file is wired and TDD red is achieved.

---

- [ ] **Step 4: Add `PluginLoaderTests.swift` pbxproj entries (test target)**

  Open `Maccy.xcodeproj/project.pbxproj` and make these four edits using the `<PLTfr>` and `<PLTbf>` UUIDs generated in Step 1.

  **Edit 1 — PBXBuildFile section:** add the following line anywhere in the `/* Begin PBXBuildFile section */` block (alphabetical order by UUID is conventional but not required):

  ```
  		<PLTbf> /* PluginLoaderTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <PLTfr> /* PluginLoaderTests.swift */; };
  ```

  **Edit 2 — PBXFileReference section:** add the following line anywhere in the `/* Begin PBXFileReference section */` block:

  ```
  		<PLTfr> /* PluginLoaderTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PluginLoaderTests.swift; sourceTree = "<group>"; };
  ```

  **Edit 3 — MaccyTests PBXGroup children** (`DA360DB11E3DF137005C6F6B /* MaccyTests */`): add `<PLTfr>` to the `children` array. Insert it before the `Info.plist` line so it stays grouped with the other test files:

  ```
  			DA360DB11E3DF137005C6F6B /* MaccyTests */ = {
  				isa = PBXGroup;
  				children = (
  					... existing entries ...
  					<PLTfr> /* PluginLoaderTests.swift */,
  					DA360DB41E3DF137005C6F6B /* Info.plist */,
  				);
  				path = MaccyTests;
  				sourceTree = "<group>";
  			};
  ```

  **Edit 4 — MaccyTests build phase** (`DA360DAC1E3DF137005C6F6B /* Sources */`): add `<PLTbf>` to the `files` array:

  ```
  		DA360DAC1E3DF137005C6F6B /* Sources */ = {
  			isa = PBXSourcesBuildPhase;
  			buildActionMask = 2147483647;
  			files = (
  				... existing entries ...
  				<PLTbf> /* PluginLoaderTests.swift in Sources */,
  			);
  			runOnlyForDeploymentPostprocessing = 0;
  		};
  ```

---

- [ ] **Step 5: Create `Maccy/Plugins/PluginLoader.swift`**

  Create the directory `Maccy/Plugins/` if it does not already exist (tasks B1–B3 will have created it; if you are running B4 standalone, create it now). Then create the file with this complete content:

  ```swift
  import Foundation

  // Scans plugin folders, parses plugin.json manifests, builds typed providers
  // via DeclarativeEngine / JSPluginRuntime, and registers them in a
  // ProviderRegistry.  Per-plugin errors are caught and printed so one bad
  // plugin cannot prevent the rest from loading.
  @MainActor
  enum PluginLoader {

    // MARK: - Folder resolution

    /// The `BundledPlugins` directory that Xcode copies into the app bundle.
    /// Returns nil when running in a unit-test host that has no bundle resource dir.
    static func bundledPluginsURL() -> URL? {
      Bundle.main.url(forResource: "BundledPlugins", withExtension: nil)
    }

    /// `~/Library/Application Support/Maccay/Plugins` — created on demand.
    static func installedPluginsURL() -> URL {
      let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

      let dir = appSupport
        .appendingPathComponent("Maccay", isDirectory: true)
        .appendingPathComponent("Plugins", isDirectory: true)

      if !FileManager.default.fileExists(atPath: dir.path) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      }
      return dir
    }

    // MARK: - Bulk load

    /// Removes any previously folder-loaded providers, then rescans every source
    /// folder (bundled dir, installed dir, and `extraFolders`) and registers the
    /// resulting providers into `registry`.
    ///
    /// Call at app startup and again from `ActionEngine.reloadRules()`.
    /// Pass `MarketplaceStore.shared.localFolders()` as `extraFolders` once C2 lands;
    /// for now pass `[]`.
    static func loadAll(into registry: ProviderRegistry, extraFolders: [URL]) {
      // Remove every provider that came from a folder source so stale plugins
      // from a previous load cycle cannot linger after their folder is deleted.
      // .builtin providers (registered by BuiltinProviders / FirstPartyProviders)
      // are left in place — they are not folder-loaded and must not be cleared.
      registry.removeAll { source in
        switch source {
        case .bundled, .marketplace, .local: return true
        case .builtin: return false
        }
      }

      // Build the ordered list of folders to scan.
      var folders: [URL] = []
      if let bundled = bundledPluginsURL() {
        folders.append(bundled)
      }
      folders.append(installedPluginsURL())
      folders.append(contentsOf: extraFolders)

      for folder in folders {
        scanFolder(folder, into: registry)
      }
    }

    // MARK: - Per-folder scan

    /// Enumerates immediate subdirectories of `folder`; each subdirectory that
    /// contains a `plugin.json` is treated as one plugin.
    private static func scanFolder(_ folder: URL, into registry: ProviderRegistry) {
      guard FileManager.default.fileExists(atPath: folder.path) else { return }

      let contents: [URL]
      do {
        contents = try FileManager.default.contentsOfDirectory(
          at: folder,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles]
        )
      } catch {
        print("[PluginLoader] Cannot read folder \(folder.lastPathComponent): \(error)")
        return
      }

      // Determine the ProviderSource for this folder.
      let source = providerSource(for: folder)

      for entry in contents {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir),
              isDir.boolValue else { continue }

        let manifestURL = entry.appendingPathComponent("plugin.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }

        do {
          _ = try loadPlugin(at: entry, source: source, into: registry)
        } catch {
          print("[PluginLoader] Skipping plugin at \(entry.lastPathComponent): \(error)")
        }
      }
    }

    // MARK: - Single plugin load

    /// Parses `plugin.json` in `folder`, validates the manifest, builds the
    /// appropriate provider, and returns its descriptor — without registering anywhere.
    /// Use this when you only need the descriptor (e.g., for preview / validation).
    ///
    /// Throws if the manifest is missing, malformed, fails `validate()`, or if the
    /// engine-specific setup fails (e.g., a JS syntax error).
    @discardableResult
    static func loadPlugin(at folder: URL, source: ProviderSource) throws -> [ProviderDescriptor] {
      let scratch = ProviderRegistry()
      return try loadPlugin(at: folder, source: source, into: scratch)
    }

    // Internal variant used by loadAll: parses, builds, registers, and returns
    // the descriptor so the caller can log it.
    @discardableResult
    private static func loadPlugin(
      at folder: URL,
      source: ProviderSource,
      into registry: ProviderRegistry
    ) throws -> [ProviderDescriptor] {
      let manifestURL = folder.appendingPathComponent("plugin.json")
      let data = try Data(contentsOf: manifestURL)
      let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
      try manifest.validate()

      let descriptor = manifest.descriptor(source: source)

      switch manifest.engine {
      case .native:
        // A manifest claiming engine=native is rejected; native providers are
        // code-only and cannot be loaded from a folder plugin.
        throw PluginManifestError.badEngineEntry

      case .declarative:
        guard let spec = manifest.declarative else {
          throw PluginManifestError.missingField("declarative")
        }
        switch manifest.kind {
        case .action:
          let provider = DeclarativeActionProvider(descriptor: descriptor, spec: spec)
          registry.register(action: provider)
        case .condition:
          let provider = DeclarativeConditionProvider(descriptor: descriptor, spec: spec)
          registry.register(condition: provider)
        }

      case .javascript:
        guard let entryFilename = manifest.entry else {
          throw PluginManifestError.missingField("entry")
        }
        let scriptURL = folder.appendingPathComponent(entryFilename)
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let runtime = try JSPluginRuntime(script: script)

        switch manifest.kind {
        case .condition:
          let provider = JSConditionProvider(descriptor: descriptor, runtime: runtime)
          registry.register(condition: provider)
        case .action:
          let provider = JSActionProvider(descriptor: descriptor, runtime: runtime)
          registry.register(action: provider)
        }
      }

      return [descriptor]
    }

    // MARK: - Source inference

    /// Maps a folder URL to the appropriate `ProviderSource`.
    private static func providerSource(for folder: URL) -> ProviderSource {
      if let bundled = bundledPluginsURL(), folder.path.hasPrefix(bundled.path) {
        return .bundled
      }
      let installed = installedPluginsURL()
      if folder.path.hasPrefix(installed.path) {
        return .marketplace("user-installed")
      }
      return .local(folder.path)
    }
  }
  ```

---

- [ ] **Step 6: Add `PluginLoader.swift` pbxproj entries (app target)**

  Open `Maccy.xcodeproj/project.pbxproj` and make these four edits using the `<PLfr>` and `<PLbf>` UUIDs generated in Step 1.

  **Edit 1 — PBXBuildFile section:** add:

  ```
  		<PLbf> /* PluginLoader.swift in Sources */ = {isa = PBXBuildFile; fileRef = <PLfr> /* PluginLoader.swift */; };
  ```

  **Edit 2 — PBXFileReference section:** add:

  ```
  		<PLfr> /* PluginLoader.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Plugins/PluginLoader.swift; sourceTree = "<group>"; };
  ```

  **Edit 3 — Maccy PBXGroup children** (`DAEE38451E3DBEB100DD2966 /* Maccy */`): add `<PLfr>` to the `children` array, near the other `Plugins/` file refs added by B1–B3:

  ```
  			DAEE38451E3DBEB100DD2966 /* Maccy */ = {
  				isa = PBXGroup;
  				children = (
  					... existing entries including PluginCore.swift, ProviderRegistry.swift, etc. ...
  					<PLfr> /* PluginLoader.swift */,
  					... rest of children ...
  				);
  				path = Maccy;
  				sourceTree = "<group>";
  			};
  ```

  **Edit 4 — Maccy app build phase** (`DAEE383F1E3DBEB100DD2966 /* Sources */`): add `<PLbf>` to the `files` array:

  ```
  		DAEE383F1E3DBEB100DD2966 /* Sources */ = {
  			isa = PBXSourcesBuildPhase;
  			buildActionMask = 2147483647;
  			files = (
  				... existing entries ...
  				<PLbf> /* PluginLoader.swift in Sources */,
  			);
  			runOnlyForDeploymentPostprocessing = 0;
  		};
  ```

---

- [ ] **Step 7: Wire `PluginLoader.loadAll` into the post-A5 `ActionEngine` (two surgical insertions only)**

  `ActionEngine.swift` was already rewritten by **A5 Part 3** to the registry-based engine (Defaults key `"actionRulesV3"`, registry dispatch via `ProviderRegistry.shared`, a `registerProviders()` helper, and **no** `ClipboardAction`/`ActionFactory`/`resolvedActions`). **Do NOT paste a full `ActionEngine.swift` here** — pasting the pre-A5 file would silently revert the entire atomic swap and fail to compile. Make exactly **two** additions to the existing post-A5 file:

  **7a — startup load.** In the provider-registration path (the `registerProviders()` helper called from `init()`, per A5 Part 3), add the loader as the LAST line, after the two native registrars:

  ```swift
  // (existing, from A5 Part 3:)
  // BuiltinProviders.registerBuiltins(into: .shared)
  // FirstPartyProviders.registerFirstParty(into: .shared)

  // NEW: load folder plugins (bundled + Application Support).
  // C2 replaces [] with MarketplaceStore.shared.localFolders().
  PluginLoader.loadAll(into: .shared, extraFolders: [])
  ```

  **7b — reload.** In the existing post-A5 `reloadRules()`, add the same call immediately before `registerShortcuts()` so install/remove from another process takes effect on the distributed-notification reload:

  ```swift
  func reloadRules() {
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    // NEW: reload folder plugins. C2 replaces [] with MarketplaceStore.shared.localFolders().
    PluginLoader.loadAll(into: .shared, extraFolders: [])
    registerShortcuts()
  }
  ```

  No other line of `ActionEngine.swift` changes. No pbxproj edit (existing file). Confirm afterward: `grep -n "PluginLoader.loadAll" Maccy/Actions/ActionEngine.swift` shows exactly the two calls above and the file still contains `"actionRulesV3"` and `ProviderRegistry.shared` (i.e. the A5 swap is intact).

---

- [ ] **Step 8: Run the tests — expect PASS**

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests/PluginLoaderTests \
    2>&1 | grep -E "Test.*passed|Test.*failed|error:"
  ```

  **Expected:** All 5 `PluginLoaderTests` tests pass; no compile errors.

  If any test fails, address only the failing assertion and re-run. Do not change passing tests.

---

- [ ] **Step 9: Run the full unit-test suite to confirm no regressions**

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests \
    2>&1 | grep -E "Test.*passed|Test.*failed|error:"
  ```

  **Expected:** All previously-passing tests still pass; `PluginLoaderTests` adds 5 new passing tests.

---

- [ ] **Step 10: Commit**

  ```sh
  git add \
    Maccy/Plugins/PluginLoader.swift \
    Maccy/Actions/ActionEngine.swift \
    MaccyTests/PluginLoaderTests.swift \
    Maccy.xcodeproj/project.pbxproj

  git commit -m "$(cat <<'EOF'
  B4: PluginLoader — scan + register folder plugins at startup and on reload

  Add PluginLoader (enum) that scans bundled, installed, and extra folders,
  parses plugin.json manifests via PluginManifest, builds providers via
  DeclarativeEngine / JSPluginRuntime, and registers them in ProviderRegistry.
  Per-plugin failures are caught and logged.  ActionEngine.init and reloadRules
  now call PluginLoader.loadAll(into:.shared, extraFolders:[]) so plugins are
  active at boot and refreshed on CLI-triggered reloads.  The extraFolders
  parameter is [] for now; C2 will pass MarketplaceStore.shared.localFolders().

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```


---

### Task B5: Bundled example plugins + boot-time load

**Goal:** Ship two bundled plugins (a declarative action and a JS condition) inside the app bundle as a folder reference, load them via `PluginLoader` at boot, and verify both providers work end-to-end in a unit test.

**Success criteria:**
1. `Maccy/Resources/BundledPlugins/example-shout/plugin.json` exists and decodes to a valid `PluginManifest`.
2. `Maccy/Resources/BundledPlugins/example-has-url/plugin.json` + `main.js` exist and decode correctly.
3. `BundledPlugins/` is registered as a folder reference in `project.pbxproj` so Xcode copies it into the bundle.
4. `BundledPluginsTests` (red) → implement B5 on-disk files → tests pass green.

---

- [ ] **Step 1: Create `Maccy/Resources/BundledPlugins/example-shout/plugin.json`**

  This is a declarative action that uppercases the input then prepends `"SHOUT: "`.

  Create the directory first:
  ```sh
  mkdir -p /Users/roypadina/Code/Padina/Maccay/Maccy/Resources/BundledPlugins/example-shout
  ```

  Full file content (`Maccy/Resources/BundledPlugins/example-shout/plugin.json`):

  ```json
  {
    "id": "com.maccay.example.shout",
    "name": "Shout",
    "version": "1.0.0",
    "description": "Uppercases the clipboard text and prepends SHOUT:.",
    "kind": "action",
    "engine": "declarative",
    "declarative": {
      "transform": [
        { "op": "case", "value": "upper" },
        { "op": "prepend", "text": "SHOUT: " }
      ]
    }
  }
  ```

  > Transform ops execute left-to-right: `case/upper` fires first (input `"hi"` → `"HI"`), then `prepend` prepends `"SHOUT: "` (→ `"SHOUT: HI"`). The test asserts `.replace("SHOUT: HI")` for input `"hi"`.

---

- [ ] **Step 2: Create `Maccy/Resources/BundledPlugins/example-has-url/plugin.json` and `main.js`**

  Create the directory:
  ```sh
  mkdir -p /Users/roypadina/Code/Padina/Maccay/Maccy/Resources/BundledPlugins/example-has-url
  ```

  Full file content (`Maccy/Resources/BundledPlugins/example-has-url/plugin.json`):

  ```json
  {
    "id": "com.maccay.example.has-url",
    "name": "Has URL",
    "version": "1.0.0",
    "description": "True when the clipboard text contains an http or https URL.",
    "kind": "condition",
    "engine": "javascript",
    "entry": "main.js"
  }
  ```

  Full file content (`Maccy/Resources/BundledPlugins/example-has-url/main.js`):

  ```javascript
  function matches(s) { return /https?:\/\//.test(s); }
  ```

---

- [ ] **Step 3: Write the failing test `MaccyTests/BundledPluginsTests.swift`**

  The test locates `BundledPlugins/` relative to `#filePath` (source-tree path, always valid on disk during a local build), loads both plugins via `PluginLoader`, and asserts their behaviour.

  > `#filePath` in `MaccyTests/BundledPluginsTests.swift` resolves to `.../Maccay/MaccyTests/BundledPluginsTests.swift`. Go up one level → `MaccyTests/`, up one more → `Maccay/` (repo root), then `Maccy/Resources/BundledPlugins/`.

  Full file content (`MaccyTests/BundledPluginsTests.swift`):

  ```swift
  import XCTest
  @testable import Maccy

  @MainActor
  final class BundledPluginsTests: XCTestCase {

    // Resolve BundledPlugins from the source tree so the test works without
    // a running bundle. #filePath always points to the source file on disk
    // during a local build, even when tests are invoked via xcodebuild.
    private static let bundledPluginsURL: URL = {
      let thisFile = URL(fileURLWithPath: #filePath)       // .../MaccyTests/BundledPluginsTests.swift
      let testsDir = thisFile.deletingLastPathComponent()  // .../MaccyTests/
      let repoRoot = testsDir.deletingLastPathComponent()  // .../Maccay/
      return repoRoot
        .appendingPathComponent("Maccy")
        .appendingPathComponent("Resources")
        .appendingPathComponent("BundledPlugins")
    }()

    override func setUp() async throws {
      try await super.setUp()
      // Reset the shared registry so each test run starts clean.
      ProviderRegistry.shared.reset()
      let shoutURL = Self.bundledPluginsURL.appendingPathComponent("example-shout")
      let hasURLURL = Self.bundledPluginsURL.appendingPathComponent("example-has-url")
      _ = try PluginLoader.loadPlugin(at: shoutURL, source: .bundled)
      _ = try PluginLoader.loadPlugin(at: hasURLURL, source: .bundled)
    }

    override func tearDown() async throws {
      ProviderRegistry.shared.reset()
      try await super.tearDown()
    }

    // MARK: - example-shout (declarative action)

    func testShoutActionRegistered() {
      XCTAssertNotNil(ProviderRegistry.shared.action("com.maccay.example.shout"))
    }

    func testShoutActionTransformsHiToSHOUT() async throws {
      let action = try XCTUnwrap(ProviderRegistry.shared.action("com.maccay.example.shout"))
      let input = PluginInput(
        string: "hi",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      let outcome = try await action.run(input, params: .emptyObject)
      XCTAssertEqual(outcome, .replace("SHOUT: HI"))
    }

    func testShoutDescriptor() {
      let descriptor = ProviderRegistry.shared.action("com.maccay.example.shout")?.descriptor
      XCTAssertEqual(descriptor?.id, "com.maccay.example.shout")
      XCTAssertEqual(descriptor?.engine, .declarative)
      XCTAssertEqual(descriptor?.kind, .action)
      XCTAssertTrue(descriptor?.isVerified == true)
    }

    // MARK: - example-has-url (JS condition)

    func testHasURLConditionRegistered() {
      XCTAssertNotNil(ProviderRegistry.shared.condition("com.maccay.example.has-url"))
    }

    func testHasURLConditionTrueForHTTPS() throws {
      let condition = try XCTUnwrap(ProviderRegistry.shared.condition("com.maccay.example.has-url"))
      let input = PluginInput(
        string: "Visit https://example.com for details",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      XCTAssertTrue(try condition.evaluate(input, params: .emptyObject))
    }

    func testHasURLConditionTrueForHTTP() throws {
      let condition = try XCTUnwrap(ProviderRegistry.shared.condition("com.maccay.example.has-url"))
      let input = PluginInput(
        string: "http://insecure.example.org",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      XCTAssertTrue(try condition.evaluate(input, params: .emptyObject))
    }

    func testHasURLConditionFalseForPlainText() throws {
      let condition = try XCTUnwrap(ProviderRegistry.shared.condition("com.maccay.example.has-url"))
      let input = PluginInput(
        string: "just some plain text",
        kinds: [.text],
        sourceAppBundleID: nil,
        fileURLs: []
      )
      XCTAssertFalse(try condition.evaluate(input, params: .emptyObject))
    }

    func testHasURLDescriptor() {
      let descriptor = ProviderRegistry.shared.condition("com.maccay.example.has-url")?.descriptor
      XCTAssertEqual(descriptor?.id, "com.maccay.example.has-url")
      XCTAssertEqual(descriptor?.engine, .javascript)
      XCTAssertEqual(descriptor?.kind, .condition)
      XCTAssertTrue(descriptor?.isVerified == true)
    }
  }
  ```

  Run (expect compile errors — this is the red state; the test file is in the build graph after Step 5):

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests/BundledPluginsTests \
    2>&1 | grep -E "error:|Build FAILED"
  ```

  Expected: compile errors referencing `PluginLoader`, `ProviderRegistry`, `PluginInput`. This confirms the file is wired into the build graph (Step 5) before B1–B4 implementations exist.

---

- [ ] **Step 4: Register `BundledPlugins/` as a folder reference in `project.pbxproj`**

  A folder reference (not a group) copies the entire directory tree into the app bundle as-is, which `PluginLoader.bundledPluginsURL()` depends on. Three edits are required.

  **4a. Generate two UUIDs:**

  ```sh
  # fileRef UUID — identifies the folder on disk:
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'
  # buildFile UUID — slot in the Resources build phase:
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'
  ```

  This plan refers to the results as `<FR_BUNDLED>` and `<BF_BUNDLED>`. Substitute the actual generated hex strings.

  **4b. Add a `PBXBuildFile` entry** in the `/* Begin PBXBuildFile section */` block (insert near other Resources build-file entries, e.g. after the `Write.caf` line):

  ```
  <BF_BUNDLED> /* BundledPlugins in Resources */ = {isa = PBXBuildFile; fileRef = <FR_BUNDLED> /* BundledPlugins */; };
  ```

  **4c. Add a `PBXFileReference` entry** in the `/* Begin PBXFileReference section */` block (insert near other resource references):

  ```
  <FR_BUNDLED> /* BundledPlugins */ = {isa = PBXFileReference; lastKnownFileType = folder; path = Resources/BundledPlugins; sourceTree = "<group>"; };
  ```

  > `lastKnownFileType = folder` is correct for a plain folder reference (not `folder.assetcatalog`, not `sourcecode.swift`). `path = Resources/BundledPlugins` is relative to the Maccy PBXGroup whose own `path = Maccy`, so the on-disk path resolves to `Maccy/Resources/BundledPlugins`.

  **4d. Add `<FR_BUNDLED>` to the `DAEE38451E3DBEB100DD2966 /* Maccy */` group children.** Insert after the `Assets.xcassets` line (currently line ~879):

  ```
  DA6373971E4AB9BB00263391 /* Assets.xcassets */,
  <FR_BUNDLED> /* BundledPlugins */,
  4762D6992467226100B3A2BA /* Localizable.strings */,
  ```

  **4e. Add `<BF_BUNDLED>` to the Maccy app Resources build phase `DAEE38411E3DBEB100DD2966 /* Resources */`** (currently lines 1060–1080). Insert before the closing `);`:

  ```
  DA9C3C4A2C20D4B40056795D /* IgnoreSettings.strings in Resources */,
  <BF_BUNDLED> /* BundledPlugins in Resources */,
  );
  ```

  After these edits Xcode copies `Maccy/Resources/BundledPlugins/` intact into `Maccy.app/Contents/Resources/BundledPlugins/`, which is the URL returned by `Bundle.main.url(forResource: "BundledPlugins", withExtension: nil)`.

---

- [ ] **Step 5: Register `BundledPluginsTests.swift` in `project.pbxproj`**

  Generate two UUIDs for the test file:

  ```sh
  # fileRef UUID:
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'
  # buildFile UUID:
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'
  ```

  Refer to them as `<FR_TEST>` and `<BF_TEST>`.

  **5a. Add `PBXBuildFile`** in the `/* Begin PBXBuildFile section */` block:

  ```
  <BF_TEST> /* BundledPluginsTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <FR_TEST> /* BundledPluginsTests.swift */; };
  ```

  **5b. Add `PBXFileReference`** in the `/* Begin PBXFileReference section */` block:

  ```
  <FR_TEST> /* BundledPluginsTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BundledPluginsTests.swift; sourceTree = "<group>"; };
  ```

  > `path = BundledPluginsTests.swift` (filename only, no subdirectory prefix) because the MaccyTests PBXGroup already has `path = MaccyTests`.

  **5c. Add `<FR_TEST>` to the `DA360DB11E3DF137005C6F6B /* MaccyTests */` group children.** Insert after `AA01C0DE00000000000000B1 /* KeyboardLayoutTests.swift */`:

  ```
  AA01C0DE00000000000000B1 /* KeyboardLayoutTests.swift */,
  <FR_TEST> /* BundledPluginsTests.swift */,
  DA360DB41E3DF137005C6F6B /* Info.plist */,
  ```

  **5d. Add `<BF_TEST>` to the `DA360DAC1E3DF137005C6F6B /* Sources */` MaccyTests build phase.** Insert after the last existing test entry (currently `AA01C0DE00000000000000B2 /* KeyboardLayoutTests.swift in Sources */`):

  ```
  AA01C0DE00000000000000B2 /* KeyboardLayoutTests.swift in Sources */,
  <BF_TEST> /* BundledPluginsTests.swift in Sources */,
  ```

---

- [ ] **Step 6: Confirm the test compiles and is red (B1–B4 not yet implemented)**

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests/BundledPluginsTests \
    2>&1 | grep -E "error:|Build FAILED"
  ```

  Expected output contains:
  ```
  error: cannot find type 'PluginLoader' in scope
  error: cannot find type 'ProviderRegistry' in scope
  error: cannot find type 'PluginInput' in scope
  ```

  These errors confirm the file is in the build graph. The red state is correct — B5 depends on B1 (`PluginManifest`), B2 (`DeclarativeEngine`), B3 (`JSPluginRuntime`), and B4 (`PluginLoader`).

---

- [ ] **Step 7: Run tests green after B1–B4 are implemented**

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests/BundledPluginsTests \
    2>&1 | grep -E "Test Suite|passed|failed|error:"
  ```

  Expected:
  ```
  Test Suite 'BundledPluginsTests' passed at ...
       Executed 8 tests, with 0 failures (0 unexpected) in ... seconds
  ```

  All eight methods must pass:
  - `testShoutActionRegistered`
  - `testShoutActionTransformsHiToSHOUT`
  - `testShoutDescriptor`
  - `testHasURLConditionRegistered`
  - `testHasURLConditionTrueForHTTPS`
  - `testHasURLConditionTrueForHTTP`
  - `testHasURLConditionFalseForPlainText`
  - `testHasURLDescriptor`

---

- [ ] **Step 8: Verify `PluginLoader.loadAll` is already wired into boot (added by B4 Step 7) — do NOT add a second call**

  Task B4 Step 7 already added `PluginLoader.loadAll(into: .shared, extraFolders: [])` to `ActionEngine`'s startup path and to `reloadRules()`. Confirm it is present; do NOT add another call and do NOT re-paste `ActionEngine.swift` (that would clobber B4 and the A5 engine).

  ```sh
  grep -n "PluginLoader.loadAll" /Users/roypadina/Code/Padina/Maccay/Maccy/Actions/ActionEngine.swift
  ```

  Expected: the two calls from B4 (startup + `reloadRules`). If absent, complete B4 Step 7 first, then re-run the build:

  ```sh
  xcodebuild build -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj -scheme Maccy -destination 'platform=macOS' 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:"
  ```

  Expected: `BUILD SUCCEEDED`

---

- [ ] **Step 9: Commit**

  ```sh
  git add \
    Maccy/Resources/BundledPlugins/example-shout/plugin.json \
    Maccy/Resources/BundledPlugins/example-has-url/plugin.json \
    Maccy/Resources/BundledPlugins/example-has-url/main.js \
    MaccyTests/BundledPluginsTests.swift \
    Maccy.xcodeproj/project.pbxproj
  git commit -m "B5: Bundled example plugins + boot-time PluginLoader call

  - Add declarative example-shout action (case/upper then prepend)
  - Add JS example-has-url condition (https?:// regex)
  - Register BundledPlugins/ as folder reference in pbxproj (copied to bundle)
  - Add BundledPluginsTests: 8 tests covering registration, transform, evaluate true/false, descriptor fields
  - Wire PluginLoader.loadAll into ActionEngine.init boot path"
  ```


## Milestone C — Marketplaces + Plugins GUI + capability UX

### Task C1 — Marketplace models + resolver (download + sha256 verify)

> **Depends on:** Milestone A/B done — `Maccy/Plugins/PluginCore.swift` exists (defines `JSONValue`, `ProviderKind`), the `Plugins` PBXGroup exists, and `CryptoKit` is available (system framework, no entitlement). This task adds `Maccy/Plugins/Marketplace.swift` + `MaccyTests/MarketplaceTests.swift`. V1 is **NO-UNZIP**: a marketplace entry's source points at a folder whose `plugin.json` (and, for JS plugins, the `entry` `.js`) are fetched as plain files — no archive extraction. `install` returns the on-disk plugin folder `dir/<entry.id>/`.

- [ ] **Step 1: Create the failing test file `MaccyTests/MarketplaceTests.swift` (compile-fail first).**

  This file references `Marketplace`, `MarketplaceEntry`, `PluginSource`, `MarketplaceError`, and `MarketplaceResolver`, none of which exist yet, so it must fail to compile. Write it in full now; the marketplace.json fixture it decodes is added in Step 2.

  ```swift
  import XCTest
  import CryptoKit
  @testable import Maccy

  @MainActor
  final class MarketplaceTests: XCTestCase {
    // Saved copy of the injectable fetch hook so each test can restore the default.
    private var savedFetch: ((URL) async throws -> (Data, Int))!

    override func setUp() {
      super.setUp()
      savedFetch = MarketplaceResolver.fetch
    }

    override func tearDown() {
      // Always restore the real network fetch so a stub from one test
      // never leaks into another.
      MarketplaceResolver.fetch = savedFetch
      super.tearDown()
    }

    // MARK: - Helpers

    /// Loads the bundled marketplace.json fixture as Data.
    private func marketplaceFixtureData() throws -> Data {
      let bundle = Bundle(for: type(of: self))
      let url = try XCTUnwrap(
        bundle.url(forResource: "marketplace", withExtension: "json"),
        "marketplace.json fixture not found in test bundle"
      )
      return try Data(contentsOf: url)
    }

    /// SHA-256 hex of an arbitrary string's UTF-8 bytes (oracle for tests).
    private func sha256(_ string: String) -> String {
      let digest = SHA256.hash(data: Data(string.utf8))
      return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Decoding the marketplace index

    func testDecodeMarketplaceFixture() throws {
      let data = try marketplaceFixtureData()
      let marketplace = try JSONDecoder().decode(Marketplace.self, from: data)

      XCTAssertEqual(marketplace.id, "maccay-official")
      XCTAssertEqual(marketplace.name, "Maccay Official")
      XCTAssertEqual(marketplace.version, "1")
      XCTAssertEqual(marketplace.plugins.count, 2)

      let base64 = try XCTUnwrap(marketplace.plugins.first { $0.id == "example-base64" })
      XCTAssertEqual(base64.name, "Base64 encode")
      XCTAssertEqual(base64.kind, .action)
      XCTAssertEqual(base64.sha256, "abc123")
      // github source decoded with all fields.
      guard case let .github(repo, ref, path) = base64.source else {
        return XCTFail("expected github source, got \(base64.source)")
      }
      XCTAssertEqual(repo, "royp/maccay-plugins")
      XCTAssertEqual(ref, "main")
      XCTAssertEqual(path, "plugins/example-base64")

      let reverse = try XCTUnwrap(marketplace.plugins.first { $0.id == "example-reverse" })
      XCTAssertEqual(reverse.kind, .condition)
      // url source decoded.
      guard case let .url(string) = reverse.source else {
        return XCTFail("expected url source, got \(reverse.source)")
      }
      XCTAssertEqual(string, "https://plugins.example.com/example-reverse")
    }

    // MARK: - PluginSource Codable round-trip

    func testPluginSourceGithubRoundTrip() throws {
      let original = PluginSource.github(repo: "royp/maccay-plugins", ref: "v1.2.0", path: "plugins/foo")
      let data = try JSONEncoder().encode(original)
      let decoded = try JSONDecoder().decode(PluginSource.self, from: data)
      XCTAssertEqual(decoded, original)
    }

    func testPluginSourceURLRoundTrip() throws {
      let original = PluginSource.url("https://example.com/plugins/bar")
      let data = try JSONEncoder().encode(original)
      let decoded = try JSONDecoder().decode(PluginSource.self, from: data)
      XCTAssertEqual(decoded, original)
    }

    func testPluginSourceGithubNilPathRoundTrip() throws {
      let original = PluginSource.github(repo: "royp/maccay-plugins", ref: "main", path: nil)
      let data = try JSONEncoder().encode(original)
      let decoded = try JSONDecoder().decode(PluginSource.self, from: data)
      XCTAssertEqual(decoded, original)
    }

    // MARK: - sha256Hex known vector

    func testSHA256HexKnownVector() {
      // Standard test vector: SHA-256("abc").
      let data = Data("abc".utf8)
      XCTAssertEqual(
        MarketplaceResolver.sha256Hex(data),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
      )
    }

    func testSHA256HexEmpty() {
      XCTAssertEqual(
        MarketplaceResolver.sha256Hex(Data()),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      )
    }

    // MARK: - fetchIndex

    func testFetchIndexParsesMarketplace() async throws {
      let fixture = try marketplaceFixtureData()
      MarketplaceResolver.fetch = { _ in (fixture, 200) }

      let marketplace = try await MarketplaceResolver.fetchIndex(
        URL(string: "https://plugins.example.com/marketplace.json")!
      )
      XCTAssertEqual(marketplace.id, "maccay-official")
      XCTAssertEqual(marketplace.plugins.count, 2)
    }

    func testFetchIndexThrowsHTTPError() async {
      MarketplaceResolver.fetch = { _ in (Data(), 404) }
      do {
        _ = try await MarketplaceResolver.fetchIndex(
          URL(string: "https://plugins.example.com/marketplace.json")!
        )
        XCTFail("expected httpError to be thrown")
      } catch {
        XCTAssertEqual(error as? MarketplaceError, .httpError(404))
      }
    }

    // MARK: - download checksum verification

    func testDownloadThrowsChecksumMismatch() async {
      // The fetched plugin.json bytes won't match the declared (bogus) sha256.
      let manifestBytes = Data(#"{"id":"example-base64"}"#.utf8)
      MarketplaceResolver.fetch = { _ in (manifestBytes, 200) }

      let entry = MarketplaceEntry(
        id: "example-base64",
        name: "Base64 encode",
        description: "Base64-encode the text",
        version: "1.0.0",
        minAppVersion: nil,
        kind: .action,
        tags: nil,
        source: .url("https://plugins.example.com/example-base64"),
        sha256: "deadbeef"  // deliberately wrong
      )

      do {
        _ = try await MarketplaceResolver.download(entry)
        XCTFail("expected checksumMismatch to be thrown")
      } catch {
        XCTAssertEqual(error as? MarketplaceError, .checksumMismatch)
      }
    }

    func testDownloadSucceedsWhenChecksumMatches() async throws {
      let manifest = #"{"id":"example-base64","engine":"declarative"}"#
      let manifestBytes = Data(manifest.utf8)
      MarketplaceResolver.fetch = { _ in (manifestBytes, 200) }

      let entry = MarketplaceEntry(
        id: "example-base64",
        name: "Base64 encode",
        description: "Base64-encode the text",
        version: "1.0.0",
        minAppVersion: nil,
        kind: .action,
        tags: nil,
        source: .url("https://plugins.example.com/example-base64"),
        sha256: sha256(manifest)
      )

      let data = try await MarketplaceResolver.download(entry)
      XCTAssertEqual(data, manifestBytes)
    }

    // MARK: - install writes the folder

    func testInstallDeclarativeWritesPluginJSON() async throws {
      let manifest = #"{"id":"example-base64","name":"Base64 encode","version":"1.0.0","description":"b64","kind":"action","engine":"declarative"}"#
      let manifestBytes = Data(manifest.utf8)
      MarketplaceResolver.fetch = { _ in (manifestBytes, 200) }

      let entry = MarketplaceEntry(
        id: "example-base64",
        name: "Base64 encode",
        description: "b64",
        version: "1.0.0",
        minAppVersion: nil,
        kind: .action,
        tags: nil,
        source: .github(repo: "royp/maccay-plugins", ref: "main", path: "plugins/example-base64"),
        sha256: sha256(manifest)
      )

      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MarketplaceTests-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: dir) }

      let folder = try await MarketplaceResolver.install(
        entry, marketplaceID: "maccay-official", into: dir
      )

      XCTAssertEqual(folder.lastPathComponent, "example-base64")
      let pluginJSON = folder.appendingPathComponent("plugin.json")
      XCTAssertTrue(FileManager.default.fileExists(atPath: pluginJSON.path))
      let written = try Data(contentsOf: pluginJSON)
      XCTAssertEqual(written, manifestBytes)
    }

    func testInstallJavaScriptWritesEntryFile() async throws {
      // engine == javascript with entry "main.js": install must fetch+write both
      // plugin.json and main.js. The stub returns the manifest first, then the JS.
      let manifest = #"{"id":"example-reverse","name":"Reverse","version":"1.0.0","description":"rev","kind":"condition","engine":"javascript","entry":"main.js"}"#
      let manifestBytes = Data(manifest.utf8)
      let jsBytes = Data("function matches(s){return true;}".utf8)

      // First call (plugin.json) returns the manifest; second call (main.js) returns the JS.
      var callCount = 0
      MarketplaceResolver.fetch = { _ in
        defer { callCount += 1 }
        return callCount == 0 ? (manifestBytes, 200) : (jsBytes, 200)
      }

      let entry = MarketplaceEntry(
        id: "example-reverse",
        name: "Reverse",
        description: "rev",
        version: "1.0.0",
        minAppVersion: nil,
        kind: .condition,
        tags: nil,
        source: .url("https://plugins.example.com/example-reverse"),
        sha256: sha256(manifest)
      )

      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MarketplaceTests-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: dir) }

      let folder = try await MarketplaceResolver.install(
        entry, marketplaceID: "maccay-official", into: dir
      )

      let pluginJSON = folder.appendingPathComponent("plugin.json")
      let mainJS = folder.appendingPathComponent("main.js")
      XCTAssertTrue(FileManager.default.fileExists(atPath: pluginJSON.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: mainJS.path))
      XCTAssertEqual(try Data(contentsOf: mainJS), jsBytes)
    }
  }
  ```

- [ ] **Step 2: Add the test fixture `MaccyTests/Fixtures/marketplace.json`.**

  ```json
  {
    "id": "maccay-official",
    "name": "Maccay Official",
    "version": "1",
    "description": "First-party Maccay plugins",
    "maintainer": "royp",
    "plugins": [
      {
        "id": "example-base64",
        "name": "Base64 encode",
        "description": "Base64-encode the copied text",
        "version": "1.0.0",
        "minAppVersion": "2.6.0",
        "kind": "action",
        "tags": ["encoding", "text"],
        "source": {
          "type": "github",
          "repo": "royp/maccay-plugins",
          "ref": "main",
          "path": "plugins/example-base64"
        },
        "sha256": "abc123"
      },
      {
        "id": "example-reverse",
        "name": "Reverse text condition",
        "description": "Matches when the text reversed equals itself",
        "version": "1.0.0",
        "minAppVersion": null,
        "kind": "condition",
        "tags": null,
        "source": {
          "type": "url",
          "url": "https://plugins.example.com/example-reverse"
        },
        "sha256": "def456"
      }
    ]
  }
  ```

- [ ] **Step 3: Register the fixture in pbxproj (test bundle Resources).** Follow the `guy.jpeg` precedent: the file sits flat in the MaccyTests group with the `Fixtures/` subfolder encoded in `path`, and goes into the test Resources build phase (`DA360DAE1E3DF137005C6F6B`), not Sources.

  Generate one fileRef UUID and one buildFile UUID:
  ```sh
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # fileRef_UUID
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # buildFile_UUID
  ```

  (a) `PBXBuildFile` — add near the other `… in Resources` entries (e.g. after the `guy.jpeg in Resources` line 95):
  ```
  <buildFile_UUID> /* marketplace.json in Resources */ = {isa = PBXBuildFile; fileRef = <fileRef_UUID> /* marketplace.json */; };
  ```

  (b) `PBXFileReference` — add near line 334 (`guy.jpeg`); note `lastKnownFileType = text.json` and the `Fixtures/` path segment:
  ```
  <fileRef_UUID> /* marketplace.json */ = {isa = PBXFileReference; lastKnownFileType = text.json; path = Fixtures/marketplace.json; sourceTree = "<group>"; };
  ```

  (c) `PBXGroup children` — add `<fileRef_UUID>` to the MaccyTests group `DA360DB11E3DF137005C6F6B /* MaccyTests */` `children` (right after the `guy.jpeg` reference at line 775):
  ```
  <fileRef_UUID> /* marketplace.json */,
  ```

  (d) `PBXResourcesBuildPhase files` — add `<buildFile_UUID>` to the test Resources phase `DA360DAE1E3DF137005C6F6B /* Resources */` `files` (right after the `guy.jpeg in Resources` line 1056):
  ```
  <buildFile_UUID> /* marketplace.json in Resources */,
  ```

- [ ] **Step 4: Register the test file `MaccyTests/MarketplaceTests.swift` in pbxproj (test bundle Sources).** Generate two more UUIDs:
  ```sh
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # tests_fileRef_UUID
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # tests_buildFile_UUID
  ```

  (a) `PBXBuildFile` (near the other test `… in Sources` entries):
  ```
  <tests_buildFile_UUID> /* MarketplaceTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <tests_fileRef_UUID> /* MarketplaceTests.swift */; };
  ```

  (b) `PBXFileReference` (test sources have a bare filename `path`, like the other `*Tests.swift`):
  ```
  <tests_fileRef_UUID> /* MarketplaceTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MarketplaceTests.swift; sourceTree = "<group>"; };
  ```

  (c) `PBXGroup children` — add `<tests_fileRef_UUID>` to the MaccyTests group `DA360DB11E3DF137005C6F6B /* MaccyTests */` `children`:
  ```
  <tests_fileRef_UUID> /* MarketplaceTests.swift */,
  ```

  (d) `PBXSourcesBuildPhase files` — add `<tests_buildFile_UUID>` to the test Sources phase `DA360DAC1E3DF137005C6F6B /* Sources */` `files`:
  ```
  <tests_buildFile_UUID> /* MarketplaceTests.swift in Sources */,
  ```

- [ ] **Step 5: Run the test and expect a COMPILE FAILURE (red).** `Marketplace`, `MarketplaceEntry`, `PluginSource`, `MarketplaceError`, and `MarketplaceResolver` do not exist yet, so the test target fails to build.
  ```sh
  xcodebuild test -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj -scheme Maccy -destination 'platform=macOS' -only-testing:MaccyTests/MarketplaceTests
  ```
  Expected: build error `cannot find 'MarketplaceResolver' in scope` (and the other types). This confirms the test is wired in and currently failing.

- [ ] **Step 6: Create `Maccy/Plugins/Marketplace.swift` with the FULL implementation.**

  ```swift
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

      // 4. For a JS plugin, fetch + write the entry script alongside plugin.json.
      let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
      if manifest.engine == .javascript, let entryFile = manifest.entry {
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
  ```

  > **Note for the engineer:** `install` decodes `PluginManifest` (from Task B1) to learn `engine`/`entry`. The `download` test uses a manifest body that does NOT need to be a valid `PluginManifest` because `download` only hashes bytes — but `install`'s two tests feed full valid-enough manifests so the decode succeeds. `PluginManifest.engine` is the `ProviderEngine` enum and `PluginManifest.entry` is `String?` per the Interface Contract.

- [ ] **Step 7: Register `Maccy/Plugins/Marketplace.swift` in pbxproj (app target Sources).** The `Plugins` PBXGroup already exists from Milestone A/B, so this is the standard 4-edit recipe (files sit flat in the `Maccy` group with the subfolder in `path`). Generate two UUIDs:
  ```sh
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # mp_fileRef_UUID
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # mp_buildFile_UUID
  ```

  (a) `PBXBuildFile`:
  ```
  <mp_buildFile_UUID> /* Marketplace.swift in Sources */ = {isa = PBXBuildFile; fileRef = <mp_fileRef_UUID> /* Marketplace.swift */; };
  ```

  (b) `PBXFileReference`:
  ```
  <mp_fileRef_UUID> /* Marketplace.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Plugins/Marketplace.swift; sourceTree = "<group>"; };
  ```

  (c) `PBXGroup children` — add `<mp_fileRef_UUID>` into the `DAEE38451E3DBEB100DD2966 /* Maccy */` group `children`:
  ```
  <mp_fileRef_UUID> /* Marketplace.swift */,
  ```

  (d) `PBXSourcesBuildPhase files` — add `<mp_buildFile_UUID>` into `DAEE383F1E3DBEB100DD2966 /* Sources */` `files`:
  ```
  <mp_buildFile_UUID> /* Marketplace.swift in Sources */,
  ```

- [ ] **Step 8: Run the test and expect PASS (green).**
  ```sh
  xcodebuild test -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj -scheme Maccy -destination 'platform=macOS' -only-testing:MaccyTests/MarketplaceTests
  ```
  Expected: `Test Suite 'MarketplaceTests' passed` — all of `testDecodeMarketplaceFixture`, `testPluginSourceGithubRoundTrip`, `testPluginSourceURLRoundTrip`, `testPluginSourceGithubNilPathRoundTrip`, `testSHA256HexKnownVector`, `testSHA256HexEmpty`, `testFetchIndexParsesMarketplace`, `testFetchIndexThrowsHTTPError`, `testDownloadThrowsChecksumMismatch`, `testDownloadSucceedsWhenChecksumMatches`, `testInstallDeclarativeWritesPluginJSON`, and `testInstallJavaScriptWritesEntryFile` green.

- [ ] **Step 9: Run the full unit suite to confirm no regression.**
  ```sh
  xcodebuild test -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj -scheme Maccy -destination 'platform=macOS' -only-testing:MaccyTests
  ```
  Expected: all suites pass.

- [ ] **Step 10: Commit.** (Do NOT push — net-new push needs explicit approval.)
  ```sh
  git add Maccy/Plugins/Marketplace.swift MaccyTests/MarketplaceTests.swift MaccyTests/Fixtures/marketplace.json Maccy.xcodeproj/project.pbxproj
  git commit -m "$(cat <<'EOF'
  Plugins C1: Marketplace models + resolver (download + sha256 verify)

  Add Maccy/Plugins/Marketplace.swift: Marketplace/MarketplaceEntry Codable
  models, type-tagged PluginSource (github/url) with custom Codable,
  MarketplaceError, and @MainActor MarketplaceResolver with injectable fetch,
  fetchIndex, sha256Hex (CryptoKit), V1 no-unzip download (verifies plugin.json
  sha256) and install (writes plugin.json atomically + the JS entry file when
  engine==javascript). Adds MarketplaceTests + marketplace.json fixture.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Tkhip6qSb9uiFxwiJQbcKX
  EOF
  )"
  ```

---

Files this task creates/touches (absolute):
- `/Users/roypadina/Code/Padina/Maccay/Maccy/Plugins/Marketplace.swift` (new)
- `/Users/roypadina/Code/Padina/Maccay/MaccyTests/MarketplaceTests.swift` (new)
- `/Users/roypadina/Code/Padina/Maccay/MaccyTests/Fixtures/marketplace.json` (new)
- `/Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj/project.pbxproj` (modified — 3 pbxproj registrations: app Sources, test Sources, test Resources)

Cross-task dependencies the engineer must have landed first: `PluginCore.swift` (`JSONValue`, `ProviderKind`) and the `Plugins` PBXGroup from Milestone A; `PluginManifest.swift` (`engine: ProviderEngine`, `entry: String?`) from Task B1 — `MarketplaceResolver.install` decodes `PluginManifest` to decide whether to fetch the JS entry file.


---

### Task C2: MarketplaceStore

**Prerequisites:** C1 (`Marketplace.swift`, `MarketplaceResolver`) is complete and committed on `feat/plugin-system`. `PluginLoader.swift` is complete (B4). The `Marketplace`, `MarketplaceEntry`, `PluginSource`, `MarketplaceResolver`, and `MarketplaceError` types are defined in `Maccy/Plugins/Marketplace.swift`.

---

- [ ] **Step 1: Add the two Defaults keys to `Maccy/Extensions/Defaults.Keys+Names.swift`**

  Open `/Users/roypadina/Code/Padina/Maccay/Maccy/Extensions/Defaults.Keys+Names.swift`. Append the two new keys inside the existing `extension Defaults.Keys` block, immediately after line 61 (`static let previewWidth …`) and before the closing `}` on line 62.

  The complete updated file becomes:

  ```swift
  import AppKit
  import Defaults

  struct StorageType {
    static let files = StorageType(types: [.fileURL])
    static let images = StorageType(types: [.png, .tiff])
    static let text = StorageType(types: [.html, .rtf, .string])
    static let all = StorageType(types: files.types + images.types + text.types)

    var types: [NSPasteboard.PasteboardType]
  }

  extension Defaults.Keys {
    static let clearOnQuit = Key<Bool>("clearOnQuit", default: false)
    static let clearSystemClipboard = Key<Bool>("clearSystemClipboard", default: false)
    static let clipboardCheckInterval = Key<Double>("clipboardCheckInterval", default: 0.5)
    static let enabledPasteboardTypes = Key<Set<NSPasteboard.PasteboardType>>(
      "enabledPasteboardTypes", default: Set(StorageType.all.types)
    )
    static let highlightMatch = Key<HighlightMatch>("highlightMatch", default: .bold)
    static let ignoreAllAppsExceptListed = Key<Bool>("ignoreAllAppsExceptListed", default: false)
    static let ignoreEvents = Key<Bool>("ignoreEvents", default: false)
    static let ignoreOnlyNextEvent = Key<Bool>("ignoreOnlyNextEvent", default: false)
    static let ignoreRegexp = Key<[String]>("ignoreRegexp", default: [])
    static let ignoredApps = Key<[String]>("ignoredApps", default: [])
    static let ignoredPasteboardTypes = Key<Set<String>>(
      "ignoredPasteboardTypes",
      default: Set([
        "Pasteboard generator type",
        "com.agilebits.onepassword",
        "com.typeit4me.clipping",
        "de.petermaurer.TransientPasteboardType",
        "net.antelle.keeweb"
      ])
    )
    static let imageMaxHeight = Key<Int>("imageMaxHeight", default: 40)
    static let lastReviewRequestedAt = Key<Date>("lastReviewRequestedAt", default: Date.now)
    static let menuIcon = Key<MenuIcon>("menuIcon", default: .maccy)
    static let migrations = Key<[String: Bool]>("migrations", default: [:])
    static let numberOfUsages = Key<Int>("numberOfUsages", default: 0)
    static let pasteByDefault = Key<Bool>("pasteByDefault", default: false)
    static let pinTo = Key<PinsPosition>("pinTo", default: .top)
    static let popupPosition = Key<PopupPosition>("popupPosition", default: .cursor)
    static let popupScreen = Key<Int>("popupScreen", default: 0)
    static let previewDelay = Key<Int>("previewDelay", default: 1500)
    static let removeFormattingByDefault = Key<Bool>("removeFormattingByDefault", default: false)
    static let searchMode = Key<Search.Mode>("searchMode", default: .exact)
    static let showFooter = Key<Bool>("showFooter", default: true)
    static let showInStatusBar = Key<Bool>("showInStatusBar", default: true)
    static let showRecentCopyInMenuBar = Key<Bool>("showRecentCopyInMenuBar", default: false)
    static let showSearch = Key<Bool>("showSearch", default: true)
    static let searchVisibility = Key<SearchVisibility>("searchVisibility", default: .always)
    static let showSpecialSymbols = Key<Bool>("showSpecialSymbols", default: true)
    static let showTitle = Key<Bool>("showTitle", default: true)
    static let size = Key<Int>("historySize", default: 200)
    static let sortBy = Key<Sorter.By>("sortBy", default: .lastCopiedAt)
    static let suppressClearAlert = Key<Bool>("suppressClearAlert", default: false)
    static let windowSize = Key<NSSize>("windowSize", default: NSSize(width: 450, height: 800))
    static let windowPosition = Key<NSPoint>("windowPosition", default: NSPoint(x: 0.5, y: 0.8))
    static let showApplicationIcons = Key<Bool>("showApplicationIcons", default: false)
    static let previewWidth = Key<CGFloat>("previewWidth", default: 400)

    // MARK: - Plugin system (Milestone C)
    static let installedMarketplaces   = Key<[String]>("installedMarketplaces", default: [])
    static let localMarketplaceFolders = Key<[String]>("localMarketplaceFolders", default: [])
  }
  ```

  > `pluginCapabilityGrants` is intentionally omitted here — it is added in Task C3 alongside `CapabilityManager`, which owns that key. The plan's Interface Contract lists all three keys together as a reference, but C2 only needs the two keys it reads/writes.

---

- [ ] **Step 2: Write the failing tests — `MaccyTests/MarketplaceStoreTests.swift`**

  Create `/Users/roypadina/Code/Padina/Maccay/MaccyTests/MarketplaceStoreTests.swift` with the full test class. All tests will fail to compile until Step 4 (the implementation file) is registered in pbxproj and written.

  ```swift
  import XCTest
  import Defaults
  @testable import Maccy

  @MainActor
  final class MarketplaceStoreTests: XCTestCase {

    // Save and restore Defaults keys around every test so tests are isolated.
    private var savedMarketplaces: [String] = []
    private var savedLocalFolders: [String] = []

    override func setUp() async throws {
      try await super.setUp()
      savedMarketplaces = Defaults[.installedMarketplaces]
      savedLocalFolders = Defaults[.localMarketplaceFolders]
      Defaults[.installedMarketplaces] = []
      Defaults[.localMarketplaceFolders] = []
    }

    override func tearDown() async throws {
      Defaults[.installedMarketplaces] = savedMarketplaces
      Defaults[.localMarketplaceFolders] = savedLocalFolders
      try await super.tearDown()
    }

    // MARK: - registeredMarketplaceURLs

    func testRegisteredMarketplaceURLsAlwaysPrependsOfficial() {
      // Even with no user-added marketplaces the official URL is returned first.
      let store = MarketplaceStore()
      let urls = store.registeredMarketplaceURLs()
      XCTAssertFalse(urls.isEmpty)
      XCTAssertEqual(urls.first, kMaccayOfficialMarketplaceURL)
    }

    func testRegisteredMarketplaceURLsIncludesUserAdded() {
      let store = MarketplaceStore()
      let extra = URL(string: "https://example.com/marketplace.json")!
      Defaults[.installedMarketplaces] = [extra.absoluteString]
      let urls = store.registeredMarketplaceURLs()
      XCTAssertTrue(urls.contains(extra))
    }

    func testRegisteredMarketplaceURLsOfficialNotDuplicatedWhenUserAddsIt() {
      // If the user somehow stores the official URL in Defaults it must not appear twice.
      let store = MarketplaceStore()
      Defaults[.installedMarketplaces] = [kMaccayOfficialMarketplaceURL.absoluteString]
      let urls = store.registeredMarketplaceURLs()
      let officialCount = urls.filter { $0 == kMaccayOfficialMarketplaceURL }.count
      XCTAssertEqual(officialCount, 1)
    }

    // MARK: - removeMarketplace(id:)

    func testRemoveMarketplaceByIDRemovesFromCache() async {
      let store = MarketplaceStore()
      // Inject a cached marketplace directly (bypassing network).
      let mp = Marketplace(
        id: "test.mp",
        name: "Test",
        version: "1.0",
        description: nil,
        maintainer: nil,
        plugins: []
      )
      store.injectForTesting(marketplace: mp,
                             url: URL(string: "https://example.com/mp.json")!)
      store.removeMarketplace(id: "test.mp")
      XCTAssertNil(store.cachedMarketplace(id: "test.mp"))
    }

    func testRemoveMarketplaceByIDRemovesURLFromDefaults() async {
      let store = MarketplaceStore()
      let url = URL(string: "https://example.com/mp2.json")!
      let mp = Marketplace(
        id: "test.mp2",
        name: "Test2",
        version: "1.0",
        description: nil,
        maintainer: nil,
        plugins: []
      )
      store.injectForTesting(marketplace: mp, url: url)
      Defaults[.installedMarketplaces] = [url.absoluteString]
      store.removeMarketplace(id: "test.mp2")
      XCTAssertFalse(Defaults[.installedMarketplaces].contains(url.absoluteString))
    }

    // MARK: - removeMarketplace(url:)

    func testRemoveMarketplaceByURLRemovesFromDefaults() {
      let store = MarketplaceStore()
      let url = URL(string: "https://example.com/mp3.json")!
      Defaults[.installedMarketplaces] = [url.absoluteString]
      store.removeMarketplace(url: url)
      XCTAssertFalse(Defaults[.installedMarketplaces].contains(url.absoluteString))
    }

    // MARK: - localFolders / addLocalFolder

    func testLocalFoldersEmptyByDefault() {
      let store = MarketplaceStore()
      XCTAssertTrue(store.localFolders().isEmpty)
    }

    func testAddLocalFolderPersists() {
      let store = MarketplaceStore()
      let url = URL(fileURLWithPath: "/tmp/my-plugins")
      store.addLocalFolder(url)
      XCTAssertTrue(Defaults[.localMarketplaceFolders].contains(url.path))
      XCTAssertTrue(store.localFolders().contains(url))
    }

    func testAddLocalFolderDeduplicates() {
      let store = MarketplaceStore()
      let url = URL(fileURLWithPath: "/tmp/my-plugins")
      store.addLocalFolder(url)
      store.addLocalFolder(url)
      XCTAssertEqual(Defaults[.localMarketplaceFolders].filter { $0 == url.path }.count, 1)
    }

    func testLocalFoldersReturnsURLsFromDefaults() {
      let store = MarketplaceStore()
      let path = "/tmp/pluginfolder"
      Defaults[.localMarketplaceFolders] = [path]
      let folders = store.localFolders()
      XCTAssertEqual(folders, [URL(fileURLWithPath: path)])
    }

    // MARK: - remove(pluginID:)

    func testRemovePluginIDRemovesFromInstalledPluginsDirectory() throws {
      let store = MarketplaceStore()
      // Create a fake plugin folder in the installed-plugins directory.
      let pluginsDir = PluginLoader.installedPluginsURL()
      let pluginDir = pluginsDir.appendingPathComponent("com.example.fakeplugin")
      try FileManager.default.createDirectory(at: pluginDir,
                                              withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: pluginDir) }

      store.remove(pluginID: "com.example.fakeplugin")
      XCTAssertFalse(FileManager.default.fileExists(atPath: pluginDir.path))
    }

    func testRemovePluginIDSilentlySucceedsForNonexistentPlugin() {
      let store = MarketplaceStore()
      // Should not throw or crash.
      store.remove(pluginID: "com.example.does-not-exist")
    }

    // MARK: - kMaccayOfficialMarketplaceURL

    func testOfficialMarketplaceURLIsHTTPS() {
      XCTAssertEqual(kMaccayOfficialMarketplaceURL.scheme, "https")
    }
  }
  ```

---

- [ ] **Step 3: Register `MarketplaceStoreTests.swift` in pbxproj (test target)**

  Generate two 24-hex UUIDs:

  ```sh
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # → TEST_FR_UUID
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # → TEST_BF_UUID
  ```

  Open `/Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj/project.pbxproj` and make four edits (replace `TEST_FR_UUID` / `TEST_BF_UUID` with the generated values):

  **(3a) In the `/* Begin PBXBuildFile section */`**, add:
  ```
  TEST_BF_UUID /* MarketplaceStoreTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = TEST_FR_UUID /* MarketplaceStoreTests.swift */; };
  ```

  **(3b) In the `/* Begin PBXFileReference section */`**, add:
  ```
  TEST_FR_UUID /* MarketplaceStoreTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MarketplaceStoreTests.swift; sourceTree = "<group>"; };
  ```

  **(3c) In the `MaccyTests` PBXGroup** (`path = MaccyTests;`), add `TEST_FR_UUID` to `children`:
  ```
  TEST_FR_UUID /* MarketplaceStoreTests.swift */,
  ```

  **(3d) In `DA360DAC1E3DF137005C6F6B /* Sources */`** (MaccyTests build phase `files`), add:
  ```
  TEST_BF_UUID /* MarketplaceStoreTests.swift in Sources */,
  ```

---

- [ ] **Step 4: Confirm tests fail to compile (MarketplaceStore type not yet defined)**

  Run:
  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests/MarketplaceStoreTests \
    2>&1 | grep -E "error:|BUILD FAILED"
  ```

  Expected: compile error such as `error: cannot find type 'MarketplaceStore' in scope` and `BUILD FAILED`. This confirms the test is wired up correctly and the implementation is genuinely missing.

---

- [ ] **Step 5: Create `Maccy/Plugins/MarketplaceStore.swift`**

  Create `/Users/roypadina/Code/Padina/Maccay/Maccy/Plugins/MarketplaceStore.swift`:

  ```swift
  import Foundation
  import Defaults

  // The official Maccay plugin marketplace index.
  // TODO(OWNER): replace the placeholder host with the real maccay-plugins GitHub Pages URL
  // once the maccay-plugins repo is created and approved (Milestone D).
  // The URL must point to a raw marketplace.json served over HTTPS.
  let kMaccayOfficialMarketplaceURL = URL(
    string: "https://OWNER.github.io/maccay-plugins/marketplace.json"
  )!

  // Manages the set of registered marketplace URLs and local plugin folders.
  // All state that needs to survive app restarts is persisted via Defaults.
  // The in-memory `cache` stores the last successfully fetched Marketplace index
  // for each URL, keyed by the marketplace's `id` field. It is populated by
  // `addMarketplace` and `refreshAll`; it is NOT persisted (re-fetched on launch).
  @MainActor
  final class MarketplaceStore {

    static let shared = MarketplaceStore()

    // In-memory cache: marketplace id → (Marketplace, source URL).
    // Populated lazily by addMarketplace / refreshAll.
    private var cache: [String: (marketplace: Marketplace, url: URL)] = [:]

    // MARK: - Registered marketplace URLs

    /// Returns all registered marketplace URLs: the official URL is always first,
    /// followed by user-added URLs from Defaults. The official URL is never
    /// duplicated even if the user stored it in Defaults.
    func registeredMarketplaceURLs() -> [URL] {
      let stored = Defaults[.installedMarketplaces].compactMap { URL(string: $0) }
      // Prepend official, deduplicate by absolute string.
      var seen = Set<String>()
      seen.insert(kMaccayOfficialMarketplaceURL.absoluteString)
      var result: [URL] = [kMaccayOfficialMarketplaceURL]
      for url in stored where seen.insert(url.absoluteString).inserted {
        result.append(url)
      }
      return result
    }

    // MARK: - Add / remove marketplaces

    /// Downloads the index at `url`, validates it is a valid Marketplace, stores
    /// the URL in Defaults, caches the result, and returns the Marketplace.
    /// Throws if the network request fails or the index cannot be parsed.
    func addMarketplace(_ url: URL) async throws -> Marketplace {
      let mp = try await MarketplaceResolver.fetchIndex(url)
      // Persist URL (avoid duplicates).
      var stored = Defaults[.installedMarketplaces]
      let urlString = url.absoluteString
      if !stored.contains(urlString) {
        stored.append(urlString)
        Defaults[.installedMarketplaces] = stored
      }
      cache[mp.id] = (mp, url)
      return mp
    }

    /// Removes the marketplace with the given id from the cache and from Defaults.
    func removeMarketplace(id: String) {
      guard let (_, url) = cache[id] else { return }
      cache.removeValue(forKey: id)
      removeURL(url)
    }

    /// Removes the marketplace whose source URL matches `url` from Defaults and the cache.
    func removeMarketplace(url: URL) {
      let urlString = url.absoluteString
      // Remove from cache (any entry whose URL matches).
      let keysToRemove = cache.compactMap { (key, value) -> String? in
        value.url.absoluteString == urlString ? key : nil
      }
      for key in keysToRemove { cache.removeValue(forKey: key) }
      removeURL(url)
    }

    // MARK: - Refresh

    /// Re-fetches all registered marketplace URLs in parallel and updates the cache.
    /// Failures are silently ignored so a single broken marketplace does not block the rest.
    func refreshAll() async {
      let urls = registeredMarketplaceURLs()
      await withTaskGroup(of: Void.self) { group in
        for url in urls {
          group.addTask {
            if let mp = try? await MarketplaceResolver.fetchIndex(url) {
              await MainActor.run {
                self.cache[mp.id] = (mp, url)
              }
            }
          }
        }
      }
    }

    // MARK: - Install / remove plugins

    /// Downloads, verifies, and installs a plugin entry from a marketplace.
    /// The plugin is extracted into the shared installed-plugins directory.
    func install(_ entry: MarketplaceEntry, marketplaceID: String) async throws {
      let dir = PluginLoader.installedPluginsURL()
      _ = try await MarketplaceResolver.install(entry, marketplaceID: marketplaceID, into: dir)
    }

    /// Removes the installed plugin folder for `pluginID` from Application Support.
    /// Silently does nothing if no folder exists for that id.
    func remove(pluginID: String) {
      let dir = PluginLoader.installedPluginsURL().appendingPathComponent(pluginID)
      guard FileManager.default.fileExists(atPath: dir.path) else { return }
      try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Local folders

    /// Returns the local plugin folder URLs stored in Defaults.
    func localFolders() -> [URL] {
      Defaults[.localMarketplaceFolders].map { URL(fileURLWithPath: $0) }
    }

    /// Adds a local folder URL to Defaults (deduplicated by path).
    func addLocalFolder(_ url: URL) {
      var stored = Defaults[.localMarketplaceFolders]
      let path = url.path
      guard !stored.contains(path) else { return }
      stored.append(path)
      Defaults[.localMarketplaceFolders] = stored
    }

    // MARK: - Testing support

    // These two methods exist solely to let unit tests inject state without
    // triggering network requests. They are NOT part of the public API surface
    // consumed by the GUI or the plugin loader.

    /// Injects a pre-built `Marketplace` + its source URL into the cache.
    /// Used by `MarketplaceStoreTests` to test remove/lookup without a network call.
    func injectForTesting(marketplace: Marketplace, url: URL) {
      cache[marketplace.id] = (marketplace, url)
    }

    /// Returns the cached Marketplace for `id`, or nil if not cached.
    /// Used by `MarketplaceStoreTests` to assert cache state after mutations.
    func cachedMarketplace(id: String) -> Marketplace? {
      cache[id]?.marketplace
    }

    // MARK: - Private helpers

    private func removeURL(_ url: URL) {
      let urlString = url.absoluteString
      Defaults[.installedMarketplaces] = Defaults[.installedMarketplaces].filter {
        $0 != urlString
      }
    }
  }
  ```

---

- [ ] **Step 6: Register `MarketplaceStore.swift` in pbxproj (app target)**

  Because `Maccy/Plugins/` is a new subdirectory that does not yet exist as a PBXGroup, this step requires **five** pbxproj edits (create group + file reference + build file + two children insertions). However, note that prior tasks (B1–B4) will have already created the `Plugins` PBXGroup. If the group already exists, skip sub-step (6a) and (6b-group-creation) and only do (6c)–(6f).

  Generate two 24-hex UUIDs:
  ```sh
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # → APP_FR_UUID
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # → APP_BF_UUID
  ```

  Open `/Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj/project.pbxproj`:

  **(6a) If the `Plugins` PBXGroup does not yet exist**, generate one more UUID (`PLUGINS_GROUP_UUID`) and add the group entry:
  ```
  PLUGINS_GROUP_UUID /* Plugins */ = {
      isa = PBXGroup;
      children = (
          APP_FR_UUID /* MarketplaceStore.swift */,
      );
      path = Plugins;
      sourceTree = "<group>";
  };
  ```
  Then insert `PLUGINS_GROUP_UUID /* Plugins */,` into the `DAEE38451E3DBEB100DD2966 /* Maccy */` group's `children` array.

  **(6b) If the `Plugins` PBXGroup already exists** (created by B1–B4), simply add `APP_FR_UUID /* MarketplaceStore.swift */,` to that group's `children` array.

  **(6c) In `/* Begin PBXBuildFile section */`**, add:
  ```
  APP_BF_UUID /* MarketplaceStore.swift in Sources */ = {isa = PBXBuildFile; fileRef = APP_FR_UUID /* MarketplaceStore.swift */; };
  ```

  **(6d) In `/* Begin PBXFileReference section */`**, add:
  ```
  APP_FR_UUID /* MarketplaceStore.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MarketplaceStore.swift; sourceTree = "<group>"; };
  ```

  > Note: `path = MarketplaceStore.swift` (filename only, not `Plugins/MarketplaceStore.swift`) because the PBXGroup node itself already carries `path = Plugins`.

  **(6e) In `DAEE383F1E3DBEB100DD2966 /* Sources */`** (app target build phase `files`), add:
  ```
  APP_BF_UUID /* MarketplaceStore.swift in Sources */,
  ```

---

- [ ] **Step 7: Update `ActionEngine.swift` to pass `extraFolders` to `PluginLoader.loadAll`**

  Open `/Users/roypadina/Code/Padina/Maccay/Maccy/Actions/ActionEngine.swift`. The `ActionEngine` initializer (or boot call, depending on how Task B4 wired the initial plugin load) calls `PluginLoader.loadAll(into:extraFolders:)`. Update that call site to pass `MarketplaceStore.shared.localFolders()`.

  The existing `ActionEngine` file shown in the code facts does not yet call `PluginLoader` (that wiring is added in Task B5). The authoritative call is introduced in B5 as part of the boot sequence. When B5's implementation writes that call, it must use this form:

  ```swift
  PluginLoader.loadAll(into: ProviderRegistry.shared,
                       extraFolders: MarketplaceStore.shared.localFolders())
  ```

  If B5 is already committed, locate the `PluginLoader.loadAll` call in `ActionEngine.swift` and confirm it already matches this signature. If B5 wrote it without `extraFolders:` or with a hard-coded empty array, replace **only that call**. The full body of the function containing the call must be shown; here is the expected form based on the contract (the function that calls it is `private init()` or a helper called from it):

  ```swift
  private init() {
    // Register built-in and first-party providers (added in A3/A4).
    BuiltinProviders.registerAll(into: ProviderRegistry.shared)
    FirstPartyProviders.registerAll(into: ProviderRegistry.shared)
    // Load folder-based plugins (bundled + Application Support + local folders).
    PluginLoader.loadAll(into: ProviderRegistry.shared,
                         extraFolders: MarketplaceStore.shared.localFolders())
  }
  ```

  > If `BuiltinProviders.registerAll` / `FirstPartyProviders.registerAll` were named differently in A3/A4, use the actual names from those files — the key requirement here is that `PluginLoader.loadAll` receives `extraFolders: MarketplaceStore.shared.localFolders()`. Do NOT touch any other line in the file.

---

- [ ] **Step 8: Run tests — expect PASS**

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests/MarketplaceStoreTests
  ```

  Expected: all 11 test methods pass, `TEST SUCCEEDED`.

  If `testRemovePluginIDRemovesFromInstalledPluginsDirectory` fails because `PluginLoader.installedPluginsURL()` returns a sandboxed path that the test runner cannot create directories at, wrap the `createDirectory` call with a `try XCTSkipIf(!FileManager.default.isWritableFile(atPath: PluginLoader.installedPluginsURL().path), "Installed plugins dir not writable in test sandbox")` guard.

---

- [ ] **Step 9: Run the full unit-test suite to confirm no regressions**

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests
  ```

  Expected: all existing tests plus the 11 new `MarketplaceStoreTests` pass, `TEST SUCCEEDED`.

---

- [ ] **Step 10: Commit**

  ```sh
  git -C /Users/roypadina/Code/Padina/Maccay add \
    Maccy/Extensions/Defaults.Keys+Names.swift \
    Maccy/Plugins/MarketplaceStore.swift \
    MaccyTests/MarketplaceStoreTests.swift \
    Maccy.xcodeproj/project.pbxproj
  git -C /Users/roypadina/Code/Padina/Maccay commit -m "$(cat <<'EOF'
  Plugin system C2: MarketplaceStore + Defaults keys

  Adds MarketplaceStore (@MainActor) with in-memory id→Marketplace cache,
  registeredMarketplaceURLs (official prepended, deduped), addMarketplace/
  removeMarketplace(id:)/removeMarketplace(url:)/refreshAll/install/remove/
  localFolders/addLocalFolder. Adds installedMarketplaces and
  localMarketplaceFolders Defaults keys. Wires PluginLoader.loadAll to pass
  extraFolders: MarketplaceStore.shared.localFolders(). 11 new unit tests.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```


---

### Task C3: CapabilityManager

**Goal:** Persisted per-plugin capability grants, consent predicate, revoke, and source-trust helper.

**Assumes done:** Tasks A1–C2 (PluginCore types including `Capability` and `ProviderSource` exist; Defaults.Keys+Names.swift already has `installedMarketplaces` and `localMarketplaceFolders` from C2). Per Global Constraints there is no nested `Plugins` PBXGroup; register `CapabilityManager.swift` flat in the `DAEE38451E3DBEB100DD2966 /* Maccy */` group with `path = Plugins/CapabilityManager.swift`.

**Files touched:**
- `Maccy/Plugins/CapabilityManager.swift` — new file
- `MaccyTests/CapabilityManagerTests.swift` — new test file
- `Maccy/Extensions/Defaults.Keys+Names.swift` — add `pluginCapabilityGrants` key
- `Maccy.xcodeproj/project.pbxproj` — 4 entries each for the two new `.swift` files

---

- [ ] **Step 1: Generate pbxproj UUIDs**

  Run these four commands and keep the output — you need one fileRef UUID and one buildFile UUID per file:

  ```sh
  # CapabilityManager.swift — app target
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # → CM_FILEREF
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # → CM_BUILDFILE

  # CapabilityManagerTests.swift — test target
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # → CMT_FILEREF
  uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'   # → CMT_BUILDFILE
  ```

  Substitute the generated values for `CM_FILEREF`, `CM_BUILDFILE`, `CMT_FILEREF`, `CMT_BUILDFILE` in Step 6.

---

- [ ] **Step 2: Write the failing test** — `MaccyTests/CapabilityManagerTests.swift`

  ```swift
  import XCTest
  import Defaults
  @testable import Maccy

  @MainActor
  final class CapabilityManagerTests: XCTestCase {

    // Save and restore Defaults so tests are isolated.
    private var savedGrants: [String: [Capability]] = [:]

    override func setUp() async throws {
      try await super.setUp()
      savedGrants = Defaults[.pluginCapabilityGrants]
      Defaults[.pluginCapabilityGrants] = [:]
    }

    override func tearDown() async throws {
      Defaults[.pluginCapabilityGrants] = savedGrants
      try await super.tearDown()
    }

    // MARK: - grantedCapabilities

    func testGrantedCapabilitiesEmptyByDefault() {
      let cm = CapabilityManager()
      XCTAssertEqual(cm.grantedCapabilities(pluginID: "com.example.plugin"), [])
    }

    func testGrantedCapabilitiesAfterGrant() {
      let cm = CapabilityManager()
      cm.grant([.network, .fileRead], pluginID: "com.example.plugin")
      let result = cm.grantedCapabilities(pluginID: "com.example.plugin")
      XCTAssertEqual(Set(result), Set([Capability.network, Capability.fileRead]))
    }

    func testGrantedCapabilitiesIsolatedByPluginID() {
      let cm = CapabilityManager()
      cm.grant([.network], pluginID: "com.example.a")
      cm.grant([.storage], pluginID: "com.example.b")
      XCTAssertEqual(cm.grantedCapabilities(pluginID: "com.example.a"), [.network])
      XCTAssertEqual(cm.grantedCapabilities(pluginID: "com.example.b"), [.storage])
    }

    // MARK: - needsConsent

    func testNeedsConsentTrueWhenNoneGranted() {
      let cm = CapabilityManager()
      XCTAssertTrue(cm.needsConsent(pluginID: "com.example.plugin", declared: [.network]))
    }

    func testNeedsConsentFalseWhenAllGranted() {
      let cm = CapabilityManager()
      cm.grant([.network, .fileRead], pluginID: "com.example.plugin")
      XCTAssertFalse(cm.needsConsent(pluginID: "com.example.plugin", declared: [.network, .fileRead]))
    }

    func testNeedsConsentTrueWhenPartiallyGranted() {
      let cm = CapabilityManager()
      cm.grant([.network], pluginID: "com.example.plugin")
      XCTAssertTrue(cm.needsConsent(pluginID: "com.example.plugin", declared: [.network, .fileRead]))
    }

    func testNeedsConsentFalseForEmptyDeclared() {
      let cm = CapabilityManager()
      XCTAssertFalse(cm.needsConsent(pluginID: "com.example.plugin", declared: []))
    }

    // MARK: - revokeAll

    func testRevokeAllClearsPlugin() {
      let cm = CapabilityManager()
      cm.grant([.network, .storage], pluginID: "com.example.plugin")
      cm.revokeAll(pluginID: "com.example.plugin")
      XCTAssertEqual(cm.grantedCapabilities(pluginID: "com.example.plugin"), [])
    }

    func testRevokeAllDoesNotAffectOtherPlugins() {
      let cm = CapabilityManager()
      cm.grant([.network], pluginID: "com.example.a")
      cm.grant([.storage], pluginID: "com.example.b")
      cm.revokeAll(pluginID: "com.example.a")
      XCTAssertEqual(cm.grantedCapabilities(pluginID: "com.example.a"), [])
      XCTAssertEqual(cm.grantedCapabilities(pluginID: "com.example.b"), [.storage])
    }

    func testRevokeAllOnUnknownPluginIsNoOp() {
      let cm = CapabilityManager()
      // Must not crash.
      cm.revokeAll(pluginID: "com.example.unknown")
      XCTAssertEqual(cm.grantedCapabilities(pluginID: "com.example.unknown"), [])
    }

    // MARK: - grant persistence

    func testGrantPersistsThroughDefaults() {
      let cm = CapabilityManager()
      cm.grant([.fileWrite], pluginID: "com.example.plugin")
      // A fresh instance reads from the same Defaults store.
      let cm2 = CapabilityManager()
      XCTAssertEqual(cm2.grantedCapabilities(pluginID: "com.example.plugin"), [.fileWrite])
    }

    // MARK: - isUnverified

    func testIsUnverifiedFalseForBuiltin() {
      let cm = CapabilityManager()
      XCTAssertFalse(cm.isUnverified(.builtin))
    }

    func testIsUnverifiedFalseForBundled() {
      let cm = CapabilityManager()
      XCTAssertFalse(cm.isUnverified(.bundled))
    }

    func testIsUnverifiedFalseForOfficialMarketplace() {
      let cm = CapabilityManager()
      XCTAssertFalse(cm.isUnverified(.marketplace("maccay-official")))
    }

    func testIsUnverifiedTrueForUnknownMarketplace() {
      let cm = CapabilityManager()
      XCTAssertTrue(cm.isUnverified(.marketplace("com.third-party.random")))
    }

    func testIsUnverifiedTrueForLocalFolder() {
      let cm = CapabilityManager()
      XCTAssertTrue(cm.isUnverified(.local("/Users/me/MyPlugin")))
    }
  }
  ```

---

- [ ] **Step 3: Run tests — expect FAIL (type not found)**

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests/CapabilityManagerTests
  ```

  Expected: build error — `CapabilityManager` not found, `Defaults.Keys.pluginCapabilityGrants` not found. (The test file will not compile until the implementation and pbxproj entries exist.)

---

- [ ] **Step 4: Add `pluginCapabilityGrants` key to `Maccy/Extensions/Defaults.Keys+Names.swift`**

  Open `Maccy/Extensions/Defaults.Keys+Names.swift`. The file currently ends with:

  ```swift
    static let previewWidth = Key<CGFloat>("previewWidth", default: 400)
  }
  ```

  Replace that closing brace section with (adding the new key before the closing brace):

  ```swift
    static let previewWidth = Key<CGFloat>("previewWidth", default: 400)
    // Plugin system — added in Task C2 (installedMarketplaces, localMarketplaceFolders)
    // and Task C3 (pluginCapabilityGrants):
    static let installedMarketplaces   = Key<[String]>("installedMarketplaces", default: [])
    static let localMarketplaceFolders = Key<[String]>("localMarketplaceFolders", default: [])
    static let pluginCapabilityGrants  = Key<[String: [Capability]]>("pluginCapabilityGrants", default: [:])
  }
  ```

  > **Note for the engineer:** `installedMarketplaces` and `localMarketplaceFolders` were added in Task C2. If they are already present, only append the `pluginCapabilityGrants` line. The full context block is shown so the exact insertion point is unambiguous.

  This is a modification of an existing registered file — no pbxproj change needed for this step.

  The `[String: [Capability]]` type is `Defaults.Serializable` because:
  - `Dictionary` is serializable when `Key: LosslessStringConvertible & Hashable` (`String` satisfies both) and `Value: Defaults.Serializable`.
  - `[Capability]` (i.e. `Array<Capability>`) is serializable when `Element: Defaults.Serializable`.
  - `Capability: Defaults.Serializable` is declared in `CapabilityManager.swift` (Step 5) via `extension Capability: Defaults.Serializable {}`. Defaults then bridges it via `RawRepresentableCodableBridge` (since `Capability: Codable & RawRepresentable`).

---

- [ ] **Step 5: Create `Maccy/Plugins/CapabilityManager.swift`**

  ```swift
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
  ```

  > `isUnverified` delegates entirely to `ProviderSource.isVerified` defined in `PluginCore.swift` (Task A1). The logic lives in one place; `CapabilityManager` just exposes the intent-named wrapper.

---

- [ ] **Step 6: Register both new files in `Maccy.xcodeproj/project.pbxproj`**

  Use the four UUIDs generated in Step 1. The four edits follow the identical pattern used for every `.swift` file in this project. The `Plugins` PBXGroup was created in Task A1; because `CapabilityManager.swift` is a child of that group, its `PBXFileReference.path` is the bare filename (the group node already encodes `path = Plugins`).

  **6a — PBXBuildFile section** (insert both lines anywhere inside the existing `/* Begin PBXBuildFile section */` block):

  ```
  <CM_BUILDFILE> /* CapabilityManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = <CM_FILEREF> /* CapabilityManager.swift */; };
  <CMT_BUILDFILE> /* CapabilityManagerTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <CMT_FILEREF> /* CapabilityManagerTests.swift */; };
  ```

  **6b — PBXFileReference section** (insert both lines anywhere inside the existing `/* Begin PBXFileReference section */` block):

  ```
  <CM_FILEREF> /* CapabilityManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CapabilityManager.swift; sourceTree = "<group>"; };
  <CMT_FILEREF> /* CapabilityManagerTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CapabilityManagerTests.swift; sourceTree = "<group>"; };
  ```

  **6c — PBXGroup children**

  Add `<CM_FILEREF>` to the `children` array of the **Plugins** PBXGroup (created in Task A1 — find it by `path = Plugins;`):

  ```
  <CM_FILEREF> /* CapabilityManager.swift */,
  ```

  Add `<CMT_FILEREF>` to the `children` array of the **MaccyTests** PBXGroup (`DA360DB11E3DF137005C6F6B` — `path = MaccyTests;`):

  ```
  <CMT_FILEREF> /* CapabilityManagerTests.swift */,
  ```

  **6d — PBXSourcesBuildPhase files**

  Add `<CM_BUILDFILE>` to the `files` array of `DAEE383F1E3DBEB100DD2966 /* Sources */` (app target build phase):

  ```
  <CM_BUILDFILE> /* CapabilityManager.swift in Sources */,
  ```

  Add `<CMT_BUILDFILE>` to the `files` array of `DA360DAC1E3DF137005C6F6B /* Sources */` (test target build phase):

  ```
  <CMT_BUILDFILE> /* CapabilityManagerTests.swift in Sources */,
  ```

---

- [ ] **Step 7: Run tests — expect PASS**

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests/CapabilityManagerTests
  ```

  All 14 test methods must pass. Confirm output contains:

  ```
  Test Suite 'CapabilityManagerTests' passed at ...
       Executed 14 tests, with 0 failures (0 unexpected) in ...
  ```

---

- [ ] **Step 8: Run the full unit suite — expect no regressions**

  ```sh
  xcodebuild test \
    -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj \
    -scheme Maccy \
    -destination 'platform=macOS' \
    -only-testing:MaccyTests
  ```

  All previously passing tests must still pass.

---

- [ ] **Step 9: Commit**

  ```sh
  git add Maccy/Plugins/CapabilityManager.swift \
          MaccyTests/CapabilityManagerTests.swift \
          Maccy/Extensions/Defaults.Keys+Names.swift \
          Maccy.xcodeproj/project.pbxproj
  git commit -m "C3: CapabilityManager — persisted grants, consent predicate, source-trust helper"
  ```


---

### Task C4: PluginsSettingsPane (GUI)

This task adds the Plugins settings tab. It depends on C1 (`Marketplace`/`MarketplaceEntry`/`MarketplaceStore`), C2 (`MarketplaceStore.shared`), C3 (`CapabilityManager.shared`), A1 (`ProviderDescriptor`, `Capability`, `ProviderSource`), and A2 (`ProviderRegistry.shared`). The static `requiresConsent(...)` helper is the unit-testable seam — it must be a pure function so `PluginsSettingsLogicTests` can drive it without instantiating SwiftUI views.

The pane has four sections, top to bottom: **Marketplaces** (registered marketplace list + Refresh + Add-by-URL sheet), **Available plugins** (entries from refreshed marketplaces with a `.help(...)` description tooltip, a sticky "Unverified source" badge on unverified sources, and an Install button that routes through the consent sheet when `requiresConsent` is true), **Installed plugins** (registry descriptors from folder sources, each with a Remove button), and **Local folders** (folder list + Add-via-NSOpenPanel). A `#Preview` is included.

- [ ] **Step C4.1: Generate the two pbxproj UUIDs for `PluginsSettingsPane.swift`.**

Run twice (one for the fileRef, one for the buildFile). Reuse the values in Step C4.3.

```sh
uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'; echo
uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'; echo
```

Throughout the steps below the placeholders `<PANE_FR>` (fileRef) and `<PANE_BF>` (buildFile) stand for the two values you generated. For copy-paste convenience, if you do not want to regenerate, use:
- `<PANE_FR>` = `607BE44564C14504B7B59B04`
- `<PANE_BF>` = `F7A2E6CEF5414B869372784B`

- [ ] **Step C4.2: Write the failing test `MaccyTests/PluginsSettingsLogicTests.swift`.**

This asserts the four behaviors of `PluginsSettingsPane.requiresConsent(declared:source:manager:pluginID:)`. Because `PluginsSettingsPane` is `@MainActor`, the test class methods are `@MainActor`. The test resets `CapabilityManager` grants for the probe plugin id at the top of each test so runs are independent (using the canonical `revokeAll(pluginID:)` from C3).

Create `MaccyTests/PluginsSettingsLogicTests.swift`:

```swift
import XCTest
@testable import Maccy

@MainActor
final class PluginsSettingsLogicTests: XCTestCase {
  private let probeID = "test.consent.probe"

  override func setUp() {
    super.setUp()
    CapabilityManager.shared.revokeAll(pluginID: probeID)
  }

  override func tearDown() {
    CapabilityManager.shared.revokeAll(pluginID: probeID)
    super.tearDown()
  }

  // No declared capabilities → no consent needed, regardless of source.
  func testNoCapabilitiesNeverRequiresConsent() {
    XCTAssertFalse(
      PluginsSettingsPane.requiresConsent(
        declared: [],
        source: .marketplace("some-third-party"),
        manager: CapabilityManager.shared,
        pluginID: probeID
      )
    )
  }

  // Declared capability, none granted yet → requires consent.
  func testUngrantedCapabilityRequiresConsent() {
    XCTAssertTrue(
      PluginsSettingsPane.requiresConsent(
        declared: [.network],
        source: .marketplace("some-third-party"),
        manager: CapabilityManager.shared,
        pluginID: probeID
      )
    )
  }

  // Declared capability already granted → no further consent needed.
  func testAlreadyGrantedCapabilityDoesNotRequireConsent() {
    CapabilityManager.shared.grant([.network], pluginID: probeID)
    XCTAssertFalse(
      PluginsSettingsPane.requiresConsent(
        declared: [.network],
        source: .marketplace("some-third-party"),
        manager: CapabilityManager.shared,
        pluginID: probeID
      )
    )
  }

  // A second, not-yet-granted capability still triggers consent.
  func testPartiallyGrantedCapabilitiesRequireConsent() {
    CapabilityManager.shared.grant([.network], pluginID: probeID)
    XCTAssertTrue(
      PluginsSettingsPane.requiresConsent(
        declared: [.network, .fileRead],
        source: .marketplace("some-third-party"),
        manager: CapabilityManager.shared,
        pluginID: probeID
      )
    )
  }
}
```

- [ ] **Step C4.3: Register `PluginsSettingsLogicTests.swift` in pbxproj (4 entries, test target).**

Generate its two UUIDs:

```sh
uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'; echo   # <TEST_FR>
uuidgen | tr -d '-' | head -c 24 | tr '[:lower:]' '[:upper:]'; echo   # <TEST_BF>
```

For copy-paste convenience you may instead use `<TEST_FR>` = `BF3278099ACA4CC884BEA407`, `<TEST_BF>` = `8132212A31CB46BB80BD0308`.

Edit `/Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj/project.pbxproj`:

(1) Add a `PBXBuildFile` line in the `/* Begin PBXBuildFile section */` block:
```
<TEST_BF> /* PluginsSettingsLogicTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <TEST_FR> /* PluginsSettingsLogicTests.swift */; };
```

(2) Add a `PBXFileReference` line in the `/* Begin PBXFileReference section */` block:
```
<TEST_FR> /* PluginsSettingsLogicTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MaccyTests/PluginsSettingsLogicTests.swift; sourceTree = "<group>"; };
```

(3) Add `<TEST_FR>` to the `children` array of the MaccyTests `PBXGroup` (find it by `path = MaccyTests;`):
```
				<TEST_FR> /* PluginsSettingsLogicTests.swift */,
```

(4) Add `<TEST_BF>` to the `files` array of the test target build phase `DA360DAC1E3DF137005C6F6B /* Sources */`:
```
				<TEST_BF> /* PluginsSettingsLogicTests.swift in Sources */,
```

- [ ] **Step C4.4: Run the test — expect FAIL (compile error: `PluginsSettingsPane` does not exist yet).**

```sh
xcodebuild test -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj -scheme Maccy -destination 'platform=macOS' -only-testing:MaccyTests/PluginsSettingsLogicTests
```

Expected: build/compile failure — `cannot find 'PluginsSettingsPane' in scope`. This is the RED state (the file doesn't exist yet).

- [ ] **Step C4.5: Create `Maccy/Settings/PluginsSettingsPane.swift` with the complete view.**

This is the full file. It follows ActionsSettingsPane idioms: `@Default` for the persisted folder list, `@State` for transient UI, `GroupBox { … } label: { Text(…).font(.headline) }` sections, `.sheet(isPresented:)` for the add-marketplace and consent flows, and `NSOpenPanel` mirroring `AppPicker`. `requiresConsent(...)` is `static` and pure so the tests can call it. The view holds `@State` mirrors of `MarketplaceStore`/`ProviderRegistry`/`CapabilityManager` data and refreshes them via async `Task`s, because those types are reference types not directly observable here.

```swift
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct PluginsSettingsPane: View {
  // Persisted local-folder marketplace paths (read for display; mutated via the store).
  @Default(.localMarketplaceFolders) private var localFolderPaths

  // Transient UI state.
  @State private var marketplaces: [Marketplace] = []
  @State private var installedDescriptors: [ProviderDescriptor] = []
  @State private var isRefreshing = false
  @State private var refreshError: String?

  @State private var showingAddMarketplace = false
  @State private var newMarketplaceURL = ""
  @State private var addMarketplaceError: String?

  @State private var consentEntry: MarketplaceEntry?
  @State private var consentMarketplaceID: String?
  @State private var consentCapabilities: [Capability] = []

  private let store = MarketplaceStore.shared
  private let registry = ProviderRegistry.shared
  private let capabilities = CapabilityManager.shared

  // MARK: Body

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        marketplacesBox
        availableBox
        installedBox
        localFoldersBox
      }
      .padding(20)
    }
    .frame(width: 760, height: 520)
    .task { await reloadEverything() }
    .sheet(isPresented: $showingAddMarketplace) { addMarketplaceSheet }
    .sheet(item: $consentEntry) { entry in consentSheet(for: entry) }
  }

  // MARK: Marketplaces section

  private var marketplacesBox: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(store.registeredMarketplaceURLs(), id: \.absoluteString) { url in
          HStack {
            Image(systemName: "globe")
              .foregroundStyle(.secondary)
            Text(url.absoluteString)
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer()
          }
        }
        if store.registeredMarketplaceURLs().isEmpty {
          Text("No marketplaces yet. Add one to browse plugins.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Divider()

        HStack(spacing: 8) {
          Button {
            Task { await refresh() }
          } label: {
            if isRefreshing {
              ProgressView().controlSize(.small)
            } else {
              Label("Refresh", systemImage: "arrow.clockwise")
            }
          }
          .disabled(isRefreshing)

          Button {
            newMarketplaceURL = ""
            addMarketplaceError = nil
            showingAddMarketplace = true
          } label: {
            Label("Add marketplace…", systemImage: "plus")
          }

          Spacer()

          if let refreshError {
            Text(refreshError)
              .font(.caption)
              .foregroundStyle(.red)
              .lineLimit(1)
          }
        }
      }
      .padding(4)
    } label: {
      Text("Marketplaces").font(.headline)
    }
  }

  // MARK: Available plugins section

  private var availableBox: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        if availableEntries.isEmpty {
          Text("Refresh a marketplace to see available plugins.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        ForEach(availableEntries, id: \.entry.id) { row in
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                Text(row.entry.name)
                  .fontWeight(.medium)
                if !row.source.isVerified {
                  unverifiedBadge
                }
              }
              Text(row.entry.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            .help(row.entry.description)

            Spacer()

            Button("Install") {
              install(entry: row.entry, marketplaceID: row.marketplaceID, source: row.source)
            }
            .disabled(isInstalled(row.entry.id))
          }
          .padding(.vertical, 2)
        }
      }
      .padding(4)
    } label: {
      Text("Available plugins").font(.headline)
    }
  }

  private var unverifiedBadge: some View {
    Text("Unverified source")
      .font(.caption2)
      .fontWeight(.semibold)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color.orange.opacity(0.2), in: Capsule())
      .foregroundStyle(.orange)
      .help("This plugin comes from a source Maccay can't verify. Review its requested capabilities before installing.")
  }

  // MARK: Installed plugins section

  private var installedBox: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        if installedDescriptors.isEmpty {
          Text("No plugins installed.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        ForEach(installedDescriptors) { descriptor in
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                Text(descriptor.name)
                  .fontWeight(.medium)
                if !descriptor.isVerified {
                  unverifiedBadge
                }
              }
              Text(descriptor.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            .help(descriptor.description)

            Spacer()

            Button(role: .destructive) {
              remove(pluginID: descriptor.id)
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
          }
          .padding(.vertical, 2)
        }
      }
      .padding(4)
    } label: {
      Text("Installed plugins").font(.headline)
    }
  }

  // MARK: Local folders section

  private var localFoldersBox: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(localFolderPaths, id: \.self) { path in
          HStack {
            Image(systemName: "folder")
              .foregroundStyle(.secondary)
            Text(path)
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer()
          }
        }
        if localFolderPaths.isEmpty {
          Text("Add a folder to load plugins from disk during development.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Divider()

        Button {
          addLocalFolder()
        } label: {
          Label("Add folder…", systemImage: "plus")
        }
      }
      .padding(4)
    } label: {
      Text("Local folders").font(.headline)
    }
  }

  // MARK: Add-marketplace sheet

  private var addMarketplaceSheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Add marketplace")
        .font(.headline)
      Text("Enter the URL of a marketplace.json index.")
        .font(.caption)
        .foregroundStyle(.secondary)
      TextField("https://example.com/marketplace.json", text: $newMarketplaceURL)
        .textFieldStyle(.roundedBorder)
        .frame(width: 380)
      if let addMarketplaceError {
        Text(addMarketplaceError)
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel") { showingAddMarketplace = false }
        Button("Add") { addMarketplace() }
          .keyboardShortcut(.defaultAction)
          .disabled(newMarketplaceURL.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 440)
  }

  // MARK: Consent sheet

  private func consentSheet(for entry: MarketplaceEntry) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.shield.fill")
          .font(.title2)
          .foregroundStyle(.orange)
        Text(""\(entry.name)" requests permissions")
          .font(.headline)
      }
      Text("If you install this plugin, it will be able to:")
        .font(.callout)
      VStack(alignment: .leading, spacing: 6) {
        ForEach(consentCapabilities, id: \.self) { capability in
          HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.circle")
              .foregroundStyle(.orange)
            Text(capability.consentSentence)
          }
        }
      }
      Divider()
      HStack {
        Spacer()
        Button("Cancel") {
          consentEntry = nil
        }
        Button("Install anyway") {
          confirmConsentAndInstall()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 460)
  }

  // MARK: - Testable logic

  /// True when at least one declared capability has not yet been granted for this plugin.
  /// Pure function so it can be unit-tested without a view instance.
  static func requiresConsent(
    declared: [Capability],
    source: ProviderSource,
    manager: CapabilityManager,
    pluginID: String
  ) -> Bool {
    _ = source  // source is surfaced via the unverified badge; consent keys on capabilities + grants
    guard !declared.isEmpty else { return false }
    return manager.needsConsent(pluginID: pluginID, declared: declared)
  }

  // MARK: - Derived data

  private struct AvailableRow {
    let entry: MarketplaceEntry
    let marketplaceID: String
    let source: ProviderSource
  }

  private var availableEntries: [AvailableRow] {
    marketplaces.flatMap { marketplace in
      marketplace.plugins.map { entry in
        AvailableRow(
          entry: entry,
          marketplaceID: marketplace.id,
          source: .marketplace(marketplace.id)
        )
      }
    }
  }

  private func isInstalled(_ pluginID: String) -> Bool {
    installedDescriptors.contains { $0.id == pluginID }
  }

  // MARK: - Actions

  private func reloadEverything() async {
    await refresh()
    reloadInstalled()
  }

  private func reloadInstalled() {
    installedDescriptors = registry.descriptors().filter { descriptor in
      switch descriptor.source {
      case .builtin, .bundled:
        return false
      case .marketplace, .local:
        return true
      }
    }
  }

  private func refresh() async {
    isRefreshing = true
    refreshError = nil
    defer { isRefreshing = false }
    await store.refreshAll()
    var loaded: [Marketplace] = []
    for url in store.registeredMarketplaceURLs() {
      do {
        loaded.append(try await MarketplaceResolver.fetchIndex(url))
      } catch {
        refreshError = "Couldn't load \(url.lastPathComponent): \(error.localizedDescription)"
      }
    }
    marketplaces = loaded
  }

  private func addMarketplace() {
    addMarketplaceError = nil
    let trimmed = newMarketplaceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed) else {
      addMarketplaceError = "That doesn't look like a valid URL."
      return
    }
    Task {
      do {
        _ = try await store.addMarketplace(url)
        showingAddMarketplace = false
        await refresh()
      } catch {
        addMarketplaceError = error.localizedDescription
      }
    }
  }

  private func install(entry: MarketplaceEntry, marketplaceID: String, source: ProviderSource) {
    let declared = capabilitiesDeclared(by: entry)
    if Self.requiresConsent(
      declared: declared,
      source: source,
      manager: capabilities,
      pluginID: entry.id
    ) {
      consentCapabilities = declared
      consentMarketplaceID = marketplaceID
      consentEntry = entry  // triggers the .sheet(item:)
    } else {
      performInstall(entry: entry, marketplaceID: marketplaceID)
    }
  }

  private func confirmConsentAndInstall() {
    guard let entry = consentEntry, let marketplaceID = consentMarketplaceID else { return }
    capabilities.grant(consentCapabilities, pluginID: entry.id)
    consentEntry = nil
    performInstall(entry: entry, marketplaceID: marketplaceID)
  }

  private func performInstall(entry: MarketplaceEntry, marketplaceID: String) {
    Task {
      do {
        try await store.install(entry, marketplaceID: marketplaceID)
        PluginLoader.loadAll(into: registry, extraFolders: store.localFolders())
        reloadInstalled()
      } catch {
        refreshError = "Install failed: \(error.localizedDescription)"
      }
    }
  }

  private func remove(pluginID: String) {
    store.remove(pluginID: pluginID)
    capabilities.revokeAll(pluginID: pluginID)
    PluginLoader.loadAll(into: registry, extraFolders: store.localFolders())
    reloadInstalled()
  }

  private func addLocalFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    store.addLocalFolder(url)
    PluginLoader.loadAll(into: registry, extraFolders: store.localFolders())
    reloadInstalled()
  }

  /// Declared capabilities for an entry. The marketplace index doesn't carry the
  /// capability list; it is read from the already-registered descriptor when present,
  /// otherwise treated as empty (consent will be re-checked at load time).
  private func capabilitiesDeclared(by entry: MarketplaceEntry) -> [Capability] {
    // Prefer the entry's declared capabilities (known BEFORE install, so the consent
    // sheet fires pre-download — even for a network/FS plugin from the verified
    // marketplace). Fall back to the registered descriptor for already-installed plugins.
    if let caps = entry.capabilities { return caps }
    return registry.descriptors().first { $0.id == entry.id }?.capabilities ?? []
  }
}

#Preview {
  PluginsSettingsPane()
}
```

> Note: `MarketplaceEntry` carries an optional `capabilities: [Capability]?` (added to the C1 model + contract), so consent is computed from the entry BEFORE download/install — the consent sheet therefore fires for a network/FS plugin even when it comes from the verified marketplace. The descriptor lookup is only a fallback for already-installed plugins. The `requiresConsent` seam and its tests are unaffected.

- [ ] **Step C4.6: Register `PluginsSettingsPane.swift` in pbxproj (4 entries, app target).**

Edit `/Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj/project.pbxproj` using `<PANE_FR>`/`<PANE_BF>` from Step C4.1. The `Settings/` subfolder is encoded in the `path` field (flat group, ActionsSettingsPane precedent — `path = Settings/ActionsSettingsPane.swift`).

(1) `PBXBuildFile` (in `/* Begin PBXBuildFile section */`):
```
<PANE_BF> /* PluginsSettingsPane.swift in Sources */ = {isa = PBXBuildFile; fileRef = <PANE_FR> /* PluginsSettingsPane.swift */; };
```

(2) `PBXFileReference` (in `/* Begin PBXFileReference section */`):
```
<PANE_FR> /* PluginsSettingsPane.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Settings/PluginsSettingsPane.swift; sourceTree = "<group>"; };
```

(3) Add `<PANE_FR>` to the `children` array of `DAEE38451E3DBEB100DD2966 /* Maccy */` group:
```
				<PANE_FR> /* PluginsSettingsPane.swift */,
```

(4) Add `<PANE_BF>` to the `files` array of `DAEE383F1E3DBEB100DD2966 /* Sources */`:
```
				<PANE_BF> /* PluginsSettingsPane.swift in Sources */,
```

- [ ] **Step C4.7: Run the test — expect PASS.**

```sh
xcodebuild test -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj -scheme Maccy -destination 'platform=macOS' -only-testing:MaccyTests/PluginsSettingsLogicTests
```

Expected: `Test Suite 'PluginsSettingsLogicTests' passed` — all four tests (`testNoCapabilitiesNeverRequiresConsent`, `testUngrantedCapabilityRequiresConsent`, `testAlreadyGrantedCapabilityDoesNotRequireConsent`, `testPartiallyGrantedCapabilitiesRequireConsent`) green.

- [ ] **Step C4.8: Add the "Plugins" PaneIdentifier.**

Edit `/Users/roypadina/Code/Padina/Maccay/Maccy/Extensions/Settings.PaneIdentifier+Panes.swift` — add the `plugins` identifier alongside the existing ones:

```swift
import Settings

extension Settings.PaneIdentifier {
  static let actions = Self("actions")
  static let advanced = Self("advanced")
  static let appearance = Self("appearance")
  static let general = Self("general")
  static let ignore = Self("ignore")
  static let pins = Self("pins")
  static let plugins = Self("plugins")
  static let storage = Self("storage")
}
```

- [ ] **Step C4.9: Wire the Plugins tab into the Settings window.**

Edit `/Users/roypadina/Code/Padina/Maccay/Maccy/Observables/AppState.swift`. Locate the `actions` pane (the last element of the `panes:` array) and append the `plugins` pane after it. The exact change: the `ActionsSettingsPane()` closing pane currently ends with `}` and no trailing comma (it is the last array element). Add a comma after it and a new `Settings.Pane` for plugins.

Find this block (lines ~157–164):
```swift
          Settings.Pane(
            identifier: Settings.PaneIdentifier.actions,
            title: "Actions",
            toolbarIcon: NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) ?? NSImage()
          ) {
            ActionsSettingsPane()
          }
        ]
```

Replace it with (note the comma added after the `actions` pane's closing `}`, then the new `plugins` pane):
```swift
          Settings.Pane(
            identifier: Settings.PaneIdentifier.actions,
            title: "Actions",
            toolbarIcon: NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) ?? NSImage()
          ) {
            ActionsSettingsPane()
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.plugins,
            title: "Plugins",
            toolbarIcon: NSImage(systemSymbolName: "puzzlepiece.extension.fill", accessibilityDescription: nil) ?? NSImage()
          ) {
            PluginsSettingsPane()
          }
        ]
```

- [ ] **Step C4.10: Build the full app to confirm the GUI wiring compiles (no new test needed — view rendering is not unit-tested).**

```sh
xcodebuild build -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj -scheme Maccy -destination 'platform=macOS'
```

Expected: `** BUILD SUCCEEDED **`. The new "Plugins" tab now appears in the Settings window with a puzzle-piece toolbar icon.

- [ ] **Step C4.11: Re-run the unit suite to confirm no regressions, then commit.**

```sh
xcodebuild test -project /Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj -scheme Maccy -destination 'platform=macOS' -only-testing:MaccyTests
```

Expected: all tests pass. Then commit on `feat/plugin-system`:
```sh
git -C /Users/roypadina/Code/Padina/Maccay add -A
git -C /Users/roypadina/Code/Padina/Maccay commit -m "C4: PluginsSettingsPane GUI (marketplaces, install/consent, installed, local folders)"
```

(Do NOT push — net-new push needs explicit owner approval.)

---

Files this task touches (all absolute):
- New: `/Users/roypadina/Code/Padina/Maccay/Maccy/Settings/PluginsSettingsPane.swift`
- New: `/Users/roypadina/Code/Padina/Maccay/MaccyTests/PluginsSettingsLogicTests.swift`
- Modified: `/Users/roypadina/Code/Padina/Maccay/Maccy/Extensions/Settings.PaneIdentifier+Panes.swift`
- Modified: `/Users/roypadina/Code/Padina/Maccay/Maccy/Observables/AppState.swift`
- Modified: `/Users/roypadina/Code/Padina/Maccay/Maccy.xcodeproj/project.pbxproj`

Cross-task dependency notes for the plan author: this task assumes the canonical C2 `MarketplaceStore` surface (`registeredMarketplaceURLs()`, `addMarketplace(_:)`, `install(_:marketplaceID:)`, `remove(pluginID:)`, `localFolders()`, `addLocalFolder(_:)`, `refreshAll()`), the C1 `MarketplaceResolver.fetchIndex(_:)` and `Marketplace`/`MarketplaceEntry`/`PluginSource` models, the C3 `CapabilityManager` (`needsConsent(pluginID:declared:)`, `grant(_:pluginID:)`, `revokeAll(pluginID:)`), the A1 `Capability.consentSentence`/`ProviderSource.isVerified`/`ProviderDescriptor.capabilities`, the A2 `ProviderRegistry.shared.descriptors()`, and the B4 `PluginLoader.loadAll(into:extraFolders:)` — all used verbatim from the Interface Contract. `MarketplaceEntry` carries an optional `capabilities: [Capability]?` (C1 model + contract); this task computes consent from the entry pre-install, falling back to the registered descriptor for already-installed plugins (see the note in Step C4.5). The `requiresConsent` test seam is independent of that detail.


## Milestone D — Official marketplace repo (GATED on approval)

### Task D1: `maccay-plugins` repo scaffold (LOCAL ONLY — GATED on owner approval before any remote push)

> **No pbxproj edits, no Xcode build, no Swift files.** This task creates a local directory tree `./maccay-plugins-repo/` committed to the `feat/plugin-system` branch. Creating the remote GitHub repository and pushing is explicitly BLOCKED until the owner gives approval.

---

- [ ] **Step 1: Create the directory skeleton**

  Run from the repo root:

  ```sh
  mkdir -p \
    ./maccay-plugins-repo/plugins/example-shout \
    ./maccay-plugins-repo/plugins/example-has-url \
    ./maccay-plugins-repo/.github/workflows \
    ./maccay-plugins-repo/scripts
  ```

---

- [ ] **Step 2: Write `plugins/example-shout/plugin.json`**

  Create `./maccay-plugins-repo/plugins/example-shout/plugin.json` with the following complete content:

  ```json
  {
    "id": "com.maccay.example-shout",
    "name": "Shout",
    "version": "1.0.0",
    "author": {
      "name": "Maccay Contributors",
      "url": "https://github.com/OWNER/maccay-plugins"
    },
    "description": "Converts the clipboard text to uppercase and appends an exclamation mark.",
    "longHelp": "The Shout action transforms any text into SHOUTED form: it first upper-cases every character, then appends '!'. Useful for emphasis. No network or file-system access is needed.",
    "kind": "action",
    "engine": "declarative",
    "params": [],
    "capabilities": [],
    "minAppVersion": "2.7.0",
    "declarative": {
      "transform": [
        { "op": "case", "value": "upper" },
        { "op": "append", "text": "!" }
      ]
    }
  }
  ```

---

- [ ] **Step 3: Write `plugins/example-has-url/plugin.json`**

  Create `./maccay-plugins-repo/plugins/example-has-url/plugin.json` with the following complete content:

  ```json
  {
    "id": "com.maccay.example-has-url",
    "name": "Has URL",
    "version": "1.0.0",
    "author": {
      "name": "Maccay Contributors",
      "url": "https://github.com/OWNER/maccay-plugins"
    },
    "description": "Matches clipboard text that contains an http:// or https:// URL anywhere in it.",
    "longHelp": "The Has URL condition returns true whenever the clipboard string contains at least one http:// or https:// link. It uses a simple regular expression and requires no network or file-system access.",
    "kind": "condition",
    "engine": "javascript",
    "entry": "main.js",
    "params": [],
    "capabilities": [],
    "minAppVersion": "2.7.0"
  }
  ```

---

- [ ] **Step 4: Write `plugins/example-has-url/main.js`**

  Create `./maccay-plugins-repo/plugins/example-has-url/main.js` with the following complete content. This is the bridge-less JavaScriptCore entry point; it must define a global `matches(input)` function that returns a boolean.

  ```js
  // Has URL — condition plugin for Maccay
  // Engine: javascript (bridge-less JavaScriptCore)
  // Called by JSPluginRuntime.callMatches(input: String) -> Bool
  //
  // The runtime calls:   matches(inputString)
  // Must return:         true  if the condition is satisfied
  //                      false otherwise
  //
  // No capabilities declared → no network or FS access.

  function matches(input) {
    // Match any http:// or https:// URL-like substring.
    // The regex does not need to be exhaustive — it just needs to detect
    // common URL patterns reliably without external dependencies.
    var pattern = /https?:\/\/[^\s]+/;
    return pattern.test(input);
  }
  ```

---

- [ ] **Step 5: Compute sha256 for each `plugin.json` and record placeholders**

  The sha256 hash is computed over the **exact bytes of `plugin.json`** as written. Run:

  ```sh
  cd ./maccay-plugins-repo

  SHA_SHOUT=$(shasum -a 256 plugins/example-shout/plugin.json | awk '{print $1}')
  echo "example-shout sha256: $SHA_SHOUT"

  SHA_HAS_URL=$(shasum -a 256 plugins/example-has-url/plugin.json | awk '{print $1}')
  echo "example-has-url sha256: $SHA_HAS_URL"
  ```

  Copy both hex strings. They are used verbatim in `marketplace.json` in the next step. Re-run whenever either `plugin.json` changes.

---

- [ ] **Step 6: Write `marketplace.json`**

  Create `./maccay-plugins-repo/marketplace.json`. Replace `<SHA256_SHOUT>` and `<SHA256_HAS_URL>` with the two hex strings printed in Step 5. The `OWNER` placeholder must be replaced with the actual GitHub username/org before the repo is ever published — leave it as `OWNER` for now since the remote repo does not yet exist.

  Complete file content (substitute the two sha256 values):

  ```json
  {
    "id": "maccay-official",
    "name": "Maccay Official Plugins",
    "version": "1.0.0",
    "description": "The official curated plugin marketplace for Maccay. All plugins are reviewed for correctness and safety before listing.",
    "maintainer": "Maccay Contributors",
    "plugins": [
      {
        "id": "com.maccay.example-shout",
        "name": "Shout",
        "description": "Converts the clipboard text to uppercase and appends an exclamation mark.",
        "version": "1.0.0",
        "minAppVersion": "2.7.0",
        "kind": "action",
        "tags": ["transform", "text", "example"],
        "source": {
          "github": {
            "repo": "OWNER/maccay-plugins",
            "ref": "main",
            "path": "plugins/example-shout"
          }
        },
        "sha256": "<SHA256_SHOUT>"
      },
      {
        "id": "com.maccay.example-has-url",
        "name": "Has URL",
        "description": "Matches clipboard text that contains an http:// or https:// URL anywhere in it.",
        "version": "1.0.0",
        "minAppVersion": "2.7.0",
        "kind": "condition",
        "tags": ["condition", "url", "example"],
        "source": {
          "github": {
            "repo": "OWNER/maccay-plugins",
            "ref": "main",
            "path": "plugins/example-has-url"
          }
        },
        "sha256": "<SHA256_HAS_URL>"
      }
    ]
  }
  ```

  > **Note on sha256 semantics:** `MarketplaceEntry.sha256` is the SHA-256 of `plugin.json` for declarative plugins (the single manifest file is the complete plugin). For JS plugins it is the SHA-256 of the zip/tarball that the resolver downloads; until the remote repo exists and a release asset is published, the value computed here is the hash of `plugin.json` alone and will need updating when a real release tarball is created. This is documented in `CONTRIBUTING.md`.

---

- [ ] **Step 7: Write `CONTRIBUTING.md`**

  Create `./maccay-plugins-repo/CONTRIBUTING.md` with the following complete content:

  ````markdown
  # Contributing to maccay-plugins

  This repository is the official Maccay plugin marketplace. All plugins listed in
  `marketplace.json` have been reviewed by at least two maintainers and satisfy the
  requirements below.

  ## Plugin requirements

  ### Required manifest fields

  Every plugin must supply a `plugin.json` in its folder with **all** of the following
  fields present and non-empty:

  | Field | Type | Constraint |
  |---|---|---|
  | `id` | `string` | Reverse-DNS, e.g. `com.yourname.myplugin`. Must be globally unique in this repo. |
  | `name` | `string` | Human-readable display name. |
  | `version` | `string` | Semantic version, e.g. `"1.0.0"`. |
  | `description` | `string` | **Required. Maximum 120 characters.** Shown as the GUI tooltip. |
  | `kind` | `"action"` or `"condition"` | Which type of provider this plugin registers. |
  | `engine` | `"declarative"` or `"javascript"` | Must never be `"native"`. |
  | `capabilities` | array | Declare every capability the plugin uses. May be `[]`. |

  For `engine: "javascript"` plugins, the field `entry` (e.g. `"main.js"`) is also
  **required** and must match an actual file in the plugin folder.

  For `engine: "declarative"` plugins, the field `declarative` is **required** and
  must contain a valid transform list (for actions) or predicate tree (for conditions).

  ### Description length

  The `description` field must be **120 characters or fewer**. Longer descriptions are
  rejected by the CI validation script and the app's manifest parser.

  ### Declared capabilities

  The `capabilities` array must declare every resource the plugin actually accesses:

  | Capability | When to declare |
  |---|---|
  | `"network"` | Plugin sends or receives data over the network. |
  | `"fileRead"` | Plugin reads files from the filesystem. |
  | `"fileWrite"` | Plugin writes files to the filesystem. |
  | `"storage"` | Plugin persists data between invocations. |

  **No undeclared network or filesystem access is permitted.** In v1 the app does not
  enforce capability isolation at the bridge level, but plugins that declare capabilities
  dishonestly will be removed and the author blocked.

  ### Review and merge process

  1. Open a pull request with your plugin folder under `plugins/<your-plugin-id>/`.
  2. Add a corresponding entry to `marketplace.json` (see format below).
  3. Compute the correct `sha256` value for `plugin.json` (see below).
  4. Your PR must receive **at least 2 approvals** from project maintainers listed in
     `CODEOWNERS` before it can be merged.
  5. `CODEOWNERS` assigns `@OWNER` as a required reviewer for all `marketplace.json`
     changes; that review counts as one of the two required approvals.

  ### Computing `sha256`

  The `sha256` field in `marketplace.json` must exactly match the SHA-256 hash of the
  plugin's `plugin.json` file (for declarative plugins) or the release tarball (for JS
  plugins with multiple files). Compute it with:

  ```sh
  shasum -a 256 plugins/<your-plugin-id>/plugin.json
  ```

  Copy the hex string (first field of the output) into `marketplace.json`. The CI
  validation script recomputes this hash and fails if it does not match.

  ### Adding your entry to `marketplace.json`

  Add one object to the `plugins` array:

  ```json
  {
    "id": "com.yourname.myplugin",
    "name": "My Plugin",
    "description": "One sentence, 120 chars max.",
    "version": "1.0.0",
    "minAppVersion": "2.7.0",
    "kind": "action",
    "tags": ["transform"],
    "source": {
      "github": {
        "repo": "OWNER/maccay-plugins",
        "ref": "main",
        "path": "plugins/com.yourname.myplugin"
      }
    },
    "sha256": "<hex from shasum -a 256 plugin.json>"
  }
  ```

  ## What is NOT allowed

  - `engine: "native"` — only the Maccay app itself can register native providers.
  - Accessing network or filesystem without declaring the corresponding capability.
  - Plugins that exfiltrate clipboard content to external servers.
  - Obfuscated JavaScript.
  - Binary files other than recognized image assets.

  ## Questions

  Open a GitHub Discussion or issue. Do not open a PR without first confirming that
  your plugin idea is in scope.
  ````

---

- [ ] **Step 8: Write `CODEOWNERS`**

  Create `./maccay-plugins-repo/CODEOWNERS` with the following complete content:

  ```
  # CODEOWNERS for maccay-plugins
  # All marketplace.json changes require review from the repo owner.
  # All plugin.json changes in any plugin folder also require owner review.
  # This file enforces the "2 approvals required" policy: the owner counts as 1.

  # Global fallback — owner reviews everything
  *                        @OWNER

  # marketplace.json always requires owner sign-off
  marketplace.json         @OWNER

  # Each plugin folder requires owner sign-off
  plugins/                 @OWNER
  ```

---

- [ ] **Step 9: Write `.github/workflows/validate.yml`**

  Create `./maccay-plugins-repo/.github/workflows/validate.yml` with the following complete content:

  ```yaml
  name: Validate plugins

  on:
    pull_request:
      paths:
        - 'plugins/**'
        - 'marketplace.json'
        - 'scripts/validate.py'
    push:
      branches:
        - main
      paths:
        - 'plugins/**'
        - 'marketplace.json'

  jobs:
    validate:
      name: Validate plugin manifests and sha256
      runs-on: ubuntu-latest

      steps:
        - name: Check out repository
          uses: actions/checkout@v4

        - name: Set up Python
          uses: actions/setup-python@v5
          with:
            python-version: '3.12'

        - name: Run validation script
          run: python scripts/validate.py
  ```

---

- [ ] **Step 10: Write `scripts/validate.py`**

  Create `./maccay-plugins-repo/scripts/validate.py` with the following complete content. The script validates every `plugin.json` for required fields and description length, then recomputes the sha256 of each `plugin.json` and checks it matches `marketplace.json`.

  ```python
  #!/usr/bin/env python3
  """validate.py — CI validation for maccay-plugins.

  Checks:
  1. marketplace.json is valid JSON with required top-level fields.
  2. Every plugin listed in marketplace.json has a corresponding plugin folder.
  3. Each plugin folder contains a plugin.json with all required fields.
  4. description is <= 120 characters.
  5. engine is "declarative" or "javascript" (never "native").
  6. engine=="javascript" plugins have an "entry" field pointing to an existing file.
  7. engine=="declarative" plugins have a "declarative" field.
  8. capabilities is present (may be an empty list).
  9. sha256 in marketplace.json matches shasum -a 256 of the plugin's plugin.json.

  Exits 0 on success. Prints a descriptive error and exits 1 on any failure.
  """

  import hashlib
  import json
  import os
  import sys

  REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
  MARKETPLACE_PATH = os.path.join(REPO_ROOT, "marketplace.json")
  PLUGINS_DIR = os.path.join(REPO_ROOT, "plugins")

  REQUIRED_MARKETPLACE_FIELDS = ["id", "name", "version", "plugins"]
  REQUIRED_PLUGIN_FIELDS = ["id", "name", "version", "description", "kind", "engine", "capabilities"]
  VALID_KINDS = {"action", "condition"}
  VALID_ENGINES = {"declarative", "javascript"}
  MAX_DESCRIPTION_LENGTH = 120


  def fail(message: str) -> None:
      print(f"ERROR: {message}", file=sys.stderr)
      sys.exit(1)


  def sha256_of_file(path: str) -> str:
      """Return the lowercase hex SHA-256 digest of the file at path."""
      h = hashlib.sha256()
      with open(path, "rb") as f:
          for chunk in iter(lambda: f.read(65536), b""):
              h.update(chunk)
      return h.hexdigest()


  def validate_marketplace(marketplace: dict) -> None:
      for field in REQUIRED_MARKETPLACE_FIELDS:
          if field not in marketplace:
              fail(f"marketplace.json is missing required field: '{field}'")
      if not isinstance(marketplace["plugins"], list):
          fail("marketplace.json: 'plugins' must be a JSON array")


  def validate_plugin_json(plugin_json_path: str, plugin_id: str) -> None:
      with open(plugin_json_path, "r", encoding="utf-8") as f:
          try:
              manifest = json.load(f)
          except json.JSONDecodeError as e:
              fail(f"plugin.json for '{plugin_id}' is not valid JSON: {e}")

      # Required fields
      for field in REQUIRED_PLUGIN_FIELDS:
          if field not in manifest:
              fail(f"plugin.json for '{plugin_id}' is missing required field: '{field}'")

      # Description length
      description = manifest["description"]
      if len(description) > MAX_DESCRIPTION_LENGTH:
          fail(
              f"plugin.json for '{plugin_id}': description is {len(description)} chars "
              f"(max {MAX_DESCRIPTION_LENGTH}): {description!r}"
          )

      # kind
      if manifest["kind"] not in VALID_KINDS:
          fail(
              f"plugin.json for '{plugin_id}': 'kind' must be one of {sorted(VALID_KINDS)}, "
              f"got {manifest['kind']!r}"
          )

      # engine
      if manifest["engine"] not in VALID_ENGINES:
          fail(
              f"plugin.json for '{plugin_id}': 'engine' must be one of {sorted(VALID_ENGINES)}, "
              f"got {manifest['engine']!r}. Native providers cannot be distributed as plugins."
          )

      # JavaScript plugins must have an entry field pointing to an existing file
      if manifest["engine"] == "javascript":
          if "entry" not in manifest or not manifest["entry"]:
              fail(
                  f"plugin.json for '{plugin_id}': engine is 'javascript' but 'entry' field is missing or empty"
              )
          plugin_folder = os.path.dirname(plugin_json_path)
          entry_path = os.path.join(plugin_folder, manifest["entry"])
          if not os.path.isfile(entry_path):
              fail(
                  f"plugin.json for '{plugin_id}': entry file '{manifest['entry']}' "
                  f"does not exist at {entry_path}"
              )

      # Declarative plugins must have a declarative field
      if manifest["engine"] == "declarative":
          if "declarative" not in manifest or manifest["declarative"] is None:
              fail(
                  f"plugin.json for '{plugin_id}': engine is 'declarative' but 'declarative' field is missing"
              )

      # capabilities must be a list (may be empty)
      if not isinstance(manifest["capabilities"], list):
          fail(f"plugin.json for '{plugin_id}': 'capabilities' must be a JSON array (may be empty [])")


  def validate_sha256(entry: dict, plugin_json_path: str) -> None:
      plugin_id = entry["id"]
      declared_sha = entry.get("sha256", "")
      if not declared_sha:
          fail(f"marketplace.json entry for '{plugin_id}' is missing 'sha256'")

      actual_sha = sha256_of_file(plugin_json_path)
      if actual_sha != declared_sha.lower():
          fail(
              f"marketplace.json sha256 mismatch for '{plugin_id}':\n"
              f"  declared: {declared_sha}\n"
              f"  actual:   {actual_sha}\n"
              f"Re-run: shasum -a 256 {plugin_json_path}"
          )


  def main() -> None:
      # Load marketplace.json
      if not os.path.isfile(MARKETPLACE_PATH):
          fail(f"marketplace.json not found at {MARKETPLACE_PATH}")

      with open(MARKETPLACE_PATH, "r", encoding="utf-8") as f:
          try:
              marketplace = json.load(f)
          except json.JSONDecodeError as e:
              fail(f"marketplace.json is not valid JSON: {e}")

      validate_marketplace(marketplace)

      errors_found = False

      for entry in marketplace["plugins"]:
          plugin_id = entry.get("id", "<missing id>")

          # Each entry needs these fields
          for field in ["id", "name", "description", "version", "kind", "source", "sha256"]:
              if field not in entry:
                  print(f"ERROR: marketplace entry for '{plugin_id}' is missing field '{field}'", file=sys.stderr)
                  errors_found = True

          if errors_found:
              continue

          # Derive plugin folder from source.github.path if present, else use id
          source = entry.get("source", {})
          github_source = source.get("github", {})
          plugin_path_in_repo = github_source.get("path", f"plugins/{plugin_id}")

          # The path in source is repo-relative; resolve against REPO_ROOT.
          plugin_folder_abs = os.path.join(REPO_ROOT, plugin_path_in_repo)
          plugin_json_path = os.path.join(plugin_folder_abs, "plugin.json")

          if not os.path.isdir(plugin_folder_abs):
              print(
                  f"ERROR: plugin folder for '{plugin_id}' not found at {plugin_folder_abs}",
                  file=sys.stderr,
              )
              errors_found = True
              continue

          if not os.path.isfile(plugin_json_path):
              print(
                  f"ERROR: plugin.json for '{plugin_id}' not found at {plugin_json_path}",
                  file=sys.stderr,
              )
              errors_found = True
              continue

          # Validate the plugin.json contents
          try:
              validate_plugin_json(plugin_json_path, plugin_id)
          except SystemExit:
              errors_found = True
              continue

          # Validate the sha256 hash
          try:
              validate_sha256(entry, plugin_json_path)
          except SystemExit:
              errors_found = True
              continue

          print(f"OK: {plugin_id} ({entry['version']})")

      if errors_found:
          sys.exit(1)

      print(f"\nAll {len(marketplace['plugins'])} plugin(s) passed validation.")
      sys.exit(0)


  if __name__ == "__main__":
      main()
  ```

---

- [ ] **Step 11: Compute real sha256 values and write the final `marketplace.json`**

  Run from the repo root:

  ```sh
  cd /Users/roypadina/Code/Padina/Maccay

  SHA_SHOUT=$(shasum -a 256 maccay-plugins-repo/plugins/example-shout/plugin.json | awk '{print $1}')
  SHA_HAS_URL=$(shasum -a 256 maccay-plugins-repo/plugins/example-has-url/plugin.json | awk '{print $1}')

  echo "example-shout  sha256: $SHA_SHOUT"
  echo "example-has-url sha256: $SHA_HAS_URL"
  ```

  Open `./maccay-plugins-repo/marketplace.json` and replace both `"<SHA256_SHOUT>"` and `"<SHA256_HAS_URL>"` with the printed hex strings. Save the file.

  > The final `marketplace.json` must have the literal 64-character lowercase hex digests, not placeholder strings. The validation script in the next step recomputes them and will fail if they do not match.

---

- [ ] **Step 12: Run `scripts/validate.py` locally — expect exit 0**

  ```sh
  cd /Users/roypadina/Code/Padina/Maccay
  python3 maccay-plugins-repo/scripts/validate.py
  ```

  Expected output:

  ```
  OK: com.maccay.example-shout (1.0.0)
  OK: com.maccay.example-has-url (1.0.0)

  All 2 plugin(s) passed validation.
  ```

  If the script exits non-zero, it will print a specific error message identifying the field or sha256 mismatch. Fix the issue and re-run until exit code is 0.

---

- [ ] **Step 13: Commit `./maccay-plugins-repo/` to the feature branch**

  Stage and commit the entire new directory to `feat/plugin-system`:

  ```sh
  cd /Users/roypadina/Code/Padina/Maccay

  git add maccay-plugins-repo/

  git commit -m "$(cat <<'EOF'
  D1: scaffold maccay-plugins repo (local only, not pushed)

  Adds ./maccay-plugins-repo/ to the working tree with:
  - marketplace.json (id maccay-official, two example plugins with real sha256)
  - plugins/example-shout/plugin.json (declarative action: uppercase + append "!")
  - plugins/example-has-url/plugin.json + main.js (JS condition: contains URL)
  - CONTRIBUTING.md (required fields, description<=120, capabilities policy,
    2-approval + CODEOWNERS requirement, sha256 instructions)
  - CODEOWNERS (owner review required on marketplace.json and plugins/)
  - .github/workflows/validate.yml (ubuntu-latest, python 3.12, validate.py)
  - scripts/validate.py (validates all plugin.json fields + sha256 matching)

  The remote github.com/OWNER/maccay-plugins repo has NOT been created.
  OWNER placeholder in marketplace.json/CODEOWNERS must be replaced with
  the real username when the repo is approved for creation.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

- [ ] **Step 14: STOP — remote repo creation requires explicit owner approval**

  ```
  ╔══════════════════════════════════════════════════════════════════════╗
  ║  STOP — DO NOT PROCEED WITHOUT EXPLICIT OWNER APPROVAL              ║
  ╠══════════════════════════════════════════════════════════════════════╣
  ║                                                                      ║
  ║  The following steps are NOT part of this task and must NOT be run  ║
  ║  until the owner explicitly approves:                                ║
  ║                                                                      ║
  ║    1. gh repo create OWNER/maccay-plugins --public                  ║
  ║    2. Replace all "OWNER" placeholders in marketplace.json and       ║
  ║       CODEOWNERS with the real GitHub username/org.                  ║
  ║    3. git remote add origin git@github-personal:OWNER/maccay-plugins ║
  ║    4. git subtree push (or initialize a new repo in the folder and   ║
  ║       push it independently)                                         ║
  ║                                                                      ║
  ║  Per project rules: creating a new remote repository or making a    ║
  ║  first push of a new project requires explicit approval from the     ║
  ║  owner before any gh or git push command is run.                     ║
  ╚══════════════════════════════════════════════════════════════════════╝
  ```

  Task D1 is complete. The `maccay-plugins-repo/` directory is committed to `feat/plugin-system` and ready to become a standalone repository whenever the owner approves.

