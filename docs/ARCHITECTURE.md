# Architecture

WinUtility is a Windows 11 setup utility written for Windows PowerShell 5.1. The
terminal and core logic also run in PowerShell 7, including on non-Windows hosts
for development. Real execution covers WinGet installs, two reversible Explorer
settings, and a separate Windows repair workflow. Linux and `-Preview` keep
simulation and repair command previews available without live controls.

## Responsibilities

```text
bootstrap.ps1 -> download one commit -> WinUtility.ps1
                                          |
                                  Terminal UI module
                                          |
data/*.json -> Core module -> selection -> ordered plan -> simulation results
                                  |             |
                           saved setup JSON     +-> Windows adapter -> history
```

| Component | Responsibility |
| --- | --- |
| `WinUtility.ps1` | Import modules, load catalogs, create the session, start the menu. |
| `bootstrap.ps1` | Resolve GitHub `main` to a commit, download/extract that commit, launch in a child PowerShell process, clean temporary files. |
| `src/WinUtility.Terminal.psm1` | Numbered menus, item toggles, previews, confirmations, and displaying results. |
| `src/WinUtility.Core.psm1` | Catalog validation, session state, selection changes, planning, simulation, JSON persistence. |
| `src/WinUtility.Windows.psm1` | Readiness probes, current-state review, WinGet calls, Explorer handlers, durable history and undo. |
| `src/WinUtility.Repair.psm1` | Code-owned repair plans, administrator checks, native command execution, repair reports, and dedicated elevation. |
| `data/` | Setting, app, and preset catalogs. |
| `tests/` | Dependency-free behavioral tests and isolated launcher fixtures. |

The entry point starts with an empty selection. Readiness probes are read-only;
selection and simulation do not execute Windows actions. Real apply has a separate
UI confirmation, and the execution adapter independently checks Windows/user
identity before creating history or making changes. The bootstrap's child-process
execution policy does not change persistent PowerShell execution policies.

## Selection and planning

`New-WuSession` holds a validated catalog, a session-local map of additional WinGet
apps, a map of selected items keyed by stable ID, a fingerprint of the last
saved/imported selection, and the last apply result
for retrying failed apps. There is one desired
value per catalog entry in this prototype. Selecting an item queues that value;
deselecting it removes the planned action, rather than queueing its inverse.

- `Set-WuPreset` replaces the selection with all referenced settings and apps.
  The UI always previews the complete preset and confirms replacement first.
- `Set-WuSelection` adds an item once; selecting an already selected item preserves
  its origin. Removing and re-adding it makes it a manual choice.
- `Get-WuPlan` returns settings first, then apps, each in catalog order. Plan items
  contain `Id`, `Kind`, `Name`, `Category`, `Value`, `Source`, `Effect`, `PackageId`,
  `RequiresAdmin`, and `RequiresRestart`.
- `Get-WuAppItems` returns bundled apps followed by session additions sorted by
  package ID. `Add-WuWinGetSelection` validates a whole batch and deduplicates by
  package ID, including matches already in the bundled catalog. Added items use
  an internal ID derived from a SHA-256 hash of the normalized package ID; exported
  files store the readable package ID. The shared catalog is never modified.
- `Find-WuCatalogApp` performs literal, case-insensitive substring search across
  names, descriptions, categories and package IDs. `ConvertFrom-WuBatchInput`
  validates numeric lists/ranges against the visible page before returning any
  choices; repeated numbers are returned once.
- `Invoke-WuSimulation -Plan <array>` returns `Id`, `Name`, `Status`, `Message`, and
  `Changed` per item. Status is always `Simulated`; Changed is always false. Empty
  plans return no results. Simulation does not check current machine state.

App administrator/restart metadata are null because installers decide those
requirements. `Get-WuActionCapability` identifies implemented handlers from code;
adding a setting to JSON does not give it executable behavior. Existing version 1
setups remain supported; version 2 adds selections from live WinGet search.

The UI uses `Read-Host` and `Write-Host` through small display helpers. A cyan/green
palette, framed headings, selection indicators, and category sections share the
same renderer. Text wraps to the available width; the home menu omits descriptions
in windows shorter than 38 rows. UTF-8 consoles get rounded borders, created from
character codes to keep the PowerShell source compatible with 5.1 encodings.

`WinUtility.ps1 -Plain` selects monochrome ASCII output. `NO_COLOR`, `TERM=dumb`,
and output redirection enable the same fallback. The renderer does not change
terminal encoding or colors globally, require ANSI escape support, or install a
UI dependency. Output stays in scrollback. Numbered input loops retain state.

## Catalogs and saved setups

Each catalog is a JSON object with `schemaVersion: 1` and an `items` array.
Settings include a stable ID, name, category, description, desired value, effect,
and boolean administrator/restart metadata. Apps include a WinGet package ID.
Presets reference settings/apps by `itemIds`; all shipped presets are examples.
Catalog loading checks required fields, types, duplicate IDs, and references.

Exported setups use this portable shape:

```json
{
  "schemaVersion": 1,
  "selections": [
    { "id": "explorer.extensions", "value": "visible" },
    { "id": "app.7zip", "value": "installed" }
  ]
}
```

Version 1 imports accept catalog IDs with their supported desired values. Unknown
fields, unsupported versions, unknown catalog IDs, duplicate selections, and
invalid values reject the entire import. JSON is parsed as data; no command text
is evaluated. A valid import
returns a separate preview session. The UI confirms before replacing the active
session with `Set-WuImportedSetup`.

When selected apps extend beyond the bundled catalog, exports use schema version
2. Its selections contain either the same `{id, value}` object for a bundled
entry or `{packageId, value: "installed"}` for an added package. The source is
fixed to `winget` in code; custom commands, sources and installer arguments cannot
be supplied. Imports validate everything into an isolated preview session, perform
no network requests, and deduplicate package IDs against curated entries. They
reject a package repeated through both an ID and a packageId entry. Additional app
metadata never modifies the active session until import confirmation.

Catalog-only selections continue to export version 1. The selection fingerprint
uses the same ID/package-ID representation and excludes unselected discoveries,
origin labels and the last run. Loading a version 2 package that has since become
a bundled app reuses the bundled entry.

Exports write UTF-8 JSON to a temporary sibling file, then move/replace it. Existing
files require explicit overwrite. A failed save leaves the session unsaved and
preserves the existing file. Fingerprints compare sorted IDs and values, excluding
origin labels. Reverting selections to their saved values clears the dirty flag.
Importing a setup establishes a saved baseline; later modifications are unsaved.

The default export is `Documents\WinUtility\setup.json` (the user-profile directory
is the fallback if Documents is unavailable). Users can choose any local path and
copy the exported file to another laptop. No automatic saves or cloud sync.

## Windows adapter

### App discovery

The App installs menu lists categories, local search, all local apps and live
WinGet search. Local app lists show eight items per page and retain selection
while paging or changing filters. Select/clear applies to the visible page;
invalid batch input changes nothing. Package details stay available in compact
terminal views. Queue review uses the existing combined settings/apps plan.

`Find-WuWinGetPackage` runs `winget search --query <query> --count 40 --source winget
--disable-interactivity`. `Get-WuWinGetPackageDetails` uses `show --id <id> --exact`
with that same source. Both return native output, exit code and a status that
distinguishes results, no match, required source agreements and failure.
`--accept-source-agreements` is passed only after the corresponding UI consent.
Preview mode never performs live searches or accepts source terms.

Search tables are displayed as text instead of parsed: their columns can be
localized, truncated or affected by Unicode widths. The user supplies up to 20
complete package IDs per batch. Every ID is syntax-checked, resolved exactly and
its native metadata displayed before the UI offers to add the batch. Failed or
cancelled verification never partly adds a batch. No apps install until the
separate apply confirmation. The package validator supports plus signs such as
`Notepad++.Notepad++`, while refusing argument/path/control-character syntax.

### Readiness and execution

`Get-WuReadiness` returns OS edition/build, architecture, PowerShell/WinGet version,
pending-reboot and battery information, identity, and probe warnings. CIM
`Win32_OperatingSystem.ProductType == 1` and build >= 22000 establish a Windows 11
workstation; failed OS verification never enables live actions. WinGet is probed
with `--version`, without automatically installing or repairing it. Missing
registry/power information remains unknown rather than being reported healthy.

`Get-WuExecutionReview -Plan -Environment` reads implemented setting state and
queries each exact WinGet package ID. It returns `Id`, `Name`, `Capability`,
`Current`, `Status`, and `Message`; preview-only items have no executable handler.
Review queries do not auto-accept source terms. Fresh-source agreement failures
can therefore show unknown status; apply rechecks after explicit confirmation.

`Invoke-WuApply -Plan [-AcceptAppAgreements]` rechecks readiness and identity,
rejects duplicate actions and unconfirmed app agreements, and executes serially.
Only the two fixed Explorer value names are writable. App IDs and package IDs
must match constrained identifier formats; native argument arrays are used without
evaluating shell/PowerShell command text. The source is explicitly `winget`.

App queries use exit codes rather than parsing localized tables: 0 means installed,
`APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND` means missing, and everything else
remains unknown. Apply fails an unknown query instead of assuming absence. Installs
use `--no-upgrade`, `--silent`, `--disable-interactivity`, and the two agreement
flags; no `--force`, security-check bypass, or `--allow-reboot` is added. The native
adapter captures stdout/stderr and the signed exit code while restoring the
caller's automatic exit-code variable. Interactive installer/UAC behavior can
still depend on the selected installer.

The returned run has `Path` and `Actions`. Each action records identity, kind,
package ID, status/message, exit code/output, nullable `Changed`, restart status,
Explorer `Before`/`After` snapshots, and `UndoStatus`. Failure/cancellation can mean
partial changes, so `Changed` is null when the outcome is uncertain. One ordinary
action failure does not stop subsequent actions; a persistence failure does.
The terminal's retry action passes only failed/cancelled selected app IDs from
the most recent run back through the same review/confirmation flow.

## History and undo

Runs are stored as versioned JSON in `%LOCALAPPDATA%\WinUtility\History`, outside
the temporary downloaded project. Each file contains a run ID, UTC timestamp,
computer name, user SID, status, and action records. Writes use a temporary sibling
and atomic move/replace. `operations.lock` is opened exclusively for apply/undo;
closing the stream releases it even though the empty lock file remains.

An action's pending record is saved before execution. Explorer's original state
is additionally saved before its registry write. After writing, the value is
read back; successful writes and failures are saved individually. Interrupted runs
can retain `Running`/`Pending` records and enough Explorer backup data for recovery.
The UI never interprets pending as success.

`Get-WuHistory` lists valid and unreadable files. `Undo-WuExplorerRun -Path` verifies
schema, ownership, known setting IDs, DWORD-or-absent snapshots, and expected target
values before any restoration. It skips apps and settings that were already
configured. An original value already in place is a no-op. A conflicting newer
value is left untouched. An already-undone run cannot undo a later reapplication.
For a matching applied value, undo records its intent, restores the original value
or removes a value that was originally absent, and verifies the result.

Undo compares values; it cannot identify an external change that happens to produce
exactly the same applied value. It does not uninstall apps, delete the whole
Explorer key, alter protected-file visibility, restart Explorer, or reboot Windows.
Reopening Explorer or signing out/in may be needed to refresh the display.

## Repair adapter

Repair is a separate, immediate workflow. It never mutates the setup selection or
saved-setup schema. `Get-WuRepairCatalog` defines tool descriptions in code;
`Get-WuRepairPlan -Id -SystemDrive [-SourcePath -SourceIndex]` builds a constrained
plan. `full` expands to disk scan, DISM RestoreHealth, SFC Scannow, DISM ScanHealth
and SFC VerifyOnly. The repair guide explains each stage and advanced actions.

`Get-WuRepairEnvironment` extends readiness with the detected Windows drive,
native system-tool directory, and a verified NTFS file-system check. Sysnative is
used for a 32-bit PowerShell process on 64-bit Windows. The UI previews commands,
shows preconditions and asks for confirmation. `Invoke-WuRepair -Id -Confirmed`
independently rebuilds its plan, rechecks platform/elevation/pending-restart
requirements, and verifies its tool and source paths. It never accepts executable
commands from a report or saved selection.

`Open-WuRepairAsAdministrator` starts a local `WinUtility.ps1 -Repair` child using
`Start-Process -Verb RunAs -Wait`. Waiting preserves the bootstrap's temporary
checkout while the administrator window is open. It does not carry pending setup
selections into the child. The original menu stays available after UAC cancellation
or the child closing. Windows `-Preview` and Linux omit elevation and execution.

Repair commands run through `Diagnostics.Process` with shell execution disabled.
Simple switches and drive letters are passed without quotes: CHKDSK rejects a
quoted `/scan`. Values requiring quotes retain their argument boundaries; DISM's
`/Source:` and `/WimFile:` prefixes remain outside those quotes. The formatter
handles embedded quotes and trailing backslashes on PowerShell 5.1, where
`ProcessStartInfo.ArgumentList` is unavailable. Previews, saved `CommandLine`
fields and process launches share this formatter. Only fixed
system executables are selected. The optional WIM source is a validated local path
and positive index, passed as one argument. Both native output streams are drained
concurrently into a UTF-8 file and the terminal, including partial progress/prompt
lines. SFC's redirected output uses UTF-16 decoding. Stdin is inherited so CHKDSK
can receive the user's own answer to a localized scheduling question.

A machine-wide named mutex excludes other WinUtility repair processes. Each run
has `%LOCALAPPDATA%\WinUtility\Repairs\<run-id>\report.json` and per-command logs.
The initial report includes every planned step as `NotRun`; the current record is
saved as `Running` before each command. Results are atomically saved after each
step. Report persistence failures stop the queue. Output failures drain the child
pipes and wait for it, rather than releasing the mutex while that tool still runs.

Reports record UTC times, elapsed seconds, executable paths, commands/arguments, native exit codes,
diagnostic messages, and Windows DISM/CBS/event-log locations. A failed/ambiguous
disk scan, failed command or required restart stops later steps. Pending-restart
state is also rechecked before subsequent repairing stages. SFC exits are treated
conservatively: zero needs summary review, while nonzero stops for attention.
Interactive disk repairs require reviewing whether scheduling was accepted; they
are never assumed repaired from a scheduling command's exit. There is no automatic
reboot, reboot resume or repair undo. Repair reports can be read, but never replayed.

The terminal automatically shows the last output for failed steps, nonzero exits,
and successful quick DISM checks. This distinguishes an immediate parameter
failure from a quick diagnostic that completed normally. Log reads use the tail
of the UTF-8 file and tolerate missing/empty files. The report waits for explicit
back navigation; an unexpected report-display error is caught by the repair menu.
New command-description fields are optional when reading older reports. Progress
callback failures are recorded as failed steps before further commands can start.

## Extending the utility

Add catalog entries to extend the menus; the terminal groups by catalog category.
Add preset references to compose those entries. New executable behavior belongs
in a code-owned handler, keeping planning and UI separate. A future GUI should reuse
the same session operations and planner.

Each additional setting needs applicability checks, current-state reading, a real
desired-state handler, persistence, and a supported undo policy. App removal,
upgrades, unattended execution, and reboot/resume remain outside this milestone.

## Validation

Run `./tests/Run-Tests.ps1`. It requires no Pester installation and uses temporary
fixtures. Core tests verify selection semantics and persistence; terminal tests
feed scripted inputs to real menu loops; bootstrap tests stub HTTP only, exercising
actual ZIP extraction and a real child PowerShell process for successful launch.
Windows-adapter tests fake OS/registry/WinGet responses but exercise real journal
files, locking, apply/retry decisions, and restoration. On Windows, a separate test
checks registry I/O under a unique test key, leaving real Explorer preferences
untouched. Native stderr and exit-code handling are tested with a child process.
Repair tests fake the OS and tools while exercising real report persistence and
failure/stop decisions. Additional child-process tests verify UTF-16 output,
argument boundaries, pipe draining after output failure, and mutex exclusion.
Terminal scenarios exercise repair previews, cancellation, confirmation, elevation
and reports, as well as app batches, pagination, discovery and search failures.
Core tests cover version 1/2 saved setups, package deduplication and isolated
imports; Windows tests verify discovery arguments and queue behavior with added
apps. Actual installations and Windows repair commands are never executed by this suite.
The GitHub Actions workflow runs the suite on Windows with `powershell` (5.1) and
`pwsh` (7). Linux tests do not establish real WinGet/Explorer correctness on Windows
11 or establish real DISM/SFC/CHKDSK behavior. Run the disposable-VM acceptance
checks in the README and repair guide before a release.
