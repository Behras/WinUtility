Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'WinUtility.Core.psm1') -Scope Local
Import-Module (Join-Path $PSScriptRoot 'WinUtility.Windows.psm1') -Scope Local
Import-Module (Join-Path $PSScriptRoot 'WinUtility.Repair.psm1') -Scope Local

$script:WuPlain = $false
$script:WuUnicode = $false
$script:WuWidthOverride = 0
$script:WuHeightOverride = 0
$script:WuPreviewOnly = $true
$script:WuEnvironment = $null
$script:WuColors = @{ Normal = 'Gray'; Title = 'White'; Accent = 'Cyan'; Muted = 'DarkGray'; Success = 'Green'; Warning = 'Yellow' }

function Initialize-WuAppearance {
    param([switch]$Plain)
    $script:WuPlain = $Plain -or -not [string]::IsNullOrEmpty($env:NO_COLOR) -or $env:TERM -eq 'dumb'
    try { $script:WuPlain = $script:WuPlain -or [Console]::IsOutputRedirected } catch { }
    # Keep source ASCII for Windows PowerShell 5.1. Modern UTF-8 consoles get borders.
    $script:WuUnicode = $false
    try { $script:WuUnicode = -not $script:WuPlain -and [Console]::OutputEncoding.CodePage -eq 65001 } catch { }
}

function Get-WuDisplayWidth {
    if ($script:WuWidthOverride -gt 0) { return $script:WuWidthOverride }
    $width = 80
    try {
        if ($Host.UI.RawUI.WindowSize.Width -gt 0) { $width = $Host.UI.RawUI.WindowSize.Width }
    }
    catch { }
    return [Math]::Max(16, [Math]::Min(92, $width - 2))
}

function Test-WuCompactDisplay {
    $height = $script:WuHeightOverride
    if ($height -le 0) {
        try { $height = $Host.UI.RawUI.WindowSize.Height } catch { }
    }
    return $height -gt 0 -and $height -lt 38
}

function Get-WuWrappedText {
    param([string]$Text, [int]$Width)
    $remaining = ($Text -replace '[\x00-\x1f\x7f]', ' ').Trim()
    if ($remaining.Length -eq 0) { return '' }
    while ($remaining.Length -gt $Width) {
        $cut = $remaining.LastIndexOf(' ', $Width)
        if ($cut -le 0) { $cut = $Width }
        $remaining.Substring(0, $cut).TrimEnd()
        $remaining = $remaining.Substring($cut).TrimStart()
    }
    if ($remaining.Length -gt 0) { $remaining }
}

function Write-WuOutput {
    param([string]$Text = '', [string]$Tone = 'Normal')
    $arguments = @{ Object = $Text }
    if (-not $script:WuPlain) { $arguments.ForegroundColor = $script:WuColors[$Tone] }
    Write-Host @arguments
}

function Write-WuText {
    param([string]$Text = '', [string]$Tone = 'Normal', [int]$Indent = 2)
    if ($Text.Length -eq 0) { Write-WuOutput; return }
    $width = [Math]::Max(1, (Get-WuDisplayWidth) - $Indent)
    foreach ($line in @(Get-WuWrappedText -Text $Text -Width $width)) {
        Write-WuOutput -Text ((' ' * $Indent) + $line) -Tone $Tone
    }
}

function Write-WuRule {
    $rule = '-'
    if ($script:WuUnicode) { $rule = [string][char]0x2500 }
    Write-WuOutput -Text ('  ' + ($rule * ((Get-WuDisplayWidth) - 2))) -Tone Muted
}

function Write-WuHeading {
    param([string]$Title, [string]$Subtitle = '')
    $width = Get-WuDisplayWidth
    $horizontal = '-'; $vertical = '|'; $topLeft = '+'; $topRight = '+'; $bottomLeft = '+'; $bottomRight = '+'
    if ($script:WuUnicode) {
        $horizontal = [string][char]0x2500; $vertical = [string][char]0x2502
        $topLeft = [string][char]0x256d; $topRight = [string][char]0x256e
        $bottomLeft = [string][char]0x2570; $bottomRight = [string][char]0x256f
    }
    Write-WuOutput
    Write-WuOutput -Text ('  ' + $topLeft + ($horizontal * ($width - 4)) + $topRight) -Tone Accent
    foreach ($line in @(Get-WuWrappedText -Text $Title -Width ($width - 8))) {
        Write-WuOutput -Text ('  ' + $vertical + '  ' + $line.PadRight($width - 8) + '  ' + $vertical) -Tone Title
    }
    if ($Subtitle.Length -gt 0) {
        foreach ($line in @(Get-WuWrappedText -Text $Subtitle -Width ($width - 8))) {
            Write-WuOutput -Text ('  ' + $vertical + '  ' + $line.PadRight($width - 8) + '  ' + $vertical) -Tone Muted
        }
    }
    Write-WuOutput -Text ('  ' + $bottomLeft + ($horizontal * ($width - 4)) + $bottomRight) -Tone Accent
    Write-WuOutput
}

function Write-WuOption {
    param([string]$Key, [string]$Label, [string]$Description = '', [string]$Tone = 'Title')
    Write-WuText -Text ('[{0}]  {1}' -f $Key, $Label) -Tone $Tone
    if ($Description.Length -gt 0) { Write-WuText -Text $Description -Tone Muted -Indent 7 }
}

function Write-WuFooter {
    param([string]$Label = 'Back')
    Write-WuText
    Write-WuRule
    Write-WuOption -Key '0' -Label $Label -Tone Muted
}

function Write-WuSelectionSummary {
    param([AllowEmptyCollection()][object[]]$Plan)
    $settingsCount = @($Plan | Where-Object { $_.Kind -eq 'Setting' }).Count
    $appsCount = @($Plan | Where-Object { $_.Kind -eq 'App' }).Count
    Write-WuText -Text "Selected: $(Format-WuCount $settingsCount 'setting'), $(Format-WuCount $appsCount 'app')" -Tone Accent
}

function Format-WuCount {
    param([int]$Count, [string]$Noun)
    if ($Count -ne 1) { $Noun += 's' }
    return "$Count $Noun"
}

function Read-WuInput {
    param([string]$Prompt)
    $value = Read-Host -Prompt $Prompt
    if ($null -eq $value) { throw 'Input ended. Open WinUtility in an interactive PowerShell window.' }
    return $value.Trim()
}

function Read-WuChoice {
    param([string[]]$Options, [string]$Prompt = '  Choose')
    while ($true) {
        $choice = Read-WuInput $Prompt
        if ($Options -contains $choice) { return $choice.ToUpperInvariant() }
        Write-WuText -Text ('Enter one of: {0}.' -f ($Options -join ', ')) -Tone Warning
    }
}

function Wait-WuContinue {
    [void](Read-WuInput '  Press Enter to continue')
}

function Confirm-WuChoice {
    param([string]$Message, [string]$ConfirmLabel = 'Confirm')
    Write-WuText
    Write-WuRule
    Write-WuText -Text $Message -Tone Warning
    Write-WuText
    Write-WuOption -Key '1' -Label $ConfirmLabel -Tone Accent
    Write-WuOption -Key '0' -Label 'Cancel' -Tone Muted
    return (Read-WuChoice @('1', '0')) -eq '1'
}

function Write-WuPlan {
    param([AllowEmptyCollection()][object[]]$Plan, [switch]$Numbered, [object[]]$Review = @())
    if ($Plan.Count -eq 0) {
        Write-WuText -Text 'Nothing selected.' -Tone Accent
        Write-WuText -Text 'Choose a preset or pick individual settings and apps.' -Tone Muted
        return
    }
    $section = ''
    $index = 0
    foreach ($action in $Plan) {
        $index++
        $nextSection = "$($action.Kind)s / $($action.Category)"
        if ($section -ne $nextSection) {
            Write-WuText
            Write-WuText -Text $nextSection -Tone Accent
            Write-WuRule
            $section = $nextSection
        }
        $prefix = '[x]'
        if ($Numbered) { $prefix = "[$index]" }
        Write-WuText -Text "$prefix $($action.Name)" -Tone Title
        Write-WuText -Text $action.Effect -Indent 6
        Write-WuText -Text "Choice: $($action.Value) | From: $($action.Source)" -Tone Muted -Indent 6
        $state = @($Review | Where-Object { $_.Id -ceq $action.Id })
        if ($state.Count -eq 1) {
            Write-WuText -Text "Current: $($state[0].Current) | $($state[0].Status)" -Tone Accent -Indent 6
            Write-WuText -Text $state[0].Message -Tone Muted -Indent 6
        }
        elseif ((Get-WuActionCapability $action) -eq 'PreviewOnly') {
            Write-WuText -Text 'Preview only / not implemented for real execution.' -Tone Warning -Indent 6
        }
        if ($action.Kind -eq 'App') {
            Write-WuText -Text "WinGet: $($action.PackageId)" -Tone Muted -Indent 6
            Write-WuText -Text 'Administrator/restart: depends on installer' -Tone Muted -Indent 6
        }
        else {
            $requirements = @()
            if ($action.RequiresAdmin) { $requirements += 'Administrator required for real action' }
            if ($action.RequiresRestart) { $requirements += 'Restart required for real action' }
            if ($requirements.Count -gt 0) { Write-WuText -Text ($requirements -join ' | ') -Tone Warning -Indent 6 }
        }
    }
}

function Show-WuPresets {
    param($Session)
    while ($true) {
        Write-WuHeading 'Presets | Example laptop setups' '01 / Choose a starting point, then make it yours.'
        $options = @('0')
        for ($i = 0; $i -lt $Session.Catalog.Presets.Count; $i++) {
            $preset = $Session.Catalog.Presets[$i]
            $number = ($i + 1).ToString()
            $options += $number
            $settingCount = @($preset.itemIds | Where-Object { $Session.Catalog.ById[$_].kind -eq 'Setting' }).Count
            $appCount = $preset.itemIds.Count - $settingCount
            Write-WuOption -Key $number -Label "$($preset.name)  /  $(Format-WuCount $settingCount 'setting') + $(Format-WuCount $appCount 'app')" -Description $preset.description
            Write-WuText
        }
        Write-WuText -Text 'Open a preset to preview every selection.' -Tone Muted
        Write-WuFooter
        $choice = Read-WuChoice $options
        if ($choice -eq '0') { return }
        $preset = $Session.Catalog.Presets[[int]$choice - 1]
        $preview = New-WuSession -Catalog $Session.Catalog
        Set-WuPreset -Session $preview -Id $preset.id
        Write-WuHeading "$($preset.name) | Example preset preview" $preset.description
        Write-WuPlan -Plan @(Get-WuPlan -Session $preview)
        if (Confirm-WuChoice -Message "Replace your current $($Session.Selected.Count) selections with this preset? You can adjust it afterward." -ConfirmLabel 'Use this preset') {
            Set-WuPreset -Session $Session -Id $preset.id
            Write-WuText -Text "$($preset.name) selected. Adjust it in Manual changes or App installs." -Tone Success
            return
        }
    }
}

function Show-WuItemPicker {
    param($Session, [AllowEmptyCollection()][object[]]$Items, [string]$Title)
    while ($true) {
        Write-WuHeading $Title 'Enter a number to toggle. [x] selected / [ ] not selected.'
        if ($Items.Count -eq 0) { Write-WuText -Text 'No matching apps.' -Tone Warning }
        $options = @('0')
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $item = $Items[$i]
            $mark = ' '
            if ($Session.Selected.ContainsKey($item.id)) { $mark = 'x' }
            $number = ($i + 1).ToString()
            $options += $number
            $tone = 'Title'
            if ($mark -eq 'x') { $tone = 'Success' }
            Write-WuOption -Key $number -Label "[$mark] $($item.name)" -Description $item.description -Tone $tone
            if ($item.kind -eq 'App') { Write-WuText -Text "WinGet: $($item.packageId)" -Tone Muted -Indent 7 }
            Write-WuText
        }
        $selectedCount = @($Items | Where-Object { $Session.Selected.ContainsKey($_.id) }).Count
        $mode = 'Review before applying'
        if ($script:WuPreviewOnly) { $mode = 'Simulation only' }
        Write-WuText -Text "$selectedCount of $($Items.Count) selected here | $mode" -Tone Accent
        Write-WuFooter
        $choice = Read-WuChoice $options
        if ($choice -eq '0') { return }
        $item = $Items[[int]$choice - 1]
        if ($Session.Selected.ContainsKey($item.id)) {
            Remove-WuSelection -Session $Session -Id $item.id
        }
        else {
            Set-WuSelection -Session $Session -Id $item.id
        }
    }
}

function Show-WuCategories {
    param($Session, [ValidateSet('Settings', 'Apps')][string]$Kind)
    $items = @($Session.Catalog.$Kind)
    $categories = @($items | Select-Object -ExpandProperty category -Unique)
    while ($true) {
        $title = 'Manual changes'
        if ($Kind -eq 'Apps') { $title = 'App installs | WinGet catalog' }
        Write-WuHeading $title '02 / Fine-tune your laptop setup.'
        $options = @('0')
        for ($i = 0; $i -lt $categories.Count; $i++) {
            $category = $categories[$i]
            $group = @($items | Where-Object { $_.category -eq $category })
            $selected = @($group | Where-Object { $Session.Selected.ContainsKey($_.id) }).Count
            $number = ($i + 1).ToString()
            $options += $number
            $bar = ('#' * $selected) + ('.' * ($group.Count - $selected))
            Write-WuOption -Key $number -Label $category -Description "[$bar]  $selected/$($group.Count) selected"
            Write-WuText
        }
        if ($Kind -eq 'Apps') {
            Write-WuOption -Key 'S' -Label 'Search apps by name' -Tone Accent
            $options += 'S'
        }
        Write-WuFooter
        $choice = Read-WuChoice $options
        if ($choice -eq '0') { return }
        if ($choice -eq 'S') {
            $query = Read-WuInput 'Search name (Enter to cancel)'
            if ($query.Length -eq 0) { continue }
            # Literal substring search: characters like [ and * are not patterns.
            $matches = @($items | Where-Object { $_.name.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
            Show-WuItemPicker -Session $Session -Items $matches -Title "App search: $query"
        }
        else {
            $category = $categories[[int]$choice - 1]
            $group = @($items | Where-Object { $_.category -eq $category })
            Show-WuItemPicker -Session $Session -Items $group -Title $category
        }
    }
}

function Show-WuReview {
    param($Session)
    while ($true) {
        $title = 'Review & apply'
        if ($script:WuPreviewOnly) { $title = 'Review & simulate' }
        Write-WuHeading $title '03 / Check your choices before running them.'
        if ($script:WuPreviewOnly) { Write-WuText -Text '[PREVIEW] Simulation only; no Windows changes.' -Tone Warning }
        else { Write-WuText -Text 'Real actions: app installs and the two Explorer settings.' -Tone Accent }
        $plan = @(Get-WuPlan -Session $Session)
        $review = @()
        if (-not $script:WuPreviewOnly -and $plan.Count -gt 0) {
            Write-WuText -Text 'Checking current settings and installed apps...' -Tone Muted
            $review = @(Get-WuExecutionReview -Plan $plan -Environment $script:WuEnvironment)
        }
        Write-WuSelectionSummary -Plan $plan
        Write-WuPlan -Plan $plan -Numbered -Review $review
        Write-WuText
        $options = @('0')
        if ($plan.Count -gt 0) {
            if (-not $script:WuPreviewOnly -and @($review | Where-Object { $_.Status -in @('Ready', 'AlreadyConfigured', 'AlreadyInstalled') }).Count -gt 0) {
                Write-WuOption -Key 'A' -Label 'Apply supported changes' -Tone Accent
                $options += 'A'
            }
            $retryPlan = @()
            if (-not $script:WuPreviewOnly -and $null -ne $Session.LastRun) {
                $retryIds = @($Session.LastRun.Actions | Where-Object { $_.Kind -eq 'App' -and $_.Status -in @('Failed', 'Cancelled') } | ForEach-Object { $_.Id })
                $retryPlan = @($plan | Where-Object { $retryIds -contains $_.Id })
                if ($retryPlan.Count -gt 0) { Write-WuOption -Key 'F' -Label 'Retry failed app installs'; $options += 'F' }
            }
            Write-WuOption -Key 'S' -Label 'Simulate selected changes' -Tone Accent
            Write-WuOption -Key 'R' -Label 'Remove an item'
            Write-WuOption -Key 'C' -Label 'Clear all selections' -Tone Muted
            $options += @('S', 'R', 'C')
        }
        Write-WuFooter
        switch (Read-WuChoice $options) {
            '0' { return }
            'A' { Show-WuApply -Session $Session -Plan $plan }
            'F' { Show-WuApply -Session $Session -Plan $retryPlan }
            'S' {
                Write-WuHeading 'Simulation results' 'Preview complete. Your selections remain available.'
                $results = @(Invoke-WuSimulation -Plan $plan)
                foreach ($result in $results) {
                    Write-WuText -Text "[SIMULATED] $($result.Name)" -Tone Success
                    Write-WuText -Text $result.Message -Indent 6
                    Write-WuText
                }
                Write-WuRule
                Write-WuText -Text "$($results.Count) simulated; 0 changes made. Your selection is still available." -Tone Accent
                Write-WuText -Text 'Simulation does not check existing settings, installed apps, or installer availability.' -Tone Muted
                Wait-WuContinue
            }
            'R' {
                $removeOptions = @('0') + @(1..$plan.Count | ForEach-Object { $_.ToString() })
                $number = Read-WuChoice -Options $removeOptions -Prompt 'Item number to remove (0 to cancel)'
                if ($number -ne '0') { Remove-WuSelection -Session $Session -Id $plan[[int]$number - 1].Id }
            }
            'C' {
                if (Confirm-WuChoice 'Clear all selected settings and apps?' 'Clear selections') {
                    Clear-WuSelection -Session $Session
                }
            }
        }
    }
}

function Write-WuResults {
    param([object[]]$Results)
    foreach ($result in $Results) {
        $tone = 'Success'
        if ($result.Status -in @('Failed', 'Cancelled', 'Conflict', 'RestartRequired', 'Skipped', 'Pending')) { $tone = 'Warning' }
        Write-WuText -Text "[$($result.Status)] $($result.Name)" -Tone $tone
        Write-WuText -Text $result.Message -Indent 6
    }
    if (@($Results | Where-Object { $_.RestartRequired }).Count -gt 0) {
        Write-WuText -Text 'A restart is required. WinUtility does not request an automatic reboot.' -Tone Warning
    }
}

function Show-WuApply {
    param($Session, [object[]]$Plan)
    if ($script:WuPreviewOnly) { return }
    Write-WuHeading 'Apply to this laptop' 'Supported actions only; preview-only entries will be skipped.'
    Write-WuPlan -Plan $Plan
    $hasApps = @($Plan | Where-Object { $_.Kind -eq 'App' }).Count -gt 0
    Write-WuText -Text 'Explorer values are backed up for undo. App installs are not undone by WinUtility.' -Tone Muted
    if ($hasApps) {
        Write-WuText -Text 'Continuing accepts the selected apps'' license terms and WinGet source agreements. Installers may request administrator access.' -Tone Warning
    }
    if (-not (Confirm-WuChoice 'Apply these supported changes to this Windows user and laptop?' 'Apply now')) { return }
    try {
        $Session.LastRun = Invoke-WuApply -Plan $Plan -AcceptAppAgreements:$hasApps -OnProgress { param($Name) Write-WuText -Text "Working: $Name" -Tone Accent }
        Write-WuHeading 'Apply results'
        Write-WuResults -Results $Session.LastRun.Actions
        Write-WuText -Text "History: $($Session.LastRun.Path)" -Tone Muted
    }
    catch { Write-WuText -Text "Run stopped: $($_.Exception.Message) Check History & Explorer undo for any completed or pending actions." -Tone Warning }
    Wait-WuContinue
}

function Show-WuReadiness {
    while ($true) {
        Write-WuHeading 'Machine readiness' 'Read-only checks for this laptop.'
        $environment = $script:WuEnvironment
        Write-WuText -Text $environment.OS -Tone Title
        Write-WuText -Text "Architecture: $($environment.Architecture) | PowerShell: $($environment.PowerShellVersion)"
        Write-WuText -Text "WinGet: $($environment.WinGetVersion)"
        $restart = 'Unknown'
        if ($null -ne $environment.PendingReboot) { $restart = $(if ($environment.PendingReboot) { 'Required' } else { 'Not detected' }) }
        Write-WuText -Text "Pending restart: $restart"
        $power = $environment.PowerStatus
        if ($null -ne $environment.BatteryPercent) { $power += " / $($environment.BatteryPercent)% charge" }
        Write-WuText -Text "Power: $power"
        Write-WuText -Text "Administrator session: $($environment.IsAdmin)"
        if (-not $environment.SupportedOS) { Write-WuText -Text 'Preview only: real execution requires a verified Windows 11 workstation.' -Tone Warning }
        foreach ($warning in $environment.Warnings) { Write-WuText -Text $warning -Tone Warning }
        Write-WuOption -Key 'R' -Label 'Refresh checks' -Tone Accent
        Write-WuFooter
        if ((Read-WuChoice @('R', '0')) -eq '0') { return }
        $script:WuEnvironment = Get-WuEnvironment
        # Refresh can disable real execution; enabling it again requires a fresh launch.
        $script:WuPreviewOnly = $script:WuPreviewOnly -or -not $script:WuEnvironment.SupportedOS
    }
}

function Show-WuHistory {
    if ($script:WuPreviewOnly) { return }
    while ($true) {
        Write-WuHeading 'History & Explorer undo' 'Saved locally for this Windows user and computer.'
        try { $runs = @(Get-WuHistory) }
        catch { Write-WuText -Text $_.Exception.Message -Tone Warning; Wait-WuContinue; return }
        if ($runs.Count -eq 0) { Write-WuText -Text 'No runs recorded yet.' -Tone Muted }
        $options = @('0')
        for ($i = 0; $i -lt $runs.Count; $i++) {
            $number = ($i + 1).ToString()
            $options += $number
            Write-WuOption -Key $number -Label "$($runs[$i].StartedAtUtc) / $($runs[$i].Status)" -Description "$($runs[$i].Actions.Count) actions"
        }
        Write-WuFooter
        $choice = Read-WuChoice $options
        if ($choice -eq '0') { return }
        $run = $runs[[int]$choice - 1]
        Write-WuHeading 'Run details' $run.StartedAtUtc
        Write-WuText -Text "History file: $($run.Path)" -Tone Muted
        if ($null -ne $run.Error) { Write-WuText -Text $run.Error -Tone Warning; Wait-WuContinue; continue }
        Write-WuResults -Results $run.Actions
        if ($run.Status -eq 'Running') { Write-WuText -Text 'This run may have been interrupted. Pending results do not mean success.' -Tone Warning }
        $undoable = @($run.Actions | Where-Object { $_.Kind -eq 'Setting' -and $null -ne $_.Before -and $null -ne $_.After -and $_.Status -ne 'AlreadyConfigured' })
        if ($undoable.Count -gt 0) {
            Write-WuText -Text 'Undo restores Explorer values only. App installations stay installed.' -Tone Muted
            if (Confirm-WuChoice 'Restore this run''s original Explorer values? Newer, conflicting values will be left alone.' 'Undo Explorer changes') {
                try { Write-WuResults -Results @(Undo-WuExplorerRun -Path $run.Path) }
                catch { Write-WuText -Text "Undo stopped: $($_.Exception.Message)" -Tone Warning }
            }
        }
        Wait-WuContinue
    }
}

function Read-WuFilePath {
    param([string]$Prompt)
    $path = Read-WuInput $Prompt
    # Accept paths copied with surrounding quotes, without evaluating their contents.
    if ($path.Length -ge 2 -and (($path.StartsWith('"') -and $path.EndsWith('"')) -or
        ($path.StartsWith("'") -and $path.EndsWith("'")))) {
        $path = $path.Substring(1, $path.Length - 2)
    }
    return $path
}

function Write-WuRepairSummary {
    param($Run)
    Write-WuHeading "Repair report | $($Run.Report.Status)" 'Command results and next steps'
    foreach ($step in $Run.Report.Steps) {
        $tone = 'Accent'
        if ($step.Status -ne 'Completed') { $tone = 'Warning' }
        Write-WuText -Text "[$($step.Status)] $($step.Name)" -Tone $tone
        Write-WuText -Text $step.Message -Indent 6
        if ($null -ne $step.ExitCode) { Write-WuText -Text "Exit: $($step.ExitCode) | Time: $($step.DurationSeconds)s" -Tone Muted -Indent 6 }
    }
    Write-WuText -Text "Saved report and command output: $(Split-Path $Run.Path -Parent)" -Tone Muted
    Write-WuText -Text 'Completed commands do not guarantee that Windows is healthy. Read the tool summaries; repairs cannot be undone through Explorer history.' -Tone Muted
    foreach ($nativeLog in $Run.Report.NativeLogs) { Write-WuText -Text $nativeLog -Tone Muted }
    if ($Run.Report.Status -eq 'Running') { Write-WuText -Text 'This report is incomplete. A repair may still be running or have been interrupted.' -Tone Warning }
}

function Show-WuRepairReport {
    param($Run)
    Write-WuRepairSummary $Run
    while ($true) {
        Write-WuOption -Key 'O' -Label 'Show the end of each command log' -Tone Accent
        Write-WuFooter
        if ((Read-WuChoice @('O', '0')) -eq '0') { return }
        foreach ($step in $Run.Report.Steps) {
            Write-WuText -Text $step.Name -Tone Accent
            try {
                $path = Join-Path (Split-Path $Run.Path -Parent) $step.LogFile
                if (-not [IO.File]::Exists($path)) { Write-WuText -Text 'No command output was recorded.' -Tone Muted; continue }
                # Progress often uses carriage returns, so split those as well as newlines.
                $lines = @([IO.File]::ReadAllText($path) -split '[\r\n]+' | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -Last 12)
                foreach ($line in $lines) { Write-WuText -Text $line -Indent 6 }
                Write-WuText -Text "Full output: $path" -Tone Muted
            }
            catch { Write-WuText -Text "Could not read log: $($_.Exception.Message)" -Tone Warning }
        }
    }
}

function Show-WuRepairHistory {
    while ($true) {
        Write-WuHeading 'Repair reports' 'Saved command output, timings and next steps'
        try { $runs = @(Get-WuRepairHistory) }
        catch { Write-WuText -Text $_.Exception.Message -Tone Warning; Wait-WuContinue; return }
        $options = @('0')
        if ($runs.Count -eq 0) { Write-WuText -Text 'No repair reports yet.' -Tone Muted }
        for ($i = 0; $i -lt $runs.Count; $i++) {
            $number = ($i + 1).ToString(); $options += $number
            $label = 'Unreadable report'
            if ($null -eq $runs[$i].Error) { $label = "$($runs[$i].Report.StartedAtUtc) | $($runs[$i].Report.RepairId) | $($runs[$i].Report.Status)" }
            Write-WuOption -Key $number -Label $label
        }
        Write-WuFooter
        $choice = Read-WuChoice $options
        if ($choice -eq '0') { return }
        $run = $runs[[int]$choice - 1]
        if ($null -ne $run.Error) { Write-WuText -Text $run.Error -Tone Warning; Wait-WuContinue }
        else { Show-WuRepairReport $run }
    }
}

function Show-WuRepairAction {
    param($Action)
    $sourcePath = ''; $sourceIndex = 0
    try {
        $environment = Get-WuRepairEnvironment
        Write-WuHeading $Action.Name $Action.Description
        if ($Action.Id -in @('source.info', 'dism.source')) {
            Write-WuText -Text 'Use a local install.wim from mounted Windows media or a serviced image. Choose the matching release, architecture, edition, language and a sufficiently updated source.'
            Write-WuText -Text 'Use List WIM image indexes first to identify the correct edition. ISO/ESD files are not accepted here.' -Tone Muted
            $sourcePath = Read-WuFilePath '  WIM path, e.g. E:\sources\install.wim (0 to cancel)'
            if ($sourcePath -eq '0' -or $sourcePath.Length -eq 0) { return }
            if ($Action.Id -eq 'dism.source') {
                $indexText = Read-WuInput '  Matching image index (0 to cancel)'
                if ($indexText -eq '0') { return }
                if (-not [int]::TryParse($indexText, [ref]$sourceIndex) -or $sourceIndex -lt 1) { throw 'Enter a positive image index from the WIM information.' }
            }
        }
        $plan = @(Get-WuRepairPlan -Id $Action.Id -SystemDrive $environment.SystemDrive -SourcePath $sourcePath -SourceIndex $sourceIndex)
        if ($script:WuPreviewOnly) { Write-WuText -Text 'PREVIEW ONLY. No repair commands will run. On Linux, C: is an example; Windows detects its actual system drive.' -Tone Warning }
        else {
            Write-WuText -Text "Windows drive: $($environment.SystemDrive) | $($environment.FileSystem) | Power: $($environment.Readiness.PowerStatus)" -Tone Muted
        }
        for ($i = 0; $i -lt $plan.Count; $i++) {
            $step = $plan[$i]
            Write-WuText -Text "$($i + 1). $($step.Name)" -Tone Title
            $displayArgs = @($step.Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
            Write-WuText -Text ($step.Tool + ' ' + ($displayArgs -join ' ')) -Tone Accent -Indent 6
        }
        Write-WuText
        if ($Action.Id -eq 'full') {
            Write-WuText -Text 'Allow time for all five steps. A disk problem, command failure or required restart stops later steps. Run again after resolving the reported issue.'
        }
        if (@($plan | Where-Object { $_.Interactive }).Count -gt 0) {
            Write-WuText -Text 'Back up important files first. CHKDSK will ask whether to schedule a check at the next restart if it cannot lock the drive. Answer its prompt in your Windows language. WinUtility will not answer or restart for you.' -Tone Warning
        }
        elseif ($Action.Id -ne 'source.info') {
            Write-WuText -Text 'Keep the laptop plugged in and let each tool finish. DISM repair may need internet access; repair progress can pause for several minutes.' -Tone Muted
        }
        if ($script:WuPreviewOnly) { Wait-WuContinue; return }
        $blockers = @(Get-WuRepairBlockers -Plan $plan -Environment $environment)
        if ($blockers.Count -gt 0) {
            foreach ($blocker in $blockers) { Write-WuText -Text $blocker -Tone Warning }
            if (-not $environment.Readiness.IsAdmin) { Write-WuText -Text 'Use [A] on the Repair menu to open an administrator window.' -Tone Accent }
            Wait-WuContinue; return
        }
        if (-not (Confirm-WuChoice 'Run the commands shown above on this Windows installation?' 'Run repair tools')) { return }
        $run = Invoke-WuRepair -Id $Action.Id -SourcePath $sourcePath -SourceIndex $sourceIndex -Confirmed -OnProgress {
            param($Name, $Number, $Total)
            Write-WuHeading "Repair $Number / $Total" $Name
        }
        Show-WuRepairReport $run
    }
    catch { Write-WuText -Text "Repair stopped: $($_.Exception.Message) Check Repair reports for any work already started." -Tone Warning; Wait-WuContinue }
}

function Show-WuRepairMenu {
    param([switch]$Advanced)
    while ($true) {
        $group = 'Main'; $title = 'Repair Windows'
        if ($Advanced) { $group = 'Advanced'; $title = 'Advanced recovery tools' }
        Write-WuHeading $title 'Diagnose, repair, verify. Every run has its own report.'
        if ($script:WuPreviewOnly) { Write-WuText -Text 'PREVIEW ONLY / explore the commands and workflow.' -Tone Warning }
        $actions = @(Get-WuRepairCatalog | Where-Object { $_.Group -eq $group })
        $options = @('0')
        for ($i = 0; $i -lt $actions.Count; $i++) {
            $number = ($i + 1).ToString(); $options += $number
            $description = ''
            if (-not (Test-WuCompactDisplay)) { $description = $actions[$i].Description }
            Write-WuOption -Key $number -Label $actions[$i].Name -Description $description
        }
        if (-not $Advanced) {
            Write-WuOption -Key '8' -Label 'Advanced recovery tools' -Description 'Boot-time disk checks and repair from Windows media.'
            $options += '8'
        }
        else {
            Write-WuText -Text 'If corruption persists: inspect DISM/CBS logs, try a matching repair source, then consider a Windows repair reinstall. Boot failures need Windows Recovery Environment.' -Tone Muted
        }
        if (-not $script:WuPreviewOnly) {
            Write-WuOption -Key 'L' -Label 'Repair reports' -Tone Muted; $options += 'L'
            if (-not $script:WuEnvironment.IsAdmin) { Write-WuOption -Key 'A' -Label 'Open repair menu as administrator' -Tone Accent; $options += 'A' }
        }
        Write-WuFooter
        $choice = Read-WuChoice $options
        switch ($choice) {
            '0' { return }
            '8' { Show-WuRepairMenu -Advanced }
            'L' { Show-WuRepairHistory }
            'A' {
                try { Open-WuRepairAsAdministrator -Plain:$script:WuPlain }
                catch { Write-WuText -Text "Administrator window was not opened: $($_.Exception.Message)" -Tone Warning; Wait-WuContinue }
            }
            default { Show-WuRepairAction $actions[[int]$choice - 1] }
        }
    }
}

function Save-WuInteractive {
    param($Session)
    $defaultPath = $Session.SavedPath
    if ([string]::IsNullOrWhiteSpace($defaultPath)) { $defaultPath = Get-WuDefaultSetupPath }
    Write-WuText -Text "Default: $defaultPath" -Tone Muted
    $path = Read-WuFilePath 'Save JSON path (Enter for default, 0 to cancel)'
    if ($path -eq '0') { return $false }
    if ($path.Length -eq 0) { $path = $defaultPath }
    try {
        $overwrite = $false
        if (Test-Path -LiteralPath $path) {
            if (-not (Confirm-WuChoice "Replace the existing file '$path'?" 'Replace file')) { return $false }
            $overwrite = $true
        }
        $savedPath = Export-WuSetup -Session $Session -Path $path -Overwrite:$overwrite
        Write-WuText -Text "Saved setup: $savedPath" -Tone Success
        return $true
    }
    catch {
        Write-WuText -Text "Setup was not saved: $($_.Exception.Message)" -Tone Warning
        return $false
    }
}

function Show-WuSavedSetups {
    param($Session)
    while ($true) {
        Write-WuHeading 'Saved setups' 'Your choices, ready for the next laptop.'
        Write-WuSelectionSummary -Plan @(Get-WuPlan -Session $Session)
        Write-WuText
        Write-WuOption -Key '1' -Label 'Export current selection' -Description 'Save your settings and app choices to a JSON file.'
        Write-WuText
        Write-WuOption -Key '2' -Label 'Import a saved setup' -Description 'Preview a saved file, then load its selections.'
        Write-WuFooter
        switch (Read-WuChoice @('1', '2', '0')) {
            '0' { return }
            '1' { [void](Save-WuInteractive -Session $Session) }
            '2' {
                $path = Read-WuFilePath 'JSON file to import (Enter or 0 to cancel)'
                if ($path.Length -eq 0 -or $path -eq '0') { continue }
                try {
                    $preview = Import-WuSetup -Catalog $Session.Catalog -Path $path
                    Write-WuHeading 'Saved setup preview'
                    Write-WuPlan -Plan @(Get-WuPlan -Session $preview)
                    if (Confirm-WuChoice "Replace your current $($Session.Selected.Count) selections with this saved setup?" 'Use saved setup') {
                        Set-WuImportedSetup -Session $Session -Preview $preview
                        Write-WuText -Text 'Saved setup loaded. You can adjust any selection.' -Tone Success
                    }
                }
                catch { Write-WuText -Text "Setup was not loaded: $($_.Exception.Message)" -Tone Warning }
            }
        }
    }
}

function Start-WuTerminal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Environment, [switch]$Plain, [switch]$Preview, [switch]$Repair)
    Initialize-WuAppearance -Plain:$Plain
    $script:WuEnvironment = $Environment
    $script:WuPreviewOnly = $Preview -or -not $Environment.SupportedOS
    if ($Repair) { Show-WuRepairMenu; return }
    while ($true) {
        $Environment = $script:WuEnvironment
        $compact = Test-WuCompactDisplay
        $subtitle = 'A fresh start. A setup that feels like yours.'
        if ($compact) { $subtitle = '' }
        Write-WuHeading 'WINUTILITY / LAPTOP SETUP' $subtitle
        if ($script:WuPreviewOnly) { Write-WuText -Text '[PREVIEW MODE] All actions are simulated.' -Tone Warning }
        else { Write-WuText -Text '[WINDOWS MODE] Review and confirm before applying.' -Tone Accent }
        if (-not $compact) { Write-WuText }
        $wingetStatus = 'not available (simulation still works)'
        if ($Environment.WinGetAvailable) { $wingetStatus = 'available' }
        Write-WuText -Text "$($Environment.OS) | PowerShell $($Environment.PowerShellVersion)" -Tone Muted
        Write-WuText -Text "WinGet: $wingetStatus" -Tone Muted
        if (-not $Environment.SupportedOS) {
            Write-WuText -Text 'Target: Windows 11. You can explore this prototype on this host.' -Tone Muted
        }
        $plan = @(Get-WuPlan -Session $Session)
        $reviewLabel = "Review & apply ($($plan.Count))"
        if ($script:WuPreviewOnly) { $reviewLabel = "Review & simulate ($($plan.Count))" }
        if (-not $compact) { Write-WuText }
        Write-WuSelectionSummary -Plan $plan
        $saveStatus = 'No unsaved changes'
        if (Test-WuUnsavedChanges -Session $Session) { $saveStatus = 'Unsaved choices / export to keep them' }
        Write-WuText -Text $saveStatus -Tone Muted
        if (-not $compact) { Write-WuText; Write-WuRule }
        if (-not $compact) { Write-WuText -Text 'CHOOSE  >  CUSTOMIZE  >  REVIEW' -Tone Accent; Write-WuText }
        $menu = @(
            @('1', 'Presets', 'Minimal, Balanced or Full. Start with a complete setup.'),
            @('2', 'Manual changes', 'Privacy, Explorer, power and Windows features.'),
            @('3', 'App installs', 'Browse the catalog or find an app by name.'),
            @('4', $reviewLabel, 'Inspect your choices, simulate or apply supported actions.'),
            @('5', 'Saved setups', 'Save this setup or bring one from another laptop.'),
            @('6', 'Repair Windows', 'Full repair, DISM, SFC, disk checks and recovery tools.')
        )
        foreach ($item in $menu) {
            $description = ''
            $tone = 'Title'
            if (-not $compact) { $description = $item[2] }
            if ($item[0] -eq '4') { $tone = 'Accent' }
            Write-WuOption -Key $item[0] -Label $item[1] -Description $description -Tone $tone
            if (-not $compact -and $item[0] -ne '6') { Write-WuText }
        }
        Write-WuOption -Key 'I' -Label 'Machine readiness' -Tone Muted
        $options = @('1', '2', '3', '4', '5', '6', 'I', '0')
        if (-not $script:WuPreviewOnly) { Write-WuOption -Key 'H' -Label 'History & Explorer undo' -Tone Muted; $options += 'H' }
        Write-WuFooter -Label 'Exit'
        switch (Read-WuChoice $options) {
            '1' { Show-WuPresets -Session $Session }
            '2' { Show-WuCategories -Session $Session -Kind Settings }
            '3' { Show-WuCategories -Session $Session -Kind Apps }
            '4' { Show-WuReview -Session $Session }
            '5' { Show-WuSavedSetups -Session $Session }
            '6' { Show-WuRepairMenu }
            'I' { Show-WuReadiness }
            'H' { Show-WuHistory }
            '0' {
                if (Test-WuUnsavedChanges -Session $Session) {
                    Write-WuHeading 'Unsaved selections' 'Keep this setup for another time?'
                    Write-WuOption -Key '1' -Label 'Save and exit' -Tone Accent
                    Write-WuOption -Key '2' -Label 'Discard and exit'
                    Write-WuFooter -Label 'Cancel'
                    $exitChoice = Read-WuChoice @('1', '2', '0')
                    if ($exitChoice -eq '0') { continue }
                    if ($exitChoice -eq '1' -and -not (Save-WuInteractive -Session $Session)) { continue }
                }
                Write-WuText -Text 'Goodbye. Your saved setups and run history remain available.' -Tone Muted
                return
            }
        }
    }
}

Export-ModuleMember -Function Start-WuTerminal
