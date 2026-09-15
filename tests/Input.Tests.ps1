function Invoke-KeyScenario {
    param([string[]]$Keys, [object[]]$Items, [string]$DefaultKey = '', [switch]$AllowText,
        [string[]]$ToggleKeys = @(), [switch]$PageNavigation, [string]$CancelValue = '0', [switch]$Plain)
    if ($null -eq $Items) {
        $Items = @('1', '2', '0') | ForEach-Object { [pscustomobject]@{ Key = $_; Label = "Option $_"; Description = '' } }
    }
    $module = Import-Module (Join-Path $script:RepoRoot 'src/WinUtility.Input.psm1') -Force -PassThru
    try {
        & $module {
            param($Tokens, $Options, $Default, $FreeText, $Toggles, $Pages, $Cancel, $PlainMode)
            $script:KeyQueue = New-Object Collections.Queue
            foreach ($token in $Tokens) {
                if ($token -match '^<([A-Za-z]+)>$') {
                    $name = $Matches[1]; $character = [char]0
                    if ($name -eq 'Spacebar') { $character = [char]' ' }
                    $script:KeyQueue.Enqueue([pscustomobject]@{ Key = [ConsoleKey]$name; KeyChar = $character; Modifiers = 0 })
                }
                else {
                    foreach ($character in $token.ToCharArray()) { $script:KeyQueue.Enqueue([pscustomobject]@{ Key = [ConsoleKey]0; KeyChar = $character; Modifiers = 0 }) }
                }
            }
            $script:Frames = New-Object Collections.ArrayList
            $script:Closed = 0
            function script:Read-WuConsoleKey {
                if ($script:KeyQueue.Count -eq 0) { throw 'Test key input exhausted.' }
                return $script:KeyQueue.Dequeue()
            }
            function script:Write-WuKeyFrame {
                param($State, $Items, $Index, $Text, $Position, $Prompt, $Message, [switch]$Plain, [switch]$CanToggle)
                [void]$script:Frames.Add([pscustomobject]@{ Index = $Index; Text = $Text; Position = $Position; Message = $Message; Plain = [bool]$Plain })
            }
            function script:Close-WuKeyFrame { param($State) $script:Closed++ }
            $result = Read-WuKeyChoice -Items $Options -DefaultKey $Default -AllowText:$FreeText -ToggleKeys $Toggles -PageNavigation:$Pages -CancelValue $Cancel -Plain:$PlainMode
            if ($script:KeyQueue.Count -ne 0) { throw 'Unused test keys.' }
            [pscustomobject]@{ Value = $result.Value; Focus = $result.FocusKey; Frames = @($script:Frames); Closed = $script:Closed }
        } $Keys $Items $DefaultKey $AllowText $ToggleKeys $PageNavigation $CancelValue $Plain
    }
    finally { Remove-Module -ModuleInfo $module -Force }
}

Test-Case 'Arrow navigation moves, wraps, and selects with Enter' {
    $result = Invoke-KeyScenario -Keys @('<DownArrow>', '<Enter>')
    Assert-Equal '2' $result.Value
    Assert-Equal '2' $result.Focus
    Assert-Equal 1 $result.Closed
    $result = Invoke-KeyScenario -Keys @('<UpArrow>', '<Enter>')
    Assert-Equal '0' $result.Value
    $result = Invoke-KeyScenario -Keys @('<End>', '<DownArrow>', '<Tab>', '<Home>', '<Enter>')
    Assert-Equal '1' $result.Value
}

Test-Case 'A default Cancel selection requires deliberate movement before confirmation' {
    $result = Invoke-KeyScenario -DefaultKey '0' -Keys @('<Enter>')
    Assert-Equal '0' $result.Value
    Assert-Equal 2 $result.Frames[0].Index
    $result = Invoke-KeyScenario -DefaultKey '0' -Keys @('<DownArrow>', '<Enter>')
    Assert-Equal '1' $result.Value
}

Test-Case 'Escape cancels menus and unfinished text without submitting it' {
    $result = Invoke-KeyScenario -Keys @('1', '<Escape>')
    Assert-Equal '0' $result.Value
    $result = Invoke-KeyScenario -Items @() -AllowText -CancelValue '' -Keys @('unfinished path', '<Escape>')
    Assert-Equal '' $result.Value
}

Test-Case 'Typed shortcuts and app batches remain available with key navigation' {
    $items = @('1', '12', '0') | ForEach-Object { [pscustomobject]@{ Key = $_; Label = $_; Description = '' } }
    $result = Invoke-KeyScenario -Items $items -Keys @('12', '<Enter>')
    Assert-Equal '12' $result.Value
    Assert-Equal '12' $result.Focus
    $result = Invoke-KeyScenario -AllowText -Keys @('1,3,5-7', '<Enter>')
    Assert-Equal '1,3,5-7' $result.Value
    $result = Invoke-KeyScenario -AllowText -Keys @('D', '<Spacebar>', '2', '<Enter>')
    Assert-Equal 'D 2' $result.Value
}

Test-Case 'Space toggles only designated checkbox items' {
    $result = Invoke-KeyScenario -ToggleKeys @('1', '2') -Keys @('<DownArrow>', '<Spacebar>')
    Assert-Equal '2' $result.Value
    $result = Invoke-KeyScenario -DefaultKey '0' -ToggleKeys @('1', '2') -Keys @('<Spacebar>', '<Escape>')
    Assert-Equal '0' $result.Value
}

Test-Case 'Page arrows only choose available pages and text editing takes precedence' {
    $items = @('1', 'N', 'P', '0') | ForEach-Object { [pscustomobject]@{ Key = $_; Label = $_; Description = '' } }
    foreach ($spec in @(@('<RightArrow>', 'N'), @('<PageDown>', 'N'), @('<LeftArrow>', 'P'), @('<PageUp>', 'P'))) {
        Assert-Equal $spec[1] (Invoke-KeyScenario -Items $items -PageNavigation -Keys @($spec[0])).Value
    }
    Assert-Equal '0' (Invoke-KeyScenario -PageNavigation -Keys @('<RightArrow>', '<Escape>')).Value
    Assert-Equal '12' (Invoke-KeyScenario -AllowText -PageNavigation -Keys @('13', '<LeftArrow>', '<Delete>', '2', '<Enter>')).Value
}

Test-Case 'Text fields support editing, spaces and literal shell characters' {
    $result = Invoke-KeyScenario -Items @() -AllowText -Keys @('abcd', '<Home>', '<RightArrow>', '<Delete>', '<End>', '<Backspace>', 'Z', '<Enter>')
    Assert-Equal 'acZ' $result.Value
    $text = 'E:\Windows media\install.wim; $(literal)'
    $result = Invoke-KeyScenario -Items @() -AllowText -Keys @($text, '<Enter>')
    Assert-Equal $text $result.Value
}

Test-Case 'Invalid menu text stays open and plain mode retains navigation' {
    $result = Invoke-KeyScenario -Plain -Keys @('unknown', '<Enter>', '<DownArrow>', '<Enter>')
    Assert-Equal '2' $result.Value
    Assert-True (@($result.Frames | Where-Object { $_.Message.Length -gt 0 }).Count -gt 0)
    Assert-True (@($result.Frames | Where-Object { -not $_.Plain }).Count -eq 0)
}
