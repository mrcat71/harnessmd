# harnessmd

A quiet macOS menu bar app for the instructions behind your coding agents.
Collect Claude Code, Codex, and OpenCode instructions across local repositories,
keep their history, compare approaches, and restore earlier versions without
touching Git history.

## Run

Requires macOS 14+ and Swift 6.1+ (Xcode's command-line tools). Dependencies are
[GRDB](https://github.com/groue/GRDB.swift) and
[Sparkle](https://sparkle-project.org), pinned in `Package.resolved`.

```sh
make test
make run
```

`make` (or `make build`) builds and ad-hoc signs `dist/harnessmd.app` without
launching it. `make run` builds and launches the normal app. The Makefile wraps
`build.sh`; `make build CONFIGURATION=debug` selects a debug build.

The app starts in the menu bar, without a Dock icon or an initial dashboard
window. Click the harnessmd icon (a page held by a strap) and choose **Open Dashboard**. Closing the
dashboard leaves collection running. **Quit harnessmd** stops it.
`make run` quits a running harnessmd first (normal or demo), because `open` would
only bring the old instance forward instead of launching the new build. If you
see `atlas`, `notebook`, and `platform`, you are looking at generated demo
repositories, not your own collected sources.

1. Choose a folder containing Git repositories. A repository itself also works.
2. Optionally enable global collection in Settings.
3. Select a source or **All files** to browse snapshots and diffs.
4. Choose **Restore** on a content version to write it back, with a safety
   snapshot of the current state first.
5. Open **Review** for problems local checks found and for AI changes as diffs.
   Filter by kind, Git state, and text; mark what's fine as **It's fine**.
6. Choose **Suggest edits** for files (the All files toolbar acts on the selection
   or every file shown; it's also in the right-click menu and the file pane), or
   **Suggest a fix** on a check. Review the exact outgoing payload, then send it.
   The diff lands in **Review**.

No folders are scanned until you choose them. Collection roots, global
collection, discovery interval, pause state, and AI settings persist locally.
Launch at login is opt-in in Settings and uses `SMAppService`; register the
packaged app from its permanent location, not a temporary build folder. macOS
may require approval in System Settings > General > Login Items; Settings shows
a pending approval and opens Login Items.

## What it collects

Repositories are discovered through `.git` directories and worktree `.git`
files. Instructions are found recursively, excluding `.git`, dependency trees,
virtual environments, and build output. A directory with its own `.git` (a nested
repository, submodule, or worktree such as `.claude/worktrees/<name>`) is a source
of its own; its files are not tracked again under the parent. Unreadable
subdirectories are skipped with a warning instead of failing the whole root.

| Area | Files |
| --- | --- |
| Instructions | `AGENTS.md`, `AGENTS.override.md`, `CLAUDE.md`, `CLAUDE.local.md`, `DESU.md`, `.github/copilot-instructions.md`, `.cursorrules`, `.windsurfrules`, `.cursor/rules/*.mdc` |
| Claude Code | `.claude/skills/*`, `commands/*.md`, `agents/*.md`, `rules/*.md`, `output-styles/*.md`, `settings.json`, `.mcp.json` |
| Codex | `.codex/config.toml`, `rules/*.rules`, `agents/*.toml`, `skills/*`; `.agents/skills/*` |
| OpenCode | `opencode.json(c)`, `.opencode/skills/*`, `agent(s)/*.md`, `command(s)/*.md` |
| Global (opt-in) | `~/.claude`, `~/.codex` (also `prompts`, top-level `memories/*.md`), `~/.agents`, `~/.agent-skills` (one skill per folder), `~/.config/opencode` |

Add your own instruction files in Settings under **Extra instruction files**: a
name such as `GEMINI.md` matches in any folder, and a path such as
`.kilocode/rules/*.md` matches from the repository root (`*` stays within one
folder, `**` spans folders). Matches are collected as instructions in
repositories; denied names and credential-like contents are still excluded.

Global locations use explicit per-tool maps: their top-level instruction and
config files plus the folders above. The plugin caches, marketplaces, sessions,
projects, worktrees, and `.tmp` folders the tools keep beside them are never
collected.

Tool configs (`settings.json`, `config.toml`, `opencode.json(c)`, `.mcp.json`),
Codex exec policies (`rules/*.rules`, which decide which commands run without
approval), TOML agent definitions, and Codex memories are versioned but never
sent to a model or edited by a proposal.

A skill directory with a regular `SKILL.md` file is one versioned unit, including
its bundled scripts, references, and binary assets such as images. `.DS_Store`,
`._*`, `__pycache__`, `*.pyc`, nested `.git`, `node_modules`, and virtual
environments inside a skill are ignored. Files over 1 MiB and skill bundles over
8 MiB or 1000 files are rejected. A denied file, a symlink, or a binary file that
embeds a private key blocks the whole bundle, rather than silently recording an
incomplete version.

Symlinks are never followed. A skill whose `SKILL.md` is a symlink is versioned
where its target lives: collect that location (skills linked from
`~/.claude/skills` usually live in `~/.agent-skills`), or the scan warns that the
skill is not versioned.

Worktrees retain separate file histories so different branch contents cannot
overwrite one another's timelines. They record their canonical main repository
path for standard Git worktrees. Identical contents share blobs across sources.

## History and safety

The default store is `~/Library/Application Support/harnessmd/`:

- `store.sqlite`: migrated SQLite database with sources, files, append-only
  versions, proposals, invocation metadata, and settings.
- `blobs/<sha256>`: each distinct file content, stored verbatim once. The store
  stays greppable, and unchanged skill files are shared across versions.
- `manifests/<sha256>`: deterministic JSON mapping a version's entries to content
  hashes and executable bits. Its hash identifies the version.

Stores written by v0.1 (one JSON payload per row, whole-snapshot blobs) migrate
on first launch, and their old blobs stay readable.

The store directory is owner-only and data is unencrypted. Back up the entire
directory. Snapshots are never pruned. Removing a collection root or disabling a
source stops collection without deleting its history. Every read verifies content
hashes. Capturing the same content again repairs a corrupt blob, and an
unreadable snapshot shows as a warning instead of breaking analysis.

Tracked files get per-file watchers with a 500 ms debounce, flushed at most 3 s
after the first change. Parent directory watchers catch atomic replacements and
recreation; skill entries are watched too. The app raises its open-file soft
limit to 10,240 at launch, because launchd starts apps at 256, and keeps watchers
within a budget below it. Paths beyond the budget rely on discovery, and Overview
shows a warning. Full discovery defaults to hourly and can run every minute or
10 minutes. **Scan now** works even when automatic collection is paused. Changes
that happen entirely between watcher registration or discovery passes cannot be
guaranteed to be captured.

Scans add versions only when contents change. A file's first version is marked
**first captured**: it starts the timeline, so its history shows the full content
instead of an all-added diff, and Recent changes and changes today leave it out.
Deletions record tombstones. A known file that the collection policy no longer
covers (after an upgrade, or a folder that became its own repository) keeps its
history and is no longer rechecked, so no false deletion is recorded.

Each repository file shows whether it is **In Git** or **Not in Git**, read
directly from the repository's index file, so no Git command or repository
config runs. For files not in Git (including ones a global gitignore excludes),
harnessmd's history is the only backup of earlier versions. Filter the file list
by it, select files, and choose **Restore...** to restore them as they were at a
point in time: the sheet shows, per file, the version it would write back, or
that the file already matches, wasn't tracked yet, or didn't exist then (such
files are left as they are; nothing is deleted). Each file gets its own safety
snapshot; a file whose current content can't be snapshotted is skipped and
reported.

Restore records `pre_restore`, then the restored state. If the current content
can't be kept as a safety snapshot (credential-like, binary, or over 1 MiB),
restore asks before overwriting it, and the restore version notes that the
replaced content was not stored. A skill restore writes all recorded entries but
deliberately preserves newer files; it is not a destructive directory mirror.
Restores never run commands or Git operations. Executable skill scripts retain
owner execute permission when recreated. Paths are traversed with directory
descriptors and `O_NOFOLLOW`, and hard-linked restore targets are refused.
Multi-file skill restores are not filesystem-wide transactions; if a write fails,
use the pre-restore snapshot to recover.

Credential-shaped filenames (`auth.json`, `.claude.json`, `.env`, `.env.*`,
`.envrc`, `*credentials*`, `*keychain*`, private keys and keystores,
`*.auto.tfvars`, `*.auto.tfvars.json`) are denied. Content sniffing rejects
private keys (a PEM header followed by key data), known token prefixes, URL
credentials, literal values assigned to secret-named keys, and random
high-entropy tokens. It treats as public:

- references: `$VAR`, `${{ secrets.NAME }}`, `os.environ[...]`;
- names: `secretName`, `existingSecret`, `passwordProperty`, plural keys, and
  Kubernetes Secret names on `*Secret` keys (`tlsSecret: wildcard-tls`);
- placeholders: `your_secret`, `YOUR_API_KEY`, `changeme`,
  `user:password@localhost`, `sk-xxxx...`, and AWS's documented `...EXAMPLE` keys;
- git object names, `sha256:` or `SHA-256 is` digests, UUIDs, paths, and slugs;
- a PEM header mentioned in prose with no key data after it.

Heuristics can produce false positives and cannot guarantee detection of every
secret. Treat the store as sensitive. Collection warnings appear on Overview
rather than hiding failures, and a blocked file's warning names the line and the
rule (for example `line 245 looks like a credential assigned to DB_PASSWORD`),
never the value.

## Analysis

Local checks run after every scan, with two kinds of results:

- **Out of sync**: `AGENTS.md` and `CLAUDE.md` in one folder share less than 60%
  of their five-word shingles (unless one imports the other with Claude Code's
  `@path` syntax), or same-named skills whose `SKILL.md` copies share less than
  90%, so per-tool renderings of one skill don't count.
- **Missing paths**: backtick-quoted relative paths found neither next to the
  file, under the source root, nor under a top-level folder that commands run
  from (`playbooks/`), listed together per file. Hosts
  (`registry.example.com/team/chart`, `github.com/org/repo`) and slugs without a
  file name whose first folder doesn't exist (`bitnami/redis`, `org/repo`) are
  not local paths and are skipped.

**Review** lists these checks next to AI changes, one row per file: a file with a
diff waiting and a missing path is one row, "1 change · Missing paths", with a tab
for each. Filter by kind (AI changes or local checks), Git state (in Git or not),
and text, and switch between what still needs a decision and what's done. After
a decision the next row is selected, as in Mail; a row stays while it still has
something to decide. Shift-click, Command-click or Control-click, and Command-A
or Control-A select several rows (Control-click here selects instead of opening a
menu), for one decision on all of them: It's fine, Reject diffs, or
Accept and apply, where a file that changed since is skipped and listed. Each item shows whether its files are in Git;
Overview counts files not in Git.

- **It's fine** on a check hides it until the problem changes: the same pair of
  files still disagreeing stays hidden, but another missing path brings it back.
- **It's fine** on an AI change rejects it and remembers its points. Later
  requests for that file tell the model the user keeps them as they are; the
  preview shows those lines. **Reopen** puts the change back and forgets them.
- **Suggest a fix** sends a check's files with a task built from what's on disk:
  for a missing path, the files with that name that do exist in the repository,
  so the model can point the reference at the right one or remove it. Files a
  check spans go together in one request. The diff is selected when it arrives;
  if the model proposes nothing, it says why. While a fix waits for review, the
  check links to it, and **Suggest another fix** replaces it.

The sidebar lists only folders where collection found instruction files.
Repositories that share a folder name show their parent folder too.

These are review signals, not proof of errors. Commands are not executed or
validated. Historical similarity trends and repo-versus-global drift are not
implemented. Findings are recomputed when collected contents change or after a
scan.

Suggested edits come from your locally installed **Claude Code**, **Codex**, or
**OpenCode** CLI with its existing authentication, or a local **Ollama** server.
Settings picks the backend, the CLI path (or Ollama server URL), a model, an
effort, and a 1-600 second timeout (default 120). Each backend remembers its own
path, model, and effort. Every backend streams its answer (Claude as
`stream-json` with partial messages), so the timeout is how long it may stay
silent, not how long it may take: a model that is still thinking or writing keeps
going. Loading a model and reading a long prompt are the silent parts. A run stops
after 20 minutes in total.

Analysis is **Quick** by default: no extended thinking, so a local model answers
in seconds per file and catches the clearer problems (contradictions, repeated
rules, vague rules). **Thorough** uses the effort set in Settings and finds more,
but a thinking model can take many minutes per file: gemma4:12b took 15 to 24
seconds quick and 6 to 15 minutes thorough on the same 3.4 KB file. Settings
holds the default depth; the preview switches it for one request.

| Backend | Models list | Thorough effort | Quick |
| --- | --- | --- | --- |
| Claude Code | `opus`, `sonnet`, `haiku`, and full model IDs | `--effort` low to max | `low` |
| Codex | `model` entries in `~/.codex/config.toml` | `model_reasoning_effort`, minimal to xhigh | `low` |
| OpenCode | `opencode models` (on refresh) | model variant, `provider/model#high` | the configured variant |
| Ollama | installed models from the server | thinking off, on, low, medium, or high | thinking off |

Tell the model what to change. Settings holds your default instructions; the
preview lets you change them for one request, with presets (resolving
contradictions, consolidating repeated guidance, tightening). The model answers
with changes, not advice: up to 8 per file, the ones that matter most, each
replacing a passage it copies from the file, with one sentence on why. Small
changes keep the diff readable and the answer short. Review shows them as a Git-style diff with
line numbers, the changed words marked, and each reason above its change.
**Copy patch** copies a patch that `git apply` accepts from the repository root.

- Only diffs are listed, one waiting per file: a newer diff for a file replaces
  the older one, which moves to Done. A file that needs no changes is counted in
  the status bar, not added.
- Files already analyzed with the same instructions, and unchanged since, are
  left out of the next request; the preview says how many and has a switch to
  analyze them again.
- A quoted passage must match the file once, exactly or allowing for the usual
  misquotes: trailing spaces, blank lines between paragraphs, a list marker added
  to a sentence from the middle of a bullet, a renumbered or unmarked list item
  (the file keeps its own number and indentation), or line breaks written as `\n`. A change that still doesn't
  match is listed under **Not applied** next to the diff. If none of a reply's
  changes match, the request is sent once more, then reported as failed.
- Text-only recommendations from earlier versions are no longer shown; they
  remain in the store.
- Each proposal keeps the instructions you gave.
- Several files go **one file per request** by default: replies come faster, each
  file's result appears in Review as soon as it is ready, and the status bar
  shows which file is running and for how long. Choose **All files in one
  request** for tasks that compare files with each other; the contradiction and
  repeated-guidance presets switch to it.
- Every request requires a preview and explicit send, and the preview always
  shows the exact payload for the current instructions. Each request is limited
  to 128 KiB and output to 2 MiB. Instructions with credential-like text are
  refused.
- Private, disabled, and removed sources never enter new AI payloads. Tool
  configs, exec policies, and memories stay local; skills contribute `SKILL.md`
  only, not bundled scripts. The preview lists each excluded file and why.
- Content is rechecked for secrets before sending. Sensitive legacy inputs are
  excluded rather than proposing replacements containing redaction markers.
- Claude uses safe mode, disabled built-in tools, strict empty MCP configuration,
  no setting sources, no skills/commands, and no session persistence. Because no
  settings load, an empty model setting uses Claude Code's built-in default, not
  the `model` in your settings. OpenCode uses a private standalone server and an
  isolated config that carries only `provider`, `model`, `small_model`, and the
  provider allow and deny lists from your global OpenCode config, with deny-all
  permissions and no plugins, MCP servers, or instructions. It disables external
  skills, Claude compatibility discovery, and auto-update checks. Flags follow the
  [Claude CLI reference](https://code.claude.com/docs/en/cli-reference) and
  [OpenCode CLI reference](https://dev.opencode.ai/docs/cli/).
- Codex runs `codex exec` with a read-only sandbox, `--ignore-user-config`,
  `--ephemeral`, a JSON schema for the reply, and its browser, computer-use,
  plugin, hook, and memory features off. Codex has no switch for its shell, and the
  read-only sandbox blocks writes, not reads: the model can still read other files
  on this Mac and send them to OpenAI. Prefer another backend for untrusted
  repositories; the preview says this before you send.
- Ollama gets the request over its HTTP API, streamed, with the reply schema and a
  context window sized to the payload, since Ollama drops the start of an
  over-long prompt.
  Models that can't constrain output (Ollama answers 501, as `gemma4` does on
  0.40) are asked again without the schema. With the default
  `http://127.0.0.1:11434`, nothing leaves this Mac.
- CLIs run in an isolated temporary working directory, not a source repository.
  The CLI is trusted local software, not an OS security sandbox. Managed CLI
  policies may still apply. Do not configure an untrusted executable.
- OpenCode may retain its own sessions and logs. Providers may receive and retain
  the payload under your existing account settings. harnessmd does not report
  token costs or automatically fall back to another backend.
- Responses are parsed as structured JSON with exact file IDs and base hashes; a
  preface or code fence around the JSON is tolerated. Proposed contents never
  execute. Accept checks live contents again, snapshots all targets as
  `pre_apply`, and then writes. Proposals that edit global instructions are
  flagged before you accept. Batch failures attempt rollback without overwriting
  an intervening user edit. Pending proposals expire on acceptance after 30 days.
  Reject keeps the proposal for reference. A request cut off by quitting the app
  is marked `interrupted` at the next launch.

There is no application HTTP server, cloud sync, automatic proposal application,
commit, push, or background model request. OpenCode's own standalone CLI runtime
may use a private local server internally. Listing models runs only when you open
Settings or choose **Refresh list**; for OpenCode it runs `opencode models`.

## Updates and releases

Published builds read the signed Sparkle feed from
`https://github.com/mrcat71/harnessmd/releases/latest/download/appcast.xml`.
**Check for Updates...** is available in the menu bar and Settings. The floating
notice follows Avi's update flow: release notes, a download ring, animated titles,
preparation, and **Relaunch to Update**. Reduce Motion stops spinning and sliding;
Reduce Transparency uses an opaque surface. Background downloads are opt-in in
Settings. A prepared update can wait until quit. Collection data stays in
Application Support, outside the app bundle.

Development builds without a signing public key explicitly disable updates.
The updater never bypasses signature checks. No GitHub credentials are needed
in installed copies; the repository and release assets must remain public.
Before the first published release, the feed URL will return 404.

### CI and dependency updates

`.github/workflows/ci.yml` builds, runs all tests serially, packages the app,
and runs its fixture self-test on pushes to `main` and `renovate/**`, and PRs
targeting `main`. Run these checks locally with `make ci`. CI also runs
`bash scripts/test-release.sh` with disposable keys: it rejects a mismatched
key, verifies the signed feed and checksums, extracts the ZIP, and mounts the
DMG read-only to verify its signature and Applications link. Its artifacts and
keys stay in a fresh temporary directory, never in the distributable `dist/`.

CI and release jobs use GitHub-hosted `macos-26` runners directly, matching
Avi's setup. No runner variable or self-hosted runner registration is needed.
Fork PRs run the same CI checks on GitHub-hosted runners. Signing secrets are
never provided to the CI workflow.

`.github/renovate.json` covers Swift packages and pinned GitHub Actions. It
requests owner review, waits seven days for ordinary releases with timestamps,
and leaves automerge off. Renovate branch CI runs before PR creation because
`prCreation` is `status-success`. Install/enable the Renovate GitHub App for
this repository separately; the config does not grant it access.

### Signing setup and publication

Generate a dedicated Sparkle key in your login Keychain (user-run setup):

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account harnessmd
```

Set the printed public key as the repository variable `SPARKLE_PUBLIC_ED_KEY`.
Export the private key with Sparkle's `generate_keys --account harnessmd -x`
to a protected file outside this repository and add its contents as the
repository secret `SPARKLE_ED_PRIVATE_KEY`. Never commit the private key.
Keep the same key pair across releases; changing it locks out installed copies.
The public variable is baked into each packaged app as `SUPublicEDKey`.

After generating the Keychain key, these user-run commands configure GitHub
Actions signing. They change repository variables/secrets; the private key is
passed through a protected temporary file and is not printed.

```sh
public_key=$(.build/artifacts/sparkle/Sparkle/bin/generate_keys --account harnessmd -p) && test -n "$public_key" && gh variable set SPARKLE_PUBLIC_ED_KEY --repo mrcat71/harnessmd --body "$public_key"
umask 077; keydir=$(mktemp -d -t harnessmd-signing) && .build/artifacts/sparkle/Sparkle/bin/generate_keys --account harnessmd -x "$keydir/private" && gh secret set SPARKLE_ED_PRIVATE_KEY --repo mrcat71/harnessmd < "$keydir/private" && rm "$keydir/private" && rmdir "$keydir"
```

Verify configuration without reading secret values with
`gh variable list --repo mrcat71/harnessmd` and
`gh secret list --repo mrcat71/harnessmd`.

For a local distributable build, provide the public variable in your environment
and run `make package`. It creates a host-native arm64 or x86_64 ZIP and DMG in
`dist/`, preserves framework symlinks, verifies the bundle signature, validates
the update configuration, and runs the packaged smoke test. `make appcast`
requires `SPARKLE_ED_PRIVATE_KEY` in the environment; it signs and verifies the
archive and feed, embeds the version's changelog notes, and writes `SHA256SUMS`
and `RELEASE_NOTES.md` for GitHub's release description.
Packaging does not publish. Debug-only notice previews use isolated fixtures:
`make build CONFIGURATION=debug`, then
`open -n dist/harnessmd.app --args --demo --preview-update`.

The app is ad-hoc signed, not Developer ID signed or notarized. Downloads on
another Mac may need System Settings > Privacy & Security > Open Anyway for
first launch. Sparkle's Ed25519 update signatures do not replace notarization.

For a release, update **both** bundle version strings in `Support/Info.plist`
to the same stable `X.Y.Z`, and add `## [X.Y.Z]` notes to `CHANGELOG.md`.
Commit and push through your Git client, then wait for CI on that exact commit.
Only then create and push the matching `vX.Y.Z` tag. This publishes remotely:

```sh
git tag -a v0.1.0 -m "Release 0.1.0"
git push origin v0.1.0
```

`.github/workflows/release.yml` rejects mismatched versions, reruns tests,
builds the ZIP/DMG, verifies signing, and publishes a complete draft as Latest
only after uploading all four assets: ZIP, DMG, `appcast.xml`, and `SHA256SUMS`.
The release description comes from the same changelog section as the appcast,
including the installation and ad-hoc signing limitations.
`workflow_dispatch` performs the same build/sign checks but only stores Actions
artifacts, never publishes. It still needs the signing variable and secret.
Do not overwrite an existing release; fix a failed published version with a new
version. Verify with `gh run list --workflow release.yml --limit 1` and
`gh release view v0.1.0 --json isDraft,isPrerelease,assets,url`.

## Development checks

```sh
make test
make self-test
make demo CONFIGURATION=debug
```

`--self-test` scans a temporary repository, captures changes, and restores a
version without opening UI or reading personal repositories. `--demo` opens the
dashboard with generated fixture repositories and a separate temporary store;
it never enables global collection. Demo stores remain in the macOS temp
directory for inspection and are separate from real data. Quit the demo before
launching the normal app.

The app icon's source is `Support/AppIcon.svg`, drawn on the macOS icon grid.
After editing it, run `make icon`: AppKit renders the SVG and `iconutil` writes
the committed `Support/AppIcon.icns`, so builds need no renderer. AppKit skips
SVG filters, so the artwork draws its shadows as plain shapes. The menu bar mark
is drawn in code (`BrandMark.swift`) as a template image.

`HarnessKit` owns discovery, privacy checks, SQLite/blob persistence, analysis,
watchers, proposal parsing, CLI execution, and restore. `HarnessApp` owns the
SwiftUI menu, dashboard, settings, and login registration. See [DESIGN.md](DESIGN.md)
for the design decisions and deferred items; this README describes the
implemented behavior and the intentionally narrower v0.1 safety boundaries.
