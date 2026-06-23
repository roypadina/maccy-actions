# Maccay Plugin System — Design Spec

**Date:** 2026-06-23
**Status:** Approved (brainstorming) — pending implementation plan
**Author:** Roy + Claude

## Goal

Turn Maccay's hardcoded clipboard **conditions** and **actions** into a **plugin system** so anyone can add new ones by dropping a small plugin into a folder — no app rebuild. Plugins are distributed through **marketplaces** (GitHub repos), with our official marketplace loaded by default, plus user-added custom marketplaces and **local folders** (no repo). Every plugin (condition or action) ships a **description** surfaced in the GUI as a tooltip. Custom logic (real code) is allowed, with capability-scoped warnings for plugins from unverified sources.

## Decisions (from brainstorming)

| # | Decision | Choice |
|---|----------|--------|
| Execution model | How third-party logic runs | **Hybrid: declarative + JavaScript (JavaScriptCore).** Code allowed; warn on unverified sources. |
| Authoring tiers | Zero-code option? | **Both** — declarative (JSON, no code) **and** JavaScript. |
| Capabilities | Network/FS for untrusted sources? | **Allow all capabilities, gated by warning.** Permissive + informed consent. |
| Warning model | When does the warning fire? | **Capability-scoped.** No-capability plugins are bridge-less → silent install (+ sticky "Unverified source" badge). The capability-consent prompt fires only when a plugin declares network/FS/etc., naming each in plain language. |
| Dispatch | Architecture shape | **Unified ProviderRegistry** — built-ins and plugins are both providers keyed by stable string id. No `switch` dispatch. |
| Built-in vs plugin | What stays native | Built-in conditions: **Kind, Regex, Contains, Source-app**. Built-in actions: **OpenURL, OpenInApp, WebSearch, RunShortcut**. Everything else (soft-wrap, terminal-source, 6 transforms) ships as **first-party plugins**. |
| Bundling / migration | No existing users | **Hard cut.** Bump `schemaVersion`, reset presets. First-party plugins ship pre-loaded via the `plugins/` repo. No back-compat decoder. |
| ExtensionKit | Out-of-process tier | **Not in v1.** JS runs **in-process** `JSContext` with a watchdog. XPC helper = future hardening. |
| macOS floor | Version bump? | **Unchanged.** |
| Default marketplace location | Subdir vs separate repo | **Separate GitHub repo** so plugin PRs don't touch app code. |

## Current state (what we're replacing)

Everything is in `Maccy/Actions/`. The feature is **closed-enum dispatch over an already-plugin-shaped protocol** — only the dispatch layer is closed; storage and reload are already external-writer-friendly.

- **Rules** — `struct ActionRule` (`ActionRule.swift:204`): `id, name, enabled, matchMode, conditions:[RuleCondition], actions:[ActionConfig], autoRunDefault`. Stored as Codable JSON in `UserDefaults` via Defaults key `actionRules` (`ActionEngine.swift:8`); default = `ActionRule.presets` (`:213`). Container `com.royp.MaccayActions`.
- **Conditions** — `enum RuleCondition` (`ActionRule.swift:63`), tagged-JSON Codable with a legacy decoder (`:99-137`). Six cases: `.kind`, `.regex`, `.contains`, `.sourceApp`, `.softWrapped`, `.terminalSource`. Evaluated in the hardcoded `switch` in `ActionEngine.matches(_:kinds:text:app:)` (`ActionEngine.swift:46`). Inputs precomputed per item via `ValueClassifier.kinds(of:)` / `.primaryString(of:)` and `item.application`. `MatchMode.all/.any` composes (`:70`).
- **Actions** — runtime `protocol ClipboardAction` (`ClipboardAction.swift:7`, `@MainActor`): `id, title, systemImage, canRun(on:), run(on:)`. Serialized `struct ActionConfig` (`ActionRule.swift:172`) keyed by `enum ActionType` (`openURL/openInApp/webSearch/transform/runShortcut`). `ActionFactory.make(config)` is a `switch`. Only clipboard-mutating family is `TransformAction` over `enum TransformKind` (`trim/uppercase/lowercase/stripFormatting/unwrap/fixKeyboardLayout`, `ActionRule.swift:40`) — pure `String -> String` then `Clipboard.shared.copy(result)`, echo-suppressed via `ActionEngine.noteAutoOutput` (`ClipboardAction.swift:147`). `OpenURL/OpenInApp/WebSearch/RunShortcut` have side effects and do not mutate the clipboard.
- **Triggers** (4): auto-run on copy (`handleNewCopy`, `ActionEngine.swift:173`, first-match, echo-guarded); global hotkey (`:116`); per-action hotkey bypassing rules (`:160`); UI click (`:97`). Errors → `NSSound.beep()`.
- **CLI** — same binary; `rules describe` emits a live enum catalog. Mutations post a `DistributedNotificationCenter` notification → `reloadRules()` → `CFPreferencesAppSynchronize` + `registerShortcuts()`. Sandboxed: `app-sandbox=true`, only `files.user-selected.read-only`.
- **GUI** — `ActionsSettingsPane.swift`: condition type-picker `:236`, kind sub-picker `:244`; action type-picker `:347`, transform sub-picker `:411`. **No tooltip/`.help()`/description affordance today.** `TransformKind` is `CaseIterable` (auto-propagates); conditions and action types are not.

> **pbxproj constraint:** the project is NOT a synchronized group — each new `.swift` file needs **4 manual pbxproj entries**.

## Architecture

### 1. ProviderRegistry (the core, replaces both switches)

Every condition and action — built-in **and** plugin — is a `Provider` keyed by a stable string id. One registry; no `switch` dispatch anywhere.

```swift
struct PluginInput {                  // the ONLY data a provider sees
  let string: String                  // the single invoked entry's primary string
  let kinds: Set<ValueKind>           // from ValueClassifier
  let sourceAppBundleID: String?      // item.application
}

enum ActionOutcome {
  case replace(String)                // mutate clipboard (routed through echo-guard)
  case sideEffect                     // launched something; no clipboard mutation
  case none
}

protocol ConditionProvider {
  var descriptor: ProviderDescriptor { get }
  func evaluate(_ input: PluginInput, params: JSONValue) throws -> Bool
}

protocol ActionProvider {
  var descriptor: ProviderDescriptor { get }
  func run(_ input: PluginInput, params: JSONValue) async throws -> ActionOutcome
}

struct ProviderDescriptor {           // single source of truth for GUI + CLI + tooltip
  let id: String                      // "builtin.regex", "com.roy.unwrap"
  let name: String
  let description: String             // <= 120 chars — the GUI tooltip + search text
  let longHelp: String?               // markdown, optional "About/Help" tab
  let kind: ProviderKind              // .condition | .action
  let engine: ProviderEngine          // .native | .declarative | .javascript
  let paramsSchema: JSONValue?        // describes editable params for the GUI/CLI
  let capabilities: [Capability]      // [] = pure text-in/out
  let source: ProviderSource          // .builtin | .bundled | .marketplace(id) | .local(path)
  let verified: Bool                  // true only for our default (signed) marketplace
}

final class ProviderRegistry {
  func register(condition: ConditionProvider)
  func register(action: ActionProvider)
  func condition(_ id: String) -> ConditionProvider?
  func action(_ id: String) -> ActionProvider?
  func catalog() -> [ProviderDescriptor]   // drives GUI pickers, `rules describe`, tooltips
}
```

**One-item rule (kept despite permissive capabilities — it's free):** `PluginInput` exposes only the entry the provider was invoked on. There is no accessor for other history entries, the pasteboard, or prefs. A plugin cannot read history entry #47 because no API exists.

### 2. Built-in providers (`BuiltinProviders.swift`)

Native providers wrapping existing logic, registered at boot:

- Conditions: `builtin.kind` (wraps `ValueClassifier`), `builtin.regex`, `builtin.contains`, `builtin.sourceApp`.
- Actions: `builtin.openURL`, `builtin.openInApp`, `builtin.webSearch`, `builtin.runShortcut`.

Launch actions stay native and are **never** synthesizable by a plugin — a plugin's text output is inert data (placed on clipboard / used as a bool), never auto-opened, auto-executed, or auto-pasted.

### 3. First-party plugins (bundled in-app; canonical source = the `maccay-plugins` repo)

Extracted from the current enums, behavior unchanged, but now real plugins (dogfoods the full path). They are **bundled in the app** at `Maccy/Resources/BundledPlugins/` so they work offline and on first launch with no network fetch; their canonical source is the separate `maccay-plugins` marketplace repo, which serves updates. On boot the loader scans the bundled dir; if the same `id` exists in an installed/updated copy, the installed copy shadows the bundled one.

- Conditions: `soft-wrap` (from `TextUnwrap.isSoftWrapped`), `terminal-source` (from `terminalAppBundleIDs`).
- Actions: `trim`, `uppercase`, `lowercase`, `stripFormatting`, `unwrap`, `fixKeyboardLayout`.

`soft-wrap`/case/trim/`unwrap` are good **declarative** examples; `fixKeyboardLayout` (EN⇄HE) is the canonical **JavaScript** example.

### 4. Plugin package format

A plugin is a folder containing `plugin.json` (and `main.js` if `engine:"javascript"`).

```jsonc
{
  "id": "com.roy.unwrap",                 // kebab/reverse-DNS, stable primary key
  "name": "Unwrap terminal command",
  "version": "1.0.0",                     // semver
  "author": { "name": "Roy", "url": "…?" },
  "description": "Join soft-wrapped terminal lines into one pasteable command.", // <=120, tooltip
  "longHelp": "…markdown…",               // optional, "About/Help" tab
  "kind": "action",                       // "condition" | "action"
  "engine": "declarative",                // "declarative" | "javascript"
  "params": { /* declarative spec OR userConfig schema */ },
  "entry": "main.js",                     // required iff engine == "javascript"
  "capabilities": [],                     // opt-in; [] = pure text-in/out, bridge-less
  "minAppVersion": "2.7.0"
}
```

**Declarative engine** (`DeclarativeEngine.swift`) — params interpreted by built-in primitives, no code:
- Action transforms: ordered ops — `regexReplace {pattern, replacement, flags}`, `case {upper|lower}`, `trim`, `encode {base64|url|…}`, `stripFormatting`, etc.
- Condition predicates: `all`/`any`/`not` trees over `regex`/`contains`/`kind`/`sourceApp` leaves.

**JavaScript engine** (`JSPluginRuntime.swift`) — `main.js` exports `transform(input)` (action) or `matches(input)` (condition).

### 5. Runtime & security (`JSPluginRuntime.swift`, `CapabilityManager.swift`)

- **Bridge-less by default:** a `JSContext` exposing only ECMAScript built-ins (`String/Math/JSON/RegExp`) plus the single entry point. **Nothing injected** — no `fetch`, `XMLHttpRequest`, `WebSocket`, `require`, FS, `Process`, or timers. JSC ships none by default; safety = not adding them. A no-capability plugin **physically cannot** exfiltrate.
- **Watchdog:** `JSContextGroupSetExecutionTimeLimit` (~250 ms) terminates runaway/infinite-loop plugins.
- **Capabilities:** the manifest `capabilities` array declares power (`network.fetch`, `fs.read`, …). The corresponding host **bridge is injected only when (a) declared in the manifest AND (b) granted by the user.** Undeclared use is impossible (the symbol isn't there).
- **Capability-scoped consent:**
  - `capabilities: []` → **silent install/run.** If the source is custom/local, a sticky **"Unverified source"** badge appears everywhere the plugin is shown (not a one-time dialog).
  - Declares capabilities → a **consent sheet** on install/enable, naming each capability in plain language (e.g. *"can send the text you run it on — which may include passwords — to the network"*). User grants or denies; grants are persisted per plugin.
  - **Re-consent** when a plugin update changes its declared capabilities (defeats trojan-update).
- **Echo-suppression:** any plugin action returning `.replace(String)` routes the clipboard write through the existing `ActionEngine.noteAutoOutput` / `lastAutoOutput` loop-guard so it doesn't re-trigger auto-run.

### 6. Marketplaces (`Marketplace.swift`, `MarketplaceStore.swift`)

- **Default marketplace** (ours), pre-registered: a separate GitHub repo serving `marketplace.json` (Claude-Code model).

```jsonc
// marketplace.json (repo root)
{
  "id": "maccay-official", "name": "Maccay Official", "version": "1",
  "description": "…", "maintainer": "…", "updatedAt": "…",
  "plugins": [
    {
      "id": "com.roy.unwrap",
      "name": "Unwrap terminal command",        // cached → list/tooltip without fetching plugin
      "description": "Join soft-wrapped terminal lines…",
      "version": "1.0.0", "minAppVersion": "2.7.0",
      "kind": "action", "tags": ["terminal"],
      "source": { "github": { "repo": "owner/maccay-plugins", "sha": "…" }, "path": "unwrap" },
      "sha256": "…",                             // of the downloaded artifact; verified before extract
      "versions": { /* optional: pin/rollback map */ }
    }
  ]
}
```

- **User-added GitHub-repo marketplaces:** add by URL; web URLs auto-rewritten to `raw.githubusercontent.com`; coexist by `id`; refresh on launch + 24h + ⌘R (conditional GET / ETag).
- **Local-folder marketplaces (no repo):** scan `~/Library/Application Support/Maccay/LocalPlugins/` one level deep; a dir is a plugin iff it has `plugin.json`; `id` (not folder name) is the key; **local shadows marketplace** with the same id (dev workflow); no checksum (user owns the folder); optional FSEvents hot-reload "Dev mode."
- **Default marketplace repo (separate):** `owner/maccay-plugins` holds the first-party plugins + `marketplace.json` + `CONTRIBUTING.md` + CI. Community PRs land there; the app repo stays app-only. (First-party plugins are also bundled in-app per §3 for offline/first-run.)
- **Install flow:** resolve `source` → download → **verify `sha256`** (abort on mismatch) → extract to `~/Library/Application Support/Maccay/Plugins/` → validate manifest (`id`/`version`/`minAppVersion`) → register provider(s) → capability consent if declared. **Atomic update:** keep the old version until the new one validates. Offline → cached index; installed plugins keep working.
- **Repo hygiene (our marketplace = production infra):** CODEOWNERS + 2 approvals + branch protection; signing separate from merge; CI gates (forbidden-symbol/static scan for undeclared `fetch`/FS/`require`, secret scan, dependency audit, capability-diff per version bump, reproducible build); `sha256` content pinning; signed revocation list (kill switch) fetched on launch.

### 7. GUI (`ActionsSettingsPane.swift` refactor + new `PluginsSettingsPane.swift`)

- **Provider pickers** list `ProviderRegistry.catalog()` entries (built-ins + plugins, one list). Each row gets `.help(descriptor.description)` (the tooltip) and an ⓘ affordance opening `longHelp`. Built-ins now get tooltips for free.
- **Param editors** render from `descriptor.paramsSchema` (e.g. a regex field for `builtin.regex`).
- **New `PluginsSettingsPane`:** browse/refresh marketplaces; install/update/remove; add custom marketplace URL; add local folders + toggle Dev mode; per-plugin capability grants; sticky "Unverified source" badge.

### 8. Schema, CLI, migration

- **Rule schema (hard cut):** `conditions`/`actions` become `{"provider": id, "params": {…}}` arrays. Bump `schemaVersion` in stored Defaults; on version mismatch / decode failure, reset to the new presets (the codebase already resets on decode failure — safe with no users).

```jsonc
{
  "schemaVersion": 3,
  "id": "…", "name": "Unwrap terminal command", "enabled": true, "matchMode": "all",
  "conditions": [
    { "provider": "com.roy.terminal-source", "params": {} },
    { "provider": "com.roy.soft-wrap", "params": {} }
  ],
  "actions": [ { "provider": "com.roy.unwrap", "params": {} } ],
  "autoRunDefault": true
}
```

- **`rules describe`** is generated from `ProviderRegistry.catalog()` — always in sync with what's installed (no manual enum/plugin merge).
- **Reload:** the existing `DistributedNotificationCenter` reload also re-scans plugin folders and re-registers providers, then re-binds shortcuts.

## New / changed files

**New** (each = 4 pbxproj entries):
`Maccy/Plugins/Provider.swift`, `ProviderRegistry.swift`, `BuiltinProviders.swift`, `PluginManifest.swift`, `PluginLoader.swift`, `DeclarativeEngine.swift`, `JSPluginRuntime.swift`, `CapabilityManager.swift`, `Marketplace.swift`, `MarketplaceStore.swift`, `Maccy/Settings/PluginsSettingsPane.swift`.

**Refactor:**
`ActionEngine.swift` (matches/run → registry), `ActionRule.swift` (RuleCondition/ActionConfig → `{provider, params}` + schemaVersion + new presets), `ActionsSettingsPane.swift` (pickers from registry + tooltips), `ActionsCLI.swift` (`describe` from registry).

**New repo (separate):** `owner/maccay-plugins` — first-party plugins (`unwrap`, `trim`, `uppercase`, `lowercase`, `stripFormatting`, `fixKeyboardLayout`, `soft-wrap`, `terminal-source`), `marketplace.json`, `CONTRIBUTING.md`, CI workflows. *(Net-new repo — requires explicit approval before creation per workflow rules.)*

## Data flow

**On copy** → `ActionEngine.handleNewCopy` → build `PluginInput` once → for each enabled rule, resolve each condition via `registry.condition(id).evaluate(input, params)`, compose by `matchMode` → first matching rule → `registry.action(id).run(input, params)` for the default action → if `.replace`, write through `noteAutoOutput` guard.

**Plugin load** (boot + reload notification) → `PluginLoader` scans bundled first-party dir + `~/Library/Application Support/Maccay/Plugins/` + local-folder marketplaces → validate manifest → register providers (descriptor carries `verified` + `source`).

**Install** → resolve `source` → download → verify `sha256` → extract → validate → register → capability consent if declared.

## Testing

- ProviderRegistry resolve/dispatch (built-in + plugin).
- Declarative interpreter: transforms + predicate trees.
- **JS sandbox assertions:** a plugin script referencing `fetch`/`XMLHttpRequest`/`require`/FS/`Process` throws ReferenceError (the symbols are absent).
- Watchdog: infinite-loop plugin is terminated by the time limit.
- Capability gate: network bridge absent unless declared **and** granted.
- Manifest validation: missing `description`/`id`/bad `engine` rejected; `entry` required iff `javascript`.
- Marketplace: resolve `source`, sha256 mismatch aborts install, atomic update keeps old on failure.
- Migration: stored old-schema rules trigger a clean reset to new presets.
- Echo-suppression: a plugin transform that rewrites the clipboard does not re-trigger auto-run.

## Risks & unknowns

- **JSC escape:** JavaScriptCore is a real VM with RCE CVE history. Bridge-less + watchdog is strong but not a guaranteed wall; in-process means an escape is in our sandbox. Acceptable for v1 (permissive model, single user); XPC helper is the documented future hardening.
- **Permissive capabilities:** "allow all + warn" means a granted network-capable plugin can exfiltrate clipboard contents (including passwords). Mitigated by capability-scoped consent (rare, truthful prompts), the bridge-less default, the unverified-source badge, and our marketplace's review/CI/kill-switch. Eyes-open tradeoff chosen for an early, single-user tool.
- **Registry refactor blast radius:** replacing `ActionFactory` switch + `matches()` switch touches the hot path (`handleNewCopy`, `matchingRules`); `rules describe` and the distributed-notification reload must be driven from the registry to avoid CLI/GUI drift.
- **Echo-suppression** must cover plugin transforms (route through `noteAutoOutput`).
- **pbxproj churn:** ~11 new native files = ~44 manual pbxproj entries.
- **Marketplace ops:** signing key custody, separate-from-merge signing, revocation-list hosting are ongoing commitments.
- **Net-new repo + first push** of `maccay-plugins` require explicit approval (per global rules).

## Out of scope (v1)

ExtensionKit/XPC out-of-process tier; Mac App Store distribution; plugin-to-plugin dependencies; a hosted central registry (marketplaces are just git repos / folders).
