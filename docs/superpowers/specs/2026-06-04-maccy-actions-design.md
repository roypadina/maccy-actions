# Maccy Actions — Design Spec

**Date:** 2026-06-04
**Status:** Approved (A+), built autonomously per user goal.
**Fork of:** [p0deje/Maccy](https://github.com/p0deje/Maccy) @ 4cd1f97 (MIT).

## Goal

Add a **rule-based actions engine** to a fork of Maccy: detect the kind of a
clipboard value (URL, email, etc.) and/or match it with regex/substring/source-app,
then run user-configured actions (open URL, open in a specific app, web search,
text transform, run a macOS Shortcut). Distributed as a **separate app**
("Maccy Actions") so it coexists with an already-installed Maccy.

This is **Feature 2** of two. Feature 1 (Android two-way clipboard sync) is a
separate project; this design only reserves a clean seam for a future
`SendToAndroidAction`.

## Decisions (locked)

- **Architecture A+:** native rules engine in Maccy core, with a protocol-based
  `ClipboardAction` so new action types (incl. future Android-send) drop in
  without touching the engine.
- **Sandboxed + Shortcuts:** no raw shell inside the app. Power users get the
  full ceiling by triggering a macOS Shortcut with the clipboard value. Keeps
  the app sandbox-clean and upstreamable.
- **Action types v1:** `openURL`, `openInApp`, `webSearch`, `transform`,
  `runShortcut`. (`sendToAndroid` stubbed, disabled.)
- **Triggers v1:** (a) manual from the popup (context menu on a row),
  (b) global shortcut → run default action on selected/top item,
  (c) auto-run default on copy (opt-in per rule, loop-guarded).
- **Match dimensions:** value kind, regex, plain contains, source app —
  combined per rule via `matchMode` (all/any).
- **Storage:** rules are Codable JSON in `Defaults` (config-shaped), NOT
  SwiftData (reserved for clipboard history).

## Separate-app strategy

- Bundle id `org.p0deje.Maccy` → `com.royp.MaccyActions` → distinct sandbox
  container ⇒ separate history DB, separate `Defaults`, separate KeyboardShortcuts
  storage. No collision with installed Maccy.
- `PRODUCT_NAME` → `Maccy Actions` (.app + display name). Swift **module name kept
  as `Maccy`** (`PRODUCT_MODULE_NAME = Maccy`) so internal references and tests
  don't break.
- Ad-hoc code signing (`CODE_SIGN_IDENTITY = -`, manual, no team) for local builds.
- Sparkle auto-update feed disabled (would otherwise offer to "update" the fork
  to upstream Maccy).

## Components (`Maccy/Actions/`)

| Type | Role |
|---|---|
| `ValueKind` + `ValueClassifier` | classify a `HistoryItem` → {url, email, phone, filePath, colorHex, image, text}. NSDataDetector + parsing. |
| `ActionRule` (Codable) | `name`, `enabled`, `conditions[]`, `matchMode`, `actions[]` (index 0 = default), `autoRunDefault`. |
| `RuleCondition` (Codable enum) | `.kind`, `.regex`, `.contains`, `.sourceApp`. |
| `ActionConfig` (Codable) | `type` + params (appBundleID, searchTemplate, transform, shortcutName). |
| `ClipboardAction` (protocol) | `title`, `systemImage`, `canRun(on:)`, `run(on:)`. Conformers: OpenURL/OpenInApp/WebSearch/Transform/RunShortcut. |
| `ActionFactory` | build a `ClipboardAction` from an `ActionConfig`. |
| `ActionEngine` (@Observable, .shared) | sync rules from Defaults; `resolvedActions(for:)`, `defaultAction(for:)`, `run...`, `runAutoActions(for:)` with loop guard. |
| `SyncService` (protocol stub) | empty seam for Feature 1. |

## Hook points in existing code

- Auto-run: `Clipboard.onNewCopy` (`Clipboard.swift:42`) — add engine hook in `AppDelegate`.
- Popup actions: `.contextMenu` on `Views/HistoryItemView.swift` rows.
- Global shortcut: new `KeyboardShortcuts.Name.runDefaultAction` (no default binding to avoid collisions), handled in `AppDelegate`.
- Settings: new `Settings/ActionsSettingsPane.swift`, registered in `AppState.openPreferences`.

## Loop safety

Auto-run `transform` writes back to the clipboard, which the poller would
re-capture → infinite loop. Guard: engine tracks `lastAutoOutput`; a new copy
equal to the last auto-produced value is skipped for auto-run.

## Out of scope (v1 / YAGNI)

- Android send action (Feature 1 dependency).
- Localization of the new pane (English only for now).
- Plugin registry / third-party actions (the protocol already allows it later).
- Raw shell/AppleScript baked into the app (delegated to Shortcuts).

## Testing

- `ValueClassifier`: kind detection per sample input.
- `ActionEngine.matches`: each condition type + matchMode all/any.
- `ActionEngine` resolution: ordering, dedupe, default-first.
- Manual smoke: build, launch, add a rule, run from context menu.
