# Feature inspiration for WinUtility

Reviewed on **2026-09-15**. This is the original research backlog. The first working
foundation now covers readiness, WinGet installs, two reversible Explorer
settings, and the repair submenu. App browsing now includes 48 curated apps,
categories, batch selection, local search and live WinGet search. Remaining ideas
below are future work. Priorities target this
project's use case: repeatedly setting up freshly installed Windows laptops.

## Repositories reviewed

| Project | What is useful here | Evidence |
| --- | --- | --- |
| **Chris Titus Tech / WinUtil** | Named presets, app selection, import/export, troubleshooting, and an environment report with Windows, hardware, package-manager, and pending-reboot information. | [Repository](https://github.com/ChrisTitusTech/winutil), [presets](https://github.com/ChrisTitusTech/winutil/blob/2260df6365b3ec8b86a42876e8a04640ba1f0e30/config/preset.json), [environment report](https://github.com/ChrisTitusTech/winutil/blob/2260df6365b3ec8b86a42876e8a04640ba1f0e30/functions/private/Get-WinUtilEnvironmentReport.ps1) |
| **Raphire / Win11Debloat** | Discoverable categories for Windows settings, build-dependent options, reusable configurations, and deployment to another/default user profile. Its power options also account for Modern Standby support. | [Feature overview](https://github.com/Raphire/Win11Debloat#features), [feature catalog](https://github.com/Raphire/Win11Debloat/blob/32024662f3c602442e7af82bbf52c89143b31aeb/Config/Features.json), [import compatibility checks](https://github.com/Raphire/Win11Debloat/blob/32024662f3c602442e7af82bbf52c89143b31aeb/Scripts/Helpers/Import-ConfigToParams.ps1) |
| **Sophia Script** | Explicit functions for opposing setting choices, Windows-version support metadata, installed-app discovery, optional Windows features, and app-association export/import. | [Feature overview](https://github.com/farag2/Sophia-Script-for-Windows#key-features), [Windows 11 module](https://github.com/farag2/Sophia-Script-for-Windows/blob/c80ceaa298f4c0c4c7fbd94d558263bce06626f1/src/Sophia_Script_for_Windows_11/Module/Sophia.psm1) |
| **Winhance** | A clear separation between software, optimization, and desktop customization. Search and explanatory labels make a large settings catalog easier to browse. Its configuration-to-unattended-install workflow fits repeated reinstalls. | [Feature overview](https://github.com/memstechtips/Winhance#current-features-%EF%B8%8F) |
| **UniGetUI** | Package details before installation, bulk operations, per-app installation preferences, portable package lists, update controls, and operation history. | [Feature overview](https://github.com/Devolutions/UniGetUI#features) |

The first three repositories were cloned into `/tmp/winutility-inspiration/` and
their source/configuration files inspected. Winhance and UniGetUI were reviewed
through their GitHub documentation. No reference utility was executed.

## Best ideas to build next

### 1. Make one laptop setup reliable

| Feature | Proposed WinUtility behavior | Why it matters |
| --- | --- | --- |
| **Machine readiness** | Report Windows edition/build, architecture, WinGet availability, and pending reboot. Add battery/AC status for laptops. Show unsupported choices with an explanation. | A saved setup needs to adapt to the laptop it is running on. Inspired by WinUtil's report and Win11Debloat's compatibility checks; battery/AC reporting is our proposed addition. |
| **Current vs. desired settings** | Review `Current -> Selected` for each supported setting. Mark an already satisfied setting as `Already configured`, and an unreadable setting as `Unknown`. | Re-running the utility becomes predictable. WinUtil's report collects tweak state; we would use that idea directly in the review flow. |
| **Real app installation queue** | Begin with WinGet, show package ID/source and installed status, then report success, already installed, failure, or restart needed per app. Allow retrying failed items. | This is immediately useful after reinstalling Windows. UniGetUI's package details and operation history provide the product inspiration; retry semantics are our design. |
| **A focused settings starter pack** | File extensions, Explorer start location, taskbar alignment, taskbar End Task, suggestions, and optional widgets/search preferences. Every setting remains individually editable. | These are visible, understandable improvements. They appear in the Win11Debloat/Sophia catalogs and suit the existing manual categories. |
| **Change history and supported undo** | Record each action and its actual previous value. Offer undo only where the handler can restore that value. List actions that cannot be undone. | Sophia's opposing setting functions are useful inspiration. Restoring a Windows default and restoring a person's previous value are different operations; our history should distinguish them. |

**Foundation implemented:** machine readiness, a real WinGet queue, and two
reversible Explorer settings, with reporting and failure tests. Repair workflows
and expanded app discovery are also implemented. Real Windows 11 smoke validation
is still required before release.

### 2. Make repeated laptop setups convenient

| Feature | Proposed WinUtility behavior | Inspiration |
| --- | --- | --- |
| **Named personal setups** | Save `Family laptop`, `Work`, or `Development`; preview differences when loading one. Keep an app-only pack reusable across multiple Windows presets. | WinUtil's configurations; UniGetUI's package bundles. We already have basic JSON save/import. |
| **Installed-app cleanup** | Detect installed inbox apps and let the user select specific removals. Explain what an app does and whether reinstatement is supported. | Sophia's dynamic UWP list; Win11Debloat's app-removal catalog. |
| **Laptop power choices** | Group battery and plugged-in behavior, sleep/hibernate preferences, and supported Modern Standby options. Show the tradeoff for each setting. | Winhance's power section; Sophia's power functions; Win11Debloat's Modern Standby checks. |
| **Search all settings** | Search names and descriptions across manual categories, with the same selection model used by category browsing. | Winhance's searchable settings. App search already exists here. |
| **Useful update controls** | Review app updates, exclude selected apps, and configure Windows active-hours/restart preferences. | UniGetUI's per-package controls; Windows-update choices in Win11Debloat. |
| **Readable session report** | Export what was requested, what changed, what failed, and what needs a restart. Keep machine diagnostics optional and local. | WinUtil's environment report; UniGetUI's operation history. |

### 3. Keep advanced deployment for later

- **Optional features:** selectable WSL, Sandbox, and developer prerequisites,
  following the patterns in Win11Debloat and Sophia. Check edition, architecture,
  virtualization support, and restart requirements before offering them.
- **Repeatable unattended runs:** a saved setup plus a deliberate noninteractive
  mode, structured results, and reliable exit codes. WinUtil and Win11Debloat both
  document command-line configuration workflows.
- **Reinstallation support:** eventually generate an unattended-install
  configuration from a saved setup, inspired by Winhance. Treat installation
  media and driver injection as a separate project milestone.

## How the menu should grow

The current six main entries cover presets, manual changes, app installs, review,
saved setups and repair.
Put readiness information above the menu, cleanup inside **Manual changes**, and
future app packs/updates inside **App installs**. **History & Explorer undo** is now
available for supported Windows runs. Avoid empty future-feature menus.

For the next real presets, preserve security updates and the normal Windows
security baseline. Changes to encryption, protection services, or broad service
lists need their own explicit scope; they are not part of these laptop presets.

## Source and implementation provenance

This review collects capabilities and interaction ideas. The terminal rendering
code in WinUtility was written for this project; reference source code and assets
were not copied into it.

The inspected WinUtil, Win11Debloat, and Sophia repositories carry MIT licenses.
UniGetUI's repository also lists MIT. Winhance lists PolyForm Shield 1.0.0 and is a
feature/design reference here. Sources: [WinUtil license](https://github.com/ChrisTitusTech/winutil/blob/2260df6365b3ec8b86a42876e8a04640ba1f0e30/LICENSE),
[Win11Debloat license](https://github.com/Raphire/Win11Debloat/blob/32024662f3c602442e7af82bbf52c89143b31aeb/LICENSE),
[Sophia license](https://github.com/farag2/Sophia-Script-for-Windows/blob/c80ceaa298f4c0c4c7fbd94d558263bce06626f1/LICENSE),
[UniGetUI repository](https://github.com/Devolutions/UniGetUI),
[Winhance license](https://github.com/memstechtips/Winhance/blob/main/LICENSE.txt).

Reference checkouts are temporary and are not vendored into this repository.
The three source links above pin the inspected revisions; the two documentation
reviews link to the projects' current pages and may change over time.
