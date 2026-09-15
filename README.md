# WinUtility

[![PowerShell tests](https://github.com/Behras/WinUtility/actions/workflows/test.yml/badge.svg)](https://github.com/Behras/WinUtility/actions/workflows/test.yml)

A PowerShell terminal utility for setting up and repairing Windows 11 laptops.
Install several apps, adjust Explorer, save a reusable setup, and run Windows
repair tools from one menu.

## Quick start

Open **PowerShell** normally and run:

```powershell
irm https://raw.githubusercontent.com/Behras/WinUtility/main/bootstrap.ps1 | iex
```

This downloads and runs WinUtility from this repository. The launcher downloads
one project archive for each session and removes its temporary files on exit.
It retries temporary network errors. If GitHub's API stays unavailable, it uses
a direct archive of the `main` branch and reports that the commit ID is unverified.
Internet access is required. Review the [launcher](bootstrap.ps1) before running
downloaded code.

If you still get a **504 Gateway Timeout**, [download the ZIP directly](https://codeload.github.com/Behras/WinUtility/zip/refs/heads/main),
extract it, and use the local command below. This opens the menu without the
launcher's GitHub API lookup.

### Run a local copy

Clone or download the repository, open PowerShell in its folder, and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WinUtility.ps1
```

Keep the `src` and `data` folders alongside the entry script. After pulling an
update, close and reopen WinUtility to load the new modules.

On Windows 11, WinUtility requests administrator access once when it opens.
Apps install one at a time in that session, with live output and elapsed time.
Apps such as Spotify that forbid elevation retry as the same normal Windows user.
Individual installers can still have their own prompts. Linux and `-Preview`
do not request administrator access.

## Controls

| Key | Action |
| --- | --- |
| **Up / Down** | Move the selection. |
| **Enter** | Open the highlighted item or toggle an app. |
| **Space** | Toggle a checkbox in an app or settings list. |
| **Esc** | Go back or cancel. At the main menu, begin exiting. |
| **Left / Right** | Previous / next app page when the input field is empty. |
| **Numbers and letters** | Type a displayed shortcut, then press Enter. |
| **`1,3,5-7`** | Toggle several apps on the current page. |

Selections stay in the queue while you browse categories or search. Installation
and repairs ask for confirmation; confirmation screens start on **Cancel**.

Key navigation is automatic in supported terminals. Use `-NoKeyNavigation` for
numbered, line-by-line input, or `-Plain` for monochrome output.
The active row has a yellow background and black text; headings stay cyan and
checked items stay green when unfocused. A `>` marker also identifies focus.

## Features

| Menu | Available now |
| --- | --- |
| **Presets** | Minimal, Balanced, and Full starting selections. |
| **Manual changes** | Show file extensions and hidden files, with change history and undo. |
| **App installs** | 48 apps in nine categories, search, multiple selection, and live WinGet discovery. |
| **Review & apply** | Check current state, apply supported changes, and retry failed app installs. |
| **Saved setups** | Export and import app/settings selections as portable JSON. |
| **Repair Windows** | Full repair workflow, individual DISM/SFC/CHKDSK commands, local WIM repair, and saved reports. |
| **Machine readiness** | Windows build, WinGet availability, power status, and pending restart checks. |

Settings that are not implemented are labeled and skipped without making changes.
These currently include Windows suggestions, the Balanced power plan, and Solitaire
removal. Selecting a preset or app does not start an installation.

### Windows repair

The full workflow runs **CHKDSK scan → DISM repair → SFC repair → DISM scan → SFC
verification**. Failures and required restarts stop subsequent steps. Reports show
the command output and remain available for review.

Repairs use the administrator session opened at startup. Boot-time disk checks
and local Windows media are separate choices under **Advanced recovery tools**.
See the [repair guide](docs/REPAIR.md) for details and troubleshooting.

## Requirements

- Windows 11 with Windows PowerShell 5.1 or PowerShell 7.
- WinGet for app installation and live package search.
- Administrator access for normal Windows startup; `-Preview` supports browsing without it.

PowerShell 7 on Linux can browse catalogs and save setups. Windows actions are
unavailable there. No additional PowerShell UI modules are required.

## Documentation

- [Usage and troubleshooting](docs/USAGE.md)
- [Complete app catalog](docs/APP-CATALOG.md)
- [Windows repair guide](docs/REPAIR.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Feature research and roadmap](docs/FEATURE-INSPIRATION.md)
- [Contributing and testing](CONTRIBUTING.md)

## Development

Run the dependency-free test suite:

```powershell
./tests/Run-Tests.ps1
```

Tests cover menus, keyboard input, saved setups, Windows adapters, repair workflows,
and the GitHub launcher. They use controlled responses for Windows changes; actual
app installs and repairs need Windows VM validation.
