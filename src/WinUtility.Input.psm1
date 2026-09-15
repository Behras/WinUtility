Set-StrictMode -Version 2.0

function Test-WuKeyInput {
    try {
        return $Host.Name -eq 'ConsoleHost' -and $env:TERM -ne 'dumb' -and
            -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected -and
            [Console]::WindowWidth -ge 20 -and [Console]::WindowHeight -ge 8
    }
    catch { return $false }
}

function Clear-WuKeyScreen { [Console]::Clear() }
function Read-WuConsoleKey { return [Console]::ReadKey($true) }

function Limit-WuInputText {
    param([string]$Text, [int]$Width)
    $text = $Text -replace '[\x00-\x1f\x7f-\x9f]', ' '
    if ($text.Length -le $Width) { return $text }
    return $text.Substring(0, [Math]::Max(0, $Width - 3)) + '...'
}

function Write-WuKeyFrame {
    param($State, [object[]]$Items, [int]$Index, [string]$Text, [int]$Position,
        [string]$Prompt, [string]$Message, [switch]$Plain, [switch]$CanToggle)
    $width = [Math]::Min(92, [Console]::WindowWidth - 2)
    $height = [Console]::WindowHeight
    if ($width -lt 18 -or $height -lt 8) { throw 'The console is too small for key navigation.' }
    $visible = [Math]::Min($Items.Count, $height - 5)
    $rows = $visible + 3
    $relativeCursor = [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT
    $escape = [string][char]27
    if (-not $State.ContainsKey('Top') -or $State.Width -ne $width -or $State.Height -ne $height) {
        if (-not $State.ContainsKey('CursorVisible')) {
            $State.CursorVisible = $true
            try { $State.CursorVisible = [Console]::CursorVisible } catch { }
        }
        # Reserve the whole widget before locating it, accounting for console scrolling.
        [Console]::Write(("`n" * $rows))
        $State.Top = 0
        if (-not $relativeCursor) { $State.Top = [Math]::Max(0, [Console]::CursorTop - $rows) }
        $State.RelativeCursor = $relativeCursor
        $State.Width = $width; $State.Height = $height; $State.Rows = $rows
    }
    $first = [Math]::Min([Math]::Max(0, $Index - [int][Math]::Floor($visible / 2)), [Math]::Max(0, $Items.Count - $visible))
    [Console]::CursorVisible = $false
    # Unix terminals need no cursor-position query: every redraw ends below this block.
    if ($relativeCursor) { [Console]::Write("${escape}[${rows}A`r") }
    for ($row = 0; $row -lt $rows; $row++) {
        $line = ''; $color = 'DarkGray'
        if ($row -lt $visible) {
            $item = $Items[$first + $row]
            $marker = '  '; $color = 'Gray'
            if ($item.PSObject.Properties.Name -contains 'Color') { $color = $item.Color }
            if (($first + $row) -eq $Index) { $marker = '> '; $color = 'Cyan' }
            $line = '{0}[{1}] {2}' -f $marker, $item.Key, $item.Label
        }
        elseif ($row -eq $visible) {
            if ($Items.Count -gt 0) { $line = $Items[$Index].Description }
            if ($Message.Length -gt 0) { $line = $Message; $color = 'Yellow' }
        }
        elseif ($row -eq ($visible + 1)) {
            $line = 'Enter submit | Esc cancel | Left/Right edit'
            if ($Items.Count -gt 0) {
                $line = 'Up/Down move | Enter select | Esc back | Type a shortcut'
                if ($CanToggle) { $line = 'Up/Down move | Space/Enter toggle | Esc back | Type a shortcut' }
            }
        }
        else {
            # Keep the caret in view while editing long paths, queries or app batches.
            $prefix = '> '
            $available = $width - $prefix.Length - 1
            $offset = [Math]::Max(0, $Position - $available + 1)
            $visibleText = $Text.Substring($offset)
            if ($visibleText.Length -gt $available) { $visibleText = $visibleText.Substring(0, $available) }
            $line = $prefix + $visibleText.Insert($Position - $offset, '|')
            if ($Text.Length -eq 0) { $line = $Prompt.Trim() + ' > ' }
            $color = 'White'
        }
        if (-not $relativeCursor) { [Console]::SetCursorPosition(0, $State.Top + $row) }
        $arguments = @{ Object = (Limit-WuInputText $line $width).PadRight($width); NoNewline = $true }
        if (-not $Plain) { $arguments.ForegroundColor = $color }
        Write-Host @arguments
        if ($relativeCursor) { [Console]::Write("`r`n") }
    }
}

function Close-WuKeyFrame {
    param($State)
    try {
        if ($State.ContainsKey('Top') -and -not $State.RelativeCursor) { [Console]::SetCursorPosition(0, [Math]::Min([Console]::BufferHeight - 1, $State.Top + $State.Rows)) }
    }
    finally {
        if ($State.ContainsKey('CursorVisible')) { [Console]::CursorVisible = $State.CursorVisible }
    }
}

function Read-WuKeyChoice {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Items = @(), [string]$DefaultKey = '',
        [string]$Prompt = 'Choose', [string]$CancelValue = '0', [switch]$AllowText,
        [string[]]$ToggleKeys = @(), [switch]$PageNavigation, [switch]$Plain)
    $index = 0
    for ($i = 0; $i -lt $Items.Count; $i++) { if ($Items[$i].Key -ieq $DefaultKey) { $index = $i; break } }
    $text = ''; $position = 0; $message = ''; $state = @{}
    try {
        while ($true) {
            Write-WuKeyFrame -State $state -Items $Items -Index $index -Text $text -Position $position -Prompt $Prompt -Message $message -Plain:$Plain -CanToggle:($ToggleKeys.Count -gt 0)
            $key = Read-WuConsoleKey
            $message = ''
            $focus = ''; if ($Items.Count -gt 0) { $focus = $Items[$index].Key }
            if ($key.Key -eq [ConsoleKey]::Escape) { return [pscustomobject]@{ Value = $CancelValue; FocusKey = $focus } }
            if ($key.Key -eq [ConsoleKey]::Enter) {
                $value = $text.Trim()
                if ($text.Length -eq 0 -and $Items.Count -gt 0) { $value = $focus }
                if ($AllowText -or @($Items | Where-Object { $_.Key -ieq $value }).Count -gt 0) {
                    if (@($Items | Where-Object { $_.Key -ieq $value }).Count -gt 0) { $focus = $value }
                    return [pscustomobject]@{ Value = $value; FocusKey = $focus }
                }
                $message = 'Choose a listed option, or press Esc to go back.'
                continue
            }
            if ($key.Key -eq [ConsoleKey]::Spacebar -and $text.Length -eq 0 -and $ToggleKeys -contains $focus) {
                return [pscustomobject]@{ Value = $focus; FocusKey = $focus }
            }
            if ($Items.Count -gt 0 -and $key.Key -in @([ConsoleKey]::UpArrow, [ConsoleKey]::DownArrow, [ConsoleKey]::Tab)) {
                $delta = 1
                if ($key.Key -eq [ConsoleKey]::UpArrow -or ($key.Key -eq [ConsoleKey]::Tab -and ($key.Modifiers -band [ConsoleModifiers]::Shift))) { $delta = -1 }
                $index = ($index + $delta + $Items.Count) % $Items.Count
                $text = ''; $position = 0; continue
            }
            if ($PageNavigation -and $text.Length -eq 0) {
                $pageKey = ''
                if ($key.Key -in @([ConsoleKey]::RightArrow, [ConsoleKey]::PageDown)) { $pageKey = 'N' }
                if ($key.Key -in @([ConsoleKey]::LeftArrow, [ConsoleKey]::PageUp)) { $pageKey = 'P' }
                if ($pageKey.Length -gt 0 -and @($Items | Where-Object { $_.Key -eq $pageKey }).Count -gt 0) {
                    return [pscustomobject]@{ Value = $pageKey; FocusKey = $focus }
                }
            }
            switch ($key.Key) {
                ([ConsoleKey]::Home) { if ($text.Length -eq 0 -and $Items.Count -gt 0) { $index = 0 } else { $position = 0 }; continue }
                ([ConsoleKey]::End) { if ($text.Length -eq 0 -and $Items.Count -gt 0) { $index = $Items.Count - 1 } else { $position = $text.Length }; continue }
                ([ConsoleKey]::LeftArrow) { $position = [Math]::Max(0, $position - 1); continue }
                ([ConsoleKey]::RightArrow) { $position = [Math]::Min($text.Length, $position + 1); continue }
                ([ConsoleKey]::Backspace) { if ($position -gt 0) { $text = $text.Remove($position - 1, 1); $position-- }; continue }
                ([ConsoleKey]::Delete) { if ($position -lt $text.Length) { $text = $text.Remove($position, 1) }; continue }
            }
            if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq [ConsoleKey]::U) { $text = ''; $position = 0; continue }
            if (-not [char]::IsControl($key.KeyChar) -and $text.Length -lt 4096) {
                $text = $text.Insert($position, [string]$key.KeyChar); $position++
            }
        }
    }
    finally { Close-WuKeyFrame $state }
}

Export-ModuleMember -Function Test-WuKeyInput, Clear-WuKeyScreen, Read-WuKeyChoice
