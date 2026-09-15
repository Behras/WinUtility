# WinUtility

A terminal menu for setting up and repairing a Windows 11 laptop.
Choose an example preset, adjust settings and apps, review the selection, and
save it for the next laptop.

**Current milestone: a small working Windows setup foundation.** Windows 11 can
install the catalog apps through WinGet and change two Explorer preferences:
show file extensions and show hidden files. Those Explorer changes support undo.
The Repair menu runs DISM, SFC and CHKDSK, including a guided full workflow and
repair from local Windows media. Other sample settings remain preview-only.
Linux always runs in preview mode.

```text
  +-----------------------------------------------------------+
  |  WINUTILITY / LAPTOP SETUP                                 |
  |  A fresh start. A setup that feels like yours.              |
  +-----------------------------------------------------------+

  [PREVIEW MODE] All actions are simulated.
  Selected: 0 settings, 0 apps

  CHOOSE  >  CUSTOMIZE  >  REVIEW

  [1]  Presets
  [2]  Manual changes
  [3]  App installs
  [4]  Review & simulate (0)
  [5]  Saved setups
  [6]  Repair Windows
  [I]  Machine readiness
  -------------------------------------------------------------
  [0]  Exit
```

The terminal uses cyan accents, framed headings, green selections, and grouped
review screens. Text wraps to the window width, and the home menu becomes compact
in shorter windows. UTF-8 terminals get rounded borders; other terminals use ASCII.

## Run locally

### Windows 11

Download/extract this repository or clone it, open PowerShell in its folder, and run:

```powershell
.\WinUtility.ps1
```

If Windows blocks script execution, launch a separate process for this run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WinUtility.ps1
```

This process option does not change the execution policy stored in the registry.
Organization-enforced policies still take precedence.
[Microsoft: execution policies](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1)

Use Windows 11 and Windows PowerShell 5.1 or PowerShell 7. The prototype menus can
also be explored on non-Windows PowerShell 7 for development. The menu and Explorer
settings need no elevation or extra modules. Individual installers may request
administrator access. Missing WinGet blocks app installs, while Explorer settings
and simulation remain available. WinGet can be unavailable immediately after a first
Windows login while registration completes.
[Microsoft: WinGet](https://learn.microsoft.com/en-us/windows/package-manager/winget/)

### Linux / CachyOS (preview only)

Use PowerShell 7's `pwsh` executable from your Linux terminal. From the repository
folder, run:

```bash
pwsh -NoProfile -File ./WinUtility.ps1
```

`powershell.exe` is the Windows executable name. If `pwsh` is not on your PATH,
use the full path to a portable PowerShell 7 executable instead:

```bash
/path/to/powershell/pwsh -NoProfile -File ./WinUtility.ps1
```

The menu, presets, simulation, and saved setups work on Linux. The header will
identify a non-Windows host; Windows configuration remains the project's target.
Linux preview does not require WinGet or an execution-policy option.

### Preview on Windows

To explore the menus on Windows without offering real apply/undo actions, add
`-Preview`:

```powershell
.\WinUtility.ps1 -Preview
```

Windows mode offers **Review & apply** and **History & Explorer undo**. Choosing a
preset or checking an item only changes the selection. Real actions require a
separate confirmation in the review screen. Simulation is available in either mode.

### Plain display

Add `-Plain` for monochrome ASCII output:

```bash
pwsh -NoProfile -File ./WinUtility.ps1 -Plain
```

The same switch works on the Windows entry point. `NO_COLOR`, `TERM=dumb`, and
redirected output also enable plain display. No additional UI module is required.

## Run from GitHub

After these project files have been published to the public `main` branch of
`Behras/WinUtility`, run:

```powershell
irm https://raw.githubusercontent.com/Behras/WinUtility/main/bootstrap.ps1 | iex
```

The command executes the launcher from this repository. It resolves `main` once to
a full commit ID, downloads that commit's archive, and opens the same menu in a
child PowerShell process. It uses a process-only execution policy, requires no Git
installation or elevation, and cleans its temporary directory when the menu exits.
The caller's persistent execution policy remains unchanged. Internet access to
GitHub is required; API limits, network failures, or incomplete downloads stop the
launcher with a readable message. Local launch remains available.

Resolving a commit gives each run a consistent project snapshot. This is not a
signed release or independent integrity check of the initial launcher.
[GitHub: source archives](https://docs.github.com/en/repositories/working-with-files/using-files/downloading-source-code-archives)

## Use the menu

1. **Presets:** preview Minimal, Balanced, or Full, then confirm replacement of the
   current selection. These are illustrative setups, not finalized recommendations.
2. **Manual changes:** toggle individual choices in Privacy & suggestions,
   Desktop & Explorer, Power & battery, or Windows apps & features.
3. **App installs:** browse 48 bundled apps across nine categories, use `S` to
   search the catalog, or `W` for live WinGet search on Windows. Select multiple
   apps with numbers/ranges such as `1,3,5-7`, then review the shared queue.
4. **Review & apply** (or **Review & simulate** in preview mode): see intended
   effects, origins, and, on Windows, current state. `A` applies supported actions
   after confirmation; `S` simulates. Remove items or clear the selection as needed.
5. **Saved setups:** export/import JSON. Imports preview their contents before
   replacing selections. Exit offers Save, Discard, or Cancel when needed.
6. **Repair Windows:** run the full repair workflow or an individual tool. Repair
   actions have their own command preview, confirmation and reports; they are not
   included in presets or saved selections.

`I` opens **Machine readiness**: Windows edition/build, architecture, WinGet version,
pending-restart detection, and battery/power information. Refresh after installing
or updating App Installer. Unknown checks stay labeled unknown. Windows Server and
unverified/older Windows versions get preview mode.

`H` opens **History & Explorer undo** in Windows mode. Inspect a run before choosing
to restore its previous Explorer values.

Enter a number and press Enter. `[x]` marks selected items; `0` goes back.
Deselecting a setting removes it from the plan; it does not queue a reverse change.
Simulation keeps selections available and reports **0 changes made**. It does not
check existing settings, installed apps, or whether an installer is available.

| Example preset | Included selections |
| --- | --- |
| Minimal | Reduce Windows suggestions, show file extensions, 7-Zip |
| Balanced | Minimal + show hidden files, Firefox, VLC |
| Full | Balanced + PowerToys, Visual Studio Code |

Balanced power and removing Microsoft Solitaire Collection are unselected manual
examples. These two settings and reducing suggestions remain preview-only and are
skipped during real execution. Nothing is selected when the app starts.

## Applying and undoing changes

### App installs

The bundled catalog covers **Browsers, Utilities, Media, Development, Office &
notes, Communication, Gaming, Passwords & VPN, and Diagnostics**. Examples include
Chrome, Brave, Everything, Notepad++, OBS Studio, Git, LibreOffice, Discord, Steam,
Bitwarden and HWiNFO. The [full catalog and source links](docs/APP-CATALOG.md) list
all 48 packages. These are selectable choices; the original example presets retain
their existing selections.

**Choosing several apps:**

| Input | Action |
| --- | --- |
| `1,3,5-7` or `1 3 5-7` | Toggle those visible app numbers together. Repeated numbers toggle once. |
| `A` / `C` | Select / clear the current page only. |
| `N` / `P` | Next / previous page, keeping all selections. |
| `D 3` | Show the description and package ID for visible item 3. |
| `R` | Review the shared settings/app queue; confirm there to install. |
| `0` | Back, keeping selections. |

App lists display eight items per page. Numbers continue across pages; only the
numbers on the current page can be toggled. An invalid number or range rejects the
whole input without partially changing your selection. Short terminals use compact
rows; details remain available through `D`.

**Finding apps:** `S` matches names, descriptions, categories and package IDs in
the bundled catalog and any packages added this session. Search is literal and
case-insensitive; try `PDF`, `archive` or `password`. `B` browses the whole local
list. Searches and categories share one queue, and adding the same package again
does not duplicate it.

**Live WinGet search:** `W` queries the `winget` source for up to 40 matches. Enter
one or several exact package IDs from the output, separated by commas/spaces (up
to 20 per batch). WinUtility displays each package's native WinGet details, then
asks to add the batch to the queue. Every ID must resolve; a failed lookup leaves
the batch unselected. IDs must be complete and correctly capitalized; refine the
query if WinGet truncates an ID. Search results remain native text, so the utility
does not guess package identities from localized/truncated table columns.
[Microsoft: search](https://learn.microsoft.com/en-us/windows/package-manager/winget/search),
[package details](https://learn.microsoft.com/en-us/windows/package-manager/winget/show).

If WinGet requires source agreements, their acceptance is prompted separately
before retrying the search. App installation agreements are still confirmed at
apply time. Linux and `-Preview` offer the bundled catalog and local search; live
WinGet commands and source-agreement changes are disabled in preview mode.

- The queue uses exact package IDs from the catalog and the `winget` source.
- Existing apps are kept as-is; `--no-upgrade` also protects against upgrading an
  app installed between the check and the install.
- The final confirmation covers app/source agreements. Installers run silently
  where supported, and can still request UAC approval.
- Results distinguish installed, already installed, failed, cancelled, skipped,
  and restart-required outcomes. `F` in review retries failed/cancelled apps that
  are still selected, without repeating the settings queue.
- WinUtility does not request an automatic reboot or disable installer hash checks.
  Installer failures/cancellations may leave partial changes; their output is saved
  in the run history. An unknown installed-state query is reported as a failure,
  rather than treated as proof that an app is missing.

Command behavior and return-code references: [Microsoft: install](https://learn.microsoft.com/en-us/windows/package-manager/winget/install),
[list](https://learn.microsoft.com/en-us/windows/package-manager/winget/list),
[WinGet return codes](https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md).

### Explorer settings and history

Only `HideFileExt` and `Hidden` under the current user's Explorer Advanced registry
key are changed. Protected operating-system files remain hidden; no Explorer
process is killed. Reopen Explorer windows or sign out/in if the display does not
refresh immediately.

Before each setting write, the original DWORD value (including an absent value)
is saved under `%LOCALAPPDATA%\WinUtility\History`. Undo restores that original
state only on the same computer and Windows user. If the current value differs
from both the saved original and the value applied by the run, undo reports a
conflict and leaves it alone. App installs are not undone by this feature.

History survives closing the app and the temporary GitHub download. Interrupted
runs remain marked `Running` with any `Pending` items; those are not success
reports. Supported Explorer backups can still be used for recovery. If history
cannot be saved, the queue stops before the next change. A lock prevents concurrent
apply/undo runs from this history directory.

### Saved setups

Saved setups default to `Documents\WinUtility\setup.json`; choose another path to
keep multiple setups. These files contain catalog/package IDs and desired values.
They do not contain commands or install packages. Copy one to another laptop and
choose **Saved setups -> Import** to reuse it. Preset/manual origin labels are
session information; imported choices are labeled **Saved setup**.

Selections containing only bundled entries retain schema version 1. Selecting
additional WinGet packages uses schema version 2, which records their package IDs.
Both formats import offline, including on Linux. Additional packages appear under
**From WinGet**, labeled with their exact ID; their details can be checked again
with live search on Windows. Importing a file does not install or verify packages.

## Repair Windows

Choose **6 -> Full repair**. The workflow detects the Windows drive and runs:

1. `chkdsk <Windows drive> /scan` - online NTFS scan (can perform online fixes).
2. `DISM /Online /Cleanup-Image /RestoreHealth` - repair the component store.
3. `sfc /scannow` - repair protected system files.
4. `DISM /Online /Cleanup-Image /ScanHealth` - rescan the component store.
5. `sfc /verifyonly` - verify protected files again.

DISM runs before SFC so the component store used for file repairs is addressed
first, following [Microsoft's repair sequence](https://support.microsoft.com/en-US/Windows/Experience/backup-recovery/using-system-file-checker-in-windows).
WinUtility adds `/NoRestart /English` to DISM commands. Full repair stops after a
disk result needing attention, a command failure, or a required restart. An
already pending restart blocks the repairing workflow until you restart Windows.
All results retain the command output; SFC results explicitly need review because
an exit code alone does not prove that every corrupted file was repaired.

Individual DISM and SFC checks are available, plus **Advanced recovery tools**:

- `chkdsk <Windows drive> /f` for file-system repair.
- `chkdsk <Windows drive> /r` for a full-volume sector check and recovery attempt;
  includes `/f` and can take hours. Back up important files before these disk repairs.
- List image indexes in a local `.wim`, then run DISM with a matching WIM/index as
  its repair source when the usual repair source fails.

Boot-time checks use CHKDSK's own scheduling prompt, including its localized
yes/no response. WinUtility does not answer it or reboot the laptop. A scheduling
request is recorded for review, never reported as a completed disk repair.
[Microsoft: CHKDSK](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/chkdsk)

Repair commands require administrator access. Use **A** inside the Repair menu to
open a dedicated administrator window; UAC cancellation leaves the current menu
available. You can also start directly in the repair menu:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WinUtility.ps1 -Repair
```

Add `-Preview` to explore it on Windows. Linux always previews; no Windows repair
commands run there. Command output is streamed and saved alongside a JSON report
under `%LOCALAPPDATA%\WinUtility\Repairs`. **L** in the Repair menu reopens reports.
Failed steps show the last command output automatically and wait for you to return
to the menu. CHKDSK exit 3 alone does not identify the cause; see the
[immediate-exit troubleshooting steps](docs/REPAIR.md#chkdsk-exits-immediately-with-code-3).
DISM's quick CheckHealth can finish immediately; its result is displayed, and
ScanHealth remains available for a fresh scan.
Reports belong to the account running the repair, including when different
administrator credentials are used. Repair changes have no automatic undo.

See the [repair guide](docs/REPAIR.md) for source-image requirements, interpreting
results, and the next steps when Windows still needs repair. This workflow covers
online image, system-file and file-system repairs; boot recovery, failing hardware,
and a repair reinstall require further diagnosis.

## Project structure

```text
WinUtility.ps1                  Local entry point
bootstrap.ps1                   GitHub launcher
src/WinUtility.Core.psm1         Catalogs, selections, planning, simulation, JSON
src/WinUtility.Terminal.psm1     Terminal menus and prompts
src/WinUtility.Windows.psm1      Readiness, WinGet, Explorer actions and history
src/WinUtility.Repair.psm1       Repair workflows, native tools, logs and elevation
data/                           Settings, apps, and example presets
tests/                          Automated behavioral tests
.github/workflows/test.yml      Windows PowerShell 5.1 and PowerShell 7 CI
docs/ARCHITECTURE.md             Interfaces and extension guidance
docs/REPAIR.md                   Repair tools, recovery steps and validation
```

See [Architecture](docs/ARCHITECTURE.md) for the selection model, saved-file format,
and how execution adapters and a future GUI can reuse the core.

See [Feature inspiration](docs/FEATURE-INSPIRATION.md) for the comparison of WinUtil,
Win11Debloat, Sophia Script, Winhance, and UniGetUI, with source links and suggested
next milestones.

## Test

```powershell
.\tests\Run-Tests.ps1
```

The suite needs no third-party test modules. It covers catalog validation, preset
replacement, manual overrides, deterministic planning, simulation, saved files,
terminal navigation, Windows readiness, apply/undo/retry behavior, repair command
ordering, stop conditions, report persistence, and launcher success/failure.
Windows actions use fakes for the behavioral tests; on Windows,
an additional test exercises the real registry adapter in its own temporary key,
without touching actual Explorer settings. The native command adapter is checked
with child PowerShell processes, including Unicode output, argument quoting, pipe
draining and repair locking. Tests never install applications or run actual repairs.

Before release, manually smoke-test on Windows 11 under Windows PowerShell 5.1:

- Run locally as a standard user, including from a folder containing spaces.
- Choose a preset, adjust an app, simulate, and verify the displayed results.
- In a disposable Windows 11 VM, apply the two Explorer settings; verify them in
  Explorer, restart WinUtility, and undo. Check restoration of absent values too.
- Install one missing catalog app and rerun the selection to check `AlreadyInstalled`.
- Select apps from several categories/searches, page forward/back, then export and
  reload the queue. Test live search with missing/accepted source agreements and
  a multi-package batch, including a package outside the bundled list. Confirm
  lookup cancellation/failure adds nothing and a saved dynamic package installs
  through the normal queue. Verify search/detail output on non-English Windows.
- Test a declined installer/UAC prompt and an unavailable source; verify saved
  failure output and retry after fixing the problem.
- Export, restart, import, and test Save/Discard/Cancel on exit.
- Launch using the GitHub command from a normal fresh PowerShell session.
- Confirm preview and Explorer actions work when WinGet is unavailable.
- Run the [repair acceptance checks](docs/REPAIR.md#windows-acceptance-checks) in a
  disposable Windows 11 VM, including UAC, localized SFC output and CHKDSK scheduling.

Additional Windows settings, app removal/upgrades, GUI, and reboot/resume handling
are future milestones. Real Windows 11 installation, Explorer and repair smoke tests must be
completed before treating this foundation as release-validated.
