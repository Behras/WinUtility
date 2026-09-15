Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'WinUtility.Windows.psm1') -Scope Local

function Assert-WuFields {
    param($Object, [string[]]$Required, [string[]]$Allowed, [string]$Context)
    if ($null -eq $Object -or $Object -isnot [pscustomobject]) {
        throw "$Context must be a JSON object."
    }
    $names = @($Object.PSObject.Properties.Name)
    foreach ($name in $Required) {
        if ($names -cnotcontains $name) { throw "$Context is missing '$name'." }
    }
    foreach ($name in $names) {
        if ($Allowed -cnotcontains $name) { throw "$Context contains unsupported field '$name'." }
    }
}

function Assert-WuText {
    param($Value, [string]$Context)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "$Context must be a non-empty string."
    }
    if ($Value -match '[\x00-\x1f\x7f]') { throw "$Context must be plain, single-line text." }
}

function Read-WuJson {
    param([string]$Path)
    try {
        $text = [System.IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($text)) { throw 'The file is empty.' }
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    }
    catch { throw "Could not read JSON file '$Path': $($_.Exception.Message)" }
}

function Assert-WuDocument {
    param($Document, [string]$ListName, [string]$Context)
    Assert-WuFields $Document @('schemaVersion', $ListName) @('schemaVersion', $ListName) $Context
    if (($Document.schemaVersion -isnot [int] -and $Document.schemaVersion -isnot [long]) -or
        $Document.schemaVersion -ne 1) {
        throw "$Context uses an unsupported schemaVersion. Expected 1."
    }
    if ($Document.$ListName -isnot [array]) { throw "$Context '$ListName' must be an array." }
}

function Get-WuCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataPath)

    $byId = @{}
    $groups = @{}
    foreach ($kind in @('settings', 'apps')) {
        $document = Read-WuJson (Join-Path $DataPath "$kind.json")
        Assert-WuDocument $document 'items' "$kind catalog"
        $items = @()
        foreach ($item in $document.items) {
            $fields = @('id', 'name', 'category', 'description', 'desiredValue')
            if ($kind -eq 'settings') { $fields += @('effect', 'requiresAdmin', 'requiresRestart') }
            else { $fields += 'packageId' }
            Assert-WuFields $item $fields $fields "$kind entry"
            foreach ($field in @('id', 'name', 'category', 'description', 'desiredValue')) {
                Assert-WuText $item.$field "$kind entry '$field'"
            }
            if ($item.id -cnotmatch '^[a-z][a-z0-9.-]*$') { throw "Invalid catalog ID '$($item.id)'." }
            if ($byId.ContainsKey($item.id)) { throw "Duplicate catalog ID '$($item.id)'." }
            if ($kind -eq 'settings') {
                Assert-WuText $item.effect "Effect for '$($item.id)'"
                if ($item.requiresAdmin -isnot [bool] -or $item.requiresRestart -isnot [bool]) {
                    throw "Administrator and restart metadata for '$($item.id)' must be boolean."
                }
            }
            else {
                Assert-WuText $item.packageId "WinGet package ID for '$($item.id)'"
                if ($item.packageId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
                    throw "Invalid WinGet package ID for '$($item.id)'."
                }
                if ($item.desiredValue -cne 'installed') { throw "Apps must use desiredValue 'installed'." }
            }
            $item | Add-Member -NotePropertyName kind -NotePropertyValue $(if ($kind -eq 'settings') { 'Setting' } else { 'App' })
            $byId[$item.id] = $item
            $items += $item
        }
        $groups[$kind] = $items
    }

    $presetDocument = Read-WuJson (Join-Path $DataPath 'presets.json')
    Assert-WuDocument $presetDocument 'items' 'Preset catalog'
    $presetIds = @{}
    foreach ($preset in $presetDocument.items) {
        $fields = @('id', 'name', 'description', 'itemIds')
        Assert-WuFields $preset $fields $fields 'Preset'
        foreach ($field in @('id', 'name', 'description')) { Assert-WuText $preset.$field "Preset '$field'" }
        if ($preset.id -cnotmatch '^[a-z][a-z0-9.-]*$' -or $presetIds.ContainsKey($preset.id)) {
            throw "Invalid or duplicate preset ID '$($preset.id)'."
        }
        $presetIds[$preset.id] = $true
        if ($preset.itemIds -isnot [array]) { throw "Preset '$($preset.id)' itemIds must be an array." }
        $seen = @{}
        foreach ($id in $preset.itemIds) {
            if ($id -isnot [string] -or -not $byId.ContainsKey($id) -or $byId[$id].id -cne $id) {
                throw "Preset '$($preset.id)' references an unknown catalog ID '$id'."
            }
            if ($seen.ContainsKey($id)) { throw "Preset '$($preset.id)' repeats '$id'." }
            $seen[$id] = $true
        }
    }

    return [pscustomobject]@{
        Settings = @($groups.settings)
        Apps = @($groups.apps)
        Presets = @($presetDocument.items)
        ById = $byId
    }
}

function New-WuSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog)
    return [pscustomobject]@{
        Catalog = $Catalog
        Selected = @{}
        SavedFingerprint = '[]'
        SavedPath = $null
        LastRun = $null
    }
}

function Set-WuSelection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Id)
    if (-not $Session.Catalog.ById.ContainsKey($Id) -or $Session.Catalog.ById[$Id].id -cne $Id) {
        throw "Unknown catalog ID '$Id'."
    }
    # Setting the same desired action twice must not duplicate it or lose its origin.
    if (-not $Session.Selected.ContainsKey($Id)) {
        $Session.Selected[$Id] = [pscustomobject]@{
            Id = $Id
            Value = $Session.Catalog.ById[$Id].desiredValue
            Source = 'Manual'
        }
    }
}

function Remove-WuSelection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Id)
    $Session.Selected.Remove($Id)
}

function Clear-WuSelection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)
    $Session.Selected.Clear()
}

function Set-WuPreset {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Id)
    $preset = @($Session.Catalog.Presets | Where-Object { $_.id -ceq $Id })
    if ($preset.Count -ne 1) { throw "Unknown preset '$Id'." }
    $selection = @{}
    foreach ($itemId in $preset[0].itemIds) {
        $selection[$itemId] = [pscustomobject]@{
            Id = $itemId
            Value = $Session.Catalog.ById[$itemId].desiredValue
            Source = "Preset: $($preset[0].name)"
        }
    }
    $Session.Selected = $selection
}

function Get-WuPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)
    # Catalog order is stable: settings first, then apps. The UI does not execute actions.
    foreach ($item in @($Session.Catalog.Settings) + @($Session.Catalog.Apps)) {
        if ($Session.Selected.ContainsKey($item.id)) {
            $selection = $Session.Selected[$item.id]
            $isSetting = $item.kind -eq 'Setting'
            [pscustomobject]@{
                Id = $item.id
                Kind = $item.kind
                Name = $item.name
                Category = $item.category
                Value = $selection.Value
                Source = $selection.Source
                Effect = $(if ($isSetting) { $item.effect } else { "Would request installation of $($item.name) through WinGet." })
                PackageId = $(if ($isSetting) { $null } else { $item.packageId })
                RequiresAdmin = $(if ($isSetting) { $item.requiresAdmin } else { $null })
                RequiresRestart = $(if ($isSetting) { $item.requiresRestart } else { $null })
            }
        }
    }
}

function Invoke-WuSimulation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan)
    # Simulation is independent of Windows APIs and always returns data only.
    foreach ($action in $Plan) {
        [pscustomobject]@{
            Id = $action.Id
            Name = $action.Name
            Status = 'Simulated'
            Message = $action.Effect
            Changed = $false
        }
    }
}

function Get-WuSelectionSnapshot {
    param($Session)
    $items = @(
        foreach ($id in @($Session.Selected.Keys | Sort-Object)) {
            [pscustomobject][ordered]@{ id = $id; value = $Session.Selected[$id].Value }
        }
    )
    return (ConvertTo-Json -InputObject $items -Depth 5 -Compress)
}

function Test-WuUnsavedChanges {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)
    return (Get-WuSelectionSnapshot $Session) -cne $Session.SavedFingerprint
}

function Export-WuSetup {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Path, [switch]$Overwrite)
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [System.IO.Directory]::Exists($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    $fingerprint = Get-WuSelectionSnapshot $Session
    $document = [ordered]@{
        schemaVersion = 1
        selections = @(ConvertFrom-Json -InputObject $fingerprint)
    }
    $json = ConvertTo-Json -InputObject $document -Depth 5
    # Write beside the destination, then replace it, preserving an existing file if writing fails.
    $temporaryPath = Join-Path $parent ('.winutility-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        if ([System.IO.File]::Exists($fullPath) -and $Overwrite) {
            [System.IO.File]::Replace($temporaryPath, $fullPath, [NullString]::Value)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $fullPath)
        }
        $Session.SavedFingerprint = $fingerprint
        $Session.SavedPath = $fullPath
        return $fullPath
    }
    catch { throw "Could not save setup to '$fullPath': $($_.Exception.Message)" }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }
    }
}

function Import-WuSetup {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)][string]$Path)
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $document = Read-WuJson $fullPath
    Assert-WuDocument $document 'selections' 'Saved setup'
    $selection = @{}
    foreach ($entry in $document.selections) {
        Assert-WuFields $entry @('id', 'value') @('id', 'value') 'Saved selection'
        Assert-WuText $entry.id 'Saved selection ID'
        if (-not $Catalog.ById.ContainsKey($entry.id) -or $Catalog.ById[$entry.id].id -cne $entry.id) {
            throw "Saved setup references unknown catalog ID '$($entry.id)'."
        }
        if ($selection.ContainsKey($entry.id)) { throw "Saved setup repeats '$($entry.id)'." }
        if ($entry.value -isnot [string] -or $entry.value -cne $Catalog.ById[$entry.id].desiredValue) {
            throw "Unsupported desired value for '$($entry.id)'."
        }
        $selection[$entry.id] = [pscustomobject]@{ Id = $entry.id; Value = $entry.value; Source = 'Saved setup' }
    }
    # Return a separate session for preview; the active session is never touched here.
    $preview = New-WuSession -Catalog $Catalog
    $preview.Selected = $selection
    $preview.SavedFingerprint = Get-WuSelectionSnapshot $preview
    $preview.SavedPath = $fullPath
    return $preview
}

function Set-WuImportedSetup {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Preview)
    $Session.Selected = @{}
    foreach ($entry in $Preview.Selected.Values) {
        $Session.Selected[$entry.Id] = [pscustomobject]@{ Id = $entry.Id; Value = $entry.Value; Source = 'Saved setup' }
    }
    $Session.SavedFingerprint = Get-WuSelectionSnapshot $Session
    $Session.SavedPath = $Preview.SavedPath
}

function Get-WuEnvironment {
    [CmdletBinding()]
    param()
    return Get-WuReadiness
}

function Get-WuDefaultSetupPath {
    [CmdletBinding()]
    param()
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($documents)) { $documents = [Environment]::GetFolderPath('UserProfile') }
    return (Join-Path (Join-Path $documents 'WinUtility') 'setup.json')
}

Export-ModuleMember -Function Get-WuCatalog, New-WuSession, Set-WuSelection, Remove-WuSelection, Clear-WuSelection, Set-WuPreset, Get-WuPlan, Invoke-WuSimulation, Test-WuUnsavedChanges, Export-WuSetup, Import-WuSetup, Set-WuImportedSetup, Get-WuEnvironment, Get-WuDefaultSetupPath
