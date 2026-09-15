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
    param($Document, [string]$ListName, [string]$Context, [int[]]$Versions = @(1))
    Assert-WuFields $Document @('schemaVersion', $ListName) @('schemaVersion', $ListName) $Context
    if (($Document.schemaVersion -isnot [int] -and $Document.schemaVersion -isnot [long]) -or
        $Document.schemaVersion -notin $Versions) {
        throw "$Context uses an unsupported schemaVersion. Expected $($Versions -join ' or ')."
    }
    if ($Document.$ListName -isnot [array]) { throw "$Context '$ListName' must be an array." }
}

function Get-WuCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataPath)

    $byId = @{}
    $packageIds = @{}
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
                if (-not (Test-WuPackageId $item.packageId)) {
                    throw "Invalid WinGet package ID for '$($item.id)'."
                }
                if ($packageIds.ContainsKey($item.packageId)) { throw "Duplicate WinGet package ID '$($item.packageId)'." }
                $packageIds[$item.packageId] = $true
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
        AdditionalApps = @{}
        Selected = @{}
        SavedFingerprint = '[]'
        SavedPath = $null
        LastRun = $null
    }
}

function Set-WuSelection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Id)
    $item = Get-WuSessionItem -Session $Session -Id $Id
    # Setting the same desired action twice must not duplicate it or lose its origin.
    if (-not $Session.Selected.ContainsKey($Id)) {
        $Session.Selected[$Id] = [pscustomobject]@{
            Id = $Id
            Value = $item.desiredValue
            Source = 'Manual'
        }
    }
}

function Get-WuSessionItem {
    param($Session, [string]$Id)
    if ($Session.Catalog.ById.ContainsKey($Id) -and $Session.Catalog.ById[$Id].id -ceq $Id) { return $Session.Catalog.ById[$Id] }
    if ($Session.AdditionalApps.ContainsKey($Id) -and $Session.AdditionalApps[$Id].id -ceq $Id) { return $Session.AdditionalApps[$Id] }
    throw "Unknown catalog ID '$Id'."
}

function Get-WuAppItems {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)
    $Session.Catalog.Apps
    $Session.AdditionalApps.Values | Sort-Object packageId
}

function Find-WuCatalogApp {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Query)
    foreach ($item in @(Get-WuAppItems $Session)) {
        foreach ($field in @('name', 'description', 'category', 'packageId')) {
            if ($item.$field.IndexOf($Query, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $item; break }
        }
    }
}

function New-WuWinGetItem {
    param([string]$PackageId)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($PackageId.ToLowerInvariant()))).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    return [pscustomobject]@{
        id = 'app.winget.' + $hash; name = $PackageId; category = 'From WinGet'
        description = 'Package from the winget source. Use live search to inspect its publisher and installer details.'
        packageId = $PackageId; desiredValue = 'installed'; kind = 'App'
    }
}

function Add-WuWinGetSelection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string[]]$PackageIds)
    # Validate the entire batch before changing the session. The UI verifies package existence.
    foreach ($packageId in $PackageIds) {
        if (-not (Test-WuPackageId $packageId)) { throw "Invalid WinGet package ID '$packageId'." }
    }
    foreach ($packageId in $PackageIds) {
        $existing = @(Get-WuAppItems $Session | Where-Object { $_.packageId -ieq $packageId })
        if ($existing.Count -gt 0) { $item = $existing[0] }
        else {
            $item = New-WuWinGetItem $packageId
            $Session.AdditionalApps[$item.id] = $item
        }
        Set-WuSelection -Session $Session -Id $item.id
    }
}

function ConvertFrom-WuBatchInput {
    [CmdletBinding()]
    param([string]$Text, [int]$First, [int]$Last)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 500) { throw 'Enter numbers such as 1,3,5-7.' }
    $numbers = @{}
    foreach ($part in @($Text.Trim() -split '[,\s]+')) {
        if ($part -notmatch '^([0-9]+)(?:-([0-9]+))?$') { throw 'Use numbers and ranges such as 1,3,5-7.' }
        $start = 0; $end = 0
        if (-not [int]::TryParse($Matches[1], [ref]$start)) { throw 'A selection number is too large.' }
        $end = $start
        if ($Matches.ContainsKey(2) -and -not [int]::TryParse($Matches[2], [ref]$end)) { throw 'A selection number is too large.' }
        if ($start -lt $First -or $end -gt $Last -or $end -lt $start) { throw 'Use only the numbers shown on this page, with ascending ranges.' }
        for ($number = $start; $number -le $end; $number++) { $numbers[$number] = $true }
    }
    # Return only after every token passed validation; duplicates toggle just once.
    $numbers.Keys | Sort-Object
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
    foreach ($item in @($Session.Catalog.Settings) + @(Get-WuAppItems $Session)) {
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

function Get-WuSelectionSnapshot {
    param($Session)
    $items = @(
        foreach ($id in @($Session.Selected.Keys | Sort-Object)) {
            if ($Session.AdditionalApps.ContainsKey($id)) {
                [pscustomobject][ordered]@{ packageId = $Session.AdditionalApps[$id].packageId; value = $Session.Selected[$id].Value }
            }
            else { [pscustomobject][ordered]@{ id = $id; value = $Session.Selected[$id].Value } }
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
    if (@($Session.Selected.Keys | Where-Object { $Session.AdditionalApps.ContainsKey($_) }).Count -gt 0) { $document.schemaVersion = 2 }
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
    Assert-WuDocument $document 'selections' 'Saved setup' @(1, 2)
    $preview = New-WuSession -Catalog $Catalog
    $selection = @{}
    foreach ($entry in $document.selections) {
        if ($document.schemaVersion -eq 2 -and $null -ne $entry -and $entry.PSObject.Properties.Name -ccontains 'packageId') {
            Assert-WuFields $entry @('packageId', 'value') @('packageId', 'value') 'Saved WinGet selection'
            if (-not (Test-WuPackageId $entry.packageId) -or $entry.value -cne 'installed') { throw 'Invalid saved WinGet selection.' }
            Add-WuWinGetSelection -Session $preview -PackageIds @($entry.packageId)
            $item = @(Get-WuAppItems $preview | Where-Object { $_.packageId -ieq $entry.packageId })[0]
        }
        else {
            Assert-WuFields $entry @('id', 'value') @('id', 'value') 'Saved selection'
            Assert-WuText $entry.id 'Saved selection ID'
            if (-not $Catalog.ById.ContainsKey($entry.id) -or $Catalog.ById[$entry.id].id -cne $entry.id) {
                throw "Saved setup references unknown catalog ID '$($entry.id)'."
            }
            $item = $Catalog.ById[$entry.id]
        }
        if ($selection.ContainsKey($item.id)) { throw "Saved setup repeats '$($item.id)'." }
        if ($entry.value -isnot [string] -or $entry.value -cne $item.desiredValue) { throw "Unsupported desired value for '$($item.id)'." }
        $selection[$item.id] = [pscustomobject]@{ Id = $item.id; Value = $entry.value; Source = 'Saved setup' }
    }
    # Return a separate session for preview; the active session is never touched here.
    $preview.Selected = $selection
    $preview.SavedFingerprint = Get-WuSelectionSnapshot $preview
    $preview.SavedPath = $fullPath
    return $preview
}

function Set-WuImportedSetup {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Preview)
    $Session.Selected = @{}
    $Session.AdditionalApps = @{}
    foreach ($item in $Preview.AdditionalApps.Values) { $Session.AdditionalApps[$item.id] = New-WuWinGetItem $item.packageId }
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

Export-ModuleMember -Function Get-WuCatalog, New-WuSession, Set-WuSelection, Remove-WuSelection, Clear-WuSelection, Set-WuPreset, Get-WuPlan, Test-WuUnsavedChanges, Export-WuSetup, Import-WuSetup, Set-WuImportedSetup, Get-WuEnvironment, Get-WuDefaultSetupPath, Get-WuAppItems, Find-WuCatalogApp, Add-WuWinGetSelection, ConvertFrom-WuBatchInput
