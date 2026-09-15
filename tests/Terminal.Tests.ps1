function Invoke-TerminalScenario {
    param([string[]]$Answers, $Session, [int]$Width = 78, [int]$Height = 50, [switch]$Plain, [switch]$LiveFixture, [switch]$AdminFixture, [switch]$RepairOnly,
        [ValidateSet('ready', 'agreement', 'missing', 'failed', 'empty')][string]$WinGetScenario = 'missing',
        [ValidateSet('ready', 'disk3', 'disk-fix3', 'dism87', 'quick', 'empty-log', 'missing-log', 'launch-failed', 'probe-failed', 'broken-report')][string]$RepairScenario = 'ready')
    if ($null -eq $Session) { $Session = New-WuSession -Catalog $script:Catalog }
    $module = Import-Module (Join-Path $script:RepoRoot 'src/WinUtility.Terminal.psm1') -Force -PassThru
    try {
        return (& $module {
            param($Inputs, $ActiveSession, $DisplayWidth, $DisplayHeight, $PlainMode, $LiveMode, $AdminMode, $RepairMode, $PackageScenario, $RepairCase, $TestDirectory)
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
            $script:UiSearchCalls = New-Object System.Collections.ArrayList
            $script:UiDetailCalls = New-Object System.Collections.ArrayList
            $script:UiPackageScenario = $PackageScenario
            $script:UiRepairScenario = $RepairCase
            $script:UiRepairDirectory = Join-Path $TestDirectory ('repair output ' + [guid]::NewGuid().ToString('N'))
            $environment = [pscustomobject]@{
                OS = 'Windows 11'; PowerShellVersion = '5.1'; WinGetAvailable = $false; SupportedOS = $true
                Architecture = 'X64'; WinGetVersion = 'Unavailable'; PendingReboot = $null
                PowerStatus = 'On battery'; BatteryPercent = 40; IsAdmin = [bool]$AdminMode; Warnings = @()
            }
            $script:UiEnvironment = $environment
            function script:Get-WuEnvironment { return $script:UiEnvironment }
            function script:Find-WuWinGetPackage {
                param($Query, [switch]$AcceptSourceAgreements)
                [void]$script:UiSearchCalls.Add([pscustomobject]@{ Query = $Query; Accepted = [bool]$AcceptSourceAgreements })
                if ($script:UiPackageScenario -eq 'missing') { throw 'WinGet is unavailable (fixture).' }
                $status = 'Found'; $code = 0
                if ($script:UiPackageScenario -eq 'agreement' -and -not $AcceptSourceAgreements) { $status = 'SourceAgreementRequired'; $code = -1978335162 }
                if ($script:UiPackageScenario -eq 'failed') { $status = 'Failed'; $code = 87 }
                if ($script:UiPackageScenario -eq 'empty') { $status = 'NotFound'; $code = -1978335212 }
                return [pscustomobject]@{ Status = $status; ExitCode = $code; Output = 'Native search results: Vendor.Tool | Vendor.Other | Mozilla.Firefox' }
            }
            function script:Get-WuWinGetPackageDetails {
                param($PackageId, [switch]$AcceptSourceAgreements)
                [void]$script:UiDetailCalls.Add($PackageId)
                $status = 'Found'; $code = 0
                if ($PackageId -eq 'Vendor.Missing') { $status = 'NotFound'; $code = -1978335212 }
                return [pscustomobject]@{ Status = $status; ExitCode = $code; Output = "Publisher: Fixture Publisher | Package: $PackageId" }
            }
            function script:Get-WuRepairEnvironment {
                if ($script:UiRepairScenario -eq 'probe-failed') { throw 'Windows drive could not be verified (fixture).' }
                return [pscustomobject]@{ Readiness = $script:UiEnvironment; SystemDrive = 'W:'; FileSystem = 'NTFS' }
            }
            function script:Open-WuRepairAsAdministrator { param([switch]$Plain) $script:UiElevationCalls++ }
            function script:Get-WuRepairHistory {
                $run = [pscustomobject]@{
                    Path = 'fixture-repair/report.json'; Error = $null
                    Report = [pscustomobject]@{
                        Status = 'Completed'; StartedAtUtc = '2026-09-15T12:00:00Z'; RepairId = 'full'; NativeLogs = @('CBS.log')
                        Steps = @([pscustomobject]@{ Id = 'dism.restore'; Name = 'DISM repair'; Status = 'Completed'; Message = 'Fixture command completed'; ExitCode = 0; DurationSeconds = 1; LogFile = 'dism.restore.log' })
                    }
                }
                if ($script:UiRepairScenario -eq 'broken-report') { $run.Report.Steps = @([pscustomobject]@{}) }
                if ($script:UiRepairScenario -in @('disk3', 'disk-fix3', 'dism87', 'quick', 'empty-log', 'missing-log')) {
                    [void][IO.Directory]::CreateDirectory($script:UiRepairDirectory)
                    $run.Path = Join-Path $script:UiRepairDirectory 'report.json'
                    $run.Report.Status = 'Stopped'
                    $run.Report.Steps = @([pscustomobject]@{
                        Id = 'disk.scan'; Name = 'CHKDSK online scan'; Status = 'NeedsAttention'; Message = 'CHKDSK could not check the disk.'
                        ExitCode = 3; DurationSeconds = 0.1; LogFile = 'disk.scan.log'
                        CommandLine = 'chkdsk.exe "W:" "/scan"'
                    })
                    $output = 'Invalid parameter - "'
                    if ($script:UiRepairScenario -eq 'disk-fix3') {
                        $run.Report.Status = 'ReviewRequired'
                        $run.Report.Steps[0].Id = 'disk.fix'
                        $run.Report.Steps[0].Status = 'ReviewRequired'
                    }
                    if ($script:UiRepairScenario -eq 'dism87') {
                        $run.Report.Steps[0] = [pscustomobject]@{
                            Id = 'dism.check'; Name = 'DISM quick check'; Status = 'Failed'; Message = 'DISM rejected a command parameter.'
                            ExitCode = 87; DurationSeconds = 0.1; LogFile = 'dism.check.log'
                        }
                        $output = 'Error: 87. The parameter is incorrect.'
                    }
                    if ($script:UiRepairScenario -eq 'quick') {
                        $run.Report.Status = 'Completed'
                        $run.Report.Steps[0] = [pscustomobject]@{
                            Id = 'dism.check'; Name = 'DISM quick check'; Status = 'Completed'; Message = 'Quick check finished.'
                            ExitCode = 0; DurationSeconds = 0.2; LogFile = 'dism.check.log'
                        }
                        $output = 'No component store corruption detected.'
                    }
                    if ($script:UiRepairScenario -eq 'empty-log') { $output = '' }
                    if ($script:UiRepairScenario -ne 'missing-log') {
                        [IO.File]::WriteAllText((Join-Path $script:UiRepairDirectory $run.Report.Steps[0].LogFile), $output)
                    }
                    if ($script:UiRepairScenario -eq 'disk3') {
                        foreach ($id in @('dism.restore', 'sfc.scan', 'dism.scan', 'sfc.verify')) {
                            $run.Report.Steps += [pscustomobject]@{
                                Id = $id; Name = $id; Status = 'NotRun'; Message = 'An earlier step needs attention.'
                                ExitCode = $null; DurationSeconds = $null; LogFile = ($id + '.log')
                            }
                        }
                    }
                }
                return $run
            }
            function script:Invoke-WuRepair {
                param($Id, $SourcePath, $SourceIndex, [switch]$Confirmed, $OnProgress)
                if (-not $Confirmed) { throw 'Missing repair confirmation.' }
                [void]$script:UiRepairCalls.Add([pscustomobject]@{ Id = $Id; SourcePath = $SourcePath; SourceIndex = $SourceIndex })
                if ($script:UiRepairScenario -eq 'launch-failed') { throw 'The repair tool could not be started (fixture).' }
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
            return [pscustomobject]@{ Text = $script:OutputLines -join "`n"; Session = $ActiveSession; ColorCalls = $script:ColorCalls; ApplyCalls = $script:UiApplyCalls; UndoCalls = $script:UiUndoCalls; RepairCalls = $script:UiRepairCalls; ElevationCalls = $script:UiElevationCalls; SearchCalls = $script:UiSearchCalls; DetailCalls = $script:UiDetailCalls }
        } $Answers $Session $Width $Height $Plain $LiveFixture $AdminFixture $RepairOnly $WinGetScenario $RepairScenario $script:TestRoot)
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
    $categoryCount = @($script:Catalog.Apps.category | Select-Object -Unique).Count
    foreach ($number in 1..$categoryCount) { $answers += @($number.ToString(), '0') }
    $answers += @('0', '0')
    $result = Invoke-TerminalScenario -Answers $answers
    Assert-True ($result.Text.Contains('Remove Microsoft Solitaire Collection'))
    Assert-True ($result.Text.Contains('Visual Studio Code'))
    Assert-Equal 0 $result.Session.Selected.Count
}

Test-Case 'App batches retain selections across categories, detail views, search and queue review' {
    $result = Invoke-TerminalScenario -Answers @('3', '1', '1,3-4', 'd3', '', '0', 's', 'archive', 'a', '0', 'r', '0', '0', '0', '2')
    Assert-Equal @('app.7zip', 'app.brave', 'app.firefox', 'app.vivaldi') @($result.Session.Selected.Keys | Sort-Object)
    Assert-True ($result.Text.Contains('WinGet: Brave.Brave'))
    Assert-True ($result.Text.Contains('4 apps in queue'))
    Assert-Equal 0 $result.ApplyCalls.Count
}

Test-Case 'App paging validates whole batches and select-clear commands affect the visible page only' {
    $result = Invoke-TerminalScenario -Plain -Height 24 -Answers @('3', 'b', '1,9', '1-3', 'n', '9,9,10', 'p', 'c', '0', '0', '0', '2')
    Assert-Equal @('app.notepadplusplus', 'app.sharex') @($result.Session.Selected.Keys | Sort-Object)
    Assert-True ($result.Text.Contains('Use only the numbers shown on this page'))
    Assert-True ($result.Text.Contains('Page 2 /'))
    Assert-True ($result.Text.Contains('Toggle: 9,11,13-15'))
}

Test-Case 'Catalog search and paged app choices wrap within a narrow terminal' {
    $result = Invoke-TerminalScenario -Plain -Width 40 -Height 24 -Answers @('3', 's', 'PDF', 'a', '0', 'b', 'n', '0', '0', '0', '2')
    Assert-True ($result.Session.Selected.Count -ge 2)
    foreach ($line in ($result.Text -split "`n")) { Assert-True ($line.Length -le 40) "Line exceeds width: $line" }
}

Test-Case 'Live WinGet search previews multiple exact packages before queueing without installation' {
    $result = Invoke-TerminalScenario -LiveFixture -WinGetScenario ready -Answers @('3', 'w', 'vendor', 'Vendor.Tool, Vendor.Other, Mozilla.Firefox', '1', '', 'r', '0', '0', '0', '2')
    Assert-Equal @('Vendor.Tool', 'Vendor.Other', 'Mozilla.Firefox') @($result.DetailCalls)
    Assert-Equal 3 $result.Session.Selected.Count
    Assert-Equal 2 $result.Session.AdditionalApps.Count
    Assert-True $result.Session.Selected.ContainsKey('app.firefox')
    Assert-True ($result.Text.Contains('Publisher: Fixture Publisher'))
    Assert-Equal 0 $result.ApplyCalls.Count
}

Test-Case 'Declined live selections and a batch containing an unresolved package change nothing' {
    $declined = Invoke-TerminalScenario -LiveFixture -WinGetScenario ready -Answers @('3', 'w', 'vendor', 'Vendor.Tool', '0', '', '0', '0')
    Assert-Equal 0 $declined.Session.Selected.Count
    $invalid = Invoke-TerminalScenario -LiveFixture -WinGetScenario ready -Answers @('3', 'w', 'vendor', 'Vendor.Tool,Vendor.Missing', '', '0', '0')
    Assert-Equal 0 $invalid.Session.Selected.Count
    Assert-Equal 0 $invalid.Session.AdditionalApps.Count
    Assert-True ($invalid.Text.Contains('No apps from this batch were added'))
}

Test-Case 'Malformed live package batches are rejected before package lookup' {
    $result = Invoke-TerminalScenario -LiveFixture -WinGetScenario ready -Answers @('3', 'w', 'vendor', 'Vendor.Tool,bad;command', '', '0', '0')
    Assert-Equal 0 $result.DetailCalls.Count
    Assert-Equal 0 $result.Session.Selected.Count
}

Test-Case 'WinGet source agreement prompts can be cancelled and are accepted only after confirmation' {
    $declined = Invoke-TerminalScenario -LiveFixture -WinGetScenario agreement -Answers @('3', 'w', 'vendor', '0', '', '0', '0')
    Assert-Equal 1 $declined.SearchCalls.Count
    Assert-Equal $false $declined.SearchCalls[0].Accepted
    $accepted = Invoke-TerminalScenario -LiveFixture -WinGetScenario agreement -Answers @('3', 'w', 'vendor', '1', '0', '0', '0')
    Assert-Equal 2 $accepted.SearchCalls.Count
    Assert-Equal $false $accepted.SearchCalls[0].Accepted
    Assert-Equal $true $accepted.SearchCalls[1].Accepted
    Assert-Equal 0 $accepted.Session.Selected.Count
}

Test-Case 'Unavailable, empty and failed live searches preserve the queue and allow returning' {
    foreach ($scenario in @('missing', 'empty', 'failed')) {
        $result = Invoke-TerminalScenario -LiveFixture -WinGetScenario $scenario -Answers @('3', 'w', 'vendor', '', '0', '0')
        Assert-Equal 0 $result.Session.Selected.Count
        Assert-Equal 0 $result.DetailCalls.Count
    }
}

Test-Case 'Live search in preview mode makes no WinGet calls' {
    $result = Invoke-TerminalScenario -Answers @('3', 'w', '', '0', '0')
    Assert-Equal 0 $result.SearchCalls.Count
    Assert-Equal 0 $result.DetailCalls.Count
    Assert-True ($result.Text.Contains('Bundled catalog search works in this preview'))
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

Test-Case 'CHKDSK exit 3 shows native output automatically and returns to a usable repair menu' {
    $result = Invoke-TerminalScenario -LiveFixture -AdminFixture -RepairScenario disk3 -Answers @('6', '1', '1', '0', '2', '0', '0', '0')
    Assert-Equal 1 $result.RepairCalls.Count
    Assert-Equal 'full' $result.RepairCalls[0].Id
    Assert-True ($result.Text.Contains('Invalid parameter - "'))
    Assert-True ($result.Text.Contains('Workflow stopped. Steps not run: 4.'))
    Assert-True ($result.Text.Contains('chkdsk.exe "W:" "/scan"'))
    Assert-True ($result.Text.Contains('Back to repair menu'))
    Assert-True (-not $result.Text.Contains('Repair stopped:'))
    Assert-Equal 0 $result.Session.Selected.Count
}

Test-Case 'DISM parameter errors from older reports show their native output without closing the menu' {
    $result = Invoke-TerminalScenario -LiveFixture -AdminFixture -RepairScenario dism87 -Answers @('6', '2', '1', '0', '7', '0', '0', '0')
    Assert-Equal 1 $result.RepairCalls.Count
    Assert-Equal 'dism.check' $result.RepairCalls[0].Id
    Assert-True ($result.Text.Contains('Error: 87. The parameter is incorrect.'))
    Assert-True (-not $result.Text.Contains('Repair stopped:'))
}

Test-Case 'Advanced disk checks also surface nonzero native output when their result requires review' {
    $result = Invoke-TerminalScenario -LiveFixture -AdminFixture -RepairScenario disk-fix3 -Answers @('6', '8', '1', '1', '0', '0', '0', '0')
    Assert-Equal 1 $result.RepairCalls.Count
    Assert-Equal 'disk.fix' $result.RepairCalls[0].Id
    Assert-True ($result.Text.Contains('Repair report | ReviewRequired'))
    Assert-True ($result.Text.Contains('Invalid parameter - "'))
}

Test-Case 'An immediate successful DISM quick check displays its actual diagnosis' {
    $result = Invoke-TerminalScenario -LiveFixture -AdminFixture -RepairScenario quick -Answers @('6', '2', '1', '0', '0', '0')
    Assert-Equal 1 $result.RepairCalls.Count
    Assert-True ($result.Text.Contains('No component store corruption detected.'))
    Assert-True ($result.Text.Contains('may finish immediately'))
    Assert-True ($result.Text.Contains('Repair report | Completed'))
}

Test-Case 'Missing and empty logs do not hide the failed repair or prevent back navigation' {
    foreach ($scenario in @('empty-log', 'missing-log')) {
        $result = Invoke-TerminalScenario -LiveFixture -AdminFixture -RepairScenario $scenario -Answers @('6', '1', '1', '0', '0', '0')
        Assert-Equal 1 $result.RepairCalls.Count
        Assert-True ($result.Text.Contains('Repair report | Stopped'))
        if ($scenario -eq 'empty-log') { Assert-True ($result.Text.Contains('The command produced no output.')) }
        else { Assert-True ($result.Text.Contains('No command output was recorded.')) }
    }
}

Test-Case 'Repair preparation and launch errors remain visible and return to the menu' {
    $result = Invoke-TerminalScenario -LiveFixture -AdminFixture -RepairScenario probe-failed -Answers @('6', '1', '', '2', '', '0', '0')
    Assert-Equal 0 $result.RepairCalls.Count
    Assert-True ($result.Text.Contains('Windows drive could not be verified'))
    $result = Invoke-TerminalScenario -LiveFixture -AdminFixture -RepairScenario launch-failed -Answers @('6', '1', '1', '', '2', '1', '', '0', '0')
    Assert-Equal @('full', 'dism.check') @($result.RepairCalls.Id)
    Assert-True ($result.Text.Contains('The repair tool could not be started'))
}

Test-Case 'Unexpected report display failures are contained by the repair menu' {
    $result = Invoke-TerminalScenario -LiveFixture -AdminFixture -RepairScenario broken-report -Answers @('6', 'l', '1', '', '0', '0')
    Assert-Equal 0 $result.RepairCalls.Count
    Assert-True ($result.Text.Contains('Repair menu action failed:'))
}
