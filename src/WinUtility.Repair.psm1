Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'WinUtility.Windows.psm1') -Scope Local
$script:RepairMutexName = 'Global\WinUtility.WindowsRepair'

# Repair commands are owned by code, never loaded from a saved setup or log.
function Get-WuRepairCatalog {
    @(
        @('full', 'Full repair | Recommended', 'Scan the drive, repair the image and system files, then verify both.', 'Main'),
        @('dism.check', 'DISM | Quick health check', 'Read previously detected component-store corruption.', 'Main'),
        @('dism.scan', 'DISM | Scan image health', 'Scan the Windows component store for corruption.', 'Main'),
        @('dism.restore', 'DISM | Repair Windows image', 'Repair the component store using the configured repair source / Windows Update.', 'Main'),
        @('sfc.scan', 'SFC | Repair system files', 'Run sfc /scannow. DISM repair should normally come first.', 'Main'),
        @('sfc.verify', 'SFC | Verify system files', 'Check protected files without replacing them.', 'Main'),
        @('disk.scan', 'CHKDSK | Online drive scan', 'Scan the Windows NTFS volume; Windows may perform online fixes.', 'Main'),
        @('disk.fix', 'CHKDSK /f | Disk repair', 'Fix file-system errors. The system drive normally needs a boot-time check.', 'Advanced'),
        @('disk.surface', 'CHKDSK /r | Sector recovery', 'Includes /f; reads the entire volume and attempts recovery. Can take many hours.', 'Advanced'),
        @('source.info', 'DISM | List WIM image indexes', 'Inspect a local install.wim before choosing the matching Windows edition.', 'Advanced'),
        @('dism.source', 'DISM | Repair from local WIM', 'Use a matching Windows image when the usual repair source fails.', 'Advanced')
    ) | ForEach-Object {
        [pscustomobject]@{ Id = $_[0]; Name = $_[1]; Description = $_[2]; Group = $_[3] }
    }
}

function Get-WuRepairPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [ValidatePattern('\A[A-Za-z]:\z')][string]$SystemDrive = 'C:',
        [string]$SourcePath, [int]$SourceIndex = 0)
    if (@(Get-WuRepairCatalog | Where-Object { $_.Id -ceq $Id }).Count -ne 1) { throw 'Unknown repair action.' }
    if ($Id -in @('source.info', 'dism.source')) {
        # Restrict this first source-repair UI to a local/attached WIM, not command text or a URL.
        if ($SourcePath -notmatch '\A[A-Za-z]:\\[^"\x00-\x1f]+\.wim\z' -or $SourcePath.Substring(2).Contains(':')) {
            throw 'Choose an absolute local path to a .wim file, for example E:\sources\install.wim.'
        }
        if ($Id -eq 'dism.source' -and $SourceIndex -lt 1) { throw 'A positive WIM image index is required.' }
    }
    $ids = @($Id)
    if ($Id -eq 'full') { $ids = @('disk.scan', 'dism.restore', 'sfc.scan', 'dism.scan', 'sfc.verify') }
    foreach ($stepId in $ids) {
        $definition = Get-WuRepairCatalog | Where-Object { $_.Id -ceq $stepId }
        $step = [pscustomobject]@{
            Id = $stepId; Name = $definition.Name; Description = $definition.Description
            Tool = ''; Arguments = @(); CommandLine = ''; Disk = $false; Interactive = $false; NeedsFreshRestart = $false
        }
        switch ($stepId) {
            'dism.check' { $step.Arguments = @('/Online', '/Cleanup-Image', '/CheckHealth') }
            'dism.scan' { $step.Arguments = @('/Online', '/Cleanup-Image', '/ScanHealth') }
            'dism.restore' { $step.Arguments = @('/Online', '/Cleanup-Image', '/RestoreHealth'); $step.NeedsFreshRestart = $true }
            'dism.source' {
                $step.Arguments = @('/Online', '/Cleanup-Image', '/RestoreHealth', "/Source:WIM:${SourcePath}:$SourceIndex", '/LimitAccess')
                $step.NeedsFreshRestart = $true
            }
            'source.info' { $step.Arguments = @('/Get-WimInfo', "/WimFile:$SourcePath") }
            'sfc.scan' { $step.Tool = 'sfc.exe'; $step.Arguments = @('/scannow'); $step.NeedsFreshRestart = $true }
            'sfc.verify' { $step.Tool = 'sfc.exe'; $step.Arguments = @('/verifyonly') }
            'disk.scan' { $step.Arguments = @($SystemDrive, '/scan') }
            'disk.fix' { $step.Arguments = @($SystemDrive, '/f'); $step.Interactive = $true }
            'disk.surface' { $step.Arguments = @($SystemDrive, '/r'); $step.Interactive = $true }
        }
        if ($stepId.StartsWith('disk.')) { $step.Tool = 'chkdsk.exe'; $step.Disk = $true }
        elseif ($step.Tool.Length -eq 0) { $step.Tool = 'dism.exe'; $step.Arguments += @('/NoRestart', '/English') }
        $step.CommandLine = $step.Tool + ' ' + (ConvertTo-WuNativeArguments $step.Arguments)
        $step
    }
}

function Get-WuRepairEnvironment {
    [CmdletBinding()]
    param()
    $readiness = Get-WuReadiness
    $context = [pscustomobject]@{
        Readiness = $readiness; WindowsDirectory = $null; SystemDirectory = $null
        SystemDrive = 'C:'; FileSystem = 'Unknown'; VolumeError = $null
    }
    if (-not $readiness.SupportedOS) { return $context }
    $context.WindowsDirectory = [Environment]::GetFolderPath('Windows')
    $context.SystemDrive = [IO.Path]::GetPathRoot($context.WindowsDirectory).TrimEnd('\')
    if ($context.SystemDrive -notmatch '\A[A-Za-z]:\z') { throw 'The Windows system drive could not be verified.' }
    # A 32-bit host must reach the native system tools on 64-bit Windows.
    $systemFolder = 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $systemFolder = 'Sysnative' }
    $context.SystemDirectory = Join-Path $context.WindowsDirectory $systemFolder
    try {
        $volume = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($context.SystemDrive)'" -ErrorAction Stop
        if ($null -eq $volume -or $volume.DriveType -ne 3) { throw 'A local Windows volume was not found.' }
        $context.FileSystem = [string]$volume.FileSystem
    }
    catch { $context.VolumeError = $_.Exception.Message }
    return $context
}

function Get-WuRepairBlockers {
    [CmdletBinding()]
    param([object[]]$Plan, [Parameter(Mandatory)]$Environment)
    if (-not $Environment.Readiness.SupportedOS) { 'Real repair requires a verified Windows 11 workstation.'; return }
    if (-not $Environment.Readiness.IsAdmin) { 'Open the repair menu as administrator to run Windows repair tools.' }
    if (@($Plan | Where-Object { $_.Disk }).Count -gt 0 -and $Environment.FileSystem -ne 'NTFS') {
        'The Windows drive must be verified as NTFS before running these disk checks.'
    }
    if ($Environment.Readiness.PendingReboot -eq $true -and @($Plan | Where-Object { $_.NeedsFreshRestart }).Count -gt 0) {
        'Windows has a pending restart. Restart first, then run this repair again.'
    }
}

function ConvertTo-WuNativeArguments {
    param([string[]]$Arguments)
    # ProcessStartInfo.ArgumentList is unavailable in Windows PowerShell 5.1.
    # CHKDSK rejects quoted switches. Leave simple arguments bare; no shell is involved.
    # Keep DISM's /Option: prefix outside quotes and quote only its value when needed.
    return (@(foreach ($argument in $Arguments) {
        if (-not [string]::IsNullOrEmpty($argument) -and $argument -notmatch '[\s"]') { $argument; continue }
        $prefix = ''; $value = [string]$argument
        if ($value -match '\A(/[A-Za-z]+:)(.+)\z') { $prefix = $Matches[1]; $value = $Matches[2] }
        $prefix + '"' + [regex]::Replace([regex]::Replace($value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
    }) -join ' ')
}

function Invoke-WuRepairProcess {
    param([string]$FilePath, [string[]]$Arguments, [string]$LogPath,
        [switch]$UnicodeOutput, [switch]$Interactive)
    if ($Interactive -and [Console]::IsInputRedirected) { throw 'Disk repair needs an interactive console for the Windows scheduling prompt.' }
    $process = New-Object Diagnostics.Process
    $writer = $null
    $started = $false
    $streams = @()
    try {
        # Open and flush the output file before launching a repair.
        $writer = New-Object IO.StreamWriter($LogPath, $false, (New-Object Text.UTF8Encoding($false)))
        $writer.AutoFlush = $true
        $process.StartInfo.FileName = $FilePath
        $process.StartInfo.Arguments = ConvertTo-WuNativeArguments $Arguments
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        # Inherit stdin so CHKDSK asks its own localized Y/N question. Never pipe an assumed answer.
        $encoding = [Console]::OutputEncoding
        if ($UnicodeOutput) { $encoding = [Text.Encoding]::Unicode }
        $process.StartInfo.StandardOutputEncoding = $encoding
        $process.StartInfo.StandardErrorEncoding = $encoding
        $started = $process.Start()
        if (-not $started) { throw 'The Windows repair tool could not be started.' }
        $streams = @(
            @{ Reader = $process.StandardOutput; Buffer = (New-Object char[] 1024); Task = $null; Closed = $false },
            @{ Reader = $process.StandardError; Buffer = (New-Object char[] 1024); Task = $null; Closed = $false }
        )
        # Drain both streams concurrently, including prompts/progress without a trailing newline.
        while (@($streams | Where-Object { -not $_.Closed }).Count -gt 0) {
            $progressed = $false
            foreach ($stream in $streams) {
                if ($stream.Closed) { continue }
                if ($null -eq $stream.Task) { $stream.Task = $stream.Reader.ReadAsync($stream.Buffer, 0, $stream.Buffer.Length) }
                if ($stream.Task.IsCompleted) {
                    $count = $stream.Task.GetAwaiter().GetResult()
                    $stream.Task = $null
                    if ($count -eq 0) { $stream.Closed = $true }
                    else {
                        $chunk = New-Object string($stream.Buffer, 0, $count)
                        $writer.Write($chunk)
                        Write-Host -Object $chunk -NoNewline
                    }
                    $progressed = $true
                }
            }
            if (-not $progressed) { [Threading.Thread]::Sleep(40) }
        }
        $process.WaitForExit()
        Write-Host ''
        return [pscustomobject]@{ ExitCode = $process.ExitCode }
    }
    finally {
        # A stopped pipeline must not release the repair lock while its child is still running.
        # Do not forcibly kill DISM/CHKDSK in the middle of disk or servicing work.
        if ($started -and -not $process.HasExited) {
            # Drain pipes even if logging/display failed; waiting with full pipes can deadlock.
            while (@($streams | Where-Object { -not $_.Closed }).Count -gt 0) {
                foreach ($stream in $streams) {
                    if ($stream.Closed) { continue }
                    try {
                        if ($null -eq $stream.Task) { $stream.Task = $stream.Reader.ReadAsync($stream.Buffer, 0, $stream.Buffer.Length) }
                        if ($stream.Task.IsCompleted) {
                            $count = $stream.Task.GetAwaiter().GetResult(); $stream.Task = $null
                            if ($count -eq 0) { $stream.Closed = $true }
                            elseif ($null -ne $writer) {
                                try { $writer.Write((New-Object string($stream.Buffer, 0, $count))) } catch { }
                            }
                        }
                    }
                    catch { $stream.Closed = $true }
                }
                [Threading.Thread]::Sleep(40)
            }
            $process.WaitForExit()
        }
        if ($null -ne $writer) { $writer.Dispose() }
        $process.Dispose()
    }
}

function Set-WuRepairResult {
    param($Record, [int]$ExitCode)
    $Record.ExitCode = $ExitCode
    $Record.Status = 'Completed'
    $Record.Message = 'Command finished. Read the tool output for its diagnosis.'
    if ($Record.Id.StartsWith('disk.')) {
        if ($Record.Id -ne 'disk.scan') {
            $Record.Status = 'ReviewRequired'
            $Record.Message = 'Read the CHKDSK output to confirm whether a boot-time check was scheduled. Scheduling is not a completed repair. Restart manually if you accepted it.'
            if ($ExitCode -notin @(0, 1)) { $Record.Message += " CHKDSK exit code: $ExitCode; the check may not have run." }
        }
        elseif ($ExitCode -eq 0) { $Record.Message = 'CHKDSK reported no file-system errors.' }
        elseif ($ExitCode -eq 1) { $Record.Message = 'CHKDSK reported that file-system errors were fixed.' }
        elseif ($ExitCode -eq 3) {
            $Record.Status = 'NeedsAttention'
            $Record.Message = 'CHKDSK could not check the disk or left errors unresolved (exit 3). This code alone does not identify the cause. Read the command output before deciding whether a boot-time /f check is needed.'
        }
        else {
            $Record.Status = 'NeedsAttention'
            $Record.Message = "CHKDSK exit code ${ExitCode}: the scan did not establish a clean/repaired volume. Review its output and consider Advanced > CHKDSK /f before further repairs."
        }
    }
    elseif ($ExitCode -in @(3010, 1641)) {
        $Record.Status = 'RestartRequired'; $Record.RestartRequired = $true
        $Record.Message = 'Windows reports that a restart is required. Restart manually, then run the workflow again.'
    }
    elseif ($Record.Id.StartsWith('sfc.')) {
        # SFC output is localized and its exit code alone is not a reliable health verdict.
        $Record.Status = 'ReviewRequired'
        $Record.Message = 'Read the SFC summary and CBS.log to determine whether corruption remains. A completed process is not proof that every file was repaired.'
        if ($ExitCode -ne 0) { $Record.Status = 'NeedsAttention'; $Record.Message = "SFC exited with code $ExitCode. " + $Record.Message }
    }
    elseif ($ExitCode -ne 0) {
        $Record.Status = 'Failed'
        $hex = '{0:X8}' -f ([long]$ExitCode -band 4294967295L)
        $Record.Message = "DISM exited with code $ExitCode (0x$hex). Review the saved output and DISM.log."
        if ($hex -in @('800F081F', '800F0906', '800F0907')) {
            $Record.Message += ' Check the repair source, network/policy, or use Advanced > Repair from local WIM with matching Windows media.'
        }
        elseif ($ExitCode -eq 87) { $Record.Message += ' DISM rejected a command parameter. Check the command and its output before retrying.' }
    }
    elseif ($Record.Id -eq 'dism.check') {
        $Record.Message = 'Quick check finished: CheckHealth reads recorded corruption and can finish immediately. Read the DISM summary for its diagnosis; choose Scan image health for a fresh scan.'
    }
}

function Get-WuRepairHistoryDirectory {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable.' }
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'WinUtility') 'Repairs')
}

function Save-WuRepairReport {
    param($Report, [string]$Path)
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Report -Depth 12), (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Enter-WuRepairLock {
    # Machine-wide because DISM, SFC and disk repairs operate on Windows itself.
    $mutex = New-Object Threading.Mutex($false, $script:RepairMutexName)
    try {
        $acquired = $false
        try { $acquired = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Another WinUtility repair is running. Wait for it to finish.' }
        return $mutex
    }
    catch { $mutex.Dispose(); throw }
}

function Invoke-WuRepair {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [string]$SourcePath, [int]$SourceIndex = 0,
        [switch]$Confirmed, [string]$HistoryDirectory, [scriptblock]$OnProgress)
    if (-not $Confirmed) { throw 'Review and confirm the repair before running it.' }
    $environment = Get-WuRepairEnvironment
    $plan = @(Get-WuRepairPlan -Id $Id -SystemDrive $environment.SystemDrive -SourcePath $SourcePath -SourceIndex $SourceIndex)
    $blockers = @(Get-WuRepairBlockers -Plan $plan -Environment $environment)
    if ($blockers.Count -gt 0) { throw ($blockers -join ' ') }
    if ($Id -in @('dism.source', 'source.info') -and -not [IO.File]::Exists($SourcePath)) { throw 'The selected WIM file does not exist.' }
    foreach ($step in $plan) {
        if (-not [IO.File]::Exists((Join-Path $environment.SystemDirectory $step.Tool))) { throw "Windows tool is missing: $($step.Tool)." }
    }
    if ([string]::IsNullOrWhiteSpace($HistoryDirectory)) { $HistoryDirectory = Get-WuRepairHistoryDirectory }
    $mutex = Enter-WuRepairLock
    try {
        $runId = [guid]::NewGuid().ToString('N')
        $directory = Join-Path $HistoryDirectory $runId
        [void][IO.Directory]::CreateDirectory($directory)
        $path = Join-Path $directory 'report.json'
        $report = [pscustomobject][ordered]@{
            SchemaVersion = 1; RunId = $runId; RepairId = $Id; StartedAtUtc = [DateTime]::UtcNow.ToString('o')
            FinishedAtUtc = $null; ComputerName = $environment.Readiness.ComputerName
            UserSid = $environment.Readiness.UserSid; SystemDrive = $environment.SystemDrive
            Status = 'Running'; Steps = @(); NativeLogs = @(
                (Join-Path $environment.WindowsDirectory 'Logs\DISM\dism.log'),
                (Join-Path $environment.WindowsDirectory 'Logs\CBS\CBS.log'),
                'Event Viewer > Windows Logs > Application > Chkdsk / Wininit (including checks at next boot)'
            )
        }
        foreach ($step in $plan) {
            $report.Steps += [pscustomobject][ordered]@{
                Id = $step.Id; Name = $step.Name; Tool = $step.Tool; Arguments = $step.Arguments
                CommandLine = $step.CommandLine; ExecutablePath = (Join-Path $environment.SystemDirectory $step.Tool)
                Status = 'NotRun'; Message = 'Not started.'; ExitCode = $null; RestartRequired = $false
                StartedAtUtc = $null; DurationSeconds = $null; LogFile = ($step.Id + '.log')
            }
        }
        Save-WuRepairReport $report $path
        $stopped = $false
        for ($i = 0; $i -lt $plan.Count; $i++) {
            $step = $plan[$i]; $record = $report.Steps[$i]
            if ($stopped) { $record.Message = 'An earlier step needs attention. Resolve it, then run the workflow again.'; continue }
            # Servicing can request a restart during the run. Recheck before each repairing stage.
            if ($step.NeedsFreshRestart -and $i -gt 0 -and (Get-WuRepairEnvironment).Readiness.PendingReboot -eq $true) {
                $record.Status = 'RestartRequired'; $record.RestartRequired = $true
                $record.Message = 'A restart became pending during this run. Restart before continuing repairs.'
                $stopped = $true
                Save-WuRepairReport $report $path
                continue
            }
            $record.Status = 'Running'; $record.StartedAtUtc = [DateTime]::UtcNow.ToString('o')
            Save-WuRepairReport $report $path
            $timer = [Diagnostics.Stopwatch]::StartNew()
            try {
                if ($null -ne $OnProgress) { & $OnProgress $step.Name ($i + 1) $plan.Count | Out-Null }
                $native = Invoke-WuRepairProcess -FilePath (Join-Path $environment.SystemDirectory $step.Tool) -Arguments $step.Arguments -LogPath (Join-Path $directory $record.LogFile) -UnicodeOutput:($step.Tool -eq 'sfc.exe') -Interactive:$step.Interactive
                Set-WuRepairResult $record $native.ExitCode
            }
            catch { $record.Status = 'Failed'; $record.Message = "Repair stopped: $($_.Exception.Message) See the partial output; changes may already have occurred." }
            finally { $timer.Stop(); $record.DurationSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 1) }
            Save-WuRepairReport $report $path
            if ($record.Status -in @('Failed', 'NeedsAttention', 'RestartRequired')) { $stopped = $true }
        }
        $report.Status = 'Completed'
        if ($stopped) { $report.Status = 'Stopped' }
        elseif (@($report.Steps | Where-Object { $_.Status -eq 'ReviewRequired' }).Count -gt 0) { $report.Status = 'ReviewRequired' }
        $report.FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
        Save-WuRepairReport $report $path
        return [pscustomobject]@{ Path = $path; Report = $report }
    }
    finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}

function Get-WuRepairHistory {
    [CmdletBinding()]
    param([string]$HistoryDirectory)
    if ([string]::IsNullOrWhiteSpace($HistoryDirectory)) { $HistoryDirectory = Get-WuRepairHistoryDirectory }
    if (-not [IO.Directory]::Exists($HistoryDirectory)) { return }
    foreach ($directory in @(Get-ChildItem -LiteralPath $HistoryDirectory -Directory | Sort-Object LastWriteTimeUtc -Descending)) {
        $path = Join-Path $directory.FullName 'report.json'
        try {
            $report = [IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
            if ($report.SchemaVersion -ne 1 -or $report.Steps -isnot [array] -or $report.NativeLogs -isnot [array] -or
                ($report.StartedAtUtc -isnot [string] -and $report.StartedAtUtc -isnot [datetime]) -or $report.RepairId -isnot [string] -or
                $report.Status -notin @('Running', 'Completed', 'ReviewRequired', 'Stopped')) { throw 'Unsupported repair report.' }
            # Recent PowerShell versions deserialize ISO timestamps to DateTime; 5.1 keeps strings.
            if ($report.StartedAtUtc -is [datetime]) { $report.StartedAtUtc = $report.StartedAtUtc.ToUniversalTime().ToString('o') }
            foreach ($step in $report.Steps) {
                if ($step.LogFile -cnotmatch '\A[a-z]+\.[a-z]+\.log\z') { throw 'Invalid repair log name.' }
                foreach ($field in @('Id', 'Name', 'Status', 'Message', 'ExitCode', 'DurationSeconds')) {
                    if ($step.PSObject.Properties.Name -notcontains $field) { throw 'Incomplete repair step.' }
                }
                if ($step.PSObject.Properties.Name -contains 'CommandLine' -and $step.CommandLine -isnot [string]) { throw 'Invalid repair command description.' }
            }
            [pscustomobject]@{ Path = $path; Report = $report; Error = $null }
        }
        catch { [pscustomobject]@{ Path = $path; Report = $null; Error = $_.Exception.Message } }
    }
}

function Open-WuRepairAsAdministrator {
    [CmdletBinding()]
    param([switch]$Plain, [switch]$NoKeyNavigation)
    $environment = Get-WuRepairEnvironment
    if (-not $environment.Readiness.SupportedOS) { throw 'Administrator repair is available on Windows 11.' }
    $entry = [IO.Path]::GetFullPath((Join-Path (Split-Path $PSScriptRoot -Parent) 'WinUtility.ps1'))
    $executable = Join-Path $environment.SystemDirectory 'WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $entry, '-Repair')
    if ($Plain) { $arguments += '-Plain' }
    if ($NoKeyNavigation) { $arguments += '-NoKeyNavigation' }
    # Wait so the GitHub bootstrap keeps its temporary checkout until this child closes.
    Start-Process -FilePath $executable -ArgumentList (ConvertTo-WuNativeArguments $arguments) -Verb RunAs -Wait -ErrorAction Stop | Out-Null
}

Export-ModuleMember -Function Get-WuRepairCatalog, Get-WuRepairPlan, Get-WuRepairEnvironment, Get-WuRepairBlockers, Invoke-WuRepair, Get-WuRepairHistory, Open-WuRepairAsAdministrator
