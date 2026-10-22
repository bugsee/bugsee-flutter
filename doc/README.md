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
| [../PLAN.md](../PLAN.md) | Project status, decisions, open questions, known gaps and the release checklist |
| [../CHANGELOG.md](../CHANGELOG.md) | Release notes |
| [../.github/CI.md](../.github/CI.md) | The CI jobs and check names, the option registry, bridge codegen, the pub workspace, branch protection |
| [../.claude/CLAUDE.md](../.claude/CLAUDE.md) | The reviewer and agent guide: rules the code must keep |
| [../example/README.md](../example/README.md) | The example app and its integration tests |

Source references in these pages name the SDK files and lines they were read from (Android tag `v7.4.2`, iOS `7.0.0-beta7`). The
SDKs are private repositories; the published artefacts are Maven Central `com.bugsee:bugsee-android` and the SwiftPM package
`github.com/bugsee/spm`.
