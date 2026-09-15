#requires -Version 5.1
# Internal worker launched by the Windows adapter with a limited interactive token.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RequestPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'WinUtility.Windows.psm1') -Force
Invoke-WuAppInstallWorker -RequestPath $RequestPath
