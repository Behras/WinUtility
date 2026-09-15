Set-StrictMode -Version 2.0

# All executable settings live here. Catalog JSON cannot supply registry paths or commands.
$script:ExplorerKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$script:ExplorerValues = @{
    'explorer.extensions' = @{ Name = 'HideFileExt'; Value = 0 }
    'explorer.hidden' = @{ Name = 'Hidden'; Value = 1 }
}

function Test-WuWindowsHost {
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Get-WuWindowsIdentity {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return [pscustomobject]@{
            UserSid = $identity.User.Value
            ComputerName = [Environment]::MachineName
            IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
    }
    finally { $identity.Dispose() }
}

function Get-WuPendingReboot {
    foreach ($path in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )) {
        if (Test-Path -LiteralPath $path -ErrorAction Stop) { return $true }
    }
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager')
    if ($null -eq $key) { throw 'Session Manager registry state is unavailable.' }
    try {
        return @($key.GetValue('PendingFileRenameOperations', $null) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
    }
    finally { $key.Dispose() }
}

function Invoke-WuWinget {
    param([string]$FilePath, [string[]]$Arguments, [switch]$Visible)
    # Native stderr must not turn a WinGet exit code into a PowerShell 5.1 exception.
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    # Native commands update the global automatic variable, even when called from a module.
    # A local LASTEXITCODE would hide that update. Preserve the caller's value explicitly.
    $previousExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $previousValue = $null
    if ($null -ne $previousExitCode) { $previousValue = $previousExitCode.Value }
    $global:LASTEXITCODE = $null
    try {
        $output = @(& $FilePath @Arguments 2>&1 | ForEach-Object {
            $line = [string]$_
            if ($Visible) { Write-Host $line }
            $line
        })
        if ($null -eq $global:LASTEXITCODE) { throw 'WinGet could not be started.' }
        return [pscustomobject]@{ ExitCode = [int]$global:LASTEXITCODE; Output = $output -join "`n" }
    }
    finally {
        if ($null -eq $previousExitCode) { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
        else { $global:LASTEXITCODE = $previousValue }
    }
}

function Get-WuReadiness {
    [CmdletBinding()]
    param()
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($architecture)) { $architecture = $env:PROCESSOR_ARCHITECTURE }
    if ([string]::IsNullOrWhiteSpace($architecture)) { $architecture = 'Unknown' }
    if (-not (Test-WuWindowsHost)) { $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() }
    $report = [pscustomobject][ordered]@{
        OS = 'Non-Windows host'; Edition = 'Not applicable'; Build = $null
        Architecture = $architecture
        PowerShellVersion = $PSVersionTable.PSVersion.ToString(); SupportedOS = $false
        WinGetAvailable = $false; WinGetPath = $null; WinGetVersion = 'Unavailable'
        PendingReboot = $null; PowerStatus = 'Not applicable'; BatteryPercent = $null
        UserSid = $null; ComputerName = [Environment]::MachineName; IsAdmin = $false
        Warnings = @()
    }
    if (-not (Test-WuWindowsHost)) { return $report }
    $report.OS = 'Windows (version not verified)'
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $report.Edition = [string]$os.Caption
        $report.Build = [int]$os.BuildNumber
        $report.OS = "$($report.Edition) (build $($report.Build))"
        # ProductType 1 is a workstation: do not treat a recent Windows Server as Windows 11.
        $report.SupportedOS = $os.ProductType -eq 1 -and $report.Build -ge 22000
    }
    catch { $report.Warnings += "Windows version could not be verified: $($_.Exception.Message)" }
    try {
        $identity = Get-WuWindowsIdentity
        $report.UserSid = $identity.UserSid
        $report.ComputerName = $identity.ComputerName
        $report.IsAdmin = $identity.IsAdmin
    }
    catch { $report.Warnings += "Current Windows user could not be verified: $($_.Exception.Message)" }
    try { $report.PendingReboot = Get-WuPendingReboot }
    catch { $report.Warnings += 'Pending restart could not be determined.' }
    try {
        $batteries = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
        $report.PowerStatus = 'No battery detected'
        if ($batteries.Count -gt 0) {
            $report.PowerStatus = 'Power source unknown'
            $charge = @($batteries | Where-Object { $null -ne $_.EstimatedChargeRemaining -and $_.EstimatedChargeRemaining -le 100 })
            if ($charge.Count -gt 0) { $report.BatteryPercent = [int](($charge | Measure-Object -Property EstimatedChargeRemaining -Minimum).Minimum) }
            if (@($batteries | Where-Object { $_.BatteryStatus -in @(1, 4, 5) }).Count -gt 0) { $report.PowerStatus = 'On battery' }
            elseif (@($batteries | Where-Object { $_.BatteryStatus -in @(2, 6, 7, 8, 9) }).Count -eq $batteries.Count) { $report.PowerStatus = 'AC power / charging' }
        }
    }
    catch { $report.PowerStatus = 'Unknown'; $report.Warnings += 'Battery information could not be read.' }
    $command = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        $report.WinGetPath = $command.Source
        try {
            $probe = Invoke-WuWinget -FilePath $report.WinGetPath -Arguments @('--version')
            if ($probe.ExitCode -ne 0) { throw "Exit code $($probe.ExitCode)" }
            $report.WinGetAvailable = $true
            $report.WinGetVersion = $probe.Output.Trim()
        }
        catch { $report.Warnings += "WinGet is present but not usable: $($_.Exception.Message)" }
    }
    return $report
}

function Test-WuPackageId {
    param($PackageId)
    return $PackageId -is [string] -and $PackageId.Length -le 128 -and $PackageId -cmatch '\A[A-Za-z0-9][A-Za-z0-9._+-]*\z'
}

function Invoke-WuPackageLookup {
    param([ValidateSet('search', 'show')][string]$Operation, [string]$Value, [switch]$AcceptSourceAgreements)
    if ($Operation -eq 'show' -and -not (Test-WuPackageId $Value)) { throw 'Enter an exact WinGet package ID.' }
    if ($Operation -eq 'search' -and ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 100 -or $Value -match '["\x00-\x1f\x7f]')) {
        throw 'Enter a search of 1-100 characters without double quotes or control characters.'
    }
    $environment = Get-WuReadiness
    if (-not $environment.SupportedOS -or -not $environment.WinGetAvailable) { throw 'Live search requires Windows 11 with WinGet available. Use the bundled catalog on this host.' }
    $arguments = @('search', '--query', $Value, '--count', '40')
    if ($Operation -eq 'show') { $arguments = @('show', '--id', $Value, '--exact') }
    $arguments += @('--source', 'winget', '--disable-interactivity')
    if ($AcceptSourceAgreements) { $arguments += '--accept-source-agreements' }
    $native = Invoke-WuWinget -FilePath $environment.WinGetPath -Arguments $arguments
    $status = 'Failed'
    if ($native.ExitCode -eq 0) { $status = 'Found' }
    elseif ($native.ExitCode -eq -1978335212) { $status = 'NotFound' }
    elseif ($native.ExitCode -eq -1978335162) { $status = 'SourceAgreementRequired' }
    return [pscustomobject]@{ Status = $status; ExitCode = $native.ExitCode; Output = $native.Output }
}

function Find-WuWinGetPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Query, [switch]$AcceptSourceAgreements)
    return Invoke-WuPackageLookup -Operation search -Value $Query -AcceptSourceAgreements:$AcceptSourceAgreements
}

function Get-WuWinGetPackageDetails {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackageId, [switch]$AcceptSourceAgreements)
    return Invoke-WuPackageLookup -Operation show -Value $PackageId -AcceptSourceAgreements:$AcceptSourceAgreements
}

function Get-WuActionCapability {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Action)
    if ($Action.Kind -ceq 'Setting' -and $script:ExplorerValues.ContainsKey($Action.Id) -and $Action.Value -ceq 'visible') { return 'Explorer' }
    if ($Action.Kind -ceq 'App' -and $Action.Value -ceq 'installed' -and $Action.Id -cmatch '^app\.[a-z0-9.-]+$' -and
        (Test-WuPackageId $Action.PackageId)) { return 'WinGet' }
    return 'PreviewOnly'
}

function Read-WuExplorerValue {
    param([string]$Id)
    if (-not $script:ExplorerValues.ContainsKey($Id)) { throw 'Unsupported Explorer setting.' }
    $name = $script:ExplorerValues[$Id].Name
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:ExplorerKey)
    try {
        if ($null -eq $key -or $key.GetValueNames() -notcontains $name) {
            return [pscustomobject]@{ Exists = $false; Value = $null }
        }
        if ($key.GetValueKind($name) -ne [Microsoft.Win32.RegistryValueKind]::DWord) { throw 'The existing registry value is not a DWORD; leaving it unchanged.' }
        return [pscustomobject]@{ Exists = $true; Value = [int]$key.GetValue($name) }
    }
    finally { if ($null -ne $key) { $key.Dispose() } }
}

function Test-WuSnapshot {
    param($Snapshot)
    if ($null -eq $Snapshot -or $Snapshot.PSObject.Properties.Name -notcontains 'Exists' -or $Snapshot.PSObject.Properties.Name -notcontains 'Value') { return $false }
    if ($Snapshot.Exists -isnot [bool]) { return $false }
    if (-not $Snapshot.Exists) { return $null -eq $Snapshot.Value }
    return ($Snapshot.Value -is [int] -or $Snapshot.Value -is [long]) -and $Snapshot.Value -ge [int]::MinValue -and $Snapshot.Value -le [int]::MaxValue
}

function Test-WuSameValue {
    param($Left, $Right)
    return $Left.Exists -eq $Right.Exists -and ((-not $Left.Exists) -or $Left.Value -eq $Right.Value)
}

function Write-WuExplorerValue {
    param([string]$Id, $Snapshot)
    if (-not $script:ExplorerValues.ContainsKey($Id) -or -not (Test-WuSnapshot $Snapshot)) { throw 'Invalid Explorer operation.' }
    $key = $null
    try {
        if ($Snapshot.Exists) {
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($script:ExplorerKey)
            $key.SetValue($script:ExplorerValues[$Id].Name, [int]$Snapshot.Value, [Microsoft.Win32.RegistryValueKind]::DWord)
        }
        else {
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:ExplorerKey, $true)
            if ($null -ne $key) { $key.DeleteValue($script:ExplorerValues[$Id].Name, $false) }
        }
    }
    finally { if ($null -ne $key) { $key.Dispose() } }
}

function Get-WuInstalledApp {
    param([string]$FilePath, [string]$PackageId, [switch]$AcceptAgreements)
    $arguments = @('list', '--id', $PackageId, '--exact', '--source', 'winget', '--disable-interactivity')
    if ($AcceptAgreements) { $arguments += '--accept-source-agreements' }
    $probe = Invoke-WuWinget -FilePath $FilePath -Arguments $arguments
    $status = 'Unknown'
    if ($probe.ExitCode -eq 0) { $status = 'Installed' }
    elseif ($probe.ExitCode -eq -1978335212) { $status = 'NotInstalled' }
    return [pscustomobject]@{ Status = $status; ExitCode = $probe.ExitCode; Output = $probe.Output }
}

function Get-WuExecutionReview {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Plan, [Parameter(Mandatory)]$Environment)
    foreach ($action in $Plan) {
        $capability = Get-WuActionCapability $action
        $row = [pscustomobject]@{ Id = $action.Id; Name = $action.Name; Capability = $capability; Current = 'Not checked'; Status = 'PreviewOnly'; Message = 'No real handler in this milestone.' }
        if ($capability -ne 'PreviewOnly' -and $Environment.SupportedOS) {
            try {
                if ($capability -eq 'Explorer') {
                    $before = Read-WuExplorerValue $action.Id
                    $row.Current = 'Windows default (value absent)'
                    if ($before.Exists) { $row.Current = "Registry value $($before.Value)" }
                    $row.Status = 'Ready'
                    $row.Message = 'Selected: visible. The previous value will be saved for undo.'
                    if ($before.Exists -and $before.Value -eq $script:ExplorerValues[$action.Id].Value) { $row.Current = 'Visible'; $row.Status = 'AlreadyConfigured'; $row.Message = 'Already configured; no write needed.' }
                    elseif ($before.Exists -and (($action.Id -eq 'explorer.extensions' -and $before.Value -eq 1) -or ($action.Id -eq 'explorer.hidden' -and $before.Value -eq 2))) { $row.Current = 'Hidden' }
                }
                elseif (-not $Environment.WinGetAvailable) { $row.Status = 'Blocked'; $row.Message = 'WinGet is unavailable. Install/update App Installer, then refresh readiness.' }
                else {
                    $probe = Get-WuInstalledApp $Environment.WinGetPath $action.PackageId
                    $row.Current = $probe.Status
                    $row.Status = 'Ready'
                    $row.Message = 'Install only if missing; existing versions will not be upgraded.'
                    if ($probe.Status -eq 'Installed') { $row.Status = 'AlreadyInstalled' }
                    elseif ($probe.Status -eq 'Unknown') { $row.Message = 'Installed status is unknown; it will be checked again after confirming source terms.' }
                }
            }
            catch { $row.Status = 'Blocked'; $row.Current = 'Unknown'; $row.Message = $_.Exception.Message }
        }
        elseif ($capability -ne 'PreviewOnly') { $row.Message = 'Real execution requires a verified Windows 11 workstation.' }
        $row
    }
}

function Get-WuHistoryDirectory {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable.' }
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'WinUtility') 'History')
}

function Save-WuJournal {
    param($Journal, [string]$Path)
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Journal -Depth 12), (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function New-WuJournal {
    param($Environment, [string]$Directory)
    [void][IO.Directory]::CreateDirectory($Directory)
    $id = [guid]::NewGuid().ToString('N')
    return [pscustomobject]@{
        Path = Join-Path $Directory ($id + '.json')
        Document = [pscustomobject][ordered]@{
            SchemaVersion = 1; RunId = $id; StartedAtUtc = [DateTime]::UtcNow.ToString('o')
            ComputerName = $Environment.ComputerName; UserSid = $Environment.UserSid
            Status = 'Running'; Actions = @()
        }
    }
}

function Set-WuInstallResult {
    param($Record, [int]$ExitCode)
    $Record.ExitCode = $ExitCode
    switch ($ExitCode) {
        0 { $Record.Status = 'Installed'; $Record.Changed = $true; $Record.Message = 'WinGet reported a successful installation.' }
        -1978334963 { $Record.Status = 'AlreadyInstalled'; $Record.Changed = $false; $Record.Message = 'The installer reports an existing version.' }
        -1978335135 { $Record.Status = 'AlreadyInstalled'; $Record.Changed = $false; $Record.Message = 'WinGet skipped the existing installation (--no-upgrade).' }
        -1978335189 { $Record.Status = 'AlreadyInstalled'; $Record.Changed = $false; $Record.Message = 'WinGet skipped the existing installation.' }
        -1978334967 { $Record.Status = 'RestartRequired'; $Record.Changed = $true; $Record.RestartRequired = $true; $Record.Message = 'Restart Windows to finish installation.' }
        3010 { $Record.Status = 'RestartRequired'; $Record.Changed = $true; $Record.RestartRequired = $true; $Record.Message = 'Restart Windows to finish installation.' }
        -1978334966 { $Record.Status = 'Failed'; $Record.Changed = $null; $Record.RestartRequired = $true; $Record.Message = 'Restart Windows, then retry this installation.' }
        -1978334965 { $Record.Status = 'RestartRequired'; $Record.Changed = $null; $Record.RestartRequired = $true; $Record.Message = 'The installer reports that it initiated a restart.' }
        1641 { $Record.Status = 'RestartRequired'; $Record.Changed = $null; $Record.RestartRequired = $true; $Record.Message = 'The installer reports that it initiated a restart.' }
        -1978334964 { $Record.Status = 'Cancelled'; $Record.Changed = $null; $Record.Message = 'The installation was cancelled; changes may be partial.' }
        default { $Record.Status = 'Failed'; $Record.Changed = $null; $Record.Message = "WinGet failed with exit code $ExitCode. See the saved output; changes may be partial." }
    }
}

function Invoke-WuApply {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan, [switch]$AcceptAppAgreements, [string]$HistoryDirectory, [scriptblock]$OnProgress)
    $environment = Get-WuReadiness
    if (-not $environment.SupportedOS -or [string]::IsNullOrWhiteSpace($environment.UserSid)) { throw 'Real execution requires a verified Windows 11 workstation and current user.' }
    $seen = @{}
    foreach ($action in $Plan) {
        if ($seen.ContainsKey($action.Id)) { throw "Duplicate action '$($action.Id)'." }
        $seen[$action.Id] = $true
        if ((Get-WuActionCapability $action) -eq 'WinGet' -and -not $AcceptAppAgreements) { throw 'Confirm app and source agreements before starting this app queue.' }
    }
    if ([string]::IsNullOrWhiteSpace($HistoryDirectory)) { $HistoryDirectory = Get-WuHistoryDirectory }
    # A shared lock also prevents a second instance from undoing an in-progress run.
    [void][IO.Directory]::CreateDirectory($HistoryDirectory)
    $lock = [IO.File]::Open((Join-Path $HistoryDirectory 'operations.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $run = New-WuJournal $environment $HistoryDirectory
        Save-WuJournal $run.Document $run.Path
        foreach ($action in $Plan) {
            $record = [pscustomobject][ordered]@{
                Id = $action.Id; Name = $action.Name; Kind = $action.Kind; PackageId = $action.PackageId
                Status = 'Pending'; Message = ''; Changed = $false; RestartRequired = $false
                ExitCode = $null; Before = $null; After = $null; Output = ''; UndoStatus = $null
            }
            $run.Document.Actions += $record
            $capability = Get-WuActionCapability $action
            if ($null -ne $OnProgress) { & $OnProgress $action.Name | Out-Null }
            # Persist failures/intent before running the next operation. A journal write failure stops the queue.
            Save-WuJournal $run.Document $run.Path
            if ($capability -eq 'PreviewOnly') { $record.Status = 'Skipped'; $record.Message = 'Preview only: no real handler in this milestone.' }
            elseif ($capability -eq 'Explorer') {
                try {
                    $record.Before = Read-WuExplorerValue $action.Id
                    $record.After = [pscustomobject]@{ Exists = $true; Value = $script:ExplorerValues[$action.Id].Value }
                    if (Test-WuSameValue $record.Before $record.After) { $record.Status = 'AlreadyConfigured'; $record.Message = 'The desired setting is already configured.' }
                }
                catch { $record.Status = 'Failed'; $record.Message = $_.Exception.Message }
                if ($record.Status -eq 'Pending') {
                    Save-WuJournal $run.Document $run.Path
                    try {
                        Write-WuExplorerValue $action.Id $record.After
                        if (-not (Test-WuSameValue (Read-WuExplorerValue $action.Id) $record.After)) { throw 'The setting did not retain the requested value.' }
                        $record.Status = 'Applied'; $record.Changed = $true
                        $record.Message = 'Explorer setting applied. Reopen Explorer windows or sign out/in if needed.'
                    }
                    catch { $record.Status = 'Failed'; $record.Changed = $null; $record.Message = $_.Exception.Message }
                }
            }
            elseif (-not $environment.WinGetAvailable) { $record.Status = 'Skipped'; $record.Message = 'WinGet is unavailable; this app was not installed.' }
            else {
                try {
                    $probe = Get-WuInstalledApp $environment.WinGetPath $action.PackageId -AcceptAgreements
                    if ($probe.Status -eq 'Installed') { $record.Status = 'AlreadyInstalled'; $record.Message = 'Already installed; no upgrade requested.' }
                    elseif ($probe.Status -eq 'Unknown') { $record.Status = 'Failed'; $record.Message = 'Could not determine installed status; fix WinGet and retry.'; $record.ExitCode = $probe.ExitCode; $record.Output = $probe.Output }
                    else {
                        $arguments = @('install', '--id', $action.PackageId, '--exact', '--source', 'winget', '--no-upgrade', '--silent', '--disable-interactivity', '--accept-package-agreements', '--accept-source-agreements')
                        $native = Invoke-WuWinget -FilePath $environment.WinGetPath -Arguments $arguments -Visible
                        Set-WuInstallResult $record $native.ExitCode
                        $record.Output = $native.Output
                    }
                }
                catch { $record.Status = 'Failed'; $record.Changed = $null; $record.Message = $_.Exception.Message }
            }
            Save-WuJournal $run.Document $run.Path
        }
        $run.Document.Status = 'Completed'
        Save-WuJournal $run.Document $run.Path
        return [pscustomobject]@{ Path = $run.Path; Actions = @($run.Document.Actions) }
    }
    finally { $lock.Dispose() }
}

function Read-WuJournal {
    param([string]$Path, $Environment)
    $document = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $document -or $document.SchemaVersion -ne 1 -or $document.Actions -isnot [array]) { throw 'Unsupported history file.' }
    if ($document.ComputerName -cne $Environment.ComputerName -or $document.UserSid -cne $Environment.UserSid) { throw 'This history belongs to a different computer or Windows user.' }
    $seen = @{}
    foreach ($entry in $document.Actions) {
        if ($seen.ContainsKey($entry.Id)) { throw 'History contains duplicate actions.' }
        $seen[$entry.Id] = $true
        if ($entry.Kind -ceq 'Setting' -and ($null -ne $entry.Before -or $null -ne $entry.After)) {
            if (-not $script:ExplorerValues.ContainsKey($entry.Id) -or -not (Test-WuSnapshot $entry.Before) -or -not (Test-WuSnapshot $entry.After)) { throw 'History contains an invalid Explorer backup.' }
            if (-not $entry.After.Exists -or $entry.After.Value -ne $script:ExplorerValues[$entry.Id].Value) { throw 'History contains an unexpected target value.' }
        }
    }
    return $document
}

function Get-WuHistory {
    [CmdletBinding()]
    param([string]$HistoryDirectory)
    $environment = Get-WuReadiness
    if (-not $environment.SupportedOS) { return }
    if ([string]::IsNullOrWhiteSpace($HistoryDirectory)) { $HistoryDirectory = Get-WuHistoryDirectory }
    if (-not (Test-Path -LiteralPath $HistoryDirectory -PathType Container)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $HistoryDirectory -Filter '*.json' -File | Sort-Object LastWriteTimeUtc -Descending)) {
        try {
            $document = Read-WuJournal $file.FullName $environment
            [pscustomobject]@{ Path = $file.FullName; StartedAtUtc = $document.StartedAtUtc; Status = $document.Status; Actions = @($document.Actions); Error = $null }
        }
        catch { [pscustomobject]@{ Path = $file.FullName; StartedAtUtc = $file.LastWriteTimeUtc.ToString('o'); Status = 'Unreadable'; Actions = @(); Error = $_.Exception.Message } }
    }
}

function Undo-WuExplorerRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $environment = Get-WuReadiness
    if (-not $environment.SupportedOS -or [string]::IsNullOrWhiteSpace($environment.UserSid)) { throw 'Undo requires a verified Windows 11 workstation and current user.' }
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    $lock = [IO.File]::Open((Join-Path $directory 'operations.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $document = Read-WuJournal $Path $environment
        $results = @()
        foreach ($entry in $document.Actions) {
            if ($entry.Kind -cne 'Setting' -or $null -eq $entry.Before -or $null -eq $entry.After -or $entry.Status -eq 'AlreadyConfigured') { continue }
            $result = [pscustomobject]@{ Id = $entry.Id; Name = $entry.Name; Status = 'Failed'; Message = ''; Changed = $false; RestartRequired = $false }
            try {
                $current = Read-WuExplorerValue $entry.Id
                if (Test-WuSameValue $current $entry.Before) { $result.Status = 'AlreadyRestored'; $result.Message = 'The original value is already in place.' }
                elseif ($entry.UndoStatus -eq 'Restored' -or -not (Test-WuSameValue $current $entry.After)) { $result.Status = 'Conflict'; $result.Message = 'The setting changed after this run; leaving the newer value untouched.' }
                else {
                    $entry.UndoStatus = 'Pending'
                    Save-WuJournal $document $Path
                    Write-WuExplorerValue $entry.Id $entry.Before
                    if (-not (Test-WuSameValue (Read-WuExplorerValue $entry.Id) $entry.Before)) { throw 'Could not verify the restored value.' }
                    $result.Status = 'Restored'; $result.Changed = $true
                    $result.Message = 'Original Explorer value restored. Reopen Explorer or sign out/in if needed.'
                }
            }
            catch { $result.Message = $_.Exception.Message; $result.Changed = $null }
            if ($result.Status -in @('Restored', 'AlreadyRestored')) { $entry.UndoStatus = 'Restored' }
            Save-WuJournal $document $Path
            $results += $result
        }
        return $results
    }
    finally { $lock.Dispose() }
}

Export-ModuleMember -Function Get-WuReadiness, Get-WuActionCapability, Get-WuExecutionReview, Invoke-WuApply, Get-WuHistory, Undo-WuExplorerRun, Test-WuPackageId, Find-WuWinGetPackage, Get-WuWinGetPackageDetails
