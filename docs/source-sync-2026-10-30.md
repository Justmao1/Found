# Source consolidation — October 30, 2026

## Scope and plan

1. Keep the maintained SwiftUI/Xcode project and nested Python backend as the canonical repository. Compare the deployed Raspberry Pi source with this baseline before copying files.
2. Preserve identical runtime code and tests. Keep newer Mac documentation in preference to the older deployed README and verification notes.
3. Recover the server-only two-pin GPIO diagnostic without changing it. Archive the obsolete Mac GPIO5 feedback experiment and earlier circuit-design generator, with their original limitations documented.
4. Exclude live configuration, credentials, TLS material, databases, photographs, backups, build products, AppleDouble metadata and agent state. Do not replace or restart the deployed service.
5. Run existing backend, Swift, browser and client/server checks; compile diagnostic/archive Python without executing hardware paths; then commit and push the reviewed source package.

## Source map

| Location | Role in the consolidated repository |
| --- | --- |
| `Lost&Found/`, `Lost&Found.xcodeproj/` | Canonical native application and Xcode project |
| `Tests/`, `NativeTests/`, `Tools/` | Swift contracts, native tests and isolated client/server checks |
| `lost-found-box/` | Canonical Pi service, browser dashboard, GPIO code, tests and deployment examples |
| `lost-found-box/tools/control_lock_gpio.py` | Unmodified server-only diagnostic for BCM17/26; see restrictions below |
| `archive/mac-feedback-experiment/` | Original obsolete single-contact BCM5 experiment; not current wiring |
| `archive/output/circuit/four-lock-controller/` | October 20 design proposal and its PDF generator; not deployed circuitry |
| `docs/technical/` | Current architecture, deployment and verification documentation |

The workspace-level `lost-found-box/` is an older development copy, not a second supported backend. Its differing service files and old README were not substituted for the maintained code. Originals remain in the workspace.

## Pi comparison

A read-only allowlist inspection found 40 source/document/example files on the Pi, excluding configuration, certificates, data, backups, caches and AppleDouble files. Of these, 37 matched the maintained backend byte for byte, two were older documentation files, and one was the additional diagnostic script. After importing that script, all 38 non-divergent files are represented unchanged. Per-file hashes and dispositions are in `source-sync-2026-10-30.json`.

The deployed two-feedback configuration and the report's assumed October 22 four-feedback completion are distinct. This consolidation does not change device configuration or certify four physical channels.

## Diagnostic and archive restrictions

`tools/control_lock_gpio.py` is retained for source completeness. It targets only BCM17/26 on a Pi 4B, uses a finite pulse and LOW cleanup, and checks line ownership. It does **not** implement the application's operation journal, request identity or per-lock cooldown. Use the maintained `tools/test_lock_once.py` and service workflow for current operation. The recovered script was syntax-checked and its help entry exercised on Mac; no physical pulse was issued.

The archived BCM5 reader conflicts with current compartment 04 output. Do not run it on the current cabinet. The archived circuit proposal contains a different pin map, optional monostables and components that are not evidence of the deployed build. Its generator requires ReportLab and a macOS Arial Unicode font; running it writes under `archive/output/pdf/`. It is retained as historical design code, not the current wiring guide.

No masking fallback or alternate runtime implementation was added. Existing recovery, compatibility and hardware safety paths are preserved without refactoring.

## Reproduction

Use the commands in the root README. Tests use temporary local databases and mocked/simulated GPIO. No deployment restart, production database modification, cloud recognition or real unlock is part of this consolidation. Fresh check results are recorded below after verification.

## Fresh verification results

Completed on October 30, 2026:

- Python backend: 196 tests passed.
- Swift Core: 44 tests passed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The default CommandLineTools selection could not locate XCTest; selecting the installed Xcode toolchain resolved that environment issue.
- Swift/Python API integration: 12 checks passed.
- Compartment workflow integration: 13 checks passed, with exactly 10 simulated opening commands.
- Browser camera lifecycle: 2 tests passed; `static/app.js` and `static/admin.js` passed Node syntax checks.
- Xcode generic iOS Simulator build: succeeded with signing disabled. Native XCTest was not repeated for this source-only packaging pass.
- Recovered and archived Python scripts: compiled without execution; recovered GPIO diagnostic `--help` completed without importing hardware drivers. No physical GPIO action was performed.
- Current tracked/new text sources: literal credential-pattern scan found no matches. This is a bounded check, not a security certification.

## Publication checks

Before changing repository visibility, all 219 reachable historical Git blobs were checked for credential signatures and exact fingerprints of the station's configured password/API credentials. No matches were found. PPTX XML and relationship contents were included in the scan; the presentations contain no embedded attachments. Live configuration, certificates, databases, recordings and backups were not tracked or imported. A historical Xcode scheme-order preference was inspected: it contains only scheme ordering, no credential; it is absent from the current tree. This check preserves history and does not rewrite past commits.

The user authorized public visibility on October 30. The report links the repository and pins the consolidated source revision, while retaining the original functional baseline for the historical test narrative.
