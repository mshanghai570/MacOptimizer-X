<p align="center">
  <img src="generated_icon.png" width="128" height="128" alt="MacOptimizer X icon">
</p>

<h1 align="center">MacOptimizer X</h1>

<p align="center">
  A reliability-focused macOS cleaner, uninstaller, storage explorer, and AI-assisted maintenance utility.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2012%2B-blue" alt="macOS 12 or newer">
  <img src="https://img.shields.io/badge/architecture-Intel%20x86__64-lightgrey" alt="Intel x86-64">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-orange" alt="Swift 5.9 or newer">
  <a href="https://github.com/mshanghai570/MacOptimizer-X/actions/workflows/swift.yml"><img src="https://github.com/mshanghai570/MacOptimizer-X/actions/workflows/swift.yml/badge.svg" alt="Intel macOS build"></a>
</p>

## About MacOptimizer X

MacOptimizer X is an Intel-focused fork of [MacOptimizer](https://github.com/ddlmanus/MacOptimizer). It keeps the original SwiftUI experience while concentrating on the parts a maintenance utility must get right: finding the expected files, deleting exactly what the user selected, reporting partial failures honestly, and making AI configuration understandable.

This fork is currently optimized and continuously built for Intel Macs (`x86_64`). It is an independent community project and is not affiliated with Apple.

## What was fixed

### Cleanup reliability

- **Smart Scan:** normalized and deduplicated discovered paths, improved selected-item handling, and routed deletion through a result-aware removal path.
- **System Junk:** made scan results and deletion outcomes consistent so failed items remain visible instead of being reported as removed.
- **Deep Clean:** strengthened orphan detection and corrected deletion handling for files that previously remained on disk.
- **Safety checks:** explicit user selections are preserved while protected macOS locations continue to be guarded.
- **Deletion reporting:** successful, failed, and partially completed operations are now tracked separately.

### Space Lens

- Selected files are passed through the shared removal service.
- Items disappear from the interface only after the filesystem confirms they were removed.
- Failed deletions remain available for review or retry.

### App Uninstaller

- The app bundle and detected leftovers are handled as one result-aware uninstall operation.
- The application list is refreshed only after the app bundle is actually gone.
- Partial success is reported clearly when the app is removed but some leftovers could not be deleted.
- Privileged fallback behavior is used when ordinary removal is insufficient.

### Mac Optimization Agent

- Provider network and HTTP errors now include actionable details.
- Connection testing verifies the returned JSON instead of treating any response as success.
- Request timeouts and empty-response handling were improved.
- Cleanup preparation no longer reuses unrelated diagnostic results.
- Official OpenAI, Gemini, and Anthropic request formats are supported.
- OpenAI-compatible gateways can use a custom Base URL, API key, and model name.
- Compatible model lists load automatically from `GET /models` after a valid endpoint and key are entered.
- Manual model entry remains available for gateways that do not publish a model list.

### Intel build pipeline

- GitHub Actions runs on a real `macos-15-intel` hosted runner.
- Swift unit and integration tests run before packaging.
- AI-provider request and response parsing is verified with mocked endpoints.
- The release executable is checked with `lipo` to ensure it is truly `x86_64`.
- The app is ad-hoc signed, packaged as a DMG, verified, checksummed, and uploaded as a GitHub Actions artifact.

## Main features

| Area | Capabilities |
| --- | --- |
| Smart Scan | Combined junk, safety, and optimization scan |
| System Junk | Application caches, browser data, logs, and temporary files |
| Deep Clean | Orphaned application support files, preferences, containers, caches, and logs |
| Space Lens | Visual storage exploration and selected-file cleanup |
| Uninstaller | Application removal with associated leftover discovery |
| Large Files | Locate and review files consuming significant disk space |
| Maintenance | Common macOS maintenance and optimization actions |
| Privacy and Malware | Privacy review and basic threat-scanning tools |
| Mac Optimization Agent | AI-assisted diagnostics and maintenance guidance |
| Localization | English, Simplified Chinese, Traditional Chinese, Japanese, Korean, and Russian |

## Download the Intel build

MacOptimizer X is currently distributed through GitHub Actions:

1. Open the [Intel macOS Build workflow](https://github.com/mshanghai570/MacOptimizer-X/actions/workflows/swift.yml).
2. Select the newest successful run with a green check.
3. Scroll to **Artifacts**.
4. Download the `MacOptimizer-Intel-...` artifact.
5. Extract the ZIP, verify the included SHA-256 checksum if desired, and open `MacOptimizer-Intel.dmg`.

The CI build is ad-hoc signed but not Apple-notarized. On first launch, macOS may require you to right-click the app and choose **Open**, or approve it under **System Settings → Privacy & Security**.

## Configure the Mac Optimization Agent

Open the agent settings and choose a protocol:

| Protocol | Base URL example | Notes |
| --- | --- | --- |
| OpenAI-compatible | `https://api.openai.com/v1` | Also supports compatible hosted or local gateways using Chat Completions |
| Gemini | `https://generativelanguage.googleapis.com/v1beta` | Uses Gemini's native `generateContent` format |
| Claude | `https://api.anthropic.com/v1` | Uses Anthropic's native Messages format |

For an OpenAI-compatible provider, enter the Base URL and API key. MacOptimizer X will request the provider's model catalog and display the available models. If that provider does not implement `GET /models`, type the model identifier manually and use **Save & Test Connection**.

> **Credential notice:** AI settings are currently stored in a regular local JSON configuration file, not the macOS Keychain. Use a restricted API key and do not share the configuration file.

## Build from source

Requirements:

- An Intel Mac running macOS 12 or newer
- Xcode command-line tools with Swift 5.9 or newer

```bash
git clone https://github.com/mshanghai570/MacOptimizer-X.git
cd MacOptimizer-X
swift test --arch x86_64
./scripts/build_intel_release.sh
```

The Intel DMG and checksum are written to `build_intel/`.

## Safety

MacOptimizer X performs destructive file operations. Review every selection, keep current backups, and prefer recoverable deletion where available. Avoid removing files you do not recognize, especially from system or shared-library locations.

The automated test suite validates code paths and packaging, but it cannot reproduce every permission state, filesystem layout, application installation, or third-party AI gateway. Please report reproducible problems with the macOS version, affected feature, selected paths, and any visible error message.

## Project status

The current focus is Intel Mac correctness and reliability. Apple Silicon may still compile through upstream scripts, but it is not the primary tested target of this fork.

Contributions and detailed bug reports are welcome through pull requests. This repository is a fork; credit for the original application and interface belongs to the [upstream MacOptimizer contributors](https://github.com/ddlmanus/MacOptimizer/graphs/contributors).
