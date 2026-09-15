#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Passed = 0
$script:Failed = 0
$script:RepoRoot = Split-Path $PSScriptRoot -Parent
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('WinUtility tests ' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($script:TestRoot)

function Assert-True {
    param([bool]$Condition, [string]$Message = 'Expected condition to be true.')
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param([AllowNull()]$Expected, [AllowNull()]$Actual, [string]$Message = 'Values differ.')
    $expectedJson = ConvertTo-Json -InputObject $Expected -Depth 15 -Compress
    $actualJson = ConvertTo-Json -InputObject $Actual -Depth 15 -Compress
    if ($expectedJson -cne $actualJson) { throw "$Message Expected: $expectedJson; actual: $actualJson" }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern = '*')
    $failure = $null
    try { & $Action | Out-Null }
    catch { $failure = $_ }
    if ($null -eq $failure) { throw 'Expected an exception, but the action succeeded.' }
    if ($failure.Exception.Message -notlike $Pattern) {
        throw "Unexpected exception: $($failure.Exception.Message); expected pattern: $Pattern"
    }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action | Out-Null
        $script:Passed++
        Write-Host "PASS $Name" -ForegroundColor Green
    }
    catch {
        $script:Failed++
        Write-Host "FAIL $Name" -ForegroundColor Red
        Write-Host $_.Exception.Message
        Write-Host $_.ScriptStackTrace
    }
}

try {
    Import-Module (Join-Path $script:RepoRoot 'src/WinUtility.Core.psm1') -Force
    $script:Catalog = Get-WuCatalog -DataPath (Join-Path $script:RepoRoot 'data')
    . (Join-Path $PSScriptRoot 'Core.Tests.ps1')
    . (Join-Path $PSScriptRoot 'Input.Tests.ps1')
    . (Join-Path $PSScriptRoot 'Terminal.Tests.ps1')
    . (Join-Path $PSScriptRoot 'Windows.Tests.ps1')
    . (Join-Path $PSScriptRoot 'Startup.Tests.ps1')
    . (Join-Path $PSScriptRoot 'AppWorker.Tests.ps1')
    . (Join-Path $PSScriptRoot 'Repair.Tests.ps1')
    . (Join-Path $PSScriptRoot 'Bootstrap.Tests.ps1')
}
finally {
    if ([IO.Directory]::Exists($script:TestRoot)) { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force }
}

Write-Host ''
Write-Host "$script:Passed passed; $script:Failed failed. PowerShell $($PSVersionTable.PSVersion)."
if ($script:Failed -gt 0) { exit 1 }
