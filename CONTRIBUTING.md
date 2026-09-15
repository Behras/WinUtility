# Contributing

## Local development

Use Windows PowerShell 5.1 or PowerShell 7. Linux with PowerShell 7 supports menu,
catalog, persistence, and fixture tests; live Windows behavior needs a Windows VM.
No external PowerShell modules are needed for the test suite.

```powershell
./tests/Run-Tests.ps1
```

For interactive menu work, run `./WinUtility.ps1 -Preview`. Also check
`-Plain -NoKeyNavigation` so limited terminals retain a usable fallback.

## Project layout

| Path | Responsibility |
| --- | --- |
| `WinUtility.ps1` | Local entry point. |
| `bootstrap.ps1` | GitHub download and launch. |
| `src/WinUtility.Core.psm1` | Catalogs, selections, plans, and portable setup files. |
| `src/WinUtility.Input.psm1` | Console key handling and selection display. |
| `src/WinUtility.Terminal.psm1` | Menus, confirmations, and result presentation. |
| `src/WinUtility.Windows.psm1` | WinGet, Explorer changes, readiness, and undo. |
| `src/WinUtility.AppWorker.ps1` | Normal-user app install worker for elevated menu sessions. |
| `src/WinUtility.Repair.psm1` | Repair commands, native execution, reports, and elevation. |
| `data/` | App, settings, and preset definitions. |
| `tests/` | Dependency-free behavioral tests and fixtures. |
| `docs/` | Usage, repair, architecture, and feature research. |

## Changes and validation

- Preserve Windows PowerShell 5.1 compatibility. Keep script source ASCII, or
  construct Unicode characters by code point to avoid legacy encoding ambiguity.
- Keep executable actions in code. Catalogs and imported JSON must never supply
  commands, registry paths, or arbitrary installer arguments.
- Keep settings without an implementation labeled and skipped. Never report a
  skipped operation as applied.
- For app entries, verify the exact package ID in Microsoft's `winget-pkgs`
  repository and update [the catalog](docs/APP-CATALOG.md).
- Add behavior tests for new execution paths and failure cases. Automated tests
  must not install apps or run repair tools against the host.
- Check `git diff --check` before submitting a change. Include what changed and
  which validation was performed in the pull request.

## Windows acceptance checks

Use a disposable Windows 11 VM with a snapshot for real actions. Test both Windows
PowerShell 5.1 and PowerShell 7, including a project path containing spaces.

1. Navigate with arrows, Enter, Space and Esc; check typed batches, search, paging,
   cancellation, a resized window, and `-NoKeyNavigation`.
2. Confirm that app selection does not install anything and confirmation starts
   on Cancel. Install a small test app, retry a failure, then verify an existing
   app is skipped. Repeat from an administrator window with Spotify and an app
   that requests UAC. Verify the normal-user install, saved exit codes/output,
   and removal of temporary `WinUtility-App-*` tasks after completion or failure.
3. Apply and undo each Explorer setting. Change a value manually before undoing
   to check conflict handling.
4. Export a setup, restart, import it, and check that its selections are restored.
5. Follow the [repair acceptance checks](docs/REPAIR.md#windows-acceptance-checks).
6. Run the GitHub launcher, including UAC cancellation and an elevated repair
   window. Verify temporary files survive until the child exits.

When reporting a bug, include the menu path, Windows build, PowerShell version,
launch method, and exact error. Review logs for usernames or local paths before
sharing them. A passing fixture suite does not establish native Windows behavior.
