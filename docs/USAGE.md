# Using WinUtility

## Launch and update

The [README](../README.md#quick-start) contains the GitHub launch command. Each
launch downloads one project revision and starts a child PowerShell process.
The process-only execution-policy option does not change the machine's stored
policy. Organization-enforced policies still apply.
[Microsoft: execution policies](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1)

For a local checkout, pull updates with Git, close the utility, and launch again:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WinUtility.ps1
```

| Option | Purpose |
| --- | --- |
| `-Repair` | Open directly in the repair menu. |
| `-Plain` | Use monochrome ASCII output. |
| `-NoKeyNavigation` | Use typed numbers/letters and Enter instead of a selection cursor. |
| `-Preview` | Browse and save selections with Windows execution disabled. |

For a terminal with limited console support:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WinUtility.ps1 -Plain -NoKeyNavigation
```

On Linux or CachyOS, use PowerShell 7:

```bash
pwsh -NoProfile -File ./WinUtility.ps1
```

Use the full path to `pwsh` if it is not on your PATH. Linux supports browsing and
portable setup files; app installation, undo, and repair execution require Windows.

## Navigation

Use **Up/Down** or **Tab** to move, **Enter** to select, and **Esc** to return.
**Home/End** jump to the first/last menu item when no shortcut is being typed.
The highlighted row shows a `>` marker; its description appears below the list.
Long lists scroll within the selection area. Focus is remembered when you return
to a menu or toggle an app.

You can also type a displayed number or letter and press Enter. Search and file
fields support text entry, paste, Left/Right, Home/End, Delete, and Backspace.
Esc cancels the field. Confirmations start on Cancel; choose the named action
explicitly to proceed.

Without console key support, WinUtility uses numbered input automatically. Enter a
number/letter, then press Enter; use **0** for Back or Cancel. Empty input returns
from searches. `-NoKeyNavigation` forces this mode.

## Select a setup

Presets replace the current selection after confirmation. You can edit it before
applying anything:

| Preset | Selected items |
| --- | --- |
| Minimal | Windows suggestions, file extensions, 7-Zip. |
| Balanced | Minimal + hidden files, Firefox, VLC. |
| Full | Balanced + PowerToys, Visual Studio Code. |

Windows suggestions is currently unimplemented and makes no changes. Manual
Balanced power and Solitaire removal are also placeholders. Review labels these
items; execution skips them. Explorer extensions and hidden files are implemented.

Deselecting an item removes it from the queue. To reverse an applied Explorer
change, use its saved history. App installation is separate from selection.

## Install apps

Open **App installs**, choose a category, and mark apps with **Space** or **Enter**.
The eight-item pages share one selection across categories and searches.

| Shortcut | Action |
| --- | --- |
| `S` in the catalog | Search name, description, category, or package ID. |
| `B` in the catalog | Browse all bundled and session-added apps. |
| `W` in the catalog | Search the live WinGet source on Windows. |
| `1,3,5-7` or `1 3 5-7` | Toggle those visible numbers together. |
| `A` / `C` in an app list | Select / clear the current page. |
| `N` / `P`, or Right / Left | Next / previous page. |
| `D 3` | Show details for visible item 3. |
| `R` | Review the combined app/settings queue. |

Repeated numbers toggle once. Invalid batches make no selection changes. Numbering
continues across pages, but a batch may reference only the current page.
See the [complete catalog](APP-CATALOG.md) for all bundled apps.

### Live WinGet search

Search returns up to 40 results from the `winget` source. Enter one or several
exact package IDs separated by commas/spaces, up to 20 per batch. WinUtility
shows each package's details and asks before adding the batch. If any ID cannot
be resolved, none are added. Refine the query if native output truncates an ID.
[Microsoft: search](https://learn.microsoft.com/en-us/windows/package-manager/winget/search),
[package details](https://learn.microsoft.com/en-us/windows/package-manager/winget/show).

Source agreements require a separate confirmation. Live search is unavailable on
Linux and with `-Preview`; local catalog search still works.

### Apply and retry

Choose **Review & apply → Apply supported changes**. The confirmation includes
app license/source agreements. Installers run silently where supported and may
request administrator access. Apps start with normal-user permissions even when
WinUtility itself is running as administrator. This applies to bundled apps and
packages added through live search; Spotify and similar installers can run without
rejecting an administrator shell. Existing apps are skipped; the queue does not
upgrade them. Duplicate package selections produce one install action.

The worker uses the same Windows account and checks its permissions before
installing. If Windows cannot provide that account's normal session, the app gets
a failed result with instructions; the rest of the queue continues. Start
WinUtility from a normal PowerShell window if you used another account's
administrator credentials, disabled UAC, or are using the built-in Administrator
account. Repair commands continue to use administrator access separately.

Results distinguish installation, existing apps, failures, cancellation, skipped
items, and restart requirements. **Retry failed app installs** retries only failed
or cancelled apps still selected. An unknown installed state prevents that app's
installation. Command output is retained in history.
[Microsoft: install](https://learn.microsoft.com/en-us/windows/package-manager/winget/install),
[list](https://learn.microsoft.com/en-us/windows/package-manager/winget/list).

## History and saved setups

Explorer changes save their previous values under:

```text
%LOCALAPPDATA%\WinUtility\History
```

**History & Explorer undo** restores values only for the original computer and
user. If a setting was subsequently changed to a different value, undo reports a
conflict. App installs are not undone. Reopen Explorer or sign out/in if its view
does not refresh immediately; protected operating-system files remain hidden.

Saved selections default to `Documents\WinUtility\setup.json`. Export one, copy it
to another laptop, then use **Saved setups → Import**. Files contain IDs and desired
values, with no executable commands. Importing never installs apps. Both bundled
selections (schema 1) and additional WinGet packages (schema 2) are supported.

Repair reports are separate, under `%LOCALAPPDATA%\WinUtility\Repairs`. They belong
to the account running the repair, including when different administrator
credentials are used. See the [repair guide](REPAIR.md).

## Troubleshooting

- **Arrow keys do not work:** restart with `-NoKeyNavigation`; typed shortcuts remain available.
- **Apps cannot install:** open Machine readiness and check WinGet. It may not be
  registered immediately after the first Windows login. Explorer settings work
  independently of WinGet. [Microsoft: WinGet](https://learn.microsoft.com/en-us/windows/package-manager/winget/).
- **Spotify says it cannot install as administrator:** update and restart
  WinUtility, then select the failed apps again. Within the same session, use
  **Retry failed app installs** in Review & apply. The app worker runs with normal
  permissions. If its startup fails, launch WinUtility
  from a normal PowerShell window with UAC enabled and select the failed apps again.
  [Spotify's WinGet manifest](https://github.com/microsoft/winget-pkgs/tree/master/manifests/s/Spotify/Spotify)
  declares that elevation is prohibited.
- **Repair stops:** read the native error displayed in the report. **O** shows the
  end of each command log. [CHKDSK exit 3](REPAIR.md#chkdsk-exits-immediately-with-code-3).
- **An update is missing:** close all WinUtility windows and launch from the updated
  checkout or rerun the GitHub launcher. Existing sessions keep their loaded modules.
