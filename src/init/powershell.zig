const std = @import("std");

pub const SCRIPT =
    \\# Zap prompt integration for PowerShell
    \\
    \\$global:ZapLastHistoryId = $null
    \\
    \\function global:prompt {
    \\    $origDollarQuestion = $global:?
    \\    $origLastExitCode = if ($global:LASTEXITCODE -ne $null) { $global:LASTEXITCODE } else { 0 }
    \\    $lastExitCodeForPrompt = $origLastExitCode
    \\    if (-not $origDollarQuestion -and $origLastExitCode -eq 0) {
    \\        $lastExitCodeForPrompt = 1
    \\    }
    \\
    \\    $duration = 0
    \\    $lastCmd = Get-History -Count 1
    \\    if ($lastCmd -and ($global:ZapLastHistoryId -ne $lastCmd.Id)) {
    \\        $global:ZapLastHistoryId = $lastCmd.Id
    \\        $duration = [int][math]::Round(($lastCmd.EndExecutionTime - $lastCmd.StartExecutionTime).TotalMilliseconds)
    \\    }
    \\
    \\    $out = & "{{EXE}}" prompt --status $lastExitCodeForPrompt --duration $duration --shell powershell
    \\    $promptText = if ($out -is [array]) { $out -join [Environment]::NewLine } else { [string]$out }
    \\
    \\    if (Get-Command -Name Set-PSReadLineOption -ErrorAction SilentlyContinue) {
    \\        $lines = ($promptText -split "`r?`n").Length - 1
    \\        Set-PSReadLineOption -ExtraPromptLineCount ([math]::Max(0, $lines))
    \\    }
    \\
    \\    $promptText
    \\}
    \\
;
