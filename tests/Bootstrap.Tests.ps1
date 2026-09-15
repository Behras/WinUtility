function Invoke-BootstrapScenario {
    param([ValidateSet('success', 'network', 'download', 'extract', 'incomplete', 'invalid-commit')][string]$Scenario)
    $source = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'bootstrap.ps1'))
    $fixtureRoot = $script:TestRoot
    # Evaluate the bootstrap as downloaded text, with HTTP responses replaced by local fixtures.
    & {
        param($SourceText, $Mode, $FixtureRoot)
        $marker = Join-Path $FixtureRoot ('started ' + [guid]::NewGuid().ToString('N'))
        $context = @{ Mode = $Mode; Started = $false; Revision = ('a' * 40); DownloadPath = $null; Messages = New-Object 'System.Collections.Generic.List[string]'; Requests = New-Object 'System.Collections.Generic.List[string]' }
        function Write-Host {
            param($Object, $ForegroundColor)
            $context.Messages.Add([string]$Object)
        }
        function Invoke-RestMethod {
            param($Uri, $Headers, $TimeoutSec)
            $context.Requests.Add($Uri)
            if ($context.Mode -eq 'network') { throw 'Network unavailable (fixture).' }
            if ($context.Mode -eq 'invalid-commit') { return [pscustomobject]@{ sha = 'main' } }
            return [pscustomobject]@{ sha = $context.Revision }
        }
        function Invoke-WebRequest {
            param([switch]$UseBasicParsing, $Uri, $Headers, $OutFile, $TimeoutSec)
            $context.Requests.Add($Uri)
            $context.DownloadPath = Split-Path $OutFile -Parent
            if ($context.Mode -eq 'download') { throw 'Archive download failed (fixture).' }
            Assert-True ($Uri.EndsWith('/zipball/' + $context.Revision)) 'Archive must use the resolved commit, not the branch.'
            if ($context.Mode -eq 'extract') {
                [IO.File]::WriteAllText($OutFile, 'not a zip file')
                return
            }
            $archiveRoot = Join-Path $FixtureRoot ('archive ' + [guid]::NewGuid().ToString('N'))
            $project = Join-Path $archiveRoot 'project with spaces'
            [void][IO.Directory]::CreateDirectory((Join-Path $project 'src'))
            [void][IO.Directory]::CreateDirectory((Join-Path $project 'data'))
            foreach ($file in @('src/WinUtility.Core.psm1', 'src/WinUtility.Terminal.psm1', 'src/WinUtility.Windows.psm1', 'src/WinUtility.Repair.psm1', 'data/settings.json', 'data/apps.json', 'data/presets.json')) {
                [IO.File]::WriteAllText((Join-Path $project $file), '')
            }
            if ($context.Mode -ne 'incomplete') {
                $entrySource = "[System.IO.File]::WriteAllText('" + $marker.Replace("'", "''") + "', 'started')"
                [IO.File]::WriteAllText((Join-Path $project 'WinUtility.ps1'), $entrySource)
            }
            Compress-Archive -LiteralPath $project -DestinationPath $OutFile
        }
        $protocol = [Net.ServicePointManager]::SecurityProtocol
        $progress = $ProgressPreference
        $originalErrorPreference = $ErrorActionPreference
        $failure = $null
        try { Invoke-Expression $SourceText }
        catch { $failure = $_.Exception.Message }
        $context.Started = [IO.File]::Exists($marker)
        Assert-Equal $protocol ([Net.ServicePointManager]::SecurityProtocol)
        Assert-Equal $progress $ProgressPreference
        Assert-Equal $originalErrorPreference $ErrorActionPreference
        if ($null -ne $context.DownloadPath) { Assert-True (-not (Test-Path -LiteralPath $context.DownloadPath)) 'Temporary download should be cleaned up.' }
        return [pscustomobject]@{ Context = $context; Failure = $failure }
    } $source $Scenario $fixtureRoot
}

Test-Case 'Downloaded bootstrap pins the archive to a commit and starts from a spaced path' {
    $result = Invoke-BootstrapScenario success
    Assert-Equal $null $result.Failure
    Assert-True $result.Context.Started
    Assert-Equal 2 $result.Context.Requests.Count
}

foreach ($failureMode in @('network', 'download', 'extract', 'incomplete', 'invalid-commit')) {
    Test-Case "Bootstrap handles $failureMode failure without launching a partial project" {
        $result = Invoke-BootstrapScenario $failureMode
        Assert-True ($null -ne $result.Failure)
        Assert-True (-not $result.Context.Started)
        Assert-True (($result.Context.Messages -join "`n").Contains('WinUtility could not'))
    }
}
