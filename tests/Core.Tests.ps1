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
        '{"schemaVersion":2,"selections":[]}',
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

Test-Case 'Catalogs reject duplicate IDs, unknown preset references, and invalid metadata' {
    $fixture = Join-Path $script:TestRoot 'catalog'
    [void][IO.Directory]::CreateDirectory($fixture)
    $source = Join-Path $script:RepoRoot 'data'
    foreach ($scenario in @('duplicate', 'unknown', 'metadata')) {
        Get-ChildItem -LiteralPath $source -File | Copy-Item -Destination $fixture
        if ($scenario -eq 'unknown') {
            $path = Join-Path $fixture 'presets.json'
            $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $document.items[0].itemIds += 'missing.id'
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
