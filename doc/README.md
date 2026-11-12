# Documentation

Start with the [package README](../README.md) (install, launch, one example per feature, privacy model, limits, troubleshooting).
The pages below go deeper.

## For app developers

| Page | What it is |
|---|---|
| [api-surface.md](api-surface.md) | Every public method of both native SDKs, what this package exposes or skips and why, what each call does before `launch`, value rules, errors, threading |
| [exceptions.md](exceptions.md) | Dart error reporting: the backend contract, what each SDK does, the installed handlers, obfuscation and uploading symbols |
| [network.md](network.md) | `dart:io` network capture: data flow, the privacy model and filter, options, limits, what was measured on devices |
| [logs.md](logs.md) | `print` / `debugPrint` / `forwardLog` capture: source attribution, the Android logcat echo (and the native filter that stops it), privacy, limits |
| [attachments.md](attachments.md) | Report attachments, annotated screenshots and `createReport`: rules, limits, differences on iOS, evidence |
| [view-hierarchy.md](view-hierarchy.md) | The Flutter widget tree stored in reports: payload, privacy rules, staleness, SDK facts |
| [migration-from-9x.md](migration-from-9x.md) | The 9.x to 10.x changes: setup, every 9.x API item and what replaced it |
| [`packages/bugsee_flutter_feedback`](../packages/bugsee_flutter_feedback/README.md) | The separate in-app feedback chat package, and its [design notes](../packages/bugsee_flutter_feedback/doc/feedback.md) |

## For maintainers and reviewers

| Page | What it is |
|---|---|
| [architecture.md](architecture.md) | The layers (Dart facade, Pigeon bridge, native wrapper, SDK), registration before launch, threading and fail-closed rules |
| [design-rules.md](design-rules.md) | The detailed invariants per area (secure rectangles, report handlers, view hierarchy, options, facade, network, logs, exceptions, attachments, feedback, harness) with the guards that hold them |
| [workbook-conformance.md](workbook-conformance.md) | Each step, trap and minimum-viable-wrapper item of the wrapper workbook mapped to its implementation, guard and device scenario, with the gaps |
| [verification.md](verification.md) | The device verification harness, its default guards, the environment, results per scenario, findings and what was not covered |
| [direct-interop-spike.md](direct-interop-spike.md) | Whether to replace the Pigeon channel bridge with Direct Interop (Flutter 3.50): measurements on the phone and iPhone, findings, decision |
| [../PLAN.md](../PLAN.md) | Project status, decisions, open questions, known gaps and the release checklist |
| [../CHANGELOG.md](../CHANGELOG.md) | Release notes |
| [../.github/CI.md](../.github/CI.md) | The CI jobs and check names, the option registry, bridge codegen, the pub workspace, branch protection |
| [../.claude/CLAUDE.md](../.claude/CLAUDE.md) | The reviewer and agent guide: rules the code must keep |
| [../example/README.md](../example/README.md) | The example app and its integration tests |

Source references in these pages name the SDK files and lines they were read from. The current pins are Android `v7.4.2` and iOS 7.0.1 (SDK source `origin/release@5c6b9d9db`, the commit the 7.0.1 banner `build:5c6b9d9db-8` names; the iOS repository has no 7.x tag), but each page keeps the revision it was actually read at: several pages (`api-surface.md`, `attachments.md`, `network.md`, `logs.md`, `view-hierarchy.md`) still cite iOS 7.0.0 (`origin/release@2b88480fa`) or the 7.0.0-beta7 commit `0581aa02c`, and are marked as such where they have not been re-read at 7.0.1. The
SDKs are private repositories; the published artefacts are Maven Central `com.bugsee:bugsee-android` and the SwiftPM package
`github.com/bugsee/spm`.
