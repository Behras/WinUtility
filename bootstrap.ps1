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
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Write-Host 'WinUtility | Downloading laptop setup utility...' -ForegroundColor Cyan
        # Resolve the branch once, then use that immutable commit for every project file.
        $commit = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/commits/$branch" -Headers $headers -TimeoutSec 30
        if ($null -eq $commit -or $commit.sha -cnotmatch '^[0-9a-f]{40}$') {
            throw 'GitHub did not return a valid project commit.'
        }
        Write-Host "Project revision: $($commit.sha)"
        [void][System.IO.Directory]::CreateDirectory($downloadDirectory)
        $archivePath = Join-Path $downloadDirectory 'project.zip'
        $extractPath = Join-Path $downloadDirectory 'project'
        $stage = 'download the project archive'
        Invoke-WebRequest -UseBasicParsing -Uri "https://api.github.com/repos/$repository/zipball/$($commit.sha)" -Headers $headers -OutFile $archivePath -TimeoutSec 120
        $stage = 'extract the project archive'
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -ErrorAction Stop | Out-Null
        $roots = @(Get-ChildItem -LiteralPath $extractPath -Directory)
        if ($roots.Count -ne 1) { throw 'The archive did not contain one project directory.' }
        $projectPath = $roots[0].FullName
        foreach ($required in @('WinUtility.ps1', 'src/WinUtility.Core.psm1', 'src/WinUtility.Terminal.psm1', 'src/WinUtility.Windows.psm1', 'src/WinUtility.Repair.psm1', 'data/settings.json', 'data/apps.json', 'data/presets.json')) {
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
        Write-Host 'You can also download the repository ZIP from GitHub, extract it, and run .\WinUtility.ps1.'
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
