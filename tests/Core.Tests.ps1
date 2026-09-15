Test-Case 'Every PowerShell file parses without errors' {
    $files = @(Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') })
    foreach ($file in $files) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        Assert-Equal 0 @($parseErrors).Count "Parse errors in $($file.Name): $parseErrors"
    }
}

Test-Case 'New sessions start empty and clean, including an empty simulation' {
    $session = New-WuSession -Catalog $script:Catalog
    Assert-Equal 0 @(Get-WuPlan -Session $session).Count
    Assert-True (-not (Test-WuUnsavedChanges -Session $session))
    Assert-Equal 0 @(Invoke-WuSimulation -Plan @()).Count
}

Test-Case 'Presets contain the specified complete setups and replace old choices' {
    $session = New-WuSession -Catalog $script:Catalog
    Set-WuSelection -Session $session -Id 'power.balanced'
    foreach ($spec in @(@('minimal', 3), @('balanced', 6), @('full', 8), @('minimal', 3))) {
        Set-WuPreset -Session $session -Id $spec[0]
        Assert-Equal $spec[1] $session.Selected.Count
        Assert-True (-not $session.Selected.ContainsKey('power.balanced'))
        Assert-True (-not $session.Selected.ContainsKey('windows.remove-solitaire'))
        Assert-True (@(Get-WuPlan -Session $session | Where-Object { $_.Source -notlike 'Preset: *' }).Count -eq 0)
    }
    Assert-True (Test-WuUnsavedChanges -Session $session)
}

Test-Case 'Manual edits preserve unaffected preset choices and prevent duplicates' {
    $session = New-WuSession -Catalog $script:Catalog
    Set-WuPreset -Session $session -Id minimal
    Set-WuSelection -Session $session -Id 'app.7zip'
    Assert-Equal 'Preset: Minimal' $session.Selected['app.7zip'].Source
    Remove-WuSelection -Session $session -Id 'explorer.extensions'
    Set-WuSelection -Session $session -Id 'app.firefox'
    Set-WuSelection -Session $session -Id 'app.firefox'
    Assert-Equal 3 $session.Selected.Count
    Assert-Equal 'Manual' $session.Selected['app.firefox'].Source
    Set-WuSelection -Session $session -Id 'explorer.extensions'
    Assert-Equal 'Manual' $session.Selected['explorer.extensions'].Source
    Assert-Throws { Set-WuSelection -Session $session -Id 'unknown' } '*Unknown catalog ID*'
    Assert-Throws { Set-WuPreset -Session $session -Id 'unknown' } '*Unknown preset*'
    Assert-Equal 4 $session.Selected.Count
}

Test-Case 'Plan order is deterministic and simulation leaves state unchanged' {
    $session = New-WuSession -Catalog $script:Catalog
    Set-WuSelection -Session $session -Id 'app.vlc'
    Set-WuSelection -Session $session -Id 'power.balanced'
    Set-WuSelection -Session $session -Id 'explorer.extensions'
    $plan = @(Get-WuPlan -Session $session)
    Assert-Equal @('explorer.extensions', 'power.balanced', 'app.vlc') @($plan | ForEach-Object { $_.Id })
    Assert-True $plan[1].RequiresAdmin
    Assert-Equal 'VideoLAN.VLC' $plan[2].PackageId
    $before = ConvertTo-Json -InputObject $session.Selected -Depth 10
    $results = @(Invoke-WuSimulation -Plan $plan)
    Assert-Equal 3 $results.Count
    foreach ($result in $results) {
        Assert-Equal 'Simulated' $result.Status
        Assert-Equal $false $result.Changed
    }
    Assert-Equal $before (ConvertTo-Json -InputObject $session.Selected -Depth 10)
    Assert-True (Test-WuUnsavedChanges -Session $session)
}

Test-Case 'Portable JSON round trip preserves desired values and resets dirty status' {
    $session = New-WuSession -Catalog $script:Catalog
    Set-WuPreset -Session $session -Id balanced
    $path = Join-Path $script:TestRoot 'folder with spaces/my setup.json'
    Export-WuSetup -Session $session -Path $path | Out-Null
    Assert-True (-not (Test-WuUnsavedChanges -Session $session))
    $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-Equal 1 $json.schemaVersion
    Assert-Equal 6 $json.selections.Count
    Assert-Equal @('id', 'value') @($json.selections[0].PSObject.Properties.Name)
    $preview = Import-WuSetup -Catalog $script:Catalog -Path $path
    $target = New-WuSession -Catalog $script:Catalog
    Set-WuSelection -Session $target -Id 'power.balanced'
    Assert-Equal 1 $target.Selected.Count 'Preview must not replace the active selection.'
    Set-WuImportedSetup -Session $target -Preview $preview
    Assert-Equal 6 $target.Selected.Count
    Assert-True (-not (Test-WuUnsavedChanges -Session $target))
    foreach ($item in $target.Selected.Values) { Assert-Equal 'Saved setup' $item.Source }
    Remove-WuSelection -Session $target -Id 'app.vlc'
    Assert-True (Test-WuUnsavedChanges -Session $target)
    Set-WuSelection -Session $target -Id 'app.vlc'
    Assert-True (-not (Test-WuUnsavedChanges -Session $target))
}

Test-Case 'Empty and single-selection setups keep JSON arrays during export and import' {
    foreach ($count in @(0, 1)) {
        $session = New-WuSession -Catalog $script:Catalog
        if ($count -eq 1) { Set-WuSelection -Session $session -Id 'app.7zip' }
        $path = Join-Path $script:TestRoot "size-$count.json"
        Export-WuSetup -Session $session -Path $path | Out-Null
        $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        Assert-True ($document.selections -is [array])
        Assert-Equal $count $document.selections.Count
        $preview = Import-WuSetup -Catalog $script:Catalog -Path $path
        Assert-Equal $count $preview.Selected.Count
    }
}

Test-Case 'Overwrite is explicit, failures preserve the existing file and dirty state' {
    $path = Join-Path $script:TestRoot 'overwrite.json'
    $session = New-WuSession -Catalog $script:Catalog
    Set-WuPreset -Session $session -Id minimal
    Export-WuSetup -Session $session -Path $path | Out-Null
    $original = [IO.File]::ReadAllText($path)
    Set-WuPreset -Session $session -Id full
    Assert-Throws { Export-WuSetup -Session $session -Path $path } '*Could not save setup*'
    Assert-Equal $original ([IO.File]::ReadAllText($path))
    Assert-True (Test-WuUnsavedChanges -Session $session)
    Export-WuSetup -Session $session -Path $path -Overwrite | Out-Null
    Assert-Equal 8 (Import-WuSetup -Catalog $script:Catalog -Path $path).Selected.Count
    Assert-True (-not (Test-WuUnsavedChanges -Session $session))
    Clear-WuSelection -Session $session
    Assert-True (Test-WuUnsavedChanges -Session $session)
}

Test-Case 'Invalid imports are rejected completely without altering active selections' {
    $invalid = @(
        '{',
        'null',
        '{"schemaVersion":3,"selections":[]}',
        '{"schemaVersion":"1","selections":[]}',
        '{"schemaVersion":1,"selections":{}}',
        '{"schemaVersion":1,"selections":[{"id":"unknown","value":"installed"}]}',
        '{"schemaVersion":1,"selections":[{"id":"app.7zip","value":"uninstalled"}]}',
        '{"schemaVersion":1,"selections":[{"id":"app.7zip","value":["installed"]}]}',
        '{"schemaVersion":1,"selections":[{"id":"APP.7ZIP","value":"installed"}]}',
        '{"schemaVersion":1,"selections":[{"id":"app.7zip","value":"installed"},{"id":"app.7zip","value":"installed"}]}',
        '{"schemaVersion":1,"selections":[{"id":"app.7zip","value":"installed","command":"Write-Output bad"}]}',
        '{"schemaVersion":1,"selections":[{"id":"app.7zip"}]}',
        '{"schemaVersion":1,"selections":[],"command":"Write-Output bad"}',
        '{"schemaVersion":1,"selections":[null]}'
    )
    $session = New-WuSession -Catalog $script:Catalog
    Set-WuPreset -Session $session -Id minimal
    $before = ConvertTo-Json -InputObject $session.Selected -Depth 10
    $path = Join-Path $script:TestRoot 'invalid.json'
    foreach ($content in $invalid) {
        [IO.File]::WriteAllText($path, $content)
        Assert-Throws { Import-WuSetup -Catalog $script:Catalog -Path $path }
        Assert-Equal $before (ConvertTo-Json -InputObject $session.Selected -Depth 10)
    }
}

Test-Case 'Catalogs reject duplicate IDs, duplicate packages, unknown preset references, and invalid metadata' {
    $fixture = Join-Path $script:TestRoot 'catalog'
    [void][IO.Directory]::CreateDirectory($fixture)
    $source = Join-Path $script:RepoRoot 'data'
    foreach ($scenario in @('duplicate', 'package', 'unknown', 'metadata')) {
        Get-ChildItem -LiteralPath $source -File | Copy-Item -Destination $fixture
        if ($scenario -eq 'unknown') {
            $path = Join-Path $fixture 'presets.json'
            $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $document.items[0].itemIds += 'missing.id'
        }
        elseif ($scenario -eq 'package') {
            $path = Join-Path $fixture 'apps.json'
            $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $document.items[1].packageId = $document.items[0].packageId.ToUpperInvariant()
        }
        else {
            $path = Join-Path $fixture 'settings.json'
            $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($scenario -eq 'duplicate') { $document.items += $document.items[0] }
            else { $document.items[0].requiresAdmin = 'false' }
        }
        [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $document -Depth 10))
        Assert-Throws { Get-WuCatalog -DataPath $fixture }
    }
}

Test-Case 'Batch selection accepts lists and ranges once and rejects invalid batches before yielding numbers' {
    Assert-Equal @(1, 3, 5, 6, 7) @(ConvertFrom-WuBatchInput -Text '1,3 5-7,6' -First 1 -Last 8)
    Assert-Equal @(9, 10, 11) @(ConvertFrom-WuBatchInput -Text '9-11,10' -First 9 -Last 16)
    foreach ($text in @('', '1,9', '0,1', '3-1', '-1', '1-99', '99999999999', '1;2', 'all', '1,')) {
        $output = New-Object Collections.ArrayList
        Assert-Throws { ConvertFrom-WuBatchInput -Text $text -First 1 -Last 8 | ForEach-Object { [void]$output.Add($_) } }
        Assert-Equal 0 $output.Count
    }
}

Test-Case 'Catalog search matches names, descriptions, categories and package IDs as literal text' {
    $session = New-WuSession $script:Catalog
    Assert-Equal @('app.7zip') @(Find-WuCatalogApp $session 'ARCHIVE' | ForEach-Object { $_.id })
    Assert-Equal @('app.notepadplusplus') @(Find-WuCatalogApp $session 'Notepad++.Notepad++' | ForEach-Object { $_.id })
    Assert-True (@(Find-WuCatalogApp $session 'PDF').Count -ge 2)
    Assert-True (@(Find-WuCatalogApp $session 'Diagnostics').Count -ge 3)
    Assert-Equal 0 @(Find-WuCatalogApp $session '[*]').Count
    Assert-Equal 0 $session.Selected.Count
}

Test-Case 'WinGet selections deduplicate package identities and stay isolated from other sessions' {
    $session = New-WuSession $script:Catalog
    $other = New-WuSession $script:Catalog
    $originalCount = $script:Catalog.Apps.Count
    Add-WuWinGetSelection $session @('Vendor.Tool', '7zip.7zip', 'vendor.tool', 'Vendor.Other')
    Assert-Equal 3 $session.Selected.Count
    Assert-Equal 2 $session.AdditionalApps.Count
    Assert-Equal $originalCount @(Get-WuAppItems $other).Count
    Assert-Equal $originalCount $script:Catalog.Apps.Count
    Assert-True $session.Selected.ContainsKey('app.7zip')
    $before = @(Get-WuPlan $session | ForEach-Object { $_.PackageId })
    Assert-Throws { Add-WuWinGetSelection $session @('Vendor.New', 'bad;command') }
    Assert-Equal $before @(Get-WuPlan $session | ForEach-Object { $_.PackageId })
    Assert-True (Test-WuUnsavedChanges $session)
}

Test-Case 'Live WinGet selections round trip offline in schema 2 with stable identity and saved state' {
    foreach ($ids in @(@('Vendor.One++'), @('Vendor.One++', 'Vendor.Two', '7zip.7zip'))) {
        $session = New-WuSession $script:Catalog
        Add-WuWinGetSelection $session $ids
        Set-WuSelection $session 'explorer.extensions'
        $path = Join-Path $script:TestRoot ('winget-' + $ids.Count + '.json')
        [void](Export-WuSetup $session $path)
        $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        Assert-Equal 2 $saved.schemaVersion
        Assert-True ($saved.selections -is [array])
        Assert-Equal 0 @($saved.selections | Where-Object { $_.PSObject.Properties.Name -contains 'command' }).Count
        $preview = Import-WuSetup $script:Catalog $path
        Assert-True (-not (Test-WuUnsavedChanges $preview))
        $target = New-WuSession $script:Catalog
        Set-WuImportedSetup $target $preview
        Assert-Equal @(Get-WuPlan $session | ForEach-Object { $_.Id }) @(Get-WuPlan $target | ForEach-Object { $_.Id })
        $id = @($target.AdditionalApps.Keys)[0]
        Remove-WuSelection $target $id
        Assert-True (Test-WuUnsavedChanges $target)
        Set-WuSelection $target $id
        Assert-True (-not (Test-WuUnsavedChanges $target))
        Clear-WuSelection $preview
        Assert-Equal ($ids.Count + 1) $target.Selected.Count
    }
}

Test-Case 'Saved package IDs reuse curated entries and catalog-only exports retain schema 1' {
    $path = Join-Path $script:TestRoot 'known-package.json'
    [IO.File]::WriteAllText($path, '{"schemaVersion":2,"selections":[{"packageId":"7zip.7zip","value":"installed"}]}')
    $session = Import-WuSetup $script:Catalog $path
    Assert-Equal @('app.7zip') @($session.Selected.Keys)
    Assert-Equal 0 $session.AdditionalApps.Count
    [void](Export-WuSetup $session $path -Overwrite)
    Assert-Equal 1 ([IO.File]::ReadAllText($path) | ConvertFrom-Json).schemaVersion
    Add-WuWinGetSelection $session @('Vendor.Tool')
    Set-WuPreset $session minimal
    Assert-Equal 3 $session.Selected.Count
    Assert-Equal 0 @(Get-WuPlan $session | Where-Object { $_.PackageId -eq 'Vendor.Tool' }).Count
}

Test-Case 'Schema 2 rejects executable fields, unsupported sources, invalid values and duplicate packages atomically' {
    $invalid = @(
        '{"schemaVersion":1,"selections":[{"packageId":"Vendor.Tool","value":"installed"}]}',
        '{"schemaVersion":2,"selections":[{"packageId":"Vendor.Tool","value":"installed","source":"other"}]}',
        '{"schemaVersion":2,"selections":[{"packageId":"Vendor.Tool","value":"installed","command":"anything"}]}',
        '{"schemaVersion":2,"selections":[{"packageId":"Vendor.Tool","value":["installed"]}]}',
        '{"schemaVersion":2,"selections":[{"packageId":"Vendor.Tool","value":"uninstalled"}]}',
        '{"schemaVersion":2,"selections":[{"packageId":"--force","value":"installed"}]}',
        '{"schemaVersion":2,"selections":[{"packageId":"Vendor.Tool\n","value":"installed"}]}',
        '{"schemaVersion":2,"selections":[{"packageId":"Vendor.Tool","value":"installed"},{"packageId":"vendor.tool","value":"installed"}]}',
        '{"schemaVersion":2,"selections":[{"id":"app.7zip","value":"installed"},{"packageId":"7zip.7zip","value":"installed"}]}',
        '{"schemaVersion":2,"selections":[{"id":"app.7zip","packageId":"Vendor.Other","value":"installed"}]}'
    )
    $path = Join-Path $script:TestRoot 'bad-live-setup.json'
    $active = New-WuSession $script:Catalog
    Add-WuWinGetSelection $active @('Vendor.Existing')
    foreach ($content in $invalid) {
        [IO.File]::WriteAllText($path, $content)
        Assert-Throws { Import-WuSetup $script:Catalog $path }
        Assert-Equal 1 $active.AdditionalApps.Count
        Assert-Equal @('Vendor.Existing') @(Get-WuPlan $active | ForEach-Object { $_.PackageId })
    }
}
