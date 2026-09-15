function Invoke-StartupFixture {
    param([scriptblock]$Body)
    $module = Import-Module (Join-Path $script:RepoRoot 'src/WinUtility.Windows.psm1') -Force -PassThru
    $entry = Join-Path $script:TestRoot 'startup & path with spaces.ps1'
    [IO.File]::WriteAllText($entry, '# Startup fixture; never executed.')
    try {
        & $module {
            param($Body, $Entry)
            $script:Startup = @{
                Entry = $Entry; Calls = (New-Object Collections.ArrayList); SessionId = 7
                ErrorCode = 0; ExitCode = 0; Waited = $false
                Environment = [pscustomobject]@{ SupportedOS = $true; IsAdmin = $false; UserSid = 'S-1-5-21-123-456-789-1001' }
            }
            function script:Get-WuProcessSessionId { return $script:Startup.SessionId }
            function script:Start-Process {
                param($FilePath, $ArgumentList, $Verb, [switch]$Wait, [switch]$PassThru, $ErrorAction)
                [void]$script:Startup.Calls.Add(@{ Path = $FilePath; Arguments = $ArgumentList; Verb = $Verb; Wait = $Wait; PassThru = $PassThru })
                if ($script:Startup.ErrorCode) { throw (New-Object ComponentModel.Win32Exception($script:Startup.ErrorCode)) }
                $child = [pscustomobject]@{ ExitCode = $script:Startup.ExitCode }
                $child | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { $script:Startup.Waited = $true }
                return $child
            }
            & $Body $script:Startup
        } $Body $entry
    }
    finally { Remove-Module -ModuleInfo $module -Force }
}

Test-Case 'Startup requests elevation once, preserves flags and identity, and waits for the elevated menu' {
    Invoke-StartupFixture {
        param($fake)
        Assert-Equal $false (Initialize-WuStartup -EntryPath $fake.Entry -Environment $fake.Environment -Plain -Repair -NoKeyNavigation)
        Assert-Equal 1 $fake.Calls.Count
        $call = $fake.Calls[0]
        Assert-Equal 'RunAs' $call.Verb
        Assert-True $fake.Waited 'Bootstrap must retain its downloaded files until the menu process exits.'
        Assert-True (-not $call.Wait) 'Do not also wait for installed apps launched from that menu.'
        Assert-True $call.PassThru
        Assert-True ($call.Arguments.Contains('-File "' + $fake.Entry + '"'))
        Assert-True ($call.Arguments.Contains(' -Plain -Repair -NoKeyNavigation'))
        Assert-True ($call.Arguments.Contains('-ExpectedUserSid "' + $fake.Environment.UserSid + '" -ExpectedSessionId 7'))
        $fake.Environment.IsAdmin = $true
        Assert-Equal $true (Initialize-WuStartup -EntryPath $fake.Entry -Environment $fake.Environment -ExpectedUserSid $fake.Environment.UserSid -ExpectedSessionId 7)
        Assert-Equal 1 $fake.Calls.Count 'The elevated child must not relaunch again.'
    }
}

Test-Case 'Preview, unsupported hosts, and existing administrator sessions never request elevation' {
    Invoke-StartupFixture {
        param($fake)
        Assert-True (Initialize-WuStartup -EntryPath $fake.Entry -Environment $fake.Environment -Preview)
        $fake.Environment.SupportedOS = $false
        Assert-True (Initialize-WuStartup -EntryPath $fake.Entry -Environment $fake.Environment)
        $fake.Environment.SupportedOS = $true; $fake.Environment.IsAdmin = $true
        Assert-True (Initialize-WuStartup -EntryPath $fake.Entry -Environment $fake.Environment)
        Assert-Equal 0 $fake.Calls.Count
    }
}

Test-Case 'Cancelled UAC and a failed elevated child stop startup without a relaunch loop' {
    Invoke-StartupFixture {
        param($fake)
        $fake.ErrorCode = 1223
        Assert-Throws { Initialize-WuStartup -EntryPath $fake.Entry -Environment $fake.Environment } '*Administrator access was cancelled*'
        Assert-Equal 1 $fake.Calls.Count
        $fake.ErrorCode = 0; $fake.ExitCode = 5
        Assert-Throws { Initialize-WuStartup -EntryPath $fake.Entry -Environment $fake.Environment } '*exited with code 5*'
        Assert-Equal 2 $fake.Calls.Count
    }
}

Test-Case 'Startup refuses another account or session and missing elevation before allowing the menu' {
    Invoke-StartupFixture {
        param($fake)
        $fake.Environment.IsAdmin = $true
        Assert-Throws { Initialize-WuStartup -EntryPath $fake.Entry -Environment $fake.Environment -ExpectedUserSid 'S-1-5-21-123-456-789-1002' -ExpectedSessionId 7 } '*same Windows user*'
        Assert-Throws { Initialize-WuStartup -EntryPath $fake.Entry -Environment $fake.Environment -ExpectedUserSid $fake.Environment.UserSid -ExpectedSessionId 42 } '*same Windows user*'
        $fake.Environment.IsAdmin = $false
        Assert-Throws { Initialize-WuStartup -EntryPath $fake.Entry -Environment $fake.Environment -ExpectedUserSid $fake.Environment.UserSid -ExpectedSessionId 7 } '*administrator access*'
        Assert-Equal 0 $fake.Calls.Count
    }
}
