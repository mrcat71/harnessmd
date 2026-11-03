# Changelog

## [0.1.1]

### Added

- An app icon and a matching menu bar mark: instruction pages held by a
  harness strap. The dashboard sidebar shows the icon beside the name.

### Installation and limitations

- Requires macOS 14 or later. Choose the download matching your Mac's
  architecture: `arm64` for Apple silicon or `x86_64` for Intel, when available.
- Open the DMG and drag `harnessmd.app` to Applications. The app starts in the
  menu bar; choose **Open Dashboard** to select collection folders.
- This build is ad-hoc signed, not Developer ID signed or notarized. The first
  downloaded launch may require **System Settings > Privacy & Security > Open
  Anyway**. Sparkle update signatures do not replace Apple notarization.
- The local store is unencrypted. Credential filtering is heuristic, not a
  guarantee; treat collected snapshots as sensitive and back up the store.

## [0.1.0]

First public release of the local-first macOS menu bar app for coding-agent
instructions.

### Added

- Collect instructions, skills, and rules from local repositories and optional
  global Claude Code, Codex, shared-skill, and OpenCode locations.
- Keep content-addressed snapshot history, compare versions, and restore files
  with safety snapshots without changing Git history.
- Track files outside Git, detect local instruction problems, and review
  AI-assisted changes before explicitly applying them.
- Preview outgoing AI requests and use Claude Code, Codex, OpenCode, or Ollama
  backends with private-source exclusions and credential filtering.
- Check signed GitHub Releases updates through Sparkle, with animated in-app
  progress, release notes, and a relaunch-to-update notice.
- Build and test in CI, package tagged releases as ZIP and DMG downloads, and
  maintain Swift and GitHub Actions dependencies through Renovate.

### Installation and limitations

- Requires macOS 14 or later. Choose the download matching your Mac's
  architecture: `arm64` for Apple silicon or `x86_64` for Intel, when available.
- Open the DMG and drag `harnessmd.app` to Applications. The app starts in the
  menu bar; choose **Open Dashboard** to select collection folders.
- This build is ad-hoc signed, not Developer ID signed or notarized. The first
  downloaded launch may require **System Settings > Privacy & Security > Open
  Anyway**. Sparkle update signatures do not replace Apple notarization.
- The local store is unencrypted. Credential filtering is heuristic, not a
  guarantee; treat collected snapshots as sensitive and back up the store.
