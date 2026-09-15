Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'WinUtility.Core.psm1') -Scope Local
Import-Module (Join-Path $PSScriptRoot 'WinUtility.Windows.psm1') -Scope Local
Import-Module (Join-Path $PSScriptRoot 'WinUtility.Repair.psm1') -Scope Local
Import-Module (Join-Path $PSScriptRoot 'WinUtility.Input.psm1') -Scope Local

$script:WuPlain = $false
$script:WuUnicode = $false
$script:WuWidthOverride = 0
$script:WuHeightOverride = 0
$script:WuPreviewOnly = $true
$script:WuEnvironment = $null
$script:WuAcceptSourceAgreements = $false
$script:WuColors = @{ Normal = 'Gray'; Title = 'White'; Accent = 'Cyan'; Muted = 'DarkGray'; Success = 'Green'; Warning = 'Yellow' }
$script:WuKeyNavigation = $false
$script:WuMenuOptions = @()
$script:WuMenuTitle = ''
$script:WuMenuFocus = @{}

function Initialize-WuAppearance {
    param([switch]$Plain, [switch]$NoKeyNavigation)
    $script:WuKeyNavigation = -not $NoKeyNavigation -and (Test-WuKeyInput)
    $script:WuPlain = $Plain -or -not [string]::IsNullOrEmpty($env:NO_COLOR) -or $env:TERM -eq 'dumb'
    try { $script:WuPlain = $script:WuPlain -or [Console]::IsOutputRedirected } catch { }
    # Keep source ASCII for Windows PowerShell 5.1. Modern UTF-8 consoles get borders.
    $script:WuUnicode = $false
    try { $script:WuUnicode = -not $script:WuPlain -and [Console]::OutputEncoding.CodePage -eq 65001 } catch { }
}

function Get-WuDisplayWidth {
    if ($script:WuWidthOverride -gt 0) { return $script:WuWidthOverride }
    $width = 80
    try {
        if ($Host.UI.RawUI.WindowSize.Width -gt 0) { $width = $Host.UI.RawUI.WindowSize.Width }
    }
    catch { }
    return [Math]::Max(16, [Math]::Min(92, $width - 2))
}

function Test-WuCompactDisplay {
    $height = $script:WuHeightOverride
    if ($height -le 0) {
        try { $height = $Host.UI.RawUI.WindowSize.Height } catch { }
    }
    return $height -gt 0 -and $height -lt 38
}

function Get-WuWrappedText {
    param([string]$Text, [int]$Width)
    $remaining = ($Text -replace '[\x00-\x1f\x7f]', ' ').Trim()
    if ($remaining.Length -eq 0) { return '' }
    while ($remaining.Length -gt $Width) {
        $cut = $remaining.LastIndexOf(' ', $Width)
        if ($cut -le 0) { $cut = $Width }
        $remaining.Substring(0, $cut).TrimEnd()
        $remaining = $remaining.Substring($cut).TrimStart()
    }
    if ($remaining.Length -gt 0) { $remaining }
}

function Write-WuOutput {
    param([string]$Text = '', [string]$Tone = 'Normal')
    $arguments = @{ Object = $Text }
    if (-not $script:WuPlain) { $arguments.ForegroundColor = $script:WuColors[$Tone] }
    Write-Host @arguments
}

function Write-WuText {
    param([string]$Text = '', [string]$Tone = 'Normal', [int]$Indent = 2)
    if ($script:WuKeyNavigation -and $Text.Length -eq 0) { return }
    if ($Text.Length -eq 0) { Write-WuOutput; return }
    $width = [Math]::Max(1, (Get-WuDisplayWidth) - $Indent)
    foreach ($line in @(Get-WuWrappedText -Text $Text -Width $width)) {
        Write-WuOutput -Text ((' ' * $Indent) + $line) -Tone $Tone
    }
}

function Write-WuRule {
    $rule = '-'
    if ($script:WuUnicode) { $rule = [string][char]0x2500 }
    Write-WuOutput -Text ('  ' + ($rule * ((Get-WuDisplayWidth) - 2))) -Tone Muted
}

function Write-WuHeading {
    param([string]$Title, [string]$Subtitle = '')
    $script:WuMenuOptions = @(); $script:WuMenuTitle = $Title
    if ($script:WuKeyNavigation) {
        try { Clear-WuKeyScreen } catch { $script:WuKeyNavigation = $false }
    }
    $width = Get-WuDisplayWidth
    $horizontal = '-'; $vertical = '|'; $topLeft = '+'; $topRight = '+'; $bottomLeft = '+'; $bottomRight = '+'
    if ($script:WuUnicode) {
        $horizontal = [string][char]0x2500; $vertical = [string][char]0x2502
        $topLeft = [string][char]0x256d; $topRight = [string][char]0x256e
        $bottomLeft = [string][char]0x2570; $bottomRight = [string][char]0x256f
    }
    Write-WuOutput
    Write-WuOutput -Text ('  ' + $topLeft + ($horizontal * ($width - 4)) + $topRight) -Tone Accent
    foreach ($line in @(Get-WuWrappedText -Text $Title -Width ($width - 8))) {
        Write-WuOutput -Text ('  ' + $vertical + '  ' + $line.PadRight($width - 8) + '  ' + $vertical) -Tone Title
    }
    if ($Subtitle.Length -gt 0) {
        foreach ($line in @(Get-WuWrappedText -Text $Subtitle -Width ($width - 8))) {
            Write-WuOutput -Text ('  ' + $vertical + '  ' + $line.PadRight($width - 8) + '  ' + $vertical) -Tone Muted
        }
    }
    Write-WuOutput -Text ('  ' + $bottomLeft + ($horizontal * ($width - 4)) + $bottomRight) -Tone Accent
    Write-WuOutput
}

function Write-WuOption {
    param([string]$Key, [string]$Label, [string]$Description = '', [string]$Tone = 'Title')
    $script:WuMenuOptions += [pscustomobject]@{ Key = $Key; Label = $Label; Description = $Description; Color = $script:WuColors[$Tone] }
    if ($script:WuKeyNavigation) { return }
    Write-WuText -Text ('[{0}]  {1}' -f $Key, $Label) -Tone $Tone
    if ($Description.Length -gt 0) { Write-WuText -Text $Description -Tone Muted -Indent 7 }
}

function Write-WuFooter {
    param([string]$Label = 'Back')
    Write-WuText
    Write-WuRule
    Write-WuOption -Key '0' -Label $Label -Tone Muted
}

function Write-WuSelectionSummary {
    param([AllowEmptyCollection()][object[]]$Plan)
    $settingsCount = @($Plan | Where-Object { $_.Kind -eq 'Setting' }).Count
    $appsCount = @($Plan | Where-Object { $_.Kind -eq 'App' }).Count
    Write-WuText -Text "Selected: $(Format-WuCount $settingsCount 'setting'), $(Format-WuCount $appsCount 'app')" -Tone Accent
}

function Format-WuCount {
    param([int]$Count, [string]$Noun)
    if ($Count -ne 1) { $Noun += 's' }
    return "$Count $Noun"
}

function Read-WuInput {
    param([string]$Prompt, [string]$CancelValue = '')
    if ($script:WuKeyNavigation) {
        try { return (Read-WuKeyChoice -Prompt $Prompt -AllowText -CancelValue $CancelValue -Plain:$script:WuPlain).Value }
        catch { $script:WuKeyNavigation = $false; Write-WuText -Text 'Key navigation is unavailable. Type your response and press Enter.' -Tone Warning }
    }
    $value = Read-Host -Prompt $Prompt
    if ($null -eq $value) { throw 'Input ended. Open WinUtility in an interactive PowerShell window.' }
    return $value.Trim()
}

function Read-WuMenuInput {
    param([string[]]$Options, [string]$Prompt = 'Choose', [string]$DefaultKey = '',
        [switch]$AllowText, [string[]]$ToggleKeys = @(), [switch]$PageNavigation)
    $items = @(); $seen = @{}
    foreach ($item in $script:WuMenuOptions) {
        if ($Options -contains $item.Key -and -not $seen.ContainsKey($item.Key)) { $items += $item; $seen[$item.Key] = $true }
    }
    foreach ($key in $Options) {
        if (-not $seen.ContainsKey($key)) { $items += [pscustomobject]@{ Key = $key; Label = $key; Description = ''; Color = 'Gray' } }
    }
    $script:WuMenuOptions = @()
    if ($script:WuKeyNavigation) {
        $scope = $script:WuMenuTitle + '|' + ($Options -join ',')
        if ($DefaultKey.Length -eq 0 -and $script:WuMenuFocus.ContainsKey($scope)) { $DefaultKey = $script:WuMenuFocus[$scope] }
        try {
            $result = Read-WuKeyChoice -Items $items -DefaultKey $DefaultKey -Prompt $Prompt -AllowText:$AllowText -ToggleKeys $ToggleKeys -PageNavigation:$PageNavigation -Plain:$script:WuPlain
            $script:WuMenuFocus[$scope] = $result.FocusKey
            return $result.Value
        }
        catch {
            $script:WuKeyNavigation = $false
            Write-WuText -Text 'Key navigation is unavailable. Type a choice and press Enter.' -Tone Warning
            foreach ($item in $items) { Write-WuOption -Key $item.Key -Label $item.Label }
        }
    }
    return Read-WuInput $Prompt
}

function Read-WuChoice {
    param([string[]]$Options, [string]$Prompt = '  Choose', [string]$DefaultKey = '', [string[]]$ToggleKeys = @())
    while ($true) {
        $choice = Read-WuMenuInput -Options $Options -Prompt $Prompt -DefaultKey $DefaultKey -ToggleKeys $ToggleKeys
        if ($Options -contains $choice) { return $choice.ToUpperInvariant() }
        Write-WuText -Text ('Enter one of: {0}.' -f ($Options -join ', ')) -Tone Warning
    }
}

function Wait-WuContinue {
    [void](Read-WuInput '  Press Enter to continue')
}

function Confirm-WuChoice {
    param([string]$Message, [string]$ConfirmLabel = 'Confirm')
    $script:WuMenuOptions = @()
    Write-WuText
    Write-WuRule
    Write-WuText -Text $Message -Tone Warning
    Write-WuText
    Write-WuOption -Key '1' -Label $ConfirmLabel -Tone Accent
    Write-WuOption -Key '0' -Label 'Cancel' -Tone Muted
    return (Read-WuChoice @('1', '0') -DefaultKey '0') -eq '1'
}

function Write-WuPlan {
    param([AllowEmptyCollection()][object[]]$Plan, [switch]$Numbered, [object[]]$Review = @())
    if ($Plan.Count -eq 0) {
        Write-WuText -Text 'Nothing selected.' -Tone Accent
        Write-WuText -Text 'Choose a preset or pick individual settings and apps.' -Tone Muted
        return
    }
    $section = ''
    $index = 0
    foreach ($action in $Plan) {
        $index++
        $nextSection = "$($action.Kind)s / $($action.Category)"
        if ($section -ne $nextSection) {
            Write-WuText
            Write-WuText -Text $nextSection -Tone Accent
            Write-WuRule
            $section = $nextSection
        }
        $prefix = '[x]'
        if ($Numbered) { $prefix = "[$index]" }
        Write-WuText -Text "$prefix $($action.Name)" -Tone Title
        Write-WuText -Text $action.Effect -Indent 6
        Write-WuText -Text "Choice: $($action.Value) | From: $($action.Source)" -Tone Muted -Indent 6
        $state = @($Review | Where-Object { $_.Id -ceq $action.Id })
        if ($state.Count -eq 1) {
            Write-WuText -Text "Current: $($state[0].Current) | $($state[0].Status)" -Tone Accent -Indent 6
            Write-WuText -Text $state[0].Message -Tone Muted -Indent 6
        }
        elseif ((Get-WuActionCapability $action) -eq 'NotImplemented') {
            Write-WuText -Text 'Not implemented yet. This item makes no changes.' -Tone Warning -Indent 6
        }
        if ($action.Kind -eq 'App') {
            Write-WuText -Text "WinGet: $($action.PackageId)" -Tone Muted -Indent 6
            Write-WuText -Text 'Administrator/restart: depends on installer' -Tone Muted -Indent 6
        }
        else {
            $requirements = @()
            if ($action.RequiresAdmin) { $requirements += 'Administrator required for real action' }
            if ($action.RequiresRestart) { $requirements += 'Restart required for real action' }
            if ($requirements.Count -gt 0) { Write-WuText -Text ($requirements -join ' | ') -Tone Warning -Indent 6 }
        }
    }
}

function Show-WuPresets {
    param($Session)
    while ($true) {
        Write-WuHeading 'Presets | Example laptop setups' '01 / Choose a starting point, then make it yours.'
        $options = @('0')
        for ($i = 0; $i -lt $Session.Catalog.Presets.Count; $i++) {
            $preset = $Session.Catalog.Presets[$i]
            $number = ($i + 1).ToString()
            $options += $number
            $settingCount = @($preset.itemIds | Where-Object { $Session.Catalog.ById[$_].kind -eq 'Setting' }).Count
            $appCount = $preset.itemIds.Count - $settingCount
            Write-WuOption -Key $number -Label "$($preset.name)  /  $(Format-WuCount $settingCount 'setting') + $(Format-WuCount $appCount 'app')" -Description $preset.description
            Write-WuText
        }
        Write-WuText -Text 'Open a preset to preview every selection.' -Tone Muted
        Write-WuFooter
        $choice = Read-WuChoice $options
        if ($choice -eq '0') { return }
        $preset = $Session.Catalog.Presets[[int]$choice - 1]
        $preview = New-WuSession -Catalog $Session.Catalog
        Set-WuPreset -Session $preview -Id $preset.id
        Write-WuHeading "$($preset.name) | Example preset preview" $preset.description
        Write-WuPlan -Plan @(Get-WuPlan -Session $preview)
        if (Confirm-WuChoice -Message "Replace your current $($Session.Selected.Count) selections with this preset? You can adjust it afterward." -ConfirmLabel 'Use this preset') {
            Set-WuPreset -Session $Session -Id $preset.id
            Write-WuText -Text "$($preset.name) selected. Adjust it in Manual changes or App installs." -Tone Success
            return
        }
    }
}

function Show-WuItemPicker {
    param($Session, [AllowEmptyCollection()][object[]]$Items, [string]$Title)
    if ($Items.Count -eq 0 -or $Items[0].kind -eq 'App') { Show-WuAppPicker -Session $Session -Items $Items -Title $Title; return }
    while ($true) {
        Write-WuHeading $Title 'Enter a number to toggle. [x] selected / [ ] not selected.'
        if ($Items.Count -eq 0) { Write-WuText -Text 'No matching apps.' -Tone Warning }
        $options = @('0')
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $item = $Items[$i]
            $mark = ' '
            if ($Session.Selected.ContainsKey($item.id)) { $mark = 'x' }
            $number = ($i + 1).ToString()
            $options += $number
            $tone = 'Title'
            if ($mark -eq 'x') { $tone = 'Success' }
            Write-WuOption -Key $number -Label "[$mark] $($item.name)" -Description $item.description -Tone $tone
            if ($item.kind -eq 'App') { Write-WuText -Text "WinGet: $($item.packageId)" -Tone Muted -Indent 7 }
            Write-WuText
        }
        $selectedCount = @($Items | Where-Object { $Session.Selected.ContainsKey($_.id) }).Count
        $mode = 'Review before applying'
        if ($script:WuPreviewOnly) { $mode = 'Windows actions unavailable on this host' }
        Write-WuText -Text "$selectedCount of $($Items.Count) selected here | $mode" -Tone Accent
        Write-WuFooter
        $choice = Read-WuChoice $options -ToggleKeys @($options | Where-Object { $_ -ne '0' })
        if ($choice -eq '0') { return }
        $item = $Items[[int]$choice - 1]
        if ($Session.Selected.ContainsKey($item.id)) {
            Remove-WuSelection -Session $Session -Id $item.id
        }
        else {
            Set-WuSelection -Session $Session -Id $item.id
        }
    }
}

function Show-WuCategories {
    param($Session, [ValidateSet('Settings', 'Apps')][string]$Kind)
    if ($Kind -eq 'Apps') { Show-WuAppCatalog -Session $Session; return }
    $items = @($Session.Catalog.$Kind)
    $categories = @($items | Select-Object -ExpandProperty category -Unique)
    while ($true) {
        $title = 'Manual changes'
        Write-WuHeading $title '02 / Fine-tune your laptop setup.'
        $options = @('0')
        for ($i = 0; $i -lt $categories.Count; $i++) {
            $category = $categories[$i]
            $group = @($items | Where-Object { $_.category -eq $category })
            $selected = @($group | Where-Object { $Session.Selected.ContainsKey($_.id) }).Count
            $number = ($i + 1).ToString()
            $options += $number
            $bar = ('#' * $selected) + ('.' * ($group.Count - $selected))
            Write-WuOption -Key $number -Label $category -Description "[$bar]  $selected/$($group.Count) selected"
            Write-WuText
        }
        Write-WuFooter
        $choice = Read-WuChoice $options
        if ($choice -eq '0') { return }
        $category = $categories[[int]$choice - 1]
        $group = @($items | Where-Object { $_.category -eq $category })
        Show-WuItemPicker -Session $Session -Items $group -Title $category
    }
}

function Show-WuAppPicker {
    param($Session, [AllowEmptyCollection()][object[]]$Items, [string]$Title)
    $page = 0; $pageSize = 8
    while ($true) {
        $first = $page * $pageSize
        $last = [Math]::Min($Items.Count, $first + $pageSize)
        $pageCount = [Math]::Max(1, [int][Math]::Ceiling($Items.Count / [double]$pageSize))
        Write-WuHeading $Title "Page $($page + 1) / $pageCount | [x] selected / [ ] not selected"
        if ($Items.Count -eq 0) { Write-WuText -Text 'No matching apps.' -Tone Warning }
        for ($i = $first; $i -lt $last; $i++) {
            $item = $Items[$i]; $mark = ' '; $tone = 'Title'
            if ($Session.Selected.ContainsKey($item.id)) { $mark = 'x'; $tone = 'Success' }
            $description = ''
            if ($script:WuKeyNavigation -or -not (Test-WuCompactDisplay)) { $description = $item.description }
            Write-WuOption -Key ($i + 1).ToString() -Label "[$mark] $($item.name)" -Description $description -Tone $tone
            if (-not $script:WuKeyNavigation -and -not (Test-WuCompactDisplay)) { Write-WuText -Text "WinGet: $($item.packageId)" -Tone Muted -Indent 7 }
        }
        $selectedHere = @($Items | Where-Object { $Session.Selected.ContainsKey($_.id) }).Count
        $selectedTotal = @(Get-WuAppItems $Session | Where-Object { $Session.Selected.ContainsKey($_.id) }).Count
        Write-WuText -Text "$selectedHere/$($Items.Count) selected in this list | $selectedTotal apps in queue" -Tone Accent
        if ($Items.Count -gt 0) {
            $example = ($first + 1).ToString()
            if (($last - $first) -ge 7) { $example = "$($first + 1),$($first + 3),$($first + 5)-$($first + 7)" }
            elseif (($last - $first) -ge 3) { $example = "$($first + 1),$($first + 2)-$($first + 3)" }
            elseif (($last - $first) -eq 2) { $example = "$($first + 1),$($first + 2)" }
            Write-WuText -Text "Toggle: $example | A select page | C clear page" -Tone Muted
            Write-WuText -Text 'D <number> details | R review queue' -Tone Muted
        }
        if ($pageCount -gt 1) { Write-WuText -Text 'N next page | P previous page' -Tone Accent }
        $options = @('0', 'R')
        $toggleKeys = @()
        for ($i = $first; $i -lt $last; $i++) { $toggleKeys += ($i + 1).ToString() }
        $options += $toggleKeys
        if ($Items.Count -gt 0) { $options += @('A', 'C') }
        if ($page -lt ($pageCount - 1)) { $options += 'N' }
        if ($page -gt 0) { $options += 'P' }
        if ($script:WuKeyNavigation) {
            if ($Items.Count -gt 0) {
                Write-WuOption -Key 'A' -Label 'Select page'
                Write-WuOption -Key 'C' -Label 'Clear page'
            }
            Write-WuOption -Key 'R' -Label 'Review & install selected apps' -Tone Accent
            if ($options -contains 'N') { Write-WuOption -Key 'N' -Label 'Next page' }
            if ($options -contains 'P') { Write-WuOption -Key 'P' -Label 'Previous page' }
        }
        Write-WuFooter
        $choice = Read-WuMenuInput -Options $options -AllowText -ToggleKeys $toggleKeys -PageNavigation
        if ($choice -eq '0') { return }
        if ($choice -ieq 'R') { Show-WuReview -Session $Session; continue }
        if ($choice -ieq 'N' -and $page -lt ($pageCount - 1)) { $page++; continue }
        if ($choice -ieq 'P' -and $page -gt 0) { $page--; continue }
        if ($Items.Count -eq 0) { Write-WuText -Text 'Enter 0 to go back.' -Tone Warning; continue }
        if ($choice -ieq 'A' -or $choice -ieq 'C') {
            for ($i = $first; $i -lt $last; $i++) {
                if ($choice -ieq 'A') { Set-WuSelection -Session $Session -Id $Items[$i].id }
                else { Remove-WuSelection -Session $Session -Id $Items[$i].id }
            }
            continue
        }
        try {
            if ($choice -match '^D\s*([0-9]+)$') {
                $detail = @(ConvertFrom-WuBatchInput -Text $Matches[1] -First ($first + 1) -Last $last)
                $item = $Items[$detail[0] - 1]
                Write-WuHeading $item.name $item.category
                Write-WuText -Text $item.description
                Write-WuText -Text "WinGet: $($item.packageId) | Source: winget" -Tone Accent
                Write-WuText -Text 'Selecting adds this app to the queue. Review and confirm to install it.' -Tone Muted
                Wait-WuContinue; continue
            }
            $numbers = @(ConvertFrom-WuBatchInput -Text $choice -First ($first + 1) -Last $last)
            foreach ($number in $numbers) {
                $item = $Items[$number - 1]
                if ($Session.Selected.ContainsKey($item.id)) { Remove-WuSelection -Session $Session -Id $item.id }
                else { Set-WuSelection -Session $Session -Id $item.id }
            }
        }
        catch { Write-WuText -Text $_.Exception.Message -Tone Warning }
    }
}

function Show-WuAppCatalog {
    param($Session)
    while ($true) {
        $items = @(Get-WuAppItems $Session)
        $categories = @($items | Select-Object -ExpandProperty category -Unique)
        $selectedCount = @($items | Where-Object { $Session.Selected.ContainsKey($_.id) }).Count
        Write-WuHeading 'App installs | WinGet catalog' "$($items.Count) apps | $selectedCount selected | Choose several, then review"
        $options = @('0', 'S', 'B', 'W', 'R')
        for ($i = 0; $i -lt $categories.Count; $i++) {
            $category = $categories[$i]
            $group = @($items | Where-Object { $_.category -eq $category })
            $selected = @($group | Where-Object { $Session.Selected.ContainsKey($_.id) }).Count
            $number = ($i + 1).ToString(); $options += $number
            Write-WuOption -Key $number -Label "$category ($selected/$($group.Count))"
        }
        Write-WuOption -Key 'S' -Label 'Search catalog: name, purpose or package ID' -Tone Accent
        Write-WuOption -Key 'B' -Label 'Browse all catalog apps'
        Write-WuOption -Key 'W' -Label 'Search live WinGet (Windows)' -Tone Accent
        Write-WuOption -Key 'R' -Label "Review queue ($selectedCount apps)"
        Write-WuFooter
        $choice = Read-WuChoice $options
        if ($choice -eq '0') { return }
        if ($choice -eq 'R') { Show-WuReview -Session $Session; continue }
        if ($choice -eq 'W') { Show-WuLiveAppSearch -Session $Session; continue }
        if ($choice -eq 'B') { Show-WuAppPicker -Session $Session -Items $items -Title 'All apps'; continue }
        if ($choice -eq 'S') {
            $query = Read-WuInput '  Search catalog (Enter to cancel)'
            if ($query.Length -eq 0) { continue }
            $matches = @(Find-WuCatalogApp -Session $Session -Query $query)
            Show-WuAppPicker -Session $Session -Items $matches -Title "App search: $query"
            continue
        }
        $group = @($items | Where-Object { $_.category -eq $categories[[int]$choice - 1] })
        Show-WuAppPicker -Session $Session -Items $group -Title $categories[[int]$choice - 1]
    }
}

function Write-WuPackageOutput {
    param([string]$Text)
    foreach ($line in ($Text -split '[\r\n]+')) {
        # Native output is display text, never parsed into executable package selections.
        Write-WuText -Text ($line -replace '\x1b\[[0-?]*[ -/]*[@-~]', '')
    }
}

function Get-WuInteractivePackageLookup {
    param([ValidateSet('search', 'show')][string]$Operation, [string]$Value)
    while ($true) {
        if ($Operation -eq 'search') { $result = Find-WuWinGetPackage -Query $Value -AcceptSourceAgreements:$script:WuAcceptSourceAgreements }
        else { $result = Get-WuWinGetPackageDetails -PackageId $Value -AcceptSourceAgreements:$script:WuAcceptSourceAgreements }
        if ($result.Status -ne 'SourceAgreementRequired' -or $script:WuAcceptSourceAgreements) { return $result }
        Write-WuPackageOutput $result.Output
        if (-not (Confirm-WuChoice 'WinGet requires its source agreements before searching. Accept the displayed source terms?' 'Accept source terms and retry')) { return $null }
        $script:WuAcceptSourceAgreements = $true
    }
}

function Show-WuLiveAppSearch {
    param($Session)
    if ($script:WuPreviewOnly) {
        Write-WuText -Text 'Live WinGet search requires Windows mode with WinGet available.' -Tone Warning
        Write-WuText -Text 'Bundled catalog search works in this preview.' -Tone Muted
        Wait-WuContinue; return
    }
    while ($true) {
        Write-WuHeading 'Search live WinGet' 'Search the winget source; selecting packages does not install them.'
        $query = Read-WuInput '  Search WinGet (Enter to go back)'
        if ($query.Length -eq 0) { return }
        try {
            $result = Get-WuInteractivePackageLookup -Operation search -Value $query
            if ($null -eq $result) { continue }
            Write-WuPackageOutput $result.Output
            if ($result.Status -eq 'NotFound') { Write-WuText -Text 'No WinGet packages matched. Try another search.' -Tone Muted; continue }
            if ($result.Status -ne 'Found') { throw "WinGet search failed with exit code $($result.ExitCode). Read its output above." }
            Write-WuText -Text 'Showing up to 40 results. Refine the search if an ID is truncated. Use exact IDs, including their capitalization.' -Tone Muted
            Write-WuText -Text 'Enter several IDs separated by commas or spaces, e.g. Vendor.One, Vendor.Two.' -Tone Accent
            $inputText = Read-WuInput '  Package IDs to add (Enter for another search, 0 to go back)' -CancelValue '0'
            if ($inputText -eq '0') { return }
            if ($inputText.Length -eq 0) { continue }
            $packageIds = @($inputText -split '[,\s]+' | Select-Object -Unique)
            if ($packageIds.Count -gt 20) { throw 'Add up to 20 package IDs in one batch.' }
            foreach ($packageId in $packageIds) {
                if (-not (Test-WuPackageId $packageId)) { throw "Invalid package ID '$packageId'. Use an exact ID from the WinGet result." }
            }
            # Resolve every ID exactly and show its publisher/installer metadata before adding any.
            # Avoid parsing localized, width-truncated search tables into package identities.
            $verified = $true
            foreach ($packageId in $packageIds) {
                Write-WuHeading "Package details | $packageId"
                $details = Get-WuInteractivePackageLookup -Operation show -Value $packageId
                if ($null -eq $details) { $verified = $false; break }
                Write-WuPackageOutput $details.Output
                if ($details.Status -ne 'Found') { $verified = $false; Write-WuText -Text "Could not verify '$packageId' (exit $($details.ExitCode))." -Tone Warning }
            }
            if (-not $verified) { Write-WuText -Text 'No apps from this batch were added. Correct the IDs or resolve the WinGet error and try again.' -Tone Warning; continue }
            if (Confirm-WuChoice "Add these $($packageIds.Count) packages to your queue? Installation has a separate review and confirmation." 'Add to queue') {
                Add-WuWinGetSelection -Session $Session -PackageIds $packageIds
                Write-WuText -Text 'Packages are selected. Repeated choices stay in the queue once. Use Review queue to install them.' -Tone Success
            }
        }
        catch { Write-WuText -Text $_.Exception.Message -Tone Warning }
    }
}

function Show-WuReview {
    param($Session)
    while ($true) {
        $title = 'Review & apply'
        if ($script:WuPreviewOnly) { $title = 'Review selection' }
        Write-WuHeading $title '03 / Check your choices before running them.'
        if ($script:WuPreviewOnly) { Write-WuText -Text 'Windows actions are unavailable in this session. You can save your selection.' -Tone Warning }
        else { Write-WuText -Text 'Real actions: app installs and the two Explorer settings.' -Tone Accent }
        $plan = @(Get-WuPlan -Session $Session)
        $review = @()
        if (-not $script:WuPreviewOnly -and $plan.Count -gt 0) {
            Write-WuText -Text 'Checking current settings and installed apps...' -Tone Muted
            $review = @(Get-WuExecutionReview -Plan $plan -Environment $script:WuEnvironment)
        }
        Write-WuSelectionSummary -Plan $plan
        Write-WuPlan -Plan $plan -Numbered -Review $review
        Write-WuText
        $options = @('0')
        if ($plan.Count -gt 0) {
            if (-not $script:WuPreviewOnly -and @($review | Where-Object { $_.Status -in @('Ready', 'AlreadyConfigured', 'AlreadyInstalled') }).Count -gt 0) {
                Write-WuOption -Key 'A' -Label 'Apply supported changes' -Tone Accent
                $options += 'A'
            }
            $retryPlan = @()
            if (-not $script:WuPreviewOnly -and $null -ne $Session.LastRun) {
                $retryIds = @($Session.LastRun.Actions | Where-Object { $_.Kind -eq 'App' -and $_.Status -in @('Failed', 'Cancelled') } | ForEach-Object { $_.Id })
                $retryPlan = @($plan | Where-Object { $retryIds -contains $_.Id })
                if ($retryPlan.Count -gt 0) { Write-WuOption -Key 'F' -Label 'Retry failed app installs'; $options += 'F' }
            }
            Write-WuOption -Key 'R' -Label 'Remove an item'
            Write-WuOption -Key 'C' -Label 'Clear all selections' -Tone Muted
            $options += @('R', 'C')
        }
        Write-WuFooter
        switch (Read-WuChoice $options) {
            '0' { return }
            'A' { Show-WuApply -Session $Session -Plan $plan }
            'F' { Show-WuApply -Session $Session -Plan $retryPlan }
            'R' {
                Write-WuHeading 'Remove from queue'
                for ($i = 0; $i -lt $plan.Count; $i++) { Write-WuOption -Key ($i + 1).ToString() -Label $plan[$i].Name }
                Write-WuFooter -Label 'Cancel'
                $removeOptions = @('0') + @(1..$plan.Count | ForEach-Object { $_.ToString() })
                $number = Read-WuChoice -Options $removeOptions -Prompt 'Item number to remove (0 to cancel)'
                if ($number -ne '0') { Remove-WuSelection -Session $Session -Id $plan[[int]$number - 1].Id }
            }
            'C' {
                if (Confirm-WuChoice 'Clear all selected settings and apps?' 'Clear selections') {
                    Clear-WuSelection -Session $Session
                }
            }
        }
    }
}

function Write-WuResults {
    param([object[]]$Results)
    foreach ($result in $Results) {
        $tone = 'Success'
        if ($result.Status -in @('Failed', 'Cancelled', 'Conflict', 'RestartRequired', 'Skipped', 'Pending')) { $tone = 'Warning' }
        Write-WuText -Text "[$($result.Status)] $($result.Name)" -Tone $tone
        Write-WuText -Text $result.Message -Indent 6
    }
    if (@($Results | Where-Object { $_.RestartRequired }).Count -gt 0) {
        Write-WuText -Text 'A restart is required. WinUtility does not request an automatic reboot.' -Tone Warning
    }
}

function Show-WuApply {
    param($Session, [object[]]$Plan)
    if ($script:WuPreviewOnly) { return }
    Write-WuHeading 'Apply to this laptop' 'Unimplemented items will be skipped.'
    Write-WuPlan -Plan $Plan
    $hasApps = @($Plan | Where-Object { $_.Kind -eq 'App' }).Count -gt 0
    Write-WuText -Text 'Explorer values are backed up for undo. App installs are not undone by WinUtility.' -Tone Muted
    if ($hasApps) {
        Write-WuText -Text 'Apps install one at a time. Apps that forbid administrator access retry with normal-user permissions.' -Tone Accent
        Write-WuText -Text 'Continuing accepts the selected apps'' license terms and WinGet source agreements.' -Tone Warning
    }
    if (-not (Confirm-WuChoice 'Apply these supported changes to this Windows user and laptop?' 'Apply now')) { return }
    try {
        $Session.LastRun = Invoke-WuApply -Plan $Plan -AcceptAppAgreements:$hasApps -OnProgress { param($Name, $Index, $Total) Write-WuText -Text "[$Index/$Total] Working: $Name" -Tone Accent }
        Write-WuHeading 'Apply results'
        Write-WuResults -Results $Session.LastRun.Actions
        Write-WuText -Text "History: $($Session.LastRun.Path)" -Tone Muted
    }
    catch { Write-WuText -Text "Run stopped: $($_.Exception.Message) Check History & Explorer undo for any completed or pending actions." -Tone Warning }
    Wait-WuContinue
}

function Show-WuReadiness {
    while ($true) {
        Write-WuHeading 'Machine readiness' 'Read-only checks for this laptop.'
        $environment = $script:WuEnvironment
        Write-WuText -Text $environment.OS -Tone Title
        Write-WuText -Text "Architecture: $($environment.Architecture) | PowerShell: $($environment.PowerShellVersion)"
        Write-WuText -Text "WinGet: $($environment.WinGetVersion)"
        $restart = 'Unknown'
        if ($null -ne $environment.PendingReboot) { $restart = $(if ($environment.PendingReboot) { 'Required' } else { 'Not detected' }) }
        Write-WuText -Text "Pending restart: $restart"
        $power = $environment.PowerStatus
        if ($null -ne $environment.BatteryPercent) { $power += " / $($environment.BatteryPercent)% charge" }
        Write-WuText -Text "Power: $power"
        Write-WuText -Text "Administrator session: $($environment.IsAdmin)"
        if (-not $environment.SupportedOS) { Write-WuText -Text 'Preview only: real execution requires a verified Windows 11 workstation.' -Tone Warning }
        foreach ($warning in $environment.Warnings) { Write-WuText -Text $warning -Tone Warning }
        Write-WuOption -Key 'R' -Label 'Refresh checks' -Tone Accent
        Write-WuFooter
        if ((Read-WuChoice @('R', '0')) -eq '0') { return }
        $script:WuEnvironment = Get-WuEnvironment
        # Refresh can disable real execution; enabling it again requires a fresh launch.
        $script:WuPreviewOnly = $script:WuPreviewOnly -or -not $script:WuEnvironment.SupportedOS
    }
}

function Show-WuHistory {
    if ($script:WuPreviewOnly) { return }
    while ($true) {
        Write-WuHeading 'History & Explorer undo' 'Saved locally for this Windows user and computer.'
        try { $runs = @(Get-WuHistory) }
        catch { Write-WuText -Text $_.Exception.Message -Tone Warning; Wait-WuContinue; return }
        if ($runs.Count -eq 0) { Write-WuText -Text 'No runs recorded yet.' -Tone Muted }
        $options = @('0')
        for ($i = 0; $i -lt $runs.Count; $i++) {
            $number = ($i + 1).ToString()
            $options += $number
            Write-WuOption -Key $number -Label "$($runs[$i].StartedAtUtc) / $($runs[$i].Status)" -Description "$($runs[$i].Actions.Count) actions"
        }
        Write-WuFooter
        $choice = Read-WuChoice $options
        if ($choice -eq '0') { return }
        $run = $runs[[int]$choice - 1]
        Write-WuHeading 'Run details' $run.StartedAtUtc
        Write-WuText -Text "History file: $($run.Path)" -Tone Muted
        if ($null -ne $run.Error) { Write-WuText -Text $run.Error -Tone Warning; Wait-WuContinue; continue }
        Write-WuResults -Results $run.Actions
        if ($run.Status -eq 'Running') { Write-WuText -Text 'This run may have been interrupted. Pending results do not mean success.' -Tone Warning }
        $undoable = @($run.Actions | Where-Object { $_.Kind -eq 'Setting' -and $null -ne $_.Before -and $null -ne $_.After -and $_.Status -ne 'AlreadyConfigured' })
        if ($undoable.Count -gt 0) {
            Write-WuText -Text 'Undo restores Explorer values only. App installations stay installed.' -Tone Muted
            if (Confirm-WuChoice 'Restore this run''s original Explorer values? Newer, conflicting values will be left alone.' 'Undo Explorer changes') {
                try { Write-WuResults -Results @(Undo-WuExplorerRun -Path $run.Path) }
                catch { Write-WuText -Text "Undo stopped: $($_.Exception.Message)" -Tone Warning }
            }
        }
        Wait-WuContinue
    }
}

function Read-WuFilePath {
    param([string]$Prompt)
    $path = Read-WuInput $Prompt -CancelValue '0'
    # Accept paths copied with surrounding quotes, without evaluating their contents.
    if ($path.Length -ge 2 -and (($path.StartsWith('"') -and $path.EndsWith('"')) -or
        ($path.StartsWith("'") -and $path.EndsWith("'")))) {
        $path = $path.Substring(1, $path.Length - 2)
    }
    return $path
}

function Write-WuRepairSummary {
    param($Run)
    Write-WuHeading "Repair report | $($Run.Report.Status)" 'Command results and next steps'
    if ($Run.Report.Status -eq 'Stopped') {
        $notRun = @($Run.Report.Steps | Where-Object { $_.Status -eq 'NotRun' }).Count
        Write-WuText -Text "Workflow stopped. Steps not run: $notRun. Review the result below before retrying." -Tone Warning
    }
    foreach ($step in $Run.Report.Steps) {
        $tone = 'Accent'
        if ($step.Status -ne 'Completed') { $tone = 'Warning' }
        Write-WuText -Text "[$($step.Status)] $($step.Name)" -Tone $tone
        Write-WuText -Text $step.Message -Indent 6
        if ($step.Status -ne 'NotRun' -and $step.PSObject.Properties.Name -contains 'CommandLine') {
            Write-WuText -Text $step.CommandLine -Tone Muted -Indent 6
        }
        if ($null -ne $step.ExitCode) { Write-WuText -Text "Exit: $($step.ExitCode) | Time: $($step.DurationSeconds)s" -Tone Muted -Indent 6 }
    }
    Write-WuText -Text "Saved report and command output: $(Split-Path $Run.Path -Parent)" -Tone Muted
    Write-WuText -Text 'Completed commands do not guarantee that Windows is healthy. Read the tool summaries; repairs cannot be undone through Explorer history.' -Tone Muted
    foreach ($nativeLog in $Run.Report.NativeLogs) { Write-WuText -Text $nativeLog -Tone Muted }
    if ($Run.Report.Status -eq 'Running') { Write-WuText -Text 'This report is incomplete. A repair may still be running or have been interrupted.' -Tone Warning }
}

function Write-WuRepairLogOutput {
    param($Run, $Step)
    Write-WuText -Text "Command output | $($Step.Name)" -Tone Accent
    try {
        if ($Step.LogFile -cnotmatch '\A[a-z]+\.[a-z]+\.log\z') { throw 'Invalid repair log name.' }
        $path = Join-Path (Split-Path $Run.Path -Parent) $Step.LogFile
        if (-not [IO.File]::Exists($path)) { Write-WuText -Text 'No command output was recorded.' -Tone Muted; return }
        # Read only the tail; repair output can be large and progress uses carriage returns.
        $lines = @(Get-Content -LiteralPath $path -Encoding UTF8 -Tail 24 -ErrorAction Stop |
            ForEach-Object { $_ -split '[\r\n]+' } | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -Last 12)
        if ($lines.Count -eq 0) { Write-WuText -Text 'The command produced no output.' -Tone Muted }
        foreach ($line in $lines) { Write-WuText -Text $line -Indent 6 }
        Write-WuText -Text "Full output: $path" -Tone Muted
    }
    catch { Write-WuText -Text "Could not read log: $($_.Exception.Message)" -Tone Warning }
}

function Show-WuRepairReport {
    param($Run, [string]$BackLabel = 'Back to repair menu')
    Write-WuRepairSummary $Run
    # Surface the actual native error immediately, including old reports without CommandLine.
    # Quick checks can finish in seconds; show their diagnosis so completion is unambiguous.
    foreach ($step in $Run.Report.Steps) {
        if ($step.Status -in @('Failed', 'NeedsAttention', 'RestartRequired') -or
            ($null -ne $step.ExitCode -and $step.ExitCode -ne 0) -or
            ($step.Id -eq 'dism.check' -and $step.Status -eq 'Completed')) {
            Write-WuRepairLogOutput -Run $Run -Step $step
        }
    }
    while ($true) {
        Write-WuOption -Key 'O' -Label 'Show the end of each command log' -Tone Accent
        Write-WuFooter -Label $BackLabel
        if ((Read-WuChoice @('O', '0') -Prompt '  Repair report choice') -eq '0') { return }
        foreach ($step in $Run.Report.Steps) {
            Write-WuRepairLogOutput -Run $Run -Step $step
        }
    }
}

function Show-WuRepairHistory {
    while ($true) {
        Write-WuHeading 'Repair reports' 'Saved command output, timings and next steps'
        try { $runs = @(Get-WuRepairHistory) }
        catch { Write-WuText -Text $_.Exception.Message -Tone Warning; Wait-WuContinue; return }
        $options = @('0')
        if ($runs.Count -eq 0) { Write-WuText -Text 'No repair reports yet.' -Tone Muted }
        for ($i = 0; $i -lt $runs.Count; $i++) {
            $number = ($i + 1).ToString(); $options += $number
            $label = 'Unreadable report'
            if ($null -eq $runs[$i].Error) { $label = "$($runs[$i].Report.StartedAtUtc) | $($runs[$i].Report.RepairId) | $($runs[$i].Report.Status)" }
            Write-WuOption -Key $number -Label $label
        }
        Write-WuFooter
        $choice = Read-WuChoice $options
        if ($choice -eq '0') { return }
        $run = $runs[[int]$choice - 1]
        if ($null -ne $run.Error) { Write-WuText -Text $run.Error -Tone Warning; Wait-WuContinue }
        else { Show-WuRepairReport -Run $run -BackLabel 'Back to repair reports' }
    }
}

function Show-WuRepairAction {
    param($Action)
    $sourcePath = ''; $sourceIndex = 0
    try {
        $environment = Get-WuRepairEnvironment
        Write-WuHeading $Action.Name $Action.Description
        if ($Action.Id -in @('source.info', 'dism.source')) {
            Write-WuText -Text 'Use a local install.wim from mounted Windows media or a serviced image. Choose the matching release, architecture, edition, language and a sufficiently updated source.'
            Write-WuText -Text 'Use List WIM image indexes first to identify the correct edition. ISO/ESD files are not accepted here.' -Tone Muted
            $sourcePath = Read-WuFilePath '  WIM path, e.g. E:\sources\install.wim (0 to cancel)'
            if ($sourcePath -eq '0' -or $sourcePath.Length -eq 0) { return }
            if ($Action.Id -eq 'dism.source') {
                $indexText = Read-WuInput '  Matching image index (0 to cancel)' -CancelValue '0'
                if ($indexText -eq '0') { return }
                if (-not [int]::TryParse($indexText, [ref]$sourceIndex) -or $sourceIndex -lt 1) { throw 'Enter a positive image index from the WIM information.' }
            }
        }
        $plan = @(Get-WuRepairPlan -Id $Action.Id -SystemDrive $environment.SystemDrive -SourcePath $sourcePath -SourceIndex $sourceIndex)
        if ($script:WuPreviewOnly) { Write-WuText -Text 'PREVIEW ONLY. No repair commands will run. On Linux, C: is an example; Windows detects its actual system drive.' -Tone Warning }
        else {
            Write-WuText -Text "Windows drive: $($environment.SystemDrive) | $($environment.FileSystem) | Power: $($environment.Readiness.PowerStatus)" -Tone Muted
        }
        for ($i = 0; $i -lt $plan.Count; $i++) {
            $step = $plan[$i]
            Write-WuText -Text "$($i + 1). $($step.Name)" -Tone Title
            Write-WuText -Text $step.CommandLine -Tone Accent -Indent 6
        }
        Write-WuText
        if ($Action.Id -eq 'full') {
            Write-WuText -Text 'Allow time for all five steps. A disk problem, command failure or required restart stops later steps. Run again after resolving the reported issue.'
        }
        if ($Action.Id -eq 'dism.check') {
            Write-WuText -Text 'This quick check reads recorded corruption and may finish immediately. Choose Scan image health for a fresh scan.' -Tone Muted
        }
        if (@($plan | Where-Object { $_.Interactive }).Count -gt 0) {
            Write-WuText -Text 'Back up important files first. CHKDSK will ask whether to schedule a check at the next restart if it cannot lock the drive. Answer its prompt in your Windows language. WinUtility will not answer or restart for you.' -Tone Warning
        }
        elseif ($Action.Id -ne 'source.info') {
            Write-WuText -Text 'Keep the laptop plugged in and let each tool finish. DISM repair may need internet access; repair progress can pause for several minutes.' -Tone Muted
        }
        if ($script:WuPreviewOnly) { Wait-WuContinue; return }
        $blockers = @(Get-WuRepairBlockers -Plan $plan -Environment $environment)
        if ($blockers.Count -gt 0) {
            foreach ($blocker in $blockers) { Write-WuText -Text $blocker -Tone Warning }
            if (-not $environment.Readiness.IsAdmin) { Write-WuText -Text 'Use [A] on the Repair menu to open an administrator window.' -Tone Accent }
            Wait-WuContinue; return
        }
        if (-not (Confirm-WuChoice 'Run the commands shown above on this Windows installation?' 'Run repair tools')) { return }
        $run = Invoke-WuRepair -Id $Action.Id -SourcePath $sourcePath -SourceIndex $sourceIndex -Confirmed -OnProgress {
            param($Name, $Number, $Total)
            Write-WuHeading "Repair $Number / $Total" $Name
        }
        Show-WuRepairReport $run
    }
    catch { Write-WuText -Text "Repair stopped: $($_.Exception.Message) Check Repair reports for any work already started." -Tone Warning; Wait-WuContinue }
}

function Show-WuRepairMenu {
    param([switch]$Advanced)
    while ($true) {
        $group = 'Main'; $title = 'Repair Windows'
        if ($Advanced) { $group = 'Advanced'; $title = 'Advanced recovery tools' }
        Write-WuHeading $title 'Diagnose, repair, verify. Every run has its own report.'
        if ($script:WuPreviewOnly) { Write-WuText -Text 'PREVIEW ONLY / explore the commands and workflow.' -Tone Warning }
        $actions = @(Get-WuRepairCatalog | Where-Object { $_.Group -eq $group })
        $options = @('0')
        for ($i = 0; $i -lt $actions.Count; $i++) {
            $number = ($i + 1).ToString(); $options += $number
            $description = ''
            if ($script:WuKeyNavigation -or -not (Test-WuCompactDisplay)) { $description = $actions[$i].Description }
            Write-WuOption -Key $number -Label $actions[$i].Name -Description $description
        }
        if (-not $Advanced) {
            Write-WuOption -Key '8' -Label 'Advanced recovery tools' -Description 'Boot-time disk checks and repair from Windows media.'
            $options += '8'
        }
        else {
            Write-WuText -Text 'If corruption persists: inspect DISM/CBS logs, try a matching repair source, then consider a Windows repair reinstall. Boot failures need Windows Recovery Environment.' -Tone Muted
        }
        if (-not $script:WuPreviewOnly) {
            Write-WuOption -Key 'L' -Label 'Repair reports' -Tone Muted; $options += 'L'
            if (-not $script:WuEnvironment.IsAdmin) { Write-WuOption -Key 'A' -Label 'Open repair menu as administrator' -Tone Accent; $options += 'A' }
        }
        Write-WuFooter
        $choice = Read-WuChoice $options
        try {
            switch ($choice) {
                '0' { return }
                '8' { Show-WuRepairMenu -Advanced }
                'L' { Show-WuRepairHistory }
                'A' {
                    try { Open-WuRepairAsAdministrator -Plain:$script:WuPlain -NoKeyNavigation:(-not $script:WuKeyNavigation) }
                    catch { Write-WuText -Text "Administrator window was not opened: $($_.Exception.Message)" -Tone Warning; Wait-WuContinue }
                }
                default { Show-WuRepairAction $actions[[int]$choice - 1] }
            }
        }
        catch { Write-WuText -Text "Repair menu action failed: $($_.Exception.Message)" -Tone Warning; Wait-WuContinue }
    }
}

function Save-WuInteractive {
    param($Session)
    $defaultPath = $Session.SavedPath
    if ([string]::IsNullOrWhiteSpace($defaultPath)) { $defaultPath = Get-WuDefaultSetupPath }
    Write-WuText -Text "Default: $defaultPath" -Tone Muted
    $path = Read-WuFilePath 'Save JSON path (Enter for default, 0 to cancel)'
    if ($path -eq '0') { return $false }
    if ($path.Length -eq 0) { $path = $defaultPath }
    try {
        $overwrite = $false
        if (Test-Path -LiteralPath $path) {
            if (-not (Confirm-WuChoice "Replace the existing file '$path'?" 'Replace file')) { return $false }
            $overwrite = $true
        }
        $savedPath = Export-WuSetup -Session $Session -Path $path -Overwrite:$overwrite
        Write-WuText -Text "Saved setup: $savedPath" -Tone Success
        return $true
    }
    catch {
        Write-WuText -Text "Setup was not saved: $($_.Exception.Message)" -Tone Warning
        return $false
    }
}

function Show-WuSavedSetups {
    param($Session)
    while ($true) {
        Write-WuHeading 'Saved setups' 'Your choices, ready for the next laptop.'
        Write-WuSelectionSummary -Plan @(Get-WuPlan -Session $Session)
        Write-WuText
        Write-WuOption -Key '1' -Label 'Export current selection' -Description 'Save your settings and app choices to a JSON file.'
        Write-WuText
        Write-WuOption -Key '2' -Label 'Import a saved setup' -Description 'Preview a saved file, then load its selections.'
        Write-WuFooter
        switch (Read-WuChoice @('1', '2', '0')) {
            '0' { return }
            '1' { [void](Save-WuInteractive -Session $Session) }
            '2' {
                $path = Read-WuFilePath 'JSON file to import (Enter or 0 to cancel)'
                if ($path.Length -eq 0 -or $path -eq '0') { continue }
                try {
                    $preview = Import-WuSetup -Catalog $Session.Catalog -Path $path
                    Write-WuHeading 'Saved setup preview'
                    Write-WuPlan -Plan @(Get-WuPlan -Session $preview)
                    if (Confirm-WuChoice "Replace your current $($Session.Selected.Count) selections with this saved setup?" 'Use saved setup') {
                        Set-WuImportedSetup -Session $Session -Preview $preview
                        Write-WuText -Text 'Saved setup loaded. You can adjust any selection.' -Tone Success
                    }
                }
                catch { Write-WuText -Text "Setup was not loaded: $($_.Exception.Message)" -Tone Warning }
            }
        }
    }
}

function Start-WuTerminal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Environment, [switch]$Plain, [switch]$Preview, [switch]$Repair, [switch]$NoKeyNavigation)
    Initialize-WuAppearance -Plain:$Plain -NoKeyNavigation:$NoKeyNavigation
    $script:WuMenuFocus = @{}
    $script:WuEnvironment = $Environment
    $script:WuAcceptSourceAgreements = $false
    $script:WuPreviewOnly = $Preview -or -not $Environment.SupportedOS
    if ($Repair) { Show-WuRepairMenu; return }
    while ($true) {
        $Environment = $script:WuEnvironment
        $compact = Test-WuCompactDisplay
        $subtitle = 'A fresh start. A setup that feels like yours.'
        if ($compact) { $subtitle = '' }
        Write-WuHeading 'WINUTILITY / LAPTOP SETUP' $subtitle
        if ($script:WuPreviewOnly) { Write-WuText -Text 'Windows actions unavailable | Browse and save your setup' -Tone Warning }
        else { Write-WuText -Text '[WINDOWS MODE] Review and confirm before applying.' -Tone Accent }
        if (-not $compact) { Write-WuText }
        $wingetStatus = 'not available (app installs disabled)'
        if ($Environment.WinGetAvailable) { $wingetStatus = 'available' }
        Write-WuText -Text "$($Environment.OS) | PowerShell $($Environment.PowerShellVersion)" -Tone Muted
        Write-WuText -Text "WinGet: $wingetStatus" -Tone Muted
        if (-not $Environment.SupportedOS) {
            Write-WuText -Text 'Target: Windows 11. You can browse and save setups on this host.' -Tone Muted
        }
        $plan = @(Get-WuPlan -Session $Session)
        $reviewLabel = "Review & apply ($($plan.Count))"
        if ($script:WuPreviewOnly) { $reviewLabel = "Review selection ($($plan.Count))" }
        if (-not $compact) { Write-WuText }
        Write-WuSelectionSummary -Plan $plan
        $saveStatus = 'No unsaved changes'
        if (Test-WuUnsavedChanges -Session $Session) { $saveStatus = 'Unsaved choices / export to keep them' }
        Write-WuText -Text $saveStatus -Tone Muted
        if (-not $compact) { Write-WuText; Write-WuRule }
        if (-not $compact) { Write-WuText -Text 'CHOOSE  >  CUSTOMIZE  >  REVIEW' -Tone Accent; Write-WuText }
        $menu = @(
            @('1', 'Presets', 'Minimal, Balanced or Full. Start with a complete setup.'),
            @('2', 'Manual changes', 'Privacy, Explorer, power and Windows features.'),
            @('3', 'App installs', 'Browse the catalog or find an app by name.'),
            @('4', $reviewLabel, 'Review your choices and apply supported actions.'),
            @('5', 'Saved setups', 'Save this setup or bring one from another laptop.'),
            @('6', 'Repair Windows', 'Full repair, DISM, SFC, disk checks and recovery tools.')
        )
        foreach ($item in $menu) {
            $description = ''
            $tone = 'Title'
            if ($script:WuKeyNavigation -or -not $compact) { $description = $item[2] }
            if ($item[0] -eq '4') { $tone = 'Accent' }
            Write-WuOption -Key $item[0] -Label $item[1] -Description $description -Tone $tone
            if (-not $compact -and $item[0] -ne '6') { Write-WuText }
        }
        Write-WuOption -Key 'I' -Label 'Machine readiness' -Tone Muted
        $options = @('1', '2', '3', '4', '5', '6', 'I', '0')
        if (-not $script:WuPreviewOnly) { Write-WuOption -Key 'H' -Label 'History & Explorer undo' -Tone Muted; $options += 'H' }
        Write-WuFooter -Label 'Exit'
        switch (Read-WuChoice $options) {
            '1' { Show-WuPresets -Session $Session }
            '2' { Show-WuCategories -Session $Session -Kind Settings }
            '3' { Show-WuCategories -Session $Session -Kind Apps }
            '4' { Show-WuReview -Session $Session }
            '5' { Show-WuSavedSetups -Session $Session }
            '6' { Show-WuRepairMenu }
            'I' { Show-WuReadiness }
            'H' { Show-WuHistory }
            '0' {
                if (Test-WuUnsavedChanges -Session $Session) {
                    Write-WuHeading 'Unsaved selections' 'Keep this setup for another time?'
                    Write-WuOption -Key '1' -Label 'Save and exit' -Tone Accent
                    Write-WuOption -Key '2' -Label 'Discard and exit'
                    Write-WuFooter -Label 'Cancel'
                    $exitChoice = Read-WuChoice @('1', '2', '0') -DefaultKey '0'
                    if ($exitChoice -eq '0') { continue }
                    if ($exitChoice -eq '1' -and -not (Save-WuInteractive -Session $Session)) { continue }
                }
                Write-WuText -Text 'Goodbye. Your saved setups and run history remain available.' -Tone Muted
                return
            }
        }
    }
}

Export-ModuleMember -Function Start-WuTerminal
