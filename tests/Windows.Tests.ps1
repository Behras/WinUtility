function Invoke-WindowsFixture {
    param([scriptblock]$Body)
    $directory = Join-Path $script:TestRoot ('history ' + [guid]::NewGuid().ToString('N'))
    $module = Import-Module (Join-Path $script:RepoRoot 'src/WinUtility.Windows.psm1') -Force -PassThru
    try {
        & $module {
            param($Action, $Directory, $Catalog)
            $script:Fake = @{
                Directory = $Directory; Catalog = $Catalog
                Environment = [pscustomobject]@{
                    OS = 'Windows 11'; Edition = 'Windows 11 Pro'; Build = 26100; Architecture = 'X64'
                    PowerShellVersion = '5.1'; SupportedOS = $true; WinGetAvailable = $true
                    WinGetPath = 'C:\Program Files\WindowsApps\winget.exe'; WinGetVersion = 'v1.12.0'
                    PendingReboot = $false; PowerStatus = 'AC power'; BatteryPercent = 80
                    UserSid = 'S-1-5-21-fixture'; ComputerName = 'FixtureLaptop'; IsAdmin = $false; Warnings = @()
                }
                Values = @{
                    'explorer.extensions' = [pscustomobject]@{ Exists = $true; Value = 1 }
                    'explorer.hidden' = [pscustomobject]@{ Exists = $false; Value = $null }
                }
                Writes = New-Object System.Collections.ArrayList
                WingetCalls = New-Object System.Collections.ArrayList
                Installed = @{}; QueryExit = @{}; InstallExit = @{}
                FailRead = $false; FailWriteAfter = $false; SaveCount = 0; FailSaveAt = 0
            }
            $script:OriginalSave = ${function:Save-WuJournal}
            function script:Get-WuReadiness { return $script:Fake.Environment }
            function script:Get-WuHistoryDirectory { return $script:Fake.Directory }
            function script:Read-WuExplorerValue {
                param($Id)
                if ($script:Fake.FailRead) { throw 'Registry read denied (fixture).' }
                $value = $script:Fake.Values[$Id]
                return [pscustomobject]@{ Exists = $value.Exists; Value = $value.Value }
            }
            function script:Write-WuExplorerValue {
                param($Id, $Snapshot)
                # Prove the original value is on disk before every write, including undo.
                $backups = @(Get-ChildItem -LiteralPath $script:Fake.Directory -Filter '*.json' | ForEach-Object {
                    $journal = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
                    $journal.Actions | Where-Object { $_.Id -eq $Id -and $null -ne $_.Before -and $null -ne $_.After }
                })
                if ($backups.Count -eq 0) { throw 'No durable backup before write.' }
                [void]$script:Fake.Writes.Add($Id)
                $script:Fake.Values[$Id] = [pscustomobject]@{ Exists = $Snapshot.Exists; Value = $Snapshot.Value }
                if ($script:Fake.FailWriteAfter) { throw 'Write verification failed (fixture).' }
            }
            function script:Save-WuJournal {
                param($Journal, $Path)
                $script:Fake.SaveCount++
                if ($script:Fake.SaveCount -eq $script:Fake.FailSaveAt) { throw 'Disk full (fixture).' }
                & $script:OriginalSave $Journal $Path
            }
            function script:Invoke-WuWinget {
                param($FilePath, $Arguments, [switch]$Visible)
                [void]$script:Fake.WingetCalls.Add(@($Arguments))
                $id = $Arguments[2]
                $code = 0
                if ($Arguments[0] -eq 'list') {
                    if ($script:Fake.QueryExit.ContainsKey($id)) { $code = $script:Fake.QueryExit[$id] }
                    elseif (-not $script:Fake.Installed.ContainsKey($id)) { $code = -1978335212 }
                }
                elseif ($Arguments[0] -eq 'install') {
                    if ($script:Fake.InstallExit.ContainsKey($id)) { $code = $script:Fake.InstallExit[$id] }
                    if ($code -eq 0) { $script:Fake.Installed[$id] = $true }
                }
                else { throw 'Unexpected native operation in test.' }
                return [pscustomobject]@{ ExitCode = $code; Output = "Fixture WinGet $($Arguments[0]): $id" }
            }
            & $Action $script:Fake
        } $Body $directory $script:Catalog
    }
    finally { Remove-Module -ModuleInfo $module -Force }
}

Test-Case 'Live actions refuse an unsupported host before creating history or making changes' {
    Invoke-WindowsFixture {
        param($fake)
        $session = New-WuSession $fake.Catalog
        Set-WuPreset $session minimal
        $fake.Environment.SupportedOS = $false
        Assert-Throws { Invoke-WuApply -Plan @(Get-WuPlan $session) -AcceptAppAgreements } '*verified Windows 11*'
        Assert-Equal 0 $fake.Writes.Count
        Assert-Equal 0 $fake.WingetCalls.Count
        Assert-True (-not (Test-Path -LiteralPath $fake.Directory))
    }
}

Test-Case 'Explorer apply saves original values, skips satisfied settings, and undoes missing values exactly' {
    Invoke-WindowsFixture {
        param($fake)
        $session = New-WuSession $fake.Catalog
        Set-WuSelection $session 'explorer.extensions'
        Set-WuSelection $session 'explorer.hidden'
        $fake.Values['explorer.extensions'].Value = 7
        $plan = @(Get-WuPlan $session)
        $review = @(Get-WuExecutionReview -Plan $plan -Environment $fake.Environment)
        Assert-Equal @('Ready', 'Ready') @($review.Status)
        $run = Invoke-WuApply -Plan $plan
        Assert-Equal @('Applied', 'Applied') @($run.Actions.Status)
        Assert-Equal 2 $fake.Writes.Count
        $onDisk = Get-Content -LiteralPath $run.Path -Raw | ConvertFrom-Json
        Assert-Equal 7 $onDisk.Actions[0].Before.Value
        Assert-Equal $false $onDisk.Actions[1].Before.Exists
        $again = Invoke-WuApply -Plan $plan
        Assert-Equal @('AlreadyConfigured', 'AlreadyConfigured') @($again.Actions.Status)
        Assert-Equal 2 $fake.Writes.Count
        Assert-Equal 0 @(Undo-WuExplorerRun -Path $again.Path).Count
        $undone = @(Undo-WuExplorerRun -Path $run.Path)
        Assert-Equal @('Restored', 'Restored') @($undone.Status)
        Assert-Equal 7 $fake.Values['explorer.extensions'].Value
        Assert-Equal $false $fake.Values['explorer.hidden'].Exists
        Assert-Equal @('AlreadyRestored', 'AlreadyRestored') @((Undo-WuExplorerRun -Path $run.Path).Status)
        Assert-Equal 4 $fake.Writes.Count
        Assert-Equal 2 @(Get-WuHistory).Count
    }
}

Test-Case 'Undo preserves subsequent edits and refuses history from another computer or user' {
    Invoke-WindowsFixture {
        param($fake)
        $session = New-WuSession $fake.Catalog
        Set-WuSelection $session 'explorer.extensions'
        $run = Invoke-WuApply -Plan @(Get-WuPlan $session)
        $fake.Values['explorer.extensions'].Value = 9
        Assert-Equal 'Conflict' (Undo-WuExplorerRun -Path $run.Path).Status
        Assert-Equal 9 $fake.Values['explorer.extensions'].Value
        Assert-Equal 1 $fake.Writes.Count
        $fake.Environment.ComputerName = 'DifferentLaptop'
        Assert-Throws { Undo-WuExplorerRun -Path $run.Path } '*different computer*'
        $fake.Environment.ComputerName = 'FixtureLaptop'
        $fake.Environment.UserSid = 'DifferentUser'
        Assert-Throws { Undo-WuExplorerRun -Path $run.Path } '*different computer*'
        Assert-Equal 1 $fake.Writes.Count
    }
}

Test-Case 'Failed backup persistence stops the entire queue before a setting write' {
    Invoke-WindowsFixture {
        param($fake)
        $session = New-WuSession $fake.Catalog
        Set-WuSelection $session 'explorer.extensions'
        Set-WuSelection $session 'app.7zip'
        $fake.FailSaveAt = 3
        Assert-Throws { Invoke-WuApply -Plan @(Get-WuPlan $session) -AcceptAppAgreements } '*Disk full*'
        Assert-Equal 0 $fake.Writes.Count
        Assert-Equal 0 $fake.WingetCalls.Count
        Assert-Equal 'Running' (Get-WuHistory).Status
    }
}

Test-Case 'Interrupted or failed setting writes retain enough data for later undo' {
    Invoke-WindowsFixture {
        param($fake)
        $session = New-WuSession $fake.Catalog
        Set-WuSelection $session 'explorer.hidden'
        $fake.FailWriteAfter = $true
        $run = Invoke-WuApply -Plan @(Get-WuPlan $session)
        Assert-Equal 'Failed' $run.Actions[0].Status
        Assert-Equal $null $run.Actions[0].Changed
        $fake.FailWriteAfter = $false
        $journal = Get-Content -LiteralPath $run.Path -Raw | ConvertFrom-Json
        $journal.Status = 'Running'; $journal.Actions[0].Status = 'Pending'
        [IO.File]::WriteAllText($run.Path, (ConvertTo-Json -InputObject $journal -Depth 12))
        Assert-Equal 'Restored' (Undo-WuExplorerRun -Path $run.Path).Status
        Assert-Equal $false $fake.Values['explorer.hidden'].Exists
    }
}

Test-Case 'Unimplemented settings are skipped and registry read failures block writes' {
    Invoke-WindowsFixture {
        param($fake)
        $session = New-WuSession $fake.Catalog
        Set-WuSelection $session 'privacy.suggestions'
        Set-WuSelection $session 'explorer.extensions'
        $fake.FailRead = $true
        $review = @(Get-WuExecutionReview -Plan @(Get-WuPlan $session) -Environment $fake.Environment)
        Assert-Equal @('PreviewOnly', 'Blocked') @($review.Status)
        $run = Invoke-WuApply -Plan @(Get-WuPlan $session)
        Assert-Equal @('Skipped', 'Failed') @($run.Actions.Status)
        Assert-Equal 0 $fake.Writes.Count
    }
}

Test-Case 'WinGet uses exact package IDs and source, installs missing apps once, and never upgrades' {
    Invoke-WindowsFixture {
        param($fake)
        $session = New-WuSession $fake.Catalog
        Set-WuSelection $session 'app.7zip'
        $plan = @(Get-WuPlan $session)
        Assert-Throws { Invoke-WuApply -Plan $plan } '*agreements*'
        Assert-Equal 0 $fake.WingetCalls.Count
        $review = @(Get-WuExecutionReview -Plan $plan -Environment $fake.Environment)
        Assert-Equal 'NotInstalled' $review[0].Current
        Assert-True ($fake.WingetCalls[0] -notcontains '--accept-source-agreements')
        $run = Invoke-WuApply -Plan $plan -AcceptAppAgreements
        Assert-Equal 'Installed' $run.Actions[0].Status
        $installs = @($fake.WingetCalls | Where-Object { $_[0] -eq 'install' })
        Assert-Equal 1 $installs.Count
        Assert-Equal @('install', '--id', '7zip.7zip', '--exact', '--source', 'winget', '--no-upgrade', '--silent', '--disable-interactivity', '--accept-package-agreements', '--accept-source-agreements') $installs[0]
        $again = Invoke-WuApply -Plan $plan -AcceptAppAgreements
        Assert-Equal 'AlreadyInstalled' $again.Actions[0].Status
        Assert-Equal 1 @($fake.WingetCalls | Where-Object { $_[0] -eq 'install' }).Count
        Assert-Equal 0 @(Undo-WuExplorerRun -Path $run.Path).Count
    }
}

Test-Case 'An unknown installed state does not trigger an install and missing WinGet does not block Explorer' {
    Invoke-WindowsFixture {
        param($fake)
        $session = New-WuSession $fake.Catalog
        Set-WuSelection $session 'app.7zip'
        $fake.QueryExit['7zip.7zip'] = -1978335214
        $run = Invoke-WuApply -Plan @(Get-WuPlan $session) -AcceptAppAgreements
        Assert-Equal 'Failed' $run.Actions[0].Status
        Assert-Equal 0 @($fake.WingetCalls | Where-Object { $_[0] -eq 'install' }).Count
        Set-WuSelection $session 'explorer.extensions'
        $fake.Environment.WinGetAvailable = $false
        $run = Invoke-WuApply -Plan @(Get-WuPlan $session) -AcceptAppAgreements
        Assert-Equal @('Applied', 'Skipped') @($run.Actions.Status)
    }
}

Test-Case 'App failures preserve output and the queue continues to the next selected app' {
    Invoke-WindowsFixture {
        param($fake)
        $session = New-WuSession $fake.Catalog
        Set-WuSelection $session 'app.firefox'
        Set-WuSelection $session 'app.7zip'
        $fake.InstallExit['Mozilla.Firefox'] = -1978335215
        $run = Invoke-WuApply -Plan @(Get-WuPlan $session) -AcceptAppAgreements
        Assert-Equal @('Failed', 'Installed') @($run.Actions.Status)
        Assert-Equal $null $run.Actions[0].Changed
        Assert-True ($run.Actions[0].Output.Contains('Mozilla.Firefox'))
        Assert-Equal (-1978335215) $run.Actions[0].ExitCode
    }
}

Test-Case 'Installer exit codes distinguish restart-to-finish, restart-before-retry, cancellation, and existing apps' {
    foreach ($spec in @(
        @(-1978334967, 'RestartRequired', $true), @(3010, 'RestartRequired', $true),
        @(-1978334966, 'Failed', $true), @(-1978334964, 'Cancelled', $false),
        @(-1978334963, 'AlreadyInstalled', $false), @(-1978335135, 'AlreadyInstalled', $false),
        @(-1978335189, 'AlreadyInstalled', $false)
    )) {
        Invoke-WindowsFixture {
            param($fake)
            $session = New-WuSession $fake.Catalog
            Set-WuSelection $session 'app.7zip'
            $fake.InstallExit['7zip.7zip'] = $spec[0]
            $run = Invoke-WuApply -Plan @(Get-WuPlan $session) -AcceptAppAgreements
            Assert-Equal $spec[1] $run.Actions[0].Status
            Assert-Equal $spec[2] $run.Actions[0].RestartRequired
            if ($spec[1] -eq 'AlreadyInstalled') { Assert-Equal $false $run.Actions[0].Changed }
        }
    }
}

Test-Case 'Corrupt undo data and duplicate plans are rejected without writes' {
    Invoke-WindowsFixture {
        param($fake)
        $session = New-WuSession $fake.Catalog
        Set-WuSelection $session 'explorer.extensions'
        $plan = @(Get-WuPlan $session)
        Assert-Throws { Invoke-WuApply -Plan @($plan[0], $plan[0]) } '*Duplicate action*'
        Assert-Equal 0 $fake.Writes.Count
        $run = Invoke-WuApply -Plan $plan
        $journal = Get-Content -LiteralPath $run.Path -Raw | ConvertFrom-Json
        $journal.Actions[0].Id = 'explorer.arbitrary-key'
        [IO.File]::WriteAllText($run.Path, (ConvertTo-Json -InputObject $journal -Depth 12))
        Assert-Throws { Undo-WuExplorerRun -Path $run.Path } '*invalid Explorer backup*'
        Assert-Equal 1 $fake.Writes.Count
        Assert-Equal 'Unreadable' (Get-WuHistory).Status
    }
}

Test-Case 'Another instance holding the operation lock prevents apply and undo' {
    Invoke-WindowsFixture {
        param($fake)
        $session = New-WuSession $fake.Catalog
        Set-WuSelection $session 'explorer.extensions'
        $run = Invoke-WuApply -Plan @(Get-WuPlan $session)
        $lock = [IO.File]::Open((Join-Path $fake.Directory 'operations.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            Assert-Throws { Invoke-WuApply -Plan @(Get-WuPlan $session) }
            Assert-Throws { Undo-WuExplorerRun -Path $run.Path }
            Assert-Equal 1 $fake.Writes.Count
        }
        finally { $lock.Dispose() }
    }
}

Test-Case 'Readiness distinguishes Windows clients from servers and retains unknown probe results' {
    $module = Import-Module (Join-Path $script:RepoRoot 'src/WinUtility.Windows.psm1') -Force -PassThru
    try {
        & $module {
            $script:ProductType = 1
            $script:FailOS = $false
            function script:Test-WuWindowsHost { return $true }
            function script:Get-WuWindowsIdentity { return [pscustomobject]@{ UserSid = 'fixture'; ComputerName = 'fixture'; IsAdmin = $false } }
            function script:Get-WuPendingReboot { throw 'Unreadable' }
            function script:Get-Command { return $null }
            function script:Get-CimInstance {
                param($ClassName, $ErrorAction)
                if ($ClassName -eq 'Win32_OperatingSystem') {
                    if ($script:FailOS) { throw 'OS information unavailable' }
                    return [pscustomobject]@{ Caption = 'Windows fixture'; BuildNumber = '26100'; ProductType = $script:ProductType }
                }
                return [pscustomobject]@{ EstimatedChargeRemaining = 40; BatteryStatus = 1 }
            }
            $client = Get-WuReadiness
            Assert-True $client.SupportedOS
            Assert-Equal $null $client.PendingReboot
            Assert-Equal 'On battery' $client.PowerStatus
            Assert-Equal 40 $client.BatteryPercent
            $script:ProductType = 3
            Assert-True (-not (Get-WuReadiness).SupportedOS)
            $script:ProductType = 1; $script:FailOS = $true
            Assert-True (-not (Get-WuReadiness).SupportedOS)
        }
    }
    finally { Remove-Module -ModuleInfo $module -Force }
}

Test-Case 'Native adapter preserves stderr and nonzero exit codes with executable and script arguments' {
    $module = Import-Module (Join-Path $script:RepoRoot 'src/WinUtility.Windows.psm1') -Force -PassThru
    $fixture = Join-Path $script:TestRoot 'native process fixture.ps1'
    [IO.File]::WriteAllText($fixture, '[Console]::Error.WriteLine("expected-native-stderr"); Write-Output "expected-native-stdout"; exit 7')
    $executableName = 'pwsh'
    if ($PSVersionTable.PSEdition -eq 'Desktop') { $executableName = 'powershell.exe' }
    elseif ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $executableName = 'pwsh.exe' }
    try {
        $result = & $module { param($Executable, $Script) Invoke-WuWinget -FilePath $Executable -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) } (Join-Path $PSHOME $executableName) $fixture
        Assert-Equal 7 $result.ExitCode
        Assert-True ($result.Output.Contains('expected-native-stderr'))
        Assert-True ($result.Output.Contains('expected-native-stdout'))
    }
    finally { Remove-Module -ModuleInfo $module -Force }
}

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    Test-Case 'Windows registry adapter preserves DWORD and absent values in an isolated test key' {
        $module = Import-Module (Join-Path $script:RepoRoot 'src/WinUtility.Windows.psm1') -Force -PassThru
        try {
            & $module {
                $script:ExplorerKey = 'Software\WinUtility.Test-' + [guid]::NewGuid().ToString('N')
                try {
                    Assert-Equal $false (Read-WuExplorerValue 'explorer.extensions').Exists
                    Write-WuExplorerValue 'explorer.extensions' ([pscustomobject]@{ Exists = $true; Value = 7 })
                    Assert-Equal 7 (Read-WuExplorerValue 'explorer.extensions').Value
                    Assert-Equal $false (Read-WuExplorerValue 'explorer.hidden').Exists
                    Write-WuExplorerValue 'explorer.extensions' ([pscustomobject]@{ Exists = $false; Value = $null })
                    Assert-Equal $false (Read-WuExplorerValue 'explorer.extensions').Exists
                }
                finally { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($script:ExplorerKey, $false) }
            }
        }
        finally { Remove-Module -ModuleInfo $module -Force }
    }
}
