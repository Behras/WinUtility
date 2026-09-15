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
    param([string]$FilePath, [string[]]$Arguments, [switch]$Visible, [string]$OutputPath)
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
            if ($OutputPath) { [IO.File]::AppendAllText($OutputPath, $line + "`n", (New-Object Text.UTF8Encoding($false))) }
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
    return 'NotImplemented'
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
    param([string]$FilePath, [string]$PackageId, [switch]$AcceptAgreements, [string]$OutputPath)
    $arguments = @('list', '--id', $PackageId, '--exact', '--source', 'winget', '--disable-interactivity')
    if ($AcceptAgreements) { $arguments += '--accept-source-agreements' }
    $probe = Invoke-WuWinget -FilePath $FilePath -Arguments $arguments -OutputPath $OutputPath
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
        $row = [pscustomobject]@{ Id = $action.Id; Name = $action.Name; Capability = $capability; Current = 'Not checked'; Status = 'NotImplemented'; Message = 'Not implemented yet. This item makes no changes.' }
        if ($capability -ne 'NotImplemented' -and $Environment.SupportedOS) {
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
                elseif ($Environment.IsAdmin) {
                    $row.Status = 'Ready'
                    $row.Current = 'Checked during apply'
                    $row.Message = 'Check and install as this Windows user without administrator privileges. Installers can request elevation when needed.'
                }
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
        elseif ($capability -ne 'NotImplemented') { $row.Message = 'Real execution requires a verified Windows 11 workstation.' }
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

function Get-WuProcessSessionId {
    $process = [Diagnostics.Process]::GetCurrentProcess()
    try { return $process.SessionId }
    finally { $process.Dispose() }
}

function Invoke-WuUserAppInstall {
    param([string]$PackageId, $Environment, [string]$OutputPath)
    if (-not (Test-WuPackageId $PackageId)) { throw 'Invalid WinGet package ID.' }
    if (-not $Environment.SupportedOS -or -not $Environment.WinGetAvailable) { throw 'App installation requires Windows 11 and WinGet available for this user.' }
    if ($Environment.IsAdmin) { throw 'App installation must start in a normal PowerShell session, without Run as administrator.' }
    $probe = Get-WuInstalledApp $Environment.WinGetPath $PackageId -AcceptAgreements -OutputPath $OutputPath
    if ($probe.Status -ne 'NotInstalled') {
        return [pscustomobject]@{ Phase = 'Probe'; ExitCode = $probe.ExitCode; Output = $probe.Output }
    }
    $arguments = @('install', '--id', $PackageId, '--exact', '--source', 'winget', '--no-upgrade', '--silent', '--disable-interactivity', '--accept-package-agreements', '--accept-source-agreements')
    $native = Invoke-WuWinget -FilePath $Environment.WinGetPath -Arguments $arguments -Visible:(-not $OutputPath) -OutputPath $OutputPath
    return [pscustomobject]@{ Phase = 'Install'; ExitCode = $native.ExitCode; Output = $native.Output }
}

function Invoke-WuAppInstallWorker {
    # Internal entry point for AppWorker.ps1. Requests contain data, never commands.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RequestPath)
    $directory = Split-Path -Parent $RequestPath
    $request = [IO.File]::ReadAllText($RequestPath) | ConvertFrom-Json -ErrorAction Stop
    if ($request.SchemaVersion -ne 1 -or -not (Test-WuPackageId $request.PackageId) -or
        $request.RequestId -cnotmatch '\A[0-9a-f]{32}\z' -or $request.AcceptAppAgreements -isnot [bool] -or -not $request.AcceptAppAgreements) {
        throw 'Invalid app installation request.'
    }
    $response = [pscustomobject]@{
        SchemaVersion = 1; RequestId = $request.RequestId; PackageId = $request.PackageId
        UserSid = $null; SessionId = $null; IsAdmin = $null; Result = $null; Error = $null
    }
    try {
        $identity = Get-WuWindowsIdentity
        $response.UserSid = $identity.UserSid
        $response.IsAdmin = $identity.IsAdmin
        $response.SessionId = Get-WuProcessSessionId
        if ($identity.UserSid -cne $request.UserSid -or $response.SessionId -ne $request.SessionId) {
            throw 'The app worker is not in the same Windows user/session. Open WinUtility from that user''s normal PowerShell window.'
        }
        if ($identity.IsAdmin) {
            throw 'Windows did not provide a non-administrator session. Open WinUtility normally with UAC enabled; the built-in Administrator account cannot be used for these installs.'
        }
        # Signal startup before readiness/WinGet probes, which can take time on a new laptop.
        [IO.File]::WriteAllText((Join-Path $directory 'started'), $request.RequestId)
        $environment = Get-WuReadiness
        $response.Result = Invoke-WuUserAppInstall -PackageId $request.PackageId -Environment $environment -OutputPath (Join-Path $directory 'output.log')
    }
    catch { $response.Error = $_.Exception.Message }
    Save-WuJournal $response (Join-Path $directory 'result.json')
}

function Start-WuUserInstallTask {
    param([string]$RequestPath, [string]$UserSid, [string]$TaskName)
    $worker = Join-Path $PSScriptRoot 'WinUtility.AppWorker.ps1'
    # Task Scheduler is a native Windows process; System32 selects the system PowerShell.
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    foreach ($path in @($worker, $shell, $RequestPath)) {
        if ($path -match '["\x00-\x1f]' -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'The app worker or its request file is unavailable.' }
    }
    $context = [pscustomobject]@{ Service = $null; Folder = $null; Task = $null; Running = $null; Name = $TaskName }
    try {
        $context.Service = New-Object -ComObject 'Schedule.Service'
        $context.Service.Connect()
        $context.Folder = $context.Service.GetFolder('\')
        $definition = $context.Service.NewTask(0)
        $definition.RegistrationInfo.Description = 'Temporary WinUtility app install. Runs on demand only, without administrator privileges.'
        $definition.Principal.UserId = $UserSid
        $definition.Principal.LogonType = 3 # TASK_LOGON_INTERACTIVE_TOKEN; no password stored.
        $definition.Principal.RunLevel = 0 # TASK_RUNLEVEL_LUA; --scope user alone does not lower privileges.
        $definition.Settings.Enabled = $true
        $definition.Settings.AllowDemandStart = $true
        $definition.Settings.DisallowStartIfOnBatteries = $false
        $definition.Settings.StopIfGoingOnBatteries = $false
        $definition.Settings.ExecutionTimeLimit = 'PT6H'
        $action = $definition.Actions.Create(0)
        $action.Path = $shell
        $action.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $worker + '" -RequestPath "' + $RequestPath + '"'
        $action.WorkingDirectory = Split-Path -Parent $RequestPath
        # No triggers, saved credentials, or elevation. Never replace an existing task.
        $context.Task = $context.Folder.RegisterTaskDefinition($TaskName, $definition, 2, $UserSid, $null, 3, $null)
        $context.Running = $context.Task.Run($null)
        return $context
    }
    catch {
        Remove-WuUserInstallTask $context
        throw
    }
}

function Remove-WuUserInstallTask {
    param($Context, [switch]$Completed)
    if ($null -eq $Context) { return }
    if ($null -ne $Context.Task) {
        # A completed installer may have opened its app. Do not terminate that process tree.
        try { if (-not $Completed -and $Context.Task.State -in @(2, 4)) { $Context.Task.Stop(0) } } catch { Write-Warning "Could not stop app task '$($Context.Name)': $($_.Exception.Message)" }
        try { $Context.Folder.DeleteTask($Context.Name, 0) } catch { Write-Warning "Could not remove temporary app task '$($Context.Name)': $($_.Exception.Message)" }
    }
    foreach ($item in @($Context.Running, $Context.Task, $Context.Folder, $Context.Service)) {
        if ($null -ne $item -and [Runtime.InteropServices.Marshal]::IsComObject($item)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($item) }
    }
}

function Wait-WuUserInstallTask {
    param($Context, [string]$Directory)
    $resultPath = Join-Path $Directory 'result.json'
    $reader = New-Object IO.StreamReader([IO.File]::Open((Join-Path $Directory 'output.log'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite), [Text.Encoding]::UTF8)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($true) {
            $text = $reader.ReadToEnd()
            if ($text.Length -gt 0) { Write-Host $text -NoNewline }
            if ([IO.File]::Exists($resultPath)) {
                # The response is written atomically after all native output has been logged.
                $tail = $reader.ReadToEnd()
                if ($tail.Length -gt 0) { Write-Host $tail -NoNewline }
                return ([IO.File]::ReadAllText($resultPath) | ConvertFrom-Json -ErrorAction Stop)
            }
            try { $Context.Running.Refresh() }
            catch {
                # The worker may publish its result and exit between the file check and Refresh.
                if ([IO.File]::Exists($resultPath)) { continue }
                throw
            }
            if ($Context.Running.State -notin @(2, 4) -and $clock.Elapsed.TotalSeconds -ge 2) {
                if ([IO.File]::Exists($resultPath)) { continue }
                throw 'The normal-user app worker exited without a result. Check that this Windows user is signed in and can run PowerShell.'
            }
            if ($clock.Elapsed.TotalSeconds -ge 60 -and -not [IO.File]::Exists((Join-Path $Directory 'started'))) {
                throw 'The normal-user app worker did not start within 60 seconds. Open WinUtility in a normal PowerShell window and retry.'
            }
            if ($clock.Elapsed.TotalHours -ge 6) { throw 'The app worker exceeded six hours. Check the installed app before retrying; installation may be incomplete.' }
            Start-Sleep -Milliseconds 250
        }
    }
    finally { $reader.Dispose(); $clock.Stop() }
}

function Invoke-WuAppInstallAsUser {
    param([string]$PackageId, $Environment, [string]$HistoryDirectory)
    if (-not (Test-WuPackageId $PackageId)) { throw 'Invalid WinGet package ID.' }
    $id = [guid]::NewGuid().ToString('N')
    $directory = [IO.Path]::GetFullPath((Join-Path $HistoryDirectory ('app-' + $id)))
    $sessionId = Get-WuProcessSessionId
    if ($sessionId -le 0) { throw 'App installs need an interactive Windows session. Open WinUtility in a normal PowerShell window.' }
    $context = $null
    $completed = $false
    try {
        [void][IO.Directory]::CreateDirectory($directory)
        $request = [pscustomobject]@{
            SchemaVersion = 1; RequestId = $id; PackageId = $PackageId
            UserSid = $Environment.UserSid; SessionId = $sessionId; AcceptAppAgreements = $true
        }
        $requestPath = Join-Path $directory 'request.json'
        Save-WuJournal $request $requestPath
        [IO.File]::WriteAllText((Join-Path $directory 'output.log'), '')
        Write-Host "Installing $PackageId as your normal Windows user. Approve any installer UAC prompt to continue."
        $context = Start-WuUserInstallTask -RequestPath $requestPath -UserSid $Environment.UserSid -TaskName ('WinUtility-App-' + $id)
        $response = Wait-WuUserInstallTask -Context $context -Directory $directory
        $completed = $true
        if ($response.SchemaVersion -ne 1 -or $response.RequestId -cne $id -or $response.PackageId -cne $PackageId) { throw 'The app worker returned an invalid result.' }
        if ($response.Error) { throw $response.Error }
        if ($response.UserSid -cne $Environment.UserSid -or $response.SessionId -ne $sessionId -or $response.IsAdmin -isnot [bool] -or $response.IsAdmin) { throw 'The app worker did not confirm normal-user permissions for this Windows session.' }
        $result = $response.Result
        if ($null -eq $result -or $result.Phase -cnotin @('Probe', 'Install') -or
            ($result.ExitCode -isnot [int] -and $result.ExitCode -isnot [long]) -or
            $result.ExitCode -lt [int]::MinValue -or $result.ExitCode -gt [int]::MaxValue -or $result.Output -isnot [string]) { throw 'The app worker did not return a WinGet exit code and output.' }
        return $result
    }
    catch {
        $failure = New-Object InvalidOperationException("App install could not complete as a normal user: $($_.Exception.Message) Open WinUtility without Run as administrator and retry the failed apps. Check installed apps first if an installer was interrupted.", $_.Exception)
        try { $failure.Data['Output'] = [IO.File]::ReadAllText((Join-Path $directory 'output.log')) } catch { }
        throw $failure
    }
    finally {
        Remove-WuUserInstallTask $context -Completed:$completed
        if ([IO.Directory]::Exists($directory)) {
            try { [IO.Directory]::Delete($directory, $true) }
            catch { Write-Warning "Temporary app files could not be removed: $directory" }
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
            if ($capability -eq 'NotImplemented') { $record.Status = 'Skipped'; $record.Message = 'Not implemented yet. No changes made.' }
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
                    if ($environment.IsAdmin) {
                        $native = Invoke-WuAppInstallAsUser -PackageId $action.PackageId -Environment $environment -HistoryDirectory $HistoryDirectory
                    }
                    else { $native = Invoke-WuUserAppInstall -PackageId $action.PackageId -Environment $environment }
                    $record.Output = $native.Output
                    $record.ExitCode = $native.ExitCode
                    if ($native.Phase -eq 'Install') { Set-WuInstallResult $record $native.ExitCode }
                    elseif ($native.ExitCode -eq 0) { $record.Status = 'AlreadyInstalled'; $record.Message = 'Already installed; no upgrade requested.' }
                    else { $record.Status = 'Failed'; $record.Message = 'Could not determine installed status; fix WinGet and retry.' }
                }
                catch {
                    $record.Status = 'Failed'; $record.Changed = $null; $record.Message = $_.Exception.Message
                    if ($_.Exception.Data.Contains('Output')) { $record.Output = [string]$_.Exception.Data['Output'] }
                }
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

Export-ModuleMember -Function Get-WuReadiness, Get-WuActionCapability, Get-WuExecutionReview, Invoke-WuApply, Get-WuHistory, Undo-WuExplorerRun, Test-WuPackageId, Find-WuWinGetPackage, Get-WuWinGetPackageDetails, Invoke-WuAppInstallWorker
