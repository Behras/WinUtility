function Invoke-TaskSchedulerFixture {
    param([scriptblock]$Body)
    $module = Import-Module (Join-Path $script:RepoRoot 'src/WinUtility.Windows.psm1') -Force -PassThru
    $previousSystemRoot = $env:SystemRoot
    $directory = Join-Path $script:TestRoot ('task fixture ' + [guid]::NewGuid().ToString('N'))
    try {
        $env:SystemRoot = $directory
        $shell = Join-Path $directory 'System32/WindowsPowerShell/v1.0/powershell.exe'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $shell))
        [IO.File]::WriteAllText($shell, 'fixture, never executed')
        $request = Join-Path $directory "a user's request.json"
        [IO.File]::WriteAllText($request, '{}')
        & $module {
            param($Action, $Request)
            $script:TaskFixture = @{
                Connected = $false; Registered = $null; Deleted = @(); Stops = 0; FailRun = $false
                Definition = [pscustomobject]@{
                    RegistrationInfo = [pscustomobject]@{ Description = '' }
                    Principal = [pscustomobject]@{ UserId = ''; LogonType = -1; RunLevel = -1 }
                    Settings = [pscustomobject]@{ Enabled = $false; AllowDemandStart = $false; DisallowStartIfOnBatteries = $true; StopIfGoingOnBatteries = $true; ExecutionTimeLimit = '' }
                    Actions = [pscustomobject]@{}; Triggers = @()
                }
                Action = [pscustomobject]@{ Path = ''; Arguments = ''; WorkingDirectory = '' }
                Task = [pscustomobject]@{ State = 3 }; Running = [pscustomobject]@{}
                Folder = [pscustomobject]@{}; Service = [pscustomobject]@{}
            }
            $script:TaskFixture.Definition.Actions | Add-Member ScriptMethod Create {
                param($Type)
                Assert-Equal 0 $Type
                return $script:TaskFixture.Action
            }
            $script:TaskFixture.Service | Add-Member ScriptMethod Connect { $script:TaskFixture.Connected = $true }
            $script:TaskFixture.Service | Add-Member ScriptMethod GetFolder {
                param($Path)
                Assert-Equal '\' $Path
                return $script:TaskFixture.Folder
            }
            $script:TaskFixture.Service | Add-Member ScriptMethod NewTask { return $script:TaskFixture.Definition }
            $script:TaskFixture.Folder | Add-Member ScriptMethod RegisterTaskDefinition {
                param($Name, $Definition, $Flags, $User, $Password, $Logon, $Sddl)
                $script:TaskFixture.Registered = [pscustomobject]@{ Name = $Name; Flags = $Flags; User = $User; Password = $Password; Logon = $Logon }
                return $script:TaskFixture.Task
            }
            $script:TaskFixture.Folder | Add-Member ScriptMethod DeleteTask {
                param($Name, $Flags)
                $script:TaskFixture.Deleted += $Name
            }
            $script:TaskFixture.Task | Add-Member ScriptMethod Run {
                if ($script:TaskFixture.FailRun) { throw 'No interactive user (fixture).' }
                $script:TaskFixture.Task.State = 4
                return $script:TaskFixture.Running
            }
            $script:TaskFixture.Task | Add-Member ScriptMethod Stop { $script:TaskFixture.Stops++ }
            function script:New-Object {
                param($ComObject)
                Assert-Equal 'Schedule.Service' $ComObject
                return $script:TaskFixture.Service
            }
            & $Action $script:TaskFixture $ExecutionContext.SessionState.Module $Request
        } $Body $request
    }
    finally { $env:SystemRoot = $previousSystemRoot; Remove-Module -ModuleInfo $module -Force }
}

Test-Case 'The app task uses a limited interactive token, literal paths, no password, no triggers, and cleans up' {
    Invoke-TaskSchedulerFixture {
        param($fake, $module, $request)
        $context = & $module { param($Path) Start-WuUserInstallTask -RequestPath $Path -UserSid 'S-1-5-21-fixture' -TaskName 'WinUtility-App-fixture' } $request
        Assert-True $fake.Connected
        Assert-Equal 'S-1-5-21-fixture' $fake.Definition.Principal.UserId
        Assert-Equal 3 $fake.Definition.Principal.LogonType
        Assert-Equal 0 $fake.Definition.Principal.RunLevel
        Assert-Equal 'S-1-5-21-fixture' $fake.Registered.User
        Assert-Equal 3 $fake.Registered.Logon
        Assert-Equal $null $fake.Registered.Password
        Assert-Equal 2 $fake.Registered.Flags 'Only create a new task; never overwrite an existing task.'
        Assert-Equal 0 $fake.Definition.Triggers.Count
        Assert-True $fake.Definition.Settings.Enabled
        Assert-True $fake.Definition.Settings.AllowDemandStart
        Assert-Equal $false $fake.Definition.Settings.DisallowStartIfOnBatteries
        Assert-Equal $false $fake.Definition.Settings.StopIfGoingOnBatteries
        Assert-Equal 'PT6H' $fake.Definition.Settings.ExecutionTimeLimit
        Assert-True ($fake.Action.Arguments.EndsWith('-RequestPath "' + $request + '"'))
        Assert-True ($fake.Action.Arguments.Contains('-File "'))
        Assert-True (-not $fake.Action.Arguments.Contains('-Command '))
        Assert-Equal (Split-Path -Parent $request) $fake.Action.WorkingDirectory
        & $module { param($Context) Remove-WuUserInstallTask $Context -Completed } $context
        Assert-Equal @('WinUtility-App-fixture') $fake.Deleted
        Assert-Equal 0 $fake.Stops 'Do not stop a completed installer or an app it launched.'
    }
}

Test-Case 'An interrupted app worker is stopped before its task is removed' {
    Invoke-TaskSchedulerFixture {
        param($fake, $module, $request)
        $context = & $module { param($Path) Start-WuUserInstallTask -RequestPath $Path -UserSid 'fixture' -TaskName 'WinUtility-App-stopped' } $request
        & $module { param($Context) Remove-WuUserInstallTask $Context } $context
        Assert-Equal 1 $fake.Stops
        Assert-Equal @('WinUtility-App-stopped') $fake.Deleted
    }
}

Test-Case 'An app task that fails to launch is removed after registration' {
    Invoke-TaskSchedulerFixture {
        param($fake, $module, $request)
        $fake.FailRun = $true
        Assert-Throws { & $module { param($Path) Start-WuUserInstallTask -RequestPath $Path -UserSid 'fixture' -TaskName 'WinUtility-App-failed' } $request } '*No interactive user*'
        Assert-Equal @('WinUtility-App-failed') $fake.Deleted
        Assert-Equal 0 $fake.Stops
    }
}

Test-Case 'The worker rejects unsafe package IDs and missing agreement consent before running anything' {
    Invoke-WindowsFixture {
        param($fake)
        [void][IO.Directory]::CreateDirectory($fake.Directory)
        $requestPath = Join-Path $fake.Directory 'request.json'
        $request = [pscustomobject]@{
            SchemaVersion = 1; RequestId = ('a' * 32); PackageId = '--source other'
            UserSid = $fake.Environment.UserSid; SessionId = $fake.SessionId; AcceptAppAgreements = $true
        }
        [IO.File]::WriteAllText($requestPath, (ConvertTo-Json $request))
        Assert-Throws { Invoke-WuAppInstallWorker -RequestPath $requestPath } '*Invalid app*'
        $request.PackageId = 'Spotify.Spotify'
        foreach ($consent in @($false, 'true', 1)) {
            $request.AcceptAppAgreements = $consent
            [IO.File]::WriteAllText($requestPath, (ConvertTo-Json $request))
            Assert-Throws { Invoke-WuAppInstallWorker -RequestPath $requestPath } '*Invalid app*'
        }
        Assert-Equal 0 $fake.WingetCalls.Count
        Assert-True (-not [IO.File]::Exists((Join-Path $fake.Directory 'started')))
    }
}

Test-Case 'Worker wait streams appended output and returns only a completed result' {
    $module = Import-Module (Join-Path $script:RepoRoot 'src/WinUtility.Windows.psm1') -Force -PassThru
    $directory = Join-Path $script:TestRoot 'worker output fixture'
    [void][IO.Directory]::CreateDirectory($directory)
    [IO.File]::WriteAllText((Join-Path $directory 'output.log'), '')
    try {
        & $module {
            param($Directory)
            $script:WaitDirectory = $Directory
            $script:WaitOutput = ''
            function script:Write-Host { param($Object, [switch]$NoNewline) $script:WaitOutput += $Object }
            $running = [pscustomobject]@{ State = 4 }
            $running | Add-Member ScriptMethod Refresh {
                [IO.File]::AppendAllText((Join-Path $script:WaitDirectory 'output.log'), 'native progress and errors', (New-Object Text.UTF8Encoding($false)))
                Save-WuJournal ([pscustomobject]@{ ExitCode = 7 }) (Join-Path $script:WaitDirectory 'result.json')
            }
            $result = Wait-WuUserInstallTask -Context ([pscustomobject]@{ Running = $running }) -Directory $Directory
            Assert-Equal 7 $result.ExitCode
            Assert-Equal 'native progress and errors' $script:WaitOutput
        } $directory
    }
    finally { Remove-Module -ModuleInfo $module -Force }
}

Test-Case 'A worker exiting without a result is a failure, not a successful app install' {
    $module = Import-Module (Join-Path $script:RepoRoot 'src/WinUtility.Windows.psm1') -Force -PassThru
    $directory = Join-Path $script:TestRoot 'worker exited fixture'
    [void][IO.Directory]::CreateDirectory($directory)
    [IO.File]::WriteAllText((Join-Path $directory 'output.log'), '')
    try {
        & $module {
            param($Directory)
            $running = [pscustomobject]@{ State = 3 }
            $running | Add-Member ScriptMethod Refresh { }
            Assert-Throws { Wait-WuUserInstallTask -Context ([pscustomobject]@{ Running = $running }) -Directory $Directory } '*exited without a result*'
        } $directory
    }
    finally { Remove-Module -ModuleInfo $module -Force }
}

Test-Case 'A result written while the task is exiting is still collected after a refresh error' {
    $module = Import-Module (Join-Path $script:RepoRoot 'src/WinUtility.Windows.psm1') -Force -PassThru
    $directory = Join-Path $script:TestRoot 'worker completion race'
    [void][IO.Directory]::CreateDirectory($directory)
    [IO.File]::WriteAllText((Join-Path $directory 'output.log'), '')
    try {
        & $module {
            param($Directory)
            $script:WaitDirectory = $Directory
            $running = [pscustomobject]@{ State = 4 }
            $running | Add-Member ScriptMethod Refresh {
                Save-WuJournal ([pscustomobject]@{ ExitCode = 0 }) (Join-Path $script:WaitDirectory 'result.json')
                throw 'Task instance no longer exists (fixture).'
            }
            $result = Wait-WuUserInstallTask -Context ([pscustomobject]@{ Running = $running }) -Directory $Directory
            Assert-Equal 0 $result.ExitCode
        } $directory
    }
    finally { Remove-Module -ModuleInfo $module -Force }
}

Test-Case 'The standalone worker script returns a structured identity failure from a real child shell' {
    $directory = Join-Path $script:TestRoot 'worker child fixture'
    [void][IO.Directory]::CreateDirectory($directory)
    $requestPath = Join-Path $directory 'request.json'
    $request = [pscustomobject]@{
        SchemaVersion = 1; RequestId = ('b' * 32); PackageId = 'Spotify.Spotify'
        UserSid = 'deliberately-not-a-Windows-SID'; SessionId = -1; AcceptAppAgreements = $true
    }
    [IO.File]::WriteAllText($requestPath, (ConvertTo-Json $request))
    $executable = 'pwsh'
    if ($PSVersionTable.PSEdition -eq 'Desktop') { $executable = 'powershell.exe' }
    elseif ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $executable = 'pwsh.exe' }
    & (Join-Path $PSHOME $executable) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $script:RepoRoot 'src/WinUtility.AppWorker.ps1') -RequestPath $requestPath
    Assert-Equal 0 $LASTEXITCODE
    $response = Get-Content -LiteralPath (Join-Path $directory 'result.json') -Raw | ConvertFrom-Json
    Assert-Equal $request.RequestId $response.RequestId
    Assert-Equal $null $response.Result
    Assert-True (-not [string]::IsNullOrWhiteSpace($response.Error))
    Assert-True (-not [IO.File]::Exists((Join-Path $directory 'started')))
}
