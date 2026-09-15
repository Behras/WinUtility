#requires -Version 5.1
[CmdletBinding()]
param([switch]$Plain, [switch]$Preview, [switch]$Repair)

& {
    $ErrorActionPreference = 'Stop'
    try {
        # Import only for this invocation so the caller's shell stays unchanged.
        Import-Module (Join-Path $PSScriptRoot 'src/WinUtility.Core.psm1') -Force -Scope Local
        Import-Module (Join-Path $PSScriptRoot 'src/WinUtility.Terminal.psm1') -Force -Scope Local
        $catalog = Get-WuCatalog -DataPath (Join-Path $PSScriptRoot 'data')
        $session = New-WuSession -Catalog $catalog
        Start-WuTerminal -Session $session -Environment (Get-WuEnvironment) -Plain:$Plain -Preview:$Preview -Repair:$Repair
    }
    catch {
        Write-Host ''
        Write-Host ('WinUtility could not continue: {0}' -f $_.Exception.Message) -ForegroundColor Red
        throw
    }
}
