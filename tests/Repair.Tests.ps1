function Invoke-RepairFixture {
    param([scriptblock]$Body)
    $fixtureRoot = Join-Path $script:TestRoot ('repair ' + [guid]::NewGuid().ToString('N'))
    $module = Import-Module (Join-Path $script:RepoRoot 'src/WinUtility.Repair.psm1') -Force -PassThru
    try {
        & $module {
            param($Action, $Root)
            $toolsDirectory = Join-Path $Root 'Windows tools'
            [void][IO.Directory]::CreateDirectory($toolsDirectory)
            foreach ($tool in @('dism.exe', 'sfc.exe', 'chkdsk.exe')) { [IO.File]::WriteAllText((Join-Path $toolsDirectory $tool), '') }
            $script:RepairFake = @{
                Directory = Join-Path $Root 'reports'; Calls = New-Object Collections.ArrayList
                Codes = @{}; FailProcess = ''; SaveCount = 0; FailSaveAt = 0; PendingAfter = ''
                Environment = [pscustomobject]@{
                    WindowsDirectory = $Root; SystemDirectory = $toolsDirectory; SystemDrive = 'W:'; FileSystem = 'NTFS'
                    Readiness = [pscustomobject]@{
                        SupportedOS = $true; IsAdmin = $true; PendingReboot = $false
                        ComputerName = 'RepairFixture'; UserSid = 'S-1-fixture'; PowerStatus = 'AC power / charging'
                    }
                }
            }
            $script:RealRepairSave = ${function:Save-WuRepairReport}
            function script:Get-WuRepairEnvironment { return $script:RepairFake.Environment }
            function script:Get-WuRepairHistoryDirectory { return $script:RepairFake.Directory }
            function script:Enter-WuRepairLock { return (New-Object Threading.Mutex($true)) }
            function script:Save-WuRepairReport {
                param($Report, $Path)
                $script:RepairFake.SaveCount++
                if ($script:RepairFake.SaveCount -eq $script:RepairFake.FailSaveAt) { throw 'Report disk full (fixture).' }
                & $script:RealRepairSave $Report $Path
            }
            function script:Invoke-WuRepairProcess {
                param($FilePath, $Arguments, $LogPath, [switch]$UnicodeOutput, [switch]$Interactive)
                $stepId = [IO.Path]::GetFileNameWithoutExtension($LogPath)
                $reportPath = Join-Path (Split-Path $LogPath -Parent) 'report.json'
                $saved = [IO.File]::ReadAllText($reportPath) | ConvertFrom-Json
                Assert-Equal 'Running' @($saved.Steps | Where-Object { $_.Id -eq $stepId })[0].Status
                [void]$script:RepairFake.Calls.Add([pscustomobject]@{ Id = $stepId; File = $FilePath; Arguments = $Arguments; Unicode = [bool]$UnicodeOutput; Interactive = [bool]$Interactive })
                [IO.File]::WriteAllText($LogPath, "Fixture output for $stepId")
                if ($script:RepairFake.PendingAfter -eq $stepId) { $script:RepairFake.Environment.Readiness.PendingReboot = $true }
                if ($script:RepairFake.FailProcess -eq $stepId) { throw 'Process interrupted (fixture).' }
                $code = 0
                if ($script:RepairFake.Codes.ContainsKey($stepId)) { $code = $script:RepairFake.Codes[$stepId] }
                return [pscustomobject]@{ ExitCode = $code }
            }
            & $Action $script:RepairFake
        } $Body $fixtureRoot
    }
    finally { Remove-Module -ModuleInfo $module -Force }
}

Test-Case 'Repair requires confirmation, Windows, elevation, and verified NTFS before making changes' {
    Invoke-RepairFixture {
        param($fake)
        Assert-Throws { Invoke-WuRepair full } '*confirm*'
        $fake.Environment.Readiness.SupportedOS = $false
        Assert-Throws { Invoke-WuRepair full -Confirmed } '*Windows 11*'
        $fake.Environment.Readiness.SupportedOS = $true
        $fake.Environment.Readiness.IsAdmin = $false
        Assert-Throws { Invoke-WuRepair full -Confirmed } '*administrator*'
        $fake.Environment.Readiness.IsAdmin = $true
        $fake.Environment.FileSystem = 'Unknown'
        Assert-Throws { Invoke-WuRepair full -Confirmed } '*NTFS*'
        Assert-Equal 0 $fake.Calls.Count
        Assert-True (-not [IO.Directory]::Exists($fake.Directory))
        $diagnostic = Invoke-WuRepair dism.check -Confirmed
        Assert-Equal 'Completed' $diagnostic.Report.Status
    }
}

Test-Case 'Full repair uses the detected drive and orders DISM before SFC with verification afterward' {
    Invoke-RepairFixture {
        param($fake)
        $run = Invoke-WuRepair full -Confirmed
        Assert-Equal @('disk.scan', 'dism.restore', 'sfc.scan', 'dism.scan', 'sfc.verify') @($fake.Calls.Id)
        Assert-Equal @('W:', '/scan') $fake.Calls[0].Arguments
        Assert-Equal @('/Online', '/Cleanup-Image', '/RestoreHealth', '/NoRestart', '/English') $fake.Calls[1].Arguments
        Assert-Equal @('/scannow') $fake.Calls[2].Arguments
        Assert-Equal $true $fake.Calls[2].Unicode
        Assert-Equal @('/verifyonly') $fake.Calls[4].Arguments
        Assert-Equal 'ReviewRequired' $run.Report.Status
        Assert-Equal 'ReviewRequired' $run.Report.Steps[2].Status
        Assert-True ($run.Report.Steps[2].Message.Contains('not proof'))
        foreach ($step in $run.Report.Steps) {
            Assert-True ([IO.File]::Exists((Join-Path (Split-Path $run.Path -Parent) $step.LogFile)))
            Assert-True ($null -ne $step.DurationSeconds)
        }
        $savedRun = Get-WuRepairHistory
        Assert-Equal $null $savedRun.Error
        Assert-Equal 5 $savedRun.Report.Steps.Count
    }
}

Test-Case 'An unresolved disk scan stops full repair before servicing while repaired errors allow it' {
    foreach ($code in @(1, 2, 3, 99)) {
        Invoke-RepairFixture {
            param($fake)
            $fake.Codes['disk.scan'] = $code
            $run = Invoke-WuRepair full -Confirmed
            if ($code -eq 1) { Assert-Equal 5 $fake.Calls.Count }
            else {
                Assert-Equal @('disk.scan') @($fake.Calls.Id)
                Assert-Equal 'Stopped' $run.Report.Status
                Assert-Equal 'NeedsAttention' $run.Report.Steps[0].Status
                Assert-Equal @('NotRun', 'NotRun', 'NotRun', 'NotRun') @($run.Report.Steps | Select-Object -Skip 1 | ForEach-Object { $_.Status })
            }
        }
    }
}

Test-Case 'Immediate CHKDSK exit 3 preserves its command and output without assuming disk damage' {
    Invoke-RepairFixture {
        param($fake)
        $fake.Codes['disk.scan'] = 3
        $run = Invoke-WuRepair full -Confirmed
        Assert-Equal @('disk.scan') @($fake.Calls.Id)
        Assert-Equal 'Stopped' $run.Report.Status
        Assert-Equal 3 $run.Report.Steps[0].ExitCode
        Assert-Equal 'chkdsk.exe W: /scan' $run.Report.Steps[0].CommandLine
        Assert-True ($run.Report.Steps[0].Message.Contains('could not check the disk'))
        Assert-True ($run.Report.Steps[0].Message.Contains('does not identify the cause'))
        $saved = Get-WuRepairHistory
        Assert-Equal $null $saved.Error
        Assert-Equal $run.Report.Steps[0].CommandLine $saved.Report.Steps[0].CommandLine
        Assert-True ([IO.File]::ReadAllText((Join-Path (Split-Path $run.Path -Parent) 'disk.scan.log')).Contains('Fixture output'))
    }
}

Test-Case 'Quick DISM checks explain that successful immediate completion is not a full scan' {
    Invoke-RepairFixture {
        param($fake)
        $run = Invoke-WuRepair dism.check -Confirmed
        Assert-Equal @('dism.check') @($fake.Calls.Id)
        Assert-Equal 'Completed' $run.Report.Status
        Assert-True ($run.Report.Steps[0].Message.Contains('recorded corruption'))
        Assert-True ($run.Report.Steps[0].Message.Contains('Scan image health'))
    }
}

Test-Case 'A failed repair progress callback is reported and stops before launching its command' {
    Invoke-RepairFixture {
        param($fake)
        $run = Invoke-WuRepair full -Confirmed -OnProgress { throw 'Progress display failed (fixture).' }
        Assert-Equal 0 $fake.Calls.Count
        Assert-Equal 'Stopped' $run.Report.Status
        Assert-Equal 'Failed' $run.Report.Steps[0].Status
        Assert-True ($run.Report.Steps[0].Message.Contains('Progress display failed'))
        Assert-Equal @('NotRun', 'NotRun', 'NotRun', 'NotRun') @($run.Report.Steps | Select-Object -Skip 1 | ForEach-Object { $_.Status })
    }
}

Test-Case 'Failed DISM, missing repair sources, and restart exit codes stop subsequent SFC steps' {
    foreach ($code in @(87, -2146498529, 3010, 1641)) {
        Invoke-RepairFixture {
            param($fake)
            $fake.Codes['dism.restore'] = $code
            $run = Invoke-WuRepair full -Confirmed
            Assert-Equal @('disk.scan', 'dism.restore') @($fake.Calls.Id)
            Assert-Equal 'Stopped' $run.Report.Status
            if ($code -eq -2146498529) { Assert-True ($run.Report.Steps[1].Message.Contains('800F081F')) }
            if ($code -in @(3010, 1641)) { Assert-Equal $true $run.Report.Steps[1].RestartRequired }
            else { Assert-Equal 'Failed' $run.Report.Steps[1].Status }
        }
    }
}

Test-Case 'Pending restarts block repairing workflows and newly pending restarts stop before SFC' {
    Invoke-RepairFixture {
        param($fake)
        $fake.Environment.Readiness.PendingReboot = $true
        Assert-Throws { Invoke-WuRepair full -Confirmed } '*pending restart*'
        Assert-Equal 0 $fake.Calls.Count
        Assert-True (-not [IO.Directory]::Exists($fake.Directory))
        [void](Invoke-WuRepair dism.check -Confirmed)
        $fake.Calls.Clear()
        $fake.Environment.Readiness.PendingReboot = $false
        $fake.PendingAfter = 'dism.restore'
        $run = Invoke-WuRepair full -Confirmed
        Assert-Equal @('disk.scan', 'dism.restore') @($fake.Calls.Id)
        Assert-Equal 'RestartRequired' $run.Report.Steps[2].Status
        Assert-Equal 'NotRun' $run.Report.Steps[3].Status
    }
}

Test-Case 'Repair report failures stop execution before the next command and preserve incomplete runs' {
    foreach ($saveNumber in @(1, 2, 3)) {
        Invoke-RepairFixture {
            param($fake)
            $fake.FailSaveAt = $saveNumber
            Assert-Throws { Invoke-WuRepair full -Confirmed } '*disk full*'
            if ($saveNumber -le 2) { Assert-Equal 0 $fake.Calls.Count }
            else {
                Assert-Equal 1 $fake.Calls.Count
                $savedRun = Get-WuRepairHistory
                Assert-Equal $null $savedRun.Error
                $report = $savedRun.Report
                Assert-Equal 'Running' $report.Status
                Assert-Equal 'Running' $report.Steps[0].Status
            }
        }
    }
}

Test-Case 'Native repair failures preserve partial logs and do not start later commands' {
    Invoke-RepairFixture {
        param($fake)
        $fake.FailProcess = 'sfc.scan'
        $run = Invoke-WuRepair full -Confirmed
        Assert-Equal 3 $fake.Calls.Count
        Assert-Equal 'Failed' $run.Report.Steps[2].Status
        Assert-Equal 'NotRun' $run.Report.Steps[3].Status
        Assert-True ([IO.File]::ReadAllText((Join-Path (Split-Path $run.Path -Parent) 'sfc.scan.log')).Contains('Fixture output'))
        $fake.FailProcess = ''; $fake.Codes['sfc.scan'] = 7
        $run = Invoke-WuRepair sfc.scan -Confirmed
        Assert-Equal 'NeedsAttention' $run.Report.Steps[0].Status
    }
}

Test-Case 'Deep disk checks inherit the native scheduling prompt and never claim a repair was completed' {
    foreach ($spec in @(@('disk.fix', '/f'), @('disk.surface', '/r'))) {
        Invoke-RepairFixture {
            param($fake)
            $run = Invoke-WuRepair $spec[0] -Confirmed
            Assert-Equal @('W:', $spec[1]) $fake.Calls[0].Arguments
            Assert-Equal $true $fake.Calls[0].Interactive
            Assert-Equal 'ReviewRequired' $run.Report.Status
            Assert-True ($run.Report.Steps[0].Message.Contains('Scheduling is not a completed repair'))
        }
    }
}

Test-Case 'Repair commands reject unknown IDs and malformed source arguments while quoting a local WIM as one argument' {
    Invoke-RepairFixture {
        param($fake)
        Assert-Throws { Invoke-WuRepair 'dism.restore; whoami' -Confirmed } '*Unknown repair*'
        Assert-Throws { Get-WuRepairPlan disk.scan -SystemDrive 'C: /r' }
        Assert-Throws { Get-WuRepairPlan disk.scan -SystemDrive "C:`n" }
        Assert-Throws { Get-WuRepairPlan dism.source -SourcePath 'E:\install.wim" /ResetBase' -SourceIndex 1 }
        Assert-Throws { Get-WuRepairPlan dism.source -SourcePath 'E:\install.wim:stream' -SourceIndex 1 }
        Assert-Throws { Get-WuRepairPlan dism.source -SourcePath "E:\install.wim`n" -SourceIndex 1 }
        Assert-Throws { Get-WuRepairPlan dism.source -SourcePath 'E:\install.wim' -SourceIndex 0 } '*positive*'
        $plan = @(Get-WuRepairPlan dism.source -SourcePath 'E:\Windows media\install.wim' -SourceIndex 6)
        Assert-Equal @('/Online', '/Cleanup-Image', '/RestoreHealth', '/Source:WIM:E:\Windows media\install.wim:6', '/LimitAccess', '/NoRestart', '/English') $plan[0].Arguments
        $info = @(Get-WuRepairPlan source.info -SourcePath 'E:\install.wim')
        Assert-Equal @('/Get-WimInfo', '/WimFile:E:\install.wim', '/NoRestart', '/English') $info[0].Arguments
        Assert-Equal 0 $fake.Calls.Count
    }
}

Test-Case 'Native repair syntax leaves switches bare and quotes only values that need it' {
    Invoke-RepairFixture {
        param($fake)
        Assert-Equal 'chkdsk.exe C: /scan' (Get-WuRepairPlan disk.scan).CommandLine
        Assert-Equal 'chkdsk.exe C: /f' (Get-WuRepairPlan disk.fix).CommandLine
        Assert-Equal 'chkdsk.exe C: /r' (Get-WuRepairPlan disk.surface).CommandLine
        Assert-Equal 'dism.exe /Online /Cleanup-Image /CheckHealth /NoRestart /English' (Get-WuRepairPlan dism.check).CommandLine
        Assert-Equal 'sfc.exe /scannow' (Get-WuRepairPlan sfc.scan).CommandLine
        Assert-Equal 'dism.exe /Online /Cleanup-Image /RestoreHealth /Source:"WIM:E:\Windows media\install.wim:6" /LimitAccess /NoRestart /English' (Get-WuRepairPlan dism.source -SourcePath 'E:\Windows media\install.wim' -SourceIndex 6).CommandLine
        Assert-Equal 'dism.exe /Get-WimInfo /WimFile:"E:\Windows media\install.wim" /NoRestart /English' (Get-WuRepairPlan source.info -SourcePath 'E:\Windows media\install.wim').CommandLine
    }
}

Test-Case 'Missing Windows tools and inaccessible WIM sources fail before creating a report' {
    Invoke-RepairFixture {
        param($fake)
        [IO.File]::Delete((Join-Path $fake.Environment.SystemDirectory 'sfc.exe'))
        Assert-Throws { Invoke-WuRepair full -Confirmed } '*tool is missing*'
        Assert-Throws { Invoke-WuRepair dism.source -SourcePath 'Z:\missing\install.wim' -SourceIndex 1 -Confirmed } '*does not exist*'
        Assert-Equal 0 $fake.Calls.Count
        Assert-True (-not [IO.Directory]::Exists($fake.Directory))
    }
}

Test-Case 'Repair history rejects malformed reports and paths escaping a run directory' {
    Invoke-RepairFixture {
        param($fake)
        $run = Invoke-WuRepair dism.check -Confirmed
        $run.Report.Steps[0].LogFile = '..\private.log'
        [IO.File]::WriteAllText($run.Path, (ConvertTo-Json -InputObject $run.Report -Depth 12))
        Assert-True ($null -ne (Get-WuRepairHistory).Error)
        [IO.File]::WriteAllText($run.Path, 'broken JSON')
        Assert-True ($null -ne (Get-WuRepairHistory).Error)
    }
}

Test-Case 'Repair process captures Unicode, partial prompts, stderr and native argument boundaries' {
    $module = Import-Module (Join-Path $script:RepoRoot 'src/WinUtility.Repair.psm1') -Force -PassThru
    $fixture = Join-Path $script:TestRoot 'repair native fixture.ps1'
    [IO.File]::WriteAllText($fixture, @'
param([string]$Payload)
[Console]::OutputEncoding = [Text.Encoding]::Unicode
[Console]::Out.Write("prompt without newline: ")
[Console]::Out.WriteLine($Payload)
[Console]::Out.WriteLine([string][char]0x017E + [char]0x4E2D)
[Console]::Error.WriteLine("expected-stderr")
exit 7
'@)
    $executableName = 'pwsh'
    if ($PSVersionTable.PSEdition -eq 'Desktop') { $executableName = 'powershell.exe' }
    elseif ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $executableName = 'pwsh.exe' }
    $logPath = Join-Path $script:TestRoot 'native repair.log'
    $payload = 'spaces "quotes" ; $(ignored) and trailing slash\'
    try {
        $result = & $module {
            param($Executable, $Script, $Log, $Text)
            function script:Write-Host { param($Object, [switch]$NoNewline) }
            Invoke-WuRepairProcess -FilePath $Executable -Arguments @('-NoProfile', '-File', $Script, '-Payload', $Text) -LogPath $Log -UnicodeOutput
        } (Join-Path $PSHOME $executableName) $fixture $logPath $payload
        Assert-Equal 7 $result.ExitCode
        $output = [IO.File]::ReadAllText($logPath)
        Assert-True ($output.Contains($payload))
        Assert-True ($output.Contains('prompt without newline: '))
        Assert-True ($output.Contains('expected-stderr'))
        Assert-True ($output.Contains([string][char]0x017E + [char]0x4E2D))
    }
    finally { Remove-Module -ModuleInfo $module -Force }
}

Test-Case 'The native runner passes repair switches and spaced WIM values intact to a real child process' {
    $module = Import-Module (Join-Path $script:RepoRoot 'src/WinUtility.Repair.psm1') -Force -PassThru
    $fixture = Join-Path $script:TestRoot 'repair argument observer.ps1'
    [IO.File]::WriteAllText($fixture, @'
$observed = [pscustomobject]@{ Values = @($args); CommandLine = [Environment]::CommandLine }
[Console]::Out.WriteLine((ConvertTo-Json -InputObject $observed -Compress))
exit 3
'@)
    $executableName = 'pwsh'
    if ($PSVersionTable.PSEdition -eq 'Desktop') { $executableName = 'powershell.exe' }
    elseif ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $executableName = 'pwsh.exe' }
    try {
        foreach ($id in @('disk.scan', 'disk.fix', 'disk.surface', 'dism.check', 'sfc.scan', 'dism.source', 'source.info')) {
            $plan = Get-WuRepairPlan -Id $id -SourcePath 'E:\Windows media\install.wim' -SourceIndex 6
            $logPath = Join-Path $script:TestRoot ($id + '.arguments.log')
            $result = & $module {
                param($Executable, $Script, $Log, $RepairArguments)
                function script:Write-Host { param($Object, [switch]$NoNewline) }
                Invoke-WuRepairProcess -FilePath $Executable -Arguments (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $RepairArguments) -LogPath $Log
            } (Join-Path $PSHOME $executableName) $fixture $logPath $plan.Arguments
            Assert-Equal 3 $result.ExitCode
            $observed = [IO.File]::ReadAllText($logPath) | ConvertFrom-Json
            Assert-Equal @($plan.Arguments) @($observed.Values)
            # On Windows this is the original command line, before any child argv parsing.
            # Unix reconstructs it from argv, so raw quote placement cannot be tested there.
            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                Assert-True ($observed.CommandLine.EndsWith($plan.CommandLine.Substring($plan.Tool.Length + 1)))
            }
        }
    }
    finally { Remove-Module -ModuleInfo $module -Force }
}

Test-Case 'Repair elevation uses a quoted local entry point and waits for the child before returning' {
    Invoke-RepairFixture {
        param($fake)
        $script:Elevation = $null
        function script:Start-Process {
            param($FilePath, $ArgumentList, $Verb, [switch]$Wait, $ErrorAction)
            $script:Elevation = [pscustomobject]@{ Path = $FilePath; Arguments = $ArgumentList; Verb = $Verb; Wait = [bool]$Wait }
        }
        Open-WuRepairAsAdministrator -Plain -NoKeyNavigation
        Assert-Equal 'RunAs' $script:Elevation.Verb
        Assert-Equal $true $script:Elevation.Wait
        Assert-True ($script:Elevation.Arguments.Contains(' -Repair'))
        Assert-True ($script:Elevation.Arguments.Contains(' -Plain'))
        Assert-True ($script:Elevation.Arguments.Contains(' -NoKeyNavigation'))
        Assert-True ($script:Elevation.Arguments.Contains(' -File '))
    }
}

Test-Case 'The repair mutex prevents a second process from entering the same machine repair' {
    $modulePath = Join-Path $script:RepoRoot 'src/WinUtility.Repair.psm1'
    $module = Import-Module $modulePath -Force -PassThru
    $name = 'WinUtilityRepairTest-' + [guid]::NewGuid().ToString('N')
    $fixture = Join-Path $script:TestRoot 'repair lock child.ps1'
    $resultPath = Join-Path $script:TestRoot 'repair lock result.txt'
    [IO.File]::WriteAllText($fixture, @'
param($ModulePath, $MutexName, $ResultPath)
$ErrorActionPreference = 'Stop'
$module = Import-Module $ModulePath -Force -PassThru
try {
    $mutex = & $module { param($Name) $script:RepairMutexName = $Name; Enter-WuRepairLock } $MutexName
    $mutex.ReleaseMutex(); $mutex.Dispose()
    [IO.File]::WriteAllText($ResultPath, 'unexpected acquisition')
} catch { [IO.File]::WriteAllText($ResultPath, $_.Exception.Message) }
'@)
    $executableName = 'pwsh'
    if ($PSVersionTable.PSEdition -eq 'Desktop') { $executableName = 'powershell.exe' }
    elseif ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $executableName = 'pwsh.exe' }
    $lock = $null
    try {
        $lock = & $module { param($Name) $script:RepairMutexName = $Name; Enter-WuRepairLock } $name
        & (Join-Path $PSHOME $executableName) -NoProfile -ExecutionPolicy Bypass -File $fixture $modulePath $name $resultPath
        Assert-True ([IO.File]::ReadAllText($resultPath).Contains('Another WinUtility repair is running'))
    }
    finally {
        if ($null -ne $lock) { $lock.ReleaseMutex(); $lock.Dispose() }
        Remove-Module -ModuleInfo $module -Force
    }
}

Test-Case 'Output display failure drains both native pipes and retains output without hanging the child' {
    $module = Import-Module (Join-Path $script:RepoRoot 'src/WinUtility.Repair.psm1') -Force -PassThru
    $fixture = Join-Path $script:TestRoot 'repair output child.ps1'
    [IO.File]::WriteAllText($fixture, @'
[Console]::OutputEncoding = [Text.Encoding]::Unicode
for ($i = 0; $i -lt 400; $i++) {
    [Console]::Out.WriteLine('stdout padding ' + ('x' * 100))
    [Console]::Error.WriteLine('stderr padding ' + ('y' * 100))
}
[Console]::Out.WriteLine('child reached the end')
'@)
    $executableName = 'pwsh'
    if ($PSVersionTable.PSEdition -eq 'Desktop') { $executableName = 'powershell.exe' }
    elseif ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $executableName = 'pwsh.exe' }
    $logPath = Join-Path $script:TestRoot 'repair output failure.log'
    try {
        Assert-Throws {
            & $module {
                param($Executable, $Script, $Log)
                function script:Write-Host { param($Object, [switch]$NoNewline) throw 'Display failed (fixture).' }
                Invoke-WuRepairProcess -FilePath $Executable -Arguments @('-NoProfile', '-File', $Script) -LogPath $Log -UnicodeOutput
            } (Join-Path $PSHOME $executableName) $fixture $logPath
        } '*Display failed*'
        Assert-True ([IO.File]::ReadAllText($logPath).Contains('child reached the end'))
    }
    finally { Remove-Module -ModuleInfo $module -Force }
}
