---
name: maccy-actions
description: >-
  Configure Maccy Actions clipboard rules and actions from the command line —
  no GUI, no recompile. Use when asked to create/edit/list/remove a Maccy rule
  or action, set up an auto-transform on copy (e.g. unwrap/trim/uppercase a
  copied value), bind a keyboard shortcut to a specific action, manage the list
  of terminal apps, or otherwise program Maccy's clipboard automation. Also use
  when the user mentions "Maccy Actions", "clipboard rules", or asks an agent to
  set up clipboard behavior on this Mac.
---

# Maccy Actions CLI

Maccy Actions is a macOS clipboard manager whose **rules** run **actions** on
copied values — automatically on copy, from the popup's right-click menu, via a
global shortcut, or via a per-action shortcut. This skill drives the app's
headless CLI so an agent can fully configure rules/actions without the GUI.

## 1. Find the binary

Bundle id: `com.royp.MaccyActions`. The executable name contains a space, so
**always quote the path**.

```bash
APP=$(mdfind "kMDItemCFBundleIdentifier == 'com.royp.MaccyActions'" | head -1)
BIN="$APP/Contents/MacOS/Maccy Actions"
"$BIN" rules describe        # prove it works; prints the live schema catalog
```

If `mdfind` returns nothing, the app may be a fresh Debug build under
`~/Library/Developer/.../Build/Products/Debug/Maccy Actions.app`. Ask the user
where it's installed if you can't locate it.

The CLI works whether or not the GUI is running. **When the GUI is running it
auto-reloads after every mutation** (a distributed notification re-reads the
config and re-binds shortcuts) — no restart needed. When it's not running, the
change is read on next launch.

## 2. Always start with `describe`

`"$BIN" rules describe` emits the **live** catalog built from the app's own
enums — value kinds, action types (and their required fields), transform kinds,
match modes, condition type tags, the shortcut grammar, and the default terminal
apps. Trust `describe` over this document if they ever disagree.

## 3. Commands

All output is pretty JSON on stdout. Errors go to stderr with a non-zero exit;
**validation runs before any write**, so a rejected command changes nothing.

```
"$BIN" rules list                      # all rules (JSON array)
"$BIN" rules export                    # same as list (stable snapshot)
"$BIN" rules get <id>                  # one rule
"$BIN" rules add      <input>          # create a rule (prints it, with ids)
"$BIN" rules update <id> <input>       # replace the rule with this id
"$BIN" rules remove <id>               # delete a rule
"$BIN" rules move   <id> <index>       # reorder (priority = position; 0 = first)
"$BIN" rules enable <id>               # set enabled = true
"$BIN" rules disable <id>              # set enabled = false
"$BIN" rules import <input>            # REPLACE ALL rules with a JSON array
"$BIN" rules describe                  # live schema catalog

"$BIN" terminals list                  # the terminal-app bundle ids
"$BIN" terminals add <bundleid>        # add one (deduped)
"$BIN" terminals remove <bundleid>     # remove one
"$BIN" terminals reset                 # back to built-in defaults
```

`<input>` for `add` / `update` / `import` is one of:
- `--json '<json>'`  (preferred for agents)
- piped **stdin** (when neither flag is given)
- `--file <path>`  — the app is **sandboxed**, so the path must be readable by the
  app's sandbox (e.g. inside its container or an allowed location like `~/Downloads`).
  Arbitrary `/tmp` paths fail with a permission error; prefer `--json` or stdin.

`add`/`update` take a single rule **object**; `import` takes a rule **array**.

## 4. Rule JSON schema

```jsonc
{
  "id": "UUID",                 // optional on add (generated); set by <id> on update
  "name": "Unwrap terminal command",
  "enabled": true,
  "matchMode": "all",           // "all" = AND, "any" = OR
  "conditions": [ /* see below */ ],
  "actions":    [ /* see below */ ],  // first action = the rule's default action
  "autoRunDefault": true        // run the default action automatically on copy
}
```

Omitted fields get struct defaults (`enabled:true`, `matchMode:"all"`,
`autoRunDefault:false`, `name:"New rule"`). Missing rule/action ids are generated.

### Conditions (tagged form)

```jsonc
{"type": "kind",          "value": "url"}            // value ∈ ValueKinds (below)
{"type": "regex",         "value": "^npm "}          // must compile
{"type": "contains",      "value": "docker"}         // case-insensitive substring
{"type": "sourceApp",     "value": "com.apple.Terminal"}  // copy's source bundle id
{"type": "softWrapped"}                              // looks like a wrapped terminal command
{"type": "terminalSource"}                           // copied from a configured terminal app
```

`ValueKinds`: `url`, `email`, `phone`, `filePath`, `colorHex`, `image`, `text`.

A rule matches when its conditions satisfy `matchMode` (all/any). Empty
conditions never match.

### Actions

```jsonc
{
  "id": "UUID",            // optional (generated)
  "type": "transform",     // see ActionTypes
  "appBundleID": "...",    // required for openInApp
  "searchTemplate": "https://www.google.com/search?q={query}", // required for webSearch
  "transform": "unwrap",   // required for transform; see TransformKinds
  "shortcutName": "...",   // required for runShortcut (a macOS Shortcuts name)
  "shortcut": "cmd+shift+u"// OPTIONAL per-action global shortcut (see grammar)
}
```

`ActionTypes` and their required field:
- `openURL` — (none)
- `openInApp` — `appBundleID`
- `webSearch` — `searchTemplate` (use `{query}` placeholder)
- `transform` — `transform`
- `runShortcut` — `shortcutName`
- `sendToAndroid` — (none)

`TransformKinds`: `trim`, `uppercase`, `lowercase`, `stripFormatting`,
`unwrap` (join soft-wrapped terminal lines into one ready-to-paste command).

### Per-action shortcut grammar (`shortcut` field)

`+`-joined, case-insensitive. Modifiers: `cmd|command`, `shift`, `opt|option|alt`,
`ctrl|control`. Final token is the key: `a`–`z`, `0`–`9`, `space`,
`return|enter`, `tab`, `escape|esc`, `delete|backspace`, `f1`–`f12`.
Example: `"cmd+shift+u"`.

A per-action shortcut runs **that specific action** on the current clipboard,
**unconditionally** — it ignores rule matching and priority. This is separate
from the rule-level **global default shortcut** (set in the GUI), which runs the
highest-priority matching rule's default action.

## 5. Recipes

### Create the "unwrap terminal command" rule (auto on copy)
Fires only when a copy comes from a terminal app **and** shows the soft-wrap
signature, then strips the wrap so it pastes as one line:

```bash
echo '{
  "name": "Unwrap terminal command",
  "matchMode": "all",
  "conditions": [{"type":"terminalSource"}, {"type":"softWrapped"}],
  "actions": [{"type":"transform","transform":"unwrap","shortcut":"cmd+shift+u"}],
  "autoRunDefault": true
}' | "$BIN" rules add
```

### Add a regex rule that opens matching values in an app
```bash
"$BIN" rules add --json '{
  "name":"Open Jira keys",
  "conditions":[{"type":"regex","value":"^[A-Z]+-[0-9]+$"}],
  "actions":[{"type":"openInApp","appBundleID":"com.apple.Safari"}]
}'
```

### Bind a shortcut to one action (without changing matching)
Fetch the rule, set the action's `shortcut`, pipe it back via stdin (sandbox-safe):
```bash
"$BIN" rules get <id> \
  | python3 -c 'import sys,json; r=json.load(sys.stdin); r["actions"][0]["shortcut"]="cmd+shift+u"; sys.stdout.write(json.dumps(r))' \
  | "$BIN" rules update <id>
```

### Manage terminal apps (what `terminalSource` matches)
```bash
"$BIN" terminals list
"$BIN" terminals add com.mitchellh.ghostty
"$BIN" terminals remove com.microsoft.VSCode
"$BIN" terminals reset
```

## 6. Notes & gotchas

- **Quote the binary path** — it contains a space.
- `add`/`update`/`import` **validate before writing**: a bad `transform`/`regex`/
  `shortcut`, or a missing required action field, exits non-zero and changes nothing.
- Editing one rule is read-modify-write: `rules get <id>` → edit JSON →
  `rules update <id>`. Use `rules import` only to replace the entire rule set.
- Reordering matters: `autoRunDefault` fires the **first** matching rule; the
  rule editor's first action is its **default** action.
- Output uses sorted keys; when scraping ids from `add` output, parse the JSON
  (the rule's top-level `id`) rather than grabbing the first `id` you see — an
  action's `id` can sort ahead of the rule's.
