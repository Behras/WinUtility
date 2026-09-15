#requires -Version 5.1
# Supports: irm https://raw.githubusercontent.com/Behras/WinUtility/main/bootstrap.ps1 | iex
# No dependency on PSScriptRoot: Invoke-Expression has no local script path.
& {
    $ErrorActionPreference = 'Stop'
    $repository = 'Behras/WinUtility'
    $branch = 'main'
    $headers = @{ 'User-Agent' = 'WinUtility-Bootstrap'; 'Accept' = 'application/vnd.github+json' }
    $downloadDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('WinUtility-' + [guid]::NewGuid().ToString('N'))
    $previousProtocol = [Net.ServicePointManager]::SecurityProtocol
    $previousProgress = $ProgressPreference
    $stage = 'contact GitHub'

    function Test-WuTemporaryDownloadError {
        param([Exception]$Exception)
        while ($null -ne $Exception) {
            $response = $Exception.PSObject.Properties['Response']
            if ($null -ne $response -and $null -ne $response.Value) {
                $status = $response.Value.PSObject.Properties['StatusCode']
                if ($null -ne $status) { return [int]$status.Value -in @(408, 500, 502, 503, 504) }
            }
            if ($Exception -is [Net.WebException]) {
                return $Exception.Status.ToString() -in @('Timeout', 'ConnectFailure', 'ConnectionClosed', 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ReceiveFailure', 'SendFailure', 'KeepAliveFailure')
            }
            if ($Exception.GetType().FullName -in @('System.Net.Http.HttpRequestException', 'System.Threading.Tasks.TaskCanceledException')) { return $true }
            $Exception = $Exception.InnerException
        }
        return $false
    }

    function Invoke-WuBootstrapDownload {
        param([string[]]$Uris, [int]$TimeoutSec, [string]$OutFile)
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $uri = $Uris[[Math]::Min($attempt - 1, $Uris.Count - 1)]
            try {
                Write-Host "Downloading (attempt $attempt/3): $uri"
                if ($OutFile) {
                    # A failed download must not leave bytes for the next attempt to reuse.
                    if ([IO.File]::Exists($OutFile)) { [IO.File]::Delete($OutFile) }
                    Invoke-WebRequest -UseBasicParsing -Uri $uri -Headers $headers -OutFile $OutFile -TimeoutSec $TimeoutSec -ErrorAction Stop | Out-Null
                    return
                }
                return Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec $TimeoutSec -ErrorAction Stop
            }
            catch {
                if ($attempt -eq 3 -or -not (Test-WuTemporaryDownloadError $_.Exception)) { throw }
                $delay = 2 * $attempt
                Write-Host "Temporary download failure: $($_.Exception.Message) Retrying in $delay seconds..." -ForegroundColor Yellow
                Start-Sleep -Seconds $delay
            }
        }
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Write-Host 'WinUtility | Downloading laptop setup utility...' -ForegroundColor Cyan
        # Prefer a pinned commit. During an API outage, one branch ZIP still keeps
        # every module/catalog in the same snapshot without individual file downloads.
        $commit = $null
        $branchArchive = $false
        try {
            $commit = Invoke-WuBootstrapDownload -Uris @("https://api.github.com/repos/$repository/commits/$branch") -TimeoutSec 30
        }
        catch {
            if (-not (Test-WuTemporaryDownloadError $_.Exception)) { throw }
            $branchArchive = $true
            Write-Host "GitHub's API is unavailable. Downloading one $branch branch archive directly." -ForegroundColor Yellow
        }
        if ($branchArchive) {
            $archiveUris = @("https://codeload.github.com/$repository/zip/refs/heads/$branch")
            Write-Host "Project source: $branch branch snapshot (commit ID could not be verified)."
        }
        else {
            if ($null -eq $commit -or $commit.PSObject.Properties.Name -notcontains 'sha' -or $commit.sha -cnotmatch '^[0-9a-f]{40}$') {
                throw 'GitHub did not return a valid project commit.'
            }
            Write-Host "Project revision: $($commit.sha)"
            $archiveUris = @("https://api.github.com/repos/$repository/zipball/$($commit.sha)", "https://codeload.github.com/$repository/zip/$($commit.sha)")
        }
        [void][System.IO.Directory]::CreateDirectory($downloadDirectory)
        $archivePath = Join-Path $downloadDirectory 'project.zip'
        $extractPath = Join-Path $downloadDirectory 'project'
        $stage = 'download the project archive'
        Invoke-WuBootstrapDownload -Uris $archiveUris -OutFile $archivePath -TimeoutSec 120
        $stage = 'extract the project archive'
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -ErrorAction Stop | Out-Null
        $roots = @(Get-ChildItem -LiteralPath $extractPath -Directory)
        if ($roots.Count -ne 1) { throw 'The archive did not contain one project directory.' }
        $projectPath = $roots[0].FullName
        foreach ($required in @('WinUtility.ps1', 'src/WinUtility.Core.psm1', 'src/WinUtility.Terminal.psm1', 'src/WinUtility.Windows.psm1', 'src/WinUtility.AppWorker.ps1', 'src/WinUtility.Repair.psm1', 'src/WinUtility.Input.psm1', 'data/settings.json', 'data/apps.json', 'data/presets.json')) {
            if (-not (Test-Path -LiteralPath (Join-Path $projectPath $required) -PathType Leaf)) {
                throw "The archive is missing '$required'."
            }
        }
        $ProgressPreference = $previousProgress
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
        $stage = 'start the menu'
        $executableName = 'pwsh'
        if ($PSVersionTable.PSEdition -eq 'Desktop') { $executableName = 'powershell.exe' }
        elseif ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $executableName = 'pwsh.exe' }
        $executable = Join-Path $PSHOME $executableName
        # A child shell can run on a fresh Windows install with Restricted policy.
        # -ExecutionPolicy applies only to that process; persistent policy is unchanged.
        & $executable -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projectPath 'WinUtility.ps1')
        if ($LASTEXITCODE -ne 0) { throw "The menu exited with code $LASTEXITCODE." }
    }
    catch {
        Write-Host "WinUtility could not ${stage}: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Download the ZIP directly: https://codeload.github.com/$repository/zip/refs/heads/$branch"
        Write-Host 'Extract it, open PowerShell in its folder, and run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WinUtility.ps1'
        throw
    }
    finally {
        $ProgressPreference = $previousProgress
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
        if ([System.IO.Directory]::Exists($downloadDirectory)) {
            try { Remove-Item -LiteralPath $downloadDirectory -Recurse -Force -ErrorAction Stop }
            catch { Write-Warning "Temporary download could not be removed: $downloadDirectory" }
        }
    }
}
