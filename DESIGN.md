# harnessmd - Design

A resident macOS menu bar app that collects, versions, analyzes, and restores AI coding-agent instruction files: `AGENTS.md`, `CLAUDE.md`, skills, rules, prompts, and tool configs for Claude Code, Codex, and OpenCode, across all local repos and global config locations.

This document records the decisions, their rationale, and what is deferred. [README.md](README.md) describes the implemented behavior in operational detail.

## Goals

- Run in the background at login, controlled from the menu bar.
- Discover repos under configured roots and snapshot every agent-instruction file on every change.
- Keep a permanent, deduplicated, content-addressed version history per file.
- Restore any previous version explicitly and safely.
- Detect out-of-sync copies and missing paths locally; use AI (via the locally installed CLIs or Ollama) to propose changes as diffs.
- Cover global locations for Claude Code, Codex, and OpenCode with the same machinery as repos.

## Non-goals (v1)

- Editing instruction files in place (snapshot, restore, and analyze only; apply happens through explicit proposal acceptance).
- Sync between machines, cloud storage, team sharing.
- Windows or Linux.
- Collecting anything credential-shaped (hard denylist, see Collection model).
- Auto-committing restores or applied proposals into user repos. Git operations stay with the user.

## Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| Platform | macOS 14+ only | Personal machine tooling. |
| App shape | Native SwiftUI `MenuBarExtra` app, `LSUIElement` | Chosen over a Go core: fully native menu and windows, `SMAppService` login item, single `.app`. Accepted tradeoff: no Go core and no automatic CLI reuse; a CLI can be added later as a second executable target sharing the same core package. |
| Storage | SQLite via GRDB with real columns and explicit migrations; contents on disk | Migrations add columns instead of rewriting JSON payloads. Contents stored verbatim under their sha256 keep the database small and the store greppable; manifests map a snapshot's entries to contents, so unchanged skill files are stored once. |
| Change detection | Per-file `DispatchSource` watchers within a descriptor budget + periodic discovery sweep | Precise and cheap for hundreds of tracked files; the sweep catches new and deleted files. FSEvents per repo root rejected: recursive streams over repo roots churn on `node_modules` and build output. kqueue costs one descriptor per path, so the app raises its soft limit from launchd's 256 at launch and leaves paths beyond the budget to the sweep. |
| AI backend | Shell out to local CLIs (`claude -p`, `codex exec`, `opencode run`); Ollama over its local HTTP API | Reuses existing subscriptions and auth; no API keys to store. Ollama uses HTTP because only the API can size the context window per request. `ProcessRunning` and `HTTPTransport` protocols keep both injectable in tests. |
| Core/UI split | Core logic in a local Swift package (`HarnessKit`), app target depends on it | Core stays UI-free and unit-testable; a future CLI target gets the same core. |

## App shape

- Menu bar resident: `LSUIElement = true` (no Dock icon), `MenuBarExtra` with a template status icon.
- Identity: instruction pages held by a harness strap, for collected files kept safe. The app icon is `Support/AppIcon.svg` on the macOS grid (an 824 px body with 185.4 px corners), rendered by `make icon` into the committed `AppIcon.icns`. macOS 27 shows it without the gray backing it gives nonconforming legacy icons. The menu bar mark is the same page and strap reduced to an 18-point template glyph, drawn in code so it stays vector and needs no SwiftPM resource bundle.
- Launch at login via `SMAppService.mainApp.register()`, toggled from Settings, which shows a pending approval and opens Login Items.
- Not sandboxed (reads all configured repo roots and global config dirs). Ad-hoc code signature for personal use; notarization can be added if it is ever distributed.

### Menu

- Status line: tracked sources, files, changes today.
- Scan Now.
- Pause / Resume watching.
- Recent Changes (submenu, last 5, opens the file's history).
- Open Dashboard.
- Run AI Analysis.
- Settings, Quit.

### Dashboard

One AppKit-hosted window with a `NavigationSplitView`:

- Sidebar: Overview, All files, Recent changes, Review, Sources (only those with collected files, with Private and Collect toggles), Settings.
- File list per source, filtered by category (instructions, skills, rules, config, prompts, agents, memories).
- File detail: version timeline (time, origin) with a diff against the previous version, or plain content.
- Diff viewer: Git-style hunks computed in core (`TextDiff`: three lines of context, nearby changes merged, old and new line numbers, the changed words marked inside modified lines), rendered natively. The same hunks produce patches that `git apply` accepts. Side-by-side rendering is deferred.
- Review: AI proposals and local check findings in one list, one row per group of items connected through shared files (so a file appears once; a check spanning AGENTS.md and CLAUDE.md joins both files' rows), with a tab per item in the detail; after a decision the next row is selected (`rowAfterDecision`: the same row while it keeps an item, else the next or nearest earlier row, matched by item since rows merge and split); several rows can be selected for one bulk decision; filtered by kind, Git state (any file outside Git counts as not in Git; global files have no state), text, and to-review versus done. Rows show the files, a Git badge, and a summary. A proposal's detail shows the model's summary, then the diff with each change's reason above its hunk, plus Copy patch, Reject, It's fine, and Accept. Edits to global instructions are flagged. Accept applies changes with automatic pre-apply snapshots. A finding's detail lists its files with Git badges and offers It's fine and Suggest a fix, or links to the diff already waiting for its file. Only proposals with diffs are listed, one pending per file; text-only proposals from earlier versions stay stored but are filtered out.
- Starting AI work: actions are named by their result and sit where the files are, not in a global button: Suggest edits in the All files toolbar (selection, or every file shown), the file table's context menu, and the file pane; Suggest a fix on a check. No sparkle icons: a sparkle doesn't say what happens, and Nielsen Norman Group reportedly saw no participant read the sparkle alone as AI.
- Settings: roots, global collection, discovery interval, watching pause, AI backend (CLI binary or Ollama URL, model with a discovered list, effort, timeout, default instructions, edits on or off), launch at login, store location (shown, not configurable).

## Architecture

```
HarnessKit (local Swift package, no UI deps)
  Scanner        discovery and per-source listings (repo walk, global maps)
  FileWatcher    budgeted per-path watchers
  SafeFiles      descriptor-based reads, writes, capture, restore
  Store          GRDB database, content blobs, manifests, version chains
  Analyzer       local checks (out of sync, missing paths)
  AIService      CLI runner protocol, request builder, response parser
  Engine         actor coordinating scans, captures, restore, analysis, proposals

harnessmd (app target)
  MenuBarExtra shell, dashboard window, settings
  Reloads the inventory after each engine call
```

- The Engine actor runs scans and analysis off the main thread. The UI reads an `Inventory` snapshot holding sources, files, the 500 newest versions, and per-file version counts; a file's full history loads on demand. Findings are cached until collected contents change or a scan runs.
- All mutating user actions (restore, apply proposal) go through the Engine, which writes a snapshot first.
- GRDB `ValueObservation` is deferred; explicit refreshes suffice for one window.

## Collection model

### Sources

Two kinds, one table:

- Repo sources: discovered by walking roots the user adds (none by default) for `.git` directories and `.git` files. Each worktree is its own source with its own history, and records its main repository as `repositoryRoot`. Sources sharing that root form one family, so analysis treats their identical files as expected copies. A directory with its own `.git` inside a repository is a separate source, never part of the parent.
- Global pseudo-sources (fixed roots with explicit maps; caches, plugins, marketplaces, sessions, projects, worktrees, and `.tmp` are never walked):
  - `~/.claude/` - `CLAUDE.md`, `settings.json`, `skills/*/`, `commands/**/*.md`, `agents/**/*.md`, `rules/**/*.md`, `output-styles/**/*.md`
  - `~/.codex/` - `AGENTS.md`, `AGENTS.override.md`, `config.toml`, `prompts/**/*.md`, `memories/*.md` (top level only), `rules/**/*.rules`, `agents/**/*.toml`, `skills/*/`
  - `~/.agents/skills/*/`
  - `~/.agent-skills/*/` - where skills linked from `~/.claude/skills` live
  - `~/.config/opencode/` - `AGENTS.md`, `opencode.json(c)`, `skill(s)/*/`, `agent(s)/**/*.md`, `command(s)/**/*.md`

### Per-repo file map

| Category | Patterns |
|---|---|
| Instructions | `AGENTS.md`, `AGENTS.override.md`, `CLAUDE.md`, `CLAUDE.local.md`, `DESU.md`, `.github/copilot-instructions.md`, `.cursorrules`, `.windsurfrules`; `.cursor/rules/*.mdc` as rules |
| Claude Code | `.claude/skills/*/` (skill units), `.claude/commands/*.md`, `.claude/agents/*.md`, `.claude/rules/*.md`, `.claude/output-styles/*.md`, `.claude/settings.json`, `.mcp.json` |
| Codex | `.codex/config.toml`, `.codex/rules/*.rules`, `.codex/agents/*.toml`, `.codex/skills/*/`, `.agents/skills/*/` |
| OpenCode | `opencode.json(c)`, `.opencode/agent(s)/*.md`, `.opencode/command(s)/*.md`, `.opencode/skill(s)/*/` |

Users add more instruction files as names or globs (`GEMINI.md`, `.kilocode/rules/*.md`, `**/*.prompt.md`), matched in repositories only.

Configuration (`settings.json`, `config.toml`, `opencode.json(c)`, `.mcp.json`, Codex `.rules` exec policies, TOML agent definitions) and Codex memories are versioned but never sent to a model or edited by a proposal. Exec policies decide which commands run without approval, so a prompt-injected proposal must not be able to touch them.

Skills: the whole skill directory, including binary assets, is the versioned unit; OS and interpreter byproducts are ignored. Links are never followed, so a skill whose `SKILL.md` is a symlink is versioned only where its target lives, and a scan warns when that place is not collected.

### Denylist (never collected)

`auth.json`, `.claude.json`, `.env`, `.env.*`, `.envrc`, private keys and keystores (`*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.jks`, `*.keystore`, `*.ppk`, `*.kdbx`, `id_rsa`, `id_ed25519`, `.ssh`), `*credentials*`, `*keychain*`, `*.auto.tfvars(.json)`. Content sniffing is the second layer, over all collected text: private keys (header plus key data), known token prefixes, URL credentials, literal values on secret-named keys, and random high-entropy tokens block a file. References, names (including Kubernetes Secret names on `*Secret` keys), placeholders (`your_secret`, `YOUR_API_KEY`, `changeme`, `sk-xxxx`, AWS `...EXAMPLE` keys), git object names, digests, UUIDs, paths, slugs, and PEM headers mentioned in prose do not, because blocking them stops ordinary instruction files from being versioned. The block reason names the file, line, and rule, never the value.

### Discovery cadence

Full discovery sweep hourly by default (every minute or 10 minutes optional) plus manual Scan Now. Tracked files get watchers after each scan; changes are debounced 500 ms and flushed at most 3 s after the first event.

## Store

Location: `~/Library/Application Support/harnessmd/`

- `store.sqlite` - GRDB database
- `blobs/<sha256>` - each distinct file content, verbatim
- `manifests/<sha256>` - JSON mapping a snapshot's entry names to content hashes, plus executable entries; the manifest hash identifies the version

### Schema

```
sources(id, kind, root, name, repositoryRoot, isPrivate, enabled, lastScan)
files(id, sourceID, path, category, tool, isDirectory, blob, lastSeen)
versions(id, fileID, blob, capturedAt, origin, note)
  -- origin: initial | scan | watcher | pre_restore | restore | pre_apply | apply | rollback
proposals(id, createdAt, status, model, rationale, edits, note, instructions, fileIDs)
analyses(fileID, blob, task, analyzedAt)
  -- content already analyzed with a task (digest of the instructions as sent), for skipping repeats
dismissals(key, dismissedAt)
  -- findings marked "It's fine", by finding key
keptNotes(id, fileID, proposalID, text, keptAt)
  -- points of proposals marked "It's fine", sent with later requests for the file
  -- status: pending | accepted | rejected | expired | kept | replaced (text-only rows from earlier versions: also unchanged)
  -- edits: [{fileID, baseBlob, content, notes: [{line, text}]}]; fileIDs: every analyzed file
invocations(id, date, backend, model, fileIDs, status)
  -- status: running | completed | failed | interrupted
settings(id, payload)
  -- one JSON document; missing keys take defaults
```

Migration `v2-columns` converts v0.1's one-JSON-payload-per-row tables and relabels each file's first capture as `initial`; v0.1 whole-snapshot blobs stay readable. Migration `v3-proposal-files` adds `proposals.fileIDs` and fills it for earlier proposals from the latest completed invocation that started before each one, which is exact because requests run one at a time. Migration `v4-decisions` adds `dismissals` and `keptNotes`. Migration `v5-analyses` adds `analyses`, fills it from existing proposals' base contents and instructions, and marks older pending proposals for a file that has a newer one as `replaced`.

Semantics:

- Append-only version chains. A scan appends a version only when the manifest hash changes.
- A file's first version has origin `initial`: it starts the timeline and is not a change, so history shows it as full content and recent changes and daily counts leave it out.
- Deletion of a tracked file records a tombstone version; content remains restorable.
- A file the collection policy no longer covers keeps its history and is no longer rechecked; no tombstone is recorded.
- Blobs are never pruned in v1 (instruction files are tiny); a pruning policy is a later addition.
- `pre_restore` and `pre_apply` origins make every mutation reversible, except a restore the user explicitly confirms over content that can't be stored.
- Every read verifies content hashes; capturing the same content again rewrites a corrupt blob.

## Restore

Always explicit from the file timeline:

1. Snapshot current content (`pre_restore`). If it can't be stored (credential-like, binary, or too large), ask before overwriting it without a snapshot, and note that in the restore version.
2. Write the selected snapshot back to the original path (skill directories restore every recorded entry and keep newer files).
3. Record the restored state (`restore`). No git commands are run in the target repo.

If the file was deleted (tombstone), restore recreates it.

Point-in-time restore applies the same steps to a selection: for each file, the version in effect at the chosen moment, compared with the content on disk. Files already matching, not yet tracked, or absent at that moment are left alone, so nothing is ever deleted. One failure does not stop the rest; skipped files are reported.

Git status: each repository file is marked In Git or Not in Git by reading the working tree's index file directly (versions 2 to 4, SHA-1 or SHA-256; split indexes report unknown). No Git command runs, so repository config such as `core.fsmonitor` can't execute anything. The index is reread only when its modification time changes.

## Local checks (no AI)

Two kinds, so the list stays short; similarity uses normalized five-word shingles with Jaccard:

- Out of sync (`sync`): `AGENTS.md` vs `CLAUDE.md` in the same folder below 0.6, unless one imports the other with `@path`; and same-named skills whose `SKILL.md` copies share less than 0.9, so per-tool renderings of one skill are not reported.
- Missing paths (`stale`): backtick-quoted relative paths missing next to the file, under the source root, and under each top-level folder, one finding per file. Hosts and slugs without a file name whose first folder is absent are not local paths.

Cross-repository near-duplicates were dropped: for per-repository instruction files they were suggestions, not problems, and they produced noise.

Suggest a fix builds its task from local facts, because a model answering without extended thinking changes nothing when it must guess: for missing paths, each path with the files of that name under the source root (up to five, skipping `.git` and dependency folders, at most 50,000 entries walked); for AGENTS.md vs CLAUDE.md, to resolve contradictions only; for skill copies, to make them match. A single request that returns no diff shows the model's summary instead of passing silently, and a diff that arrives is selected in Review.

Each finding has a key for "It's fine": the file pair for AGENTS.md vs CLAUDE.md (similarity changes don't bring it back), and the files plus the problem itself for missing paths and skill copies (a new missing path does).

Deferred: similarity trends over time, repo file vs the corresponding global file, skills missing an equivalent in another tool, and never-referenced skills.

## AI analysis (Suggest edits)

Backends, chosen in Settings; no automatic fallback:

- Depth: quick (default) sends each backend's fastest useful effort (Ollama `think: false`, Claude and Codex `low`; OpenCode keeps its configured variant, which is model-specific); thorough sends the configured effort. On gemma4:12b with a 3.4 KB file, quick took 15 to 24 s and thorough 6 to 15 minutes, almost all of it thinking. The default task is a checklist (contradictions, repeated rules, unverifiable rules, near-duplicate sections) because a model answering without extended thinking finds more with named problems to look for.
- `claude -p` (default), with `--effort` low to max, and `--output-format stream-json --verbose --include-partial-messages` so output arrives while Claude thinks and writes; the final `result` event is the answer, and an error result is reported.
- `codex exec` with a read-only sandbox, `--ignore-user-config`, `--ephemeral`, `--output-schema`, and browser, computer-use, plugin, hook, and memory features disabled; effort via `model_reasoning_effort`. Codex cannot turn off its shell, so the model can still read files on the machine; Settings and the preview say so.
- `opencode run --standalone`; effort as a model variant (`provider/model#high`).
- Ollama's `/api/generate`, streamed, with the reply schema as `format`, `num_ctx` sized to the payload, and `think` off, on, or a level. A 501 (the model can't constrain output) gets one retry without `format`. Streaming makes the timeout an idle limit, so slow generation and thinking don't fail.
- Each backend keeps its own path, model, and effort. Models come from Claude aliases, Codex `config.toml` entries, `opencode models`, or Ollama's `/api/tags`.
- Several files go one per request by default, sequentially, each producing its own proposal as it finishes; one combined request remains for cross-file tasks. Cancel stops the remaining requests.
- Configurable timeout (default 120 s, 1-600), per request, measured as the longest silence: CLI output and Ollama chunks reset it. A 20-minute cap bounds a run that never stops. Each request is limited to 128 KiB and output to 2 MiB (32 MiB for Claude's event stream).
- Input building: the user selects files (or a finding's files), writes or picks instructions, previews the exact payload, and sends it explicitly. The user's instructions are trusted and sit inside a fixed frame: file contents are untrusted data, the reply must be JSON, and no new commands, URLs, or tool permissions. File contents go out as JSON with file IDs and base hashes; skills contribute `SKILL.md` only.
- Output: changes, not advice. The prompt asks for the changes that matter most, at most 8 per file, each as small as possible: in tests with gemma4:12b this halved thinking time and gave narrower diffs. One JSON object `{summary, changes: [{fileID, find, replace, why}]}`, tolerant of a preface or a code fence. A model writes only what changes, which is faster than rewriting whole files and can't silently reword the rest. `TextPatch` places each change where its `find` text matches exactly once, then tries the misquotes seen from gemma4:12b: whole lines with trailing whitespace and blank lines ignored; a single-line quote with a list marker the file doesn't have there (the marker is dropped from `replace` too); line breaks escaped twice into a literal `\n`; and, last, lines compared without list markers and indentation, for renumbered or unmarked list items, where each replacement line that repeats the misquoted prefix gets the file's own prefix back. An empty `find` appends and an empty `replace` deletes. Changes that don't match once, overlap, or name a file outside the request are listed under "Not applied" in the summary, never guessed. When none match, the reply is an error and the request is sent once more, since quotes vary between runs; a second miss is reported as failed. A one-file request accepts any `fileID`, since the change can only land in that file. The result stores full new content per file (the apply path is unchanged), each `why` as a note on the line where its change starts, and the analyzed file IDs. Credential-like text or redaction markers in a replacement, or credential-like text in the summary or reasons, reject the reply. A reply with no changes is counted in the status bar and not stored.

Privacy controls:

- Per-source `isPrivate` flag: versioned locally, never sent to any model.
- A file with any credential-like match is excluded, not masked; the preview lists every excluded file with its reason.
- Every AI invocation is logged (timestamp, backend, model, files included, status) in the store.
- Claude runs with no tools, MCP servers, setting sources, slash commands, or session persistence. OpenCode runs with an isolated config holding only the user's provider definitions and default models, deny-all permissions, and no plugins, MCP servers, or instructions. Ollama on a loopback URL keeps the payload on the machine. Codex is the least isolated backend (see above).
- Instructions with credential-like text are refused like file contents.

Proposal lifecycle: pending -> accepted (applies changes with `pre_apply` snapshots, rolls back on failure), rejected (kept for reference), or kept ("It's fine": rejected, and each change's reason is stored per file). Kept reasons are added to later prompts for the same file, under the task, as points the user keeps as they are; the preview shows them. Reopen returns a kept proposal to pending and deletes its reasons. Pending proposals expire after 30 days, checked on accept. Only proposals with changes are stored, and saving one marks older pending proposals that touch any of its files as `replaced`, so each file has one diff waiting. Every completed request records its files' contents and task in `analyses`; the preview leaves out files analyzed with the same task and unchanged since, unless the user switches them back on (Suggest another fix does so).

## Security notes

- No credentials are collected or stored; the denylist and content sniffing block them at scan time.
- All data stays local except explicit AI analysis payloads, which exclude private sources, configs, exec policies, memories, and credential-like files.
- No network listener of any kind in v1 (no embedded server; the dashboard is native).
- Collected files are untrusted model input. The model gets no tools, proposals can target only files in the request, and edits to global instructions are flagged; the human diff review remains the final control against prompt injection.
- Kept reasons are model text that the user marked fine, and they reach later prompts beside the task. A file could steer that text, so they are shown in the preview before each send, and Reopen removes them.
- TCC: repos under `~/Personal` and global dotdirs are not protected locations, so no Full Disk Access prompt is expected; watching locations under `~/Documents`, `~/Desktop`, or `~/Downloads` may trigger a consent prompt and is supported.

## Testing

- `HarnessKit` unit tests (XCTest):
  - Scanner: fixture trees (plain repos, worktrees, nested worktrees, nested skills, symlinked skills, global maps, denylisted files, unreadable folders).
  - Store: migrations (including v0.1 payload stores), version chains, dedup, blob repair, restore round-trips.
  - Analyzer: out-of-sync pairs and skill copies, imports, stale reference fixtures, finding keys.
  - AIService: mocked process runner and HTTP transport, per-backend arguments and requests, model discovery, instructions and recommendations-only mode, privacy exclusions, OpenCode isolation, output parsing.
  - Watcher: atomic replacement, budget, rewatch after an inode change.
- App level: `--self-test` scans, captures, and restores a temporary repository through the packaged binary; `--demo` opens the dashboard on generated fixtures. UI automation is deferred.

## Milestones

M1 through M5 are implemented in v0.1; deferred items are listed in the sections above.

- M1: HarnessKit package skeleton, GRDB store + migrations, scanner with fixture-tree tests, app target with MenuBarExtra showing status.
- M2: Watchers + version chains + dashboard (sources, file history, diff view, restore).
- M3: Local analyses and their dashboard views (since reduced to out of sync and missing paths, and merged with proposals into Review).
- M4: AIService CLI backend, privacy exclusions, proposals inbox, apply/reject.
- M5: Login item, Settings polish, packaging (ad-hoc signed `.app`), README.

## Resolved questions

- Cadence: watchers run continuously (500 ms debounce, 3 s maximum delay); discovery defaults to hourly.
- Thresholds on 5-word shingles: 0.6 for AGENTS.md vs CLAUDE.md, 0.9 for skill copies. Tune them against the real corpus.
- Proposal expiry: 30 days, checked on accept.
- Bundle identifier: `md.harnessmd.app`.
