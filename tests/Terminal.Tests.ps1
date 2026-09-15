function Invoke-TerminalScenario {
    param([string[]]$Answers, $Session, [int]$Width = 78, [int]$Height = 50, [switch]$Plain, [switch]$LiveFixture, [switch]$AdminFixture, [switch]$RepairOnly)
    if ($null -eq $Session) { $Session = New-WuSession -Catalog $script:Catalog }
    $module = Import-Module (Join-Path $script:RepoRoot 'src/WinUtility.Terminal.psm1') -Force -PassThru
    try {
        return (& $module {
            param($Inputs, $ActiveSession, $DisplayWidth, $DisplayHeight, $PlainMode, $LiveMode, $AdminMode, $RepairMode)
            $script:WuWidthOverride = $DisplayWidth
            $script:WuHeightOverride = $DisplayHeight
            $script:Answers = New-Object System.Collections.Queue
            foreach ($answer in $Inputs) { $script:Answers.Enqueue($answer) }
            $script:OutputLines = New-Object 'System.Collections.Generic.List[string]'
            $script:ColorCalls = 0
            function script:Read-Host {
                param($Prompt)
                if ($script:Answers.Count -eq 0) { throw "Test input exhausted at: $Prompt" }
                return $script:Answers.Dequeue()
            }
            function script:Write-Host {
                param($Object, $ForegroundColor, $BackgroundColor, [switch]$NoNewline, $Separator = ' ')
                $script:OutputLines.Add([string]($Object -join $Separator))
                if ($PSBoundParameters.ContainsKey('ForegroundColor')) { $script:ColorCalls++ }
            }
            $script:UiApplyCalls = New-Object System.Collections.ArrayList
            $script:UiUndoCalls = 0
            $script:UiRepairCalls = New-Object System.Collections.ArrayList
            $script:UiElevationCalls = 0
            $environment = [pscustomobject]@{
                OS = 'Windows 11'; PowerShellVersion = '5.1'; WinGetAvailable = $false; SupportedOS = $true
                Architecture = 'X64'; WinGetVersion = 'Unavailable'; PendingReboot = $null
                PowerStatus = 'On battery'; BatteryPercent = 40; IsAdmin = [bool]$AdminMode; Warnings = @()
            }
            $script:UiEnvironment = $environment
            function script:Get-WuEnvironment { return $script:UiEnvironment }
            function script:Get-WuRepairEnvironment {
                return [pscustomobject]@{ Readiness = $script:UiEnvironment; SystemDrive = 'W:'; FileSystem = 'NTFS' }
            }
            function script:Open-WuRepairAsAdministrator { param([switch]$Plain) $script:UiElevationCalls++ }
            function script:Get-WuRepairHistory {
                return [pscustomobject]@{
                    Path = 'fixture-repair/report.json'; Error = $null
                    Report = [pscustomobject]@{
                        Status = 'Completed'; StartedAtUtc = '2026-09-15T12:00:00Z'; RepairId = 'full'; NativeLogs = @('CBS.log')
                        Steps = @([pscustomobject]@{ Id = 'dism.restore'; Name = 'DISM repair'; Status = 'Completed'; Message = 'Fixture command completed'; ExitCode = 0; DurationSeconds = 1; LogFile = 'dism.restore.log' })
                    }
                }
            }
            function script:Invoke-WuRepair {
                param($Id, $SourcePath, $SourceIndex, [switch]$Confirmed, $OnProgress)
                if (-not $Confirmed) { throw 'Missing repair confirmation.' }
                [void]$script:UiRepairCalls.Add([pscustomobject]@{ Id = $Id; SourcePath = $SourcePath; SourceIndex = $SourceIndex })
                return Get-WuRepairHistory
            }
            if ($LiveMode) {
                function script:Get-WuExecutionReview {
                    param($Plan, $Environment)
                    foreach ($item in $Plan) {
                        [pscustomobject]@{ Id = $item.Id; Status = 'Ready'; Current = 'Fixture state'; Message = 'Fixture review'; Capability = 'Fixture' }
                    }
                }
                function script:Invoke-WuApply {
                    param($Plan, [switch]$AcceptAppAgreements, $OnProgress)
                    [void]$script:UiApplyCalls.Add(@($Plan | ForEach-Object { $_.Id }))
                    $results = @(
                        foreach ($item in $Plan) {
                            $status = 'Applied'
                            if ($item.Kind -eq 'App') {
                                if (-not $AcceptAppAgreements) { throw 'Missing app agreement confirmation.' }
                                $status = 'Installed'
                                if ($script:UiApplyCalls.Count -eq 1) { $status = 'Failed' }
                            }
                            [pscustomobject]@{ Id = $item.Id; Name = $item.Name; Kind = $item.Kind; Status = $status; Message = 'Fixture result'; RestartRequired = $false }
                        }
                    )
                    return [pscustomobject]@{ Path = 'fixture-history.json'; Actions = $results }
                }
                function script:Get-WuHistory {
                    return [pscustomobject]@{
                        Path = 'fixture-history.json'; StartedAtUtc = '2026-09-15T12:00:00Z'; Status = 'Completed'; Error = $null
                        Actions = @([pscustomobject]@{ Id = 'explorer.extensions'; Name = 'Show file extensions'; Kind = 'Setting'; Status = 'Applied'; Message = 'Fixture result'; RestartRequired = $false; Before = 1; After = 0 })
                    }
                }
                function script:Undo-WuExplorerRun {
                    param($Path)
                    $script:UiUndoCalls++
                    return [pscustomobject]@{ Name = 'Show file extensions'; Status = 'Restored'; Message = 'Fixture restoration'; RestartRequired = $false }
                }
            }
            Start-WuTerminal -Session $ActiveSession -Environment $environment -Plain:$PlainMode -Preview:(-not $LiveMode) -Repair:$RepairMode
            if ($script:Answers.Count -ne 0) { throw "Unused test inputs: $($script:Answers.Count)" }
            return [pscustomobject]@{ Text = $script:OutputLines -join "`n"; Session = $ActiveSession; ColorCalls = $script:ColorCalls; ApplyCalls = $script:UiApplyCalls; UndoCalls = $script:UiUndoCalls; RepairCalls = $script:UiRepairCalls; ElevationCalls = $script:UiElevationCalls }
        } $Answers $Session $Width $Height $Plain $LiveFixture $AdminFixture $RepairOnly)
    }
    finally { Remove-Module -ModuleInfo $module -Force }
}

Test-Case 'Menus tolerate invalid input, empty review, back navigation, and missing WinGet' {
    $result = Invoke-TerminalScenario -Answers @('oops', '', '4', '0', '1', '0', '2', '0', '3', '0', '5', '0', '0')
    Assert-True ($result.Text.Contains('Enter one of:'))
    Assert-True ($result.Text.Contains('Nothing selected.'))
    Assert-True ($result.Text.Contains('not available (simulation still works)'))
    Assert-True (-not $result.Text.Contains('Unsaved selections'))
    Assert-Equal 0 $result.Session.Selected.Count
}

Test-Case 'Preset preview cancellation preserves selections' {
    $session = New-WuSession -Catalog $script:Catalog
    Set-WuSelection -Session $session -Id 'power.balanced'
    $result = Invoke-TerminalScenario -Session $session -Answers @('1', '3', '0', '0', '0', '2')
    Assert-True ($result.Text.Contains('Full | Example preset preview'))
    Assert-Equal @('power.balanced') @($result.Session.Selected.Keys)
}

Test-Case 'Preset, manual toggle, app search, simulation, and cancelled exit form one flow' {
    $answers = @(
        '1', '1', '1',                # Minimal, confirm.
        '2', '2', '1', '1', '0', '0', # Toggle extensions off, then back on.
        '3', 's', 'fireFOX', '1', '0', '0',
        '4', 's', '', 'r', '4', '0', # Simulate four actions, then remove item four.
        '0', '0',                   # Cancel exit.
        '0', '2'                    # Discard and exit.
    )
    $result = Invoke-TerminalScenario -Answers $answers
    Assert-True ($result.Text.Contains('Selected: 2 settings, 2 apps'))
    Assert-True ($result.Text.Contains('4 simulated; 0 changes made.'))
    Assert-True ($result.Text.Contains('From: Manual'))
    Assert-True ($result.Text.Contains('From: Preset: Minimal'))
    Assert-Equal 3 $result.Session.Selected.Count
}

Test-Case 'Search is literal, no matches and empty queries allow returning' {
    $result = Invoke-TerminalScenario -Answers @('3', 's', '[', '0', 's', '', '0', '0')
    Assert-True ($result.Text.Contains('No matching apps.'))
    Assert-Equal 0 $result.Session.Selected.Count
}

Test-Case 'All manual and app categories open and return without changing state' {
    $answers = @('2')
    foreach ($number in @('1', '2', '3', '4')) { $answers += @($number, '0') }
    $answers += @('0', '3')
    foreach ($number in @('1', '2', '3', '4')) { $answers += @($number, '0') }
    $answers += @('0', '0')
    $result = Invoke-TerminalScenario -Answers $answers
    Assert-True ($result.Text.Contains('Remove Microsoft Solitaire Collection'))
    Assert-True ($result.Text.Contains('Visual Studio Code'))
    Assert-Equal 0 $result.Session.Selected.Count
}

Test-Case 'Clearing requires confirmation and restores an initially empty session' {
    $result = Invoke-TerminalScenario -Answers @('1', '1', '1', '4', 'c', '0', 'c', '1', '0', '0')
    Assert-Equal 0 $result.Session.Selected.Count
    Assert-True (-not (Test-WuUnsavedChanges -Session $result.Session))
}

Test-Case 'Save-on-exit writes to a path with spaces and exits cleanly' {
    $path = Join-Path $script:TestRoot 'saved through UI.json'
    $result = Invoke-TerminalScenario -Answers @('1', '2', '1', '0', '1', "`"$path`"")
    Assert-True ($result.Text.Contains('Saved setup:'))
    Assert-Equal 6 (Import-WuSetup -Catalog $script:Catalog -Path $path).Selected.Count
    Assert-True (-not (Test-WuUnsavedChanges -Session $result.Session))
}

Test-Case 'Failed or cancelled saves keep the menu and unsaved selections available' {
    $directory = Join-Path $script:TestRoot 'destination directory'
    [void][IO.Directory]::CreateDirectory($directory)
    $result = Invoke-TerminalScenario -Answers @('1', '1', '1', '0', '1', '0', '0', '1', $directory, '1', '0', '2')
    Assert-True ($result.Text.Contains('Setup was not saved:'))
    Assert-Equal 3 $result.Session.Selected.Count
    Assert-True (Test-WuUnsavedChanges -Session $result.Session)
}

Test-Case 'Saved setup preview can be cancelled, imported, and exported from its menu' {
    $source = Join-Path $script:TestRoot 'import source.json'
    $destination = Join-Path $script:TestRoot 'export destination.json'
    $session = New-WuSession -Catalog $script:Catalog
    Set-WuPreset -Session $session -Id full
    Export-WuSetup -Session $session -Path $source | Out-Null
    $result = Invoke-TerminalScenario -Answers @('5', '2', $source, '0', '2', $source, '1', '1', $destination, '0', '0')
    Assert-Equal 8 $result.Session.Selected.Count
    Assert-True ($result.Text.Contains('Saved setup preview'))
    Assert-Equal 8 (Import-WuSetup -Catalog $script:Catalog -Path $destination).Selected.Count
}

Test-Case 'An invalid import reports the problem and preserves an existing selection' {
    $path = Join-Path $script:TestRoot 'invalid ui setup.json'
    [IO.File]::WriteAllText($path, '{"schemaVersion":99,"selections":[]}')
    $result = Invoke-TerminalScenario -Answers @('1', '1', '1', '5', '2', $path, '0', '0', '2')
    Assert-Equal 3 $result.Session.Selected.Count
    Assert-True ($result.Text.Contains('Setup was not loaded:'))
}

Test-Case 'Plain mode preserves navigation without colors or Unicode decorations' {
    $result = Invoke-TerminalScenario -Answers @('1', '1', '1', '4', 's', '', '0', '0', '2') -Plain
    Assert-Equal 0 $result.ColorCalls
    Assert-True (-not ($result.Text -match '[^\x00-\x7f]'))
    Assert-True ($result.Text.Contains('[SIMULATED]'))
    Assert-Equal 3 $result.Session.Selected.Count
}

Test-Case 'Narrow terminal output wraps without losing selections or overflowing lines' {
    $result = Invoke-TerminalScenario -Answers @('1', '3', '1', '4', '0', '3', 's', ('z' * 100), '0', '0', '0', '2') -Width 40 -Plain
    foreach ($line in ($result.Text -split "`n")) {
        Assert-True ($line.Length -le 40) "Line exceeds terminal width: $line"
    }
    Assert-Equal 8 $result.Session.Selected.Count
    Assert-True ($result.Text.Contains('No matching apps.'))
}

Test-Case 'Compact home screen keeps every action visible in a 24-row terminal' {
    $result = Invoke-TerminalScenario -Answers @('0') -Height 24 -Plain
    $homeScreen = $result.Text.Substring(0, $result.Text.IndexOf('Goodbye.'))
    Assert-True (@($homeScreen -split "`n").Count -le 24)
    foreach ($label in @('Presets', 'Manual changes', 'App installs', 'Review & simulate', 'Saved setups', 'Repair Windows', 'Exit')) {
        Assert-True ($homeScreen.Contains($label))
    }
}

Test-Case 'Readiness can be viewed and refreshed without applying anything' {
    $result = Invoke-TerminalScenario -Answers @('i', 'r', '0', '0')
    Assert-True ($result.Text.Contains('Pending restart: Unknown'))
    Assert-True ($result.Text.Contains('Power: On battery / 40% charge'))
    Assert-Equal 0 $result.ApplyCalls.Count
}

Test-Case 'Preview mode never offers apply or undo controls' {
    $result = Invoke-TerminalScenario -Answers @('1', '1', '1', '4', '0', '0', '2')
    Assert-True (-not $result.Text.Contains('[A]'))
    Assert-True (-not $result.Text.Contains('[H]'))
    Assert-Equal 0 $result.ApplyCalls.Count
}

Test-Case 'Windows apply cancellation changes nothing and confirmed retry contains only failed apps' {
    $result = Invoke-TerminalScenario -LiveFixture -Answers @('1', '1', '1', '4', 'a', '0', 'a', '1', '', 'f', '1', '', '0', '0', '2')
    Assert-Equal 2 $result.ApplyCalls.Count
    Assert-Equal 3 $result.ApplyCalls[0].Count
    Assert-Equal @('app.7zip') $result.ApplyCalls[1]
    Assert-True ($result.Text.Contains('[WINDOWS MODE]'))
    Assert-True ($result.Text.Contains('Retry failed app installs'))
    Assert-True ($result.Text.Contains('History: fixture-history.json'))
}

Test-Case 'History undo requires confirmation before invoking restoration' {
    $result = Invoke-TerminalScenario -LiveFixture -Answers @('h', '1', '0', '', '1', '1', '', '0', '0')
    Assert-Equal 1 $result.UndoCalls
    Assert-True ($result.Text.Contains('[Restored] Show file extensions'))
    Assert-True ($result.Text.Contains('App installations stay installed.'))
}

Test-Case 'Repair preview explores full, disk and media tools without repairs or elevation' {
    $result = Invoke-TerminalScenario -Answers @('6', '1', '', '7', '', '8', '1', '', '2', '', '3', 'E:\Windows media\install.wim', '', '4', 'E:\install.wim', '6', '', '0', '0', '0')
    Assert-Equal 0 $result.RepairCalls.Count
    Assert-Equal 0 $result.ElevationCalls
    Assert-True ($result.Text.Contains('PREVIEW ONLY'))
    Assert-True ($result.Text.Contains('sfc.exe /scannow'))
    Assert-True ($result.Text.Contains('chkdsk.exe W: /r'))
    Assert-True ($result.Text.Contains('/Source:WIM:E:\install.wim:6'))
    Assert-True (-not $result.Text.Contains('Run repair tools'))
    Assert-True (-not $result.Text.Contains('[A]'))
    Assert-Equal 0 $result.Session.Selected.Count
}

Test-Case 'Full repair cancellation invokes nothing and confirmation starts exactly one independent repair' {
    $result = Invoke-TerminalScenario -LiveFixture -AdminFixture -Answers @('6', '1', '0', '1', '1', '0', '0', '0')
    Assert-Equal 1 $result.RepairCalls.Count
    Assert-Equal 'full' $result.RepairCalls[0].Id
    Assert-Equal 0 $result.Session.Selected.Count
    Assert-True ($result.Text.Contains('Repair report | Completed'))
    Assert-True (-not $result.Text.Contains('Unsaved selections'))
}

Test-Case 'Unelevated repairs show the administrator action without starting any commands' {
    $result = Invoke-TerminalScenario -LiveFixture -Answers @('6', '1', '', 'a', '0', '0')
    Assert-Equal 0 $result.RepairCalls.Count
    Assert-Equal 1 $result.ElevationCalls
    Assert-True ($result.Text.Contains('Open repair menu as administrator'))
    Assert-True (-not $result.Text.Contains('Run repair tools'))
}

Test-Case 'Repair reports can be revisited without rerunning commands' {
    $result = Invoke-TerminalScenario -LiveFixture -AdminFixture -Answers @('6', 'l', '1', 'o', '0', '0', '0', '0')
    Assert-Equal 0 $result.RepairCalls.Count
    Assert-True ($result.Text.Contains('Fixture command completed'))
    Assert-True ($result.Text.Contains('No command output was recorded'))
}

Test-Case 'Repair-only entry point returns directly and narrow command previews remain readable' {
    $result = Invoke-TerminalScenario -RepairOnly -Plain -Width 40 -Answers @('1', '', '0')
    Assert-Equal 0 $result.RepairCalls.Count
    Assert-True (-not $result.Text.Contains('WINUTILITY / LAPTOP SETUP'))
    foreach ($line in ($result.Text -split "`n")) { Assert-True ($line.Length -le 40) "Line exceeds terminal width: $line" }
}
