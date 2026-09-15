if (-not ('WinUtility.Tests.DownloadException' -as [type])) {
    Add-Type -TypeDefinition @'
namespace WinUtility.Tests {
    public sealed class DownloadResponse {
        public int StatusCode { get; private set; }
        public DownloadResponse(int statusCode) { StatusCode = statusCode; }
    }
    public sealed class DownloadException : System.Exception {
        public DownloadResponse Response { get; private set; }
        public DownloadException(int statusCode) : base("HTTP " + statusCode) {
            Response = new DownloadResponse(statusCode);
        }
    }
}
'@
}

function Invoke-BootstrapScenario {
    param([ValidateSet('success', 'network', 'download', 'extract', 'incomplete', 'invalid-commit', 'api-retry', 'api-unavailable', 'timeout', 'archive-retry', 'archive-unavailable', 'not-found', 'forbidden', 'menu-failure')][string]$Scenario)
    $source = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'bootstrap.ps1'))
    $fixtureRoot = $script:TestRoot
    # Evaluate the bootstrap as downloaded text, with HTTP responses replaced by local fixtures.
    & {
        param($SourceText, $Mode, $FixtureRoot)
        $marker = Join-Path $FixtureRoot ('started ' + [guid]::NewGuid().ToString('N'))
        $context = @{
            Mode = $Mode; Started = $false; Revision = ('a' * 40); DownloadPath = $null
            ApiAttempts = 0; ArchiveAttempts = 0
            Messages = New-Object 'System.Collections.Generic.List[string]'
            Requests = New-Object 'System.Collections.Generic.List[string]'
            Delays = New-Object 'System.Collections.Generic.List[int]'
        }
        function Start-Sleep { param($Seconds) $context.Delays.Add($Seconds) }
        function Write-Host {
            param($Object, $ForegroundColor)
            $context.Messages.Add([string]$Object)
        }
        function Invoke-RestMethod {
            param($Uri, $Headers, $TimeoutSec, $ErrorAction)
            $context.Requests.Add($Uri)
            $context.ApiAttempts++
            Assert-Equal 'Stop' $ErrorAction
            if ($context.Mode -eq 'network') { throw (New-Object Net.WebException('DNS unavailable (fixture).', $null, ([Net.WebExceptionStatus]::NameResolutionFailure), $null)) }
            if ($context.Mode -eq 'not-found') { throw (New-Object WinUtility.Tests.DownloadException(404)) }
            if ($context.Mode -eq 'forbidden') { throw (New-Object WinUtility.Tests.DownloadException(403)) }
            if ($context.Mode -eq 'api-unavailable' -or ($context.Mode -eq 'api-retry' -and $context.ApiAttempts -lt 3)) { throw (New-Object WinUtility.Tests.DownloadException(504)) }
            if ($context.Mode -eq 'timeout' -and $context.ApiAttempts -eq 1) { throw (New-Object Net.WebException('Request timed out (fixture).', $null, ([Net.WebExceptionStatus]::Timeout), $null)) }
            if ($context.Mode -eq 'invalid-commit') { return [pscustomobject]@{ sha = 'main' } }
            return [pscustomobject]@{ sha = $context.Revision }
        }
        function Invoke-WebRequest {
            param([switch]$UseBasicParsing, $Uri, $Headers, $OutFile, $TimeoutSec, $ErrorAction)
            $context.Requests.Add($Uri)
            $context.ArchiveAttempts++
            $context.DownloadPath = Split-Path $OutFile -Parent
            Assert-Equal 'Stop' $ErrorAction
            Assert-True (-not [IO.File]::Exists($OutFile)) 'Partial archives must be removed before a new attempt.'
            if ($context.Mode -eq 'network') { throw (New-Object Net.WebException('DNS unavailable (fixture).', $null, ([Net.WebExceptionStatus]::NameResolutionFailure), $null)) }
            if ($context.Mode -eq 'download') { throw 'Archive download failed (fixture).' }
            if ($context.Mode -eq 'api-unavailable') {
                Assert-Equal 'https://codeload.github.com/Behras/WinUtility/zip/refs/heads/main' $Uri
            }
            else {
                Assert-True ($Uri.EndsWith('/zipball/' + $context.Revision) -or $Uri.EndsWith('/zip/' + $context.Revision)) 'Archive must use the resolved commit when the API is available.'
            }
            if ($context.Mode -eq 'archive-unavailable' -or ($context.Mode -eq 'archive-retry' -and $context.ArchiveAttempts -eq 1)) {
                [IO.File]::WriteAllText($OutFile, 'partial download')
                throw (New-Object WinUtility.Tests.DownloadException(504))
            }
            if ($context.Mode -eq 'extract') {
                [IO.File]::WriteAllText($OutFile, 'not a zip file')
                return
            }
            $archiveRoot = Join-Path $FixtureRoot ('archive ' + [guid]::NewGuid().ToString('N'))
            $project = Join-Path $archiveRoot 'project with spaces'
            [void][IO.Directory]::CreateDirectory((Join-Path $project 'src'))
            [void][IO.Directory]::CreateDirectory((Join-Path $project 'data'))
            foreach ($file in @('src/WinUtility.Core.psm1', 'src/WinUtility.Terminal.psm1', 'src/WinUtility.Windows.psm1', 'src/WinUtility.AppWorker.ps1', 'src/WinUtility.Repair.psm1', 'src/WinUtility.Input.psm1', 'data/settings.json', 'data/apps.json', 'data/presets.json')) {
                [IO.File]::WriteAllText((Join-Path $project $file), '')
            }
            if ($context.Mode -ne 'incomplete') {
                $entrySource = "[System.IO.File]::AppendAllText('" + $marker.Replace("'", "''") + "', 'started')"
                if ($context.Mode -eq 'menu-failure') { $entrySource += '; exit 7' }
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
        if ($context.Started) { Assert-Equal 'started' ([IO.File]::ReadAllText($marker)) 'The menu must run at most once.' }
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
    Assert-Equal 0 $result.Context.Delays.Count
}

foreach ($failureMode in @('network', 'download', 'extract', 'incomplete', 'invalid-commit')) {
    Test-Case "Bootstrap handles $failureMode failure without launching a partial project" {
        $result = Invoke-BootstrapScenario $failureMode
        Assert-True ($null -ne $result.Failure)
        Assert-True (-not $result.Context.Started)
        Assert-True (($result.Context.Messages -join "`n").Contains('WinUtility could not'))
    }
}

Test-Case 'Bootstrap retries temporary commit lookup failures with bounded delays and keeps the pinned revision' {
    $result = Invoke-BootstrapScenario api-retry
    Assert-Equal $null $result.Failure
    Assert-True $result.Context.Started
    Assert-Equal 3 $result.Context.ApiAttempts
    Assert-Equal 1 $result.Context.ArchiveAttempts
    Assert-Equal @(2, 4) @($result.Context.Delays)
    Assert-True (-not ($result.Context.Messages -join "`n").Contains('commit ID could not be verified'))
}

Test-Case 'A persistent GitHub API gateway timeout falls back to one direct branch archive' {
    $result = Invoke-BootstrapScenario api-unavailable
    Assert-Equal $null $result.Failure
    Assert-True $result.Context.Started
    Assert-Equal 3 $result.Context.ApiAttempts
    Assert-Equal 1 $result.Context.ArchiveAttempts
    Assert-Equal 4 $result.Context.Requests.Count
    Assert-Equal @(2, 4) @($result.Context.Delays)
    Assert-True (($result.Context.Messages -join "`n").Contains('commit ID could not be verified'))
    Assert-True (-not ($result.Context.Messages -join "`n").Contains('Project revision:'))
}

Test-Case 'Bootstrap retries Windows PowerShell transport timeouts' {
    $result = Invoke-BootstrapScenario timeout
    Assert-Equal $null $result.Failure
    Assert-True $result.Context.Started
    Assert-Equal 2 $result.Context.ApiAttempts
    Assert-Equal @(2) @($result.Context.Delays)
}

Test-Case 'An archive gateway timeout retries through codeload with the same commit and no partial file' {
    $result = Invoke-BootstrapScenario archive-retry
    Assert-Equal $null $result.Failure
    Assert-True $result.Context.Started
    Assert-Equal 1 $result.Context.ApiAttempts
    Assert-Equal 2 $result.Context.ArchiveAttempts
    Assert-Equal @(2) @($result.Context.Delays)
    Assert-Equal ('https://codeload.github.com/Behras/WinUtility/zip/' + $result.Context.Revision) $result.Context.Requests[2]
}

Test-Case 'Exhausted archive retries stop without launching and show the direct ZIP recovery option' {
    $result = Invoke-BootstrapScenario archive-unavailable
    Assert-True ($null -ne $result.Failure)
    Assert-True (-not $result.Context.Started)
    Assert-Equal 3 $result.Context.ArchiveAttempts
    Assert-Equal @(2, 4) @($result.Context.Delays)
    Assert-True (($result.Context.Messages -join "`n").Contains('Download the ZIP directly:'))
}

Test-Case 'Permanent API errors are not retried or silently replaced by a branch archive' {
    foreach ($mode in @('not-found', 'forbidden', 'invalid-commit')) {
        $result = Invoke-BootstrapScenario $mode
        Assert-True ($null -ne $result.Failure)
        Assert-True (-not $result.Context.Started)
        Assert-Equal 1 $result.Context.ApiAttempts
        Assert-Equal 0 $result.Context.ArchiveAttempts
        Assert-Equal 0 $result.Context.Delays.Count
    }
}

Test-Case 'A menu failure never restarts the utility or repeats download attempts' {
    $result = Invoke-BootstrapScenario menu-failure
    Assert-True ($result.Failure.Contains('code 7'))
    Assert-True $result.Context.Started
    Assert-Equal 2 $result.Context.Requests.Count
    Assert-Equal 0 $result.Context.Delays.Count
}
