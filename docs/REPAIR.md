# Windows repair guide

Open **6 -> Repair Windows**, or launch `WinUtility.ps1 -Repair`. On Windows 11,
startup requests administrator access once, which also covers repair commands.
The GitHub launcher keeps its temporary files until the administrator window
exits. If the terminal is opened separately without startup elevation, **A** opens
an administrator repair window. Linux and `-Preview` show command plans only.
Use arrows and Enter to navigate, or type a displayed shortcut. Esc returns from
the current screen. Confirmation starts on Cancel. `-NoKeyNavigation` uses typed
input and is retained when opening the administrator repair window.

Repair is independent of laptop setup selections. Each repair asks you to review
its commands before running. Save your work and keep the laptop on AC power during
long operations. WinUtility does not request a restart or offer automatic undo for
repair commands.

## Full repair

| Order | Command | Purpose |
| --- | --- | --- |
| 1 | `chkdsk <Windows drive> /scan` | Online scan of the verified NTFS system volume; online corrections are possible. |
| 2 | `DISM /Online /Cleanup-Image /RestoreHealth /NoRestart /English` | Repair the component store, using the system's configured repair source. |
| 3 | `sfc /scannow` | Check and repair protected system files. |
| 4 | `DISM /Online /Cleanup-Image /ScanHealth /NoRestart /English` | Recheck the component store after repairs. |
| 5 | `sfc /verifyonly` | Verify protected files again without replacing them. |

The Windows drive is detected; it is not assumed to be `C:`. The preview on Linux
uses `C:` as an example. This sequence addresses the file system, the source used
to repair Windows components, and protected files. DISM repair precedes SFC as in
[Microsoft's recommended sequence](https://support.microsoft.com/en-US/Windows/Experience/backup-recovery/using-system-file-checker-in-windows).
The final two steps provide fresh diagnostic output to review.

### When it pauses

- A known pending restart blocks a repairing workflow. Restart and try again;
  quick DISM checks and other diagnostic-only choices remain available.
- A CHKDSK scan that does not establish a clean or repaired volume stops the full
  run before DISM. Review the disk report, back up important files, and consider
  a boot-time `/f` check.
- A failed command or reported restart requirement stops later commands. A new
  pending restart is also checked before subsequent repairing stages.
- Missing tools, unavailable administrator access, or an unverified NTFS drive
  block the relevant operation before execution.
- A failure to persist the report stops the queue before the next command.

Re-run the full workflow after resolving the cause. There is no automatic resume
after reboot and no unattended retry loop.

### CHKDSK exits immediately with code 3

Code 3 means CHKDSK could not check the disk or left errors unresolved; the code
alone does not identify the cause. A stopped report shows the last command output
automatically and waits for **0 -> Back to repair menu**. The remaining stages
stay **NotRun**. **O** shows the output again.
[Microsoft: CHKDSK exit codes](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/chkdsk#understanding-exit-codes)

If the output says `Invalid parameter - "`, update your WinUtility copy and
restart the utility. Earlier versions quoted every native argument, producing
`chkdsk.exe "C:" "/scan"`. The launcher now uses `chkdsk.exe C: /scan`; DISM and
SFC switches also stay unquoted. WIM paths containing spaces still retain their
required quoting. This parameter error does not establish disk corruption.

If a different error persists, use its exact text and the saved command to
diagnose it before choosing an offline disk check. Code 3 does not automatically
trigger `/f`, `/r`, a reboot, or further system repairs.

## Individual tools

The main Repair menu also exposes DISM CheckHealth, ScanHealth and RestoreHealth,
SFC Scannow and VerifyOnly, and the online disk scan. CheckHealth reads recorded
corruption status; ScanHealth performs a scan. RestoreHealth attempts repairs and
may use Windows Update, subject to machine policy.
[Microsoft: DISM repair](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/repair-a-windows-image?view=windows-11)

**2 -> Quick health check** can finish immediately because it reads recorded
corruption status. Its DISM output appears in the report automatically. Use
**3 -> Scan image health** to perform a fresh scan.

SFC Scannow can replace protected files; VerifyOnly does not repair them. SFC output
is localized, and WinUtility does not infer a universal health verdict from its
exit code. A zero exit is shown as **ReviewRequired**, with its raw summary and
CBS log location available. A nonzero exit stops later workflow stages for review.
[Microsoft: SFC](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/sfc)

## Advanced disk repairs

**CHKDSK /f** fixes file-system errors. If the running Windows volume cannot be
locked, CHKDSK asks whether to schedule a check at next boot. Answer its own
prompt in the language shown; WinUtility neither supplies an answer nor forces
a dismount. After accepting a scheduled check, restart Windows when ready.

**CHKDSK /r** includes `/f` and reads the volume to identify unreadable sectors and
attempt recovery of readable information. It can take many hours. Use it when
disk symptoms warrant it; it is a separate advanced action. Back up accessible
important files first, especially when hardware failure is suspected. These
commands do not repair physically failing hardware.
[Microsoft: CHKDSK parameters](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/chkdsk)

WinUtility records the immediate command and output as **ReviewRequired**, since
an accepted boot-time scheduling request is not proof the repair has happened.
After reboot, check **Event Viewer -> Windows Logs -> Application**, filtering
for **Chkdsk** and **Wininit**, for the disk-check result.
[Microsoft: viewing CHKDSK logs](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/chkdsk#viewing-chkdsk-logs)

## DISM repair from Windows media

If DISM reports missing source files or cannot download repair content:

1. Check the saved error, network connection and repair-source policy first.
2. Obtain suitable Windows media and locate a local `install.wim` (for example,
   `E:\sources\install.wim` on mounted media).
3. Choose **Advanced -> List WIM image indexes** to identify the matching edition.
4. Choose **Advanced -> Repair from local WIM**, enter the path and its positive
   image index, and review the command before confirming.
5. After successful DISM repair and any required restart, run SFC or full repair.

The command uses `/Source:WIM:<path>:<index> /LimitAccess`, so this attempt uses
the selected local source without falling back to Windows Update. Select a source
matching the installed Windows release, architecture, edition and language. It
must contain the needed servicing versions; an older source can lack required
files on a more fully patched target. Listing an index does not validate that the
source can repair this machine.
[Microsoft: repair source configuration](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-a-windows-repair-source?view=windows-11)

This source picker currently accepts local `.wim` files. It does not mount ISOs,
convert `.esd` files, download Windows media, or automatically select an index.

## Reports and next steps

Reports and UTF-8 command logs are saved to:

```text
%LOCALAPPDATA%\WinUtility\Repairs\<run-id>\
    report.json
    disk.scan.log
    dism.restore.log
    sfc.scan.log
    dism.scan.log
    sfc.verify.log
```

Individual runs only create logs for their chosen commands. Use **L -> Repair
reports** to reopen a run, then **O** to show the last lines of each log. Full
output remains in the named files. Paths to Windows' DISM and CBS logs are included
in the report. If elevation uses another account, reports are stored under that
account. Nothing is uploaded.

New reports store the executable path and formatted command as well as arguments,
timing, exit codes and each step's status. Older reports remain readable. Failed
steps and nonzero exits show their last output automatically; missing or empty
logs are reported without leaving the menu.
**Completed** means a command exited successfully, not that every Windows problem
is resolved. **ReviewRequired** calls for reading the diagnostic summary.
**NotRun** stages did not execute. A **Running** report without a completion time
may be active or interrupted; inspect its output before starting another run.
The native runner streams both output pipes and handles SFC's Unicode output.
It waits for its child before releasing the repair lock, even if output display
fails. Let running repair tools finish; closing the console or losing power can
leave an incomplete operation and report.

If corruption remains, use the logs to choose the next step. Some cases need an
offline repair from Windows Recovery Environment or a Windows repair reinstall.
This online workflow does not alter boot records, rebuild BCD, reset networking,
reset update caches, or remove component rollback data. Those procedures address
different symptoms and need their own diagnosis and scope.

## Windows acceptance checks

Automated tests replace actual repairs with controlled responses. They check
sequence, preconditions, failures, persistence, native output handling, locking
and menu behavior. No test runs DISM, SFC or CHKDSK against Windows itself.

Before release, test in a disposable Windows 11 VM with a snapshot:

- Launch from a path with spaces in Windows PowerShell 5.1 and PowerShell 7.
  Verify `-Repair`, `-Plain` and `-Preview`, and all main-menu choices.
- Launch from a normal shell, cancel startup UAC, then relaunch and accept it.
  Verify the launcher waits for the administrator menu and saved reports survive
  cleanup. Verify `-Preview` does not request UAC.
- Run individual DISM checks and SFC VerifyOnly, including a non-English Windows
  installation. Check that output is readable and report/log files agree.
- Confirm CHKDSK `/scan` no longer rejects a quote as an invalid parameter. Check
  that previews and saved command lines match, and that returning from reports
  leaves the repair menu usable. Use fixtures for forced exit-code failures.
- Run full repair; check the order and SFC summaries. Verify a known pending
  restart blocks the repairing workflow and report results remain conservative.
- Open `/f`, decline CHKDSK's scheduling prompt, and verify no boot check is claimed.
  On another run accept it, reboot manually, and inspect the Wininit event.
  Verify `/r` stays a separately confirmed action; do not run it routinely.
- List WIM indexes and repair from a suitable test source in a path with spaces.
  Verify missing files and incorrect source indexes produce useful results.
- Check simultaneous WinUtility repair sessions are blocked, and reports reopen
  after restarting WinUtility. Actual Windows behavior remains a release check
  even when all Linux tests pass.
