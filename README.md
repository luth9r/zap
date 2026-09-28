<div align="center">

# zap ⚡︎

<p align="center">
  <a href="https://github.com/luth9r/zap/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-yellow.svg?style=flat-square" alt="License: MIT"></a>
  <a href="https://ziglang.org/"><img src="https://img.shields.io/badge/zig-0.16-orange.svg?style=flat-square&logo=zig" alt="Zig 0.16"></a>
  <a href="#"><img src="https://img.shields.io/badge/memory-~1.2MB-brightgreen.svg?style=flat-square" alt="Memory Usage"></a>
</p>

[Build](#build) • [Configuration](#configuration) • [License](#license)

</div>

**A minimalist shell prompt written in Zig**
Takes ~1.2 MB of memory (~1280 KB Max RSS), zero heap allocations on prompt render path, and renders with sub-millisecond latency (< 1ms).

## Build

Requires Zig 0.16.

```bash
git clone https://github.com/luth9r/zap.git
cd zap
zig build -Doptimize=ReleaseFast
```

The compiled binary will be placed at `zig-out/bin/zap`.

Run tests:

```bash
zig build test
```

## Shell Integration

### Fish

Add to `~/.config/fish/config.fish`:

```fish
zap init fish | source
```

### Zsh

Add to `~/.zshrc`:

```zsh
eval "$(zap init zsh)"
```

### Bash

Add to `~/.bashrc`:

```bash
eval "$(zap init bash)"
```

### PowerShell

Add to your `$PROFILE`:

```powershell
(&zap init powershell | Out-String) | Invoke-Expression
```

## Configuration

zap searches for configuration in:

1. `$ZAP_CONFIG`
2. `$XDG_CONFIG_HOME/zap/config.toml`
3. `~/.config/zap/config.toml` (or `%APPDATA%\zap\config.toml` on Windows)

### Example `~/.config/zap/config.toml`

```toml
"$schema" = "https://raw.githubusercontent.com/luth9r/zap/main/zap.schema.json"

add_newline = true

format = """
[┌─](bold purple)[ X ](bold purple)$directory$git_branch$git_commit$git_state$git_status$cmd_duration
[└─](bold purple)[ ⚡ ](bold yellow)$character"""

[directory]
format = "[$path]($style)[$read_only]($read_only_style) "
style = "bold cyan"
home_symbol = "~"
read_only = " 󰌾"
read_only_style = "bold red"
truncation_length = 3
truncation_symbol = "…/"
truncate_to_repo = true
disabled = false

[git_branch]
format = "on [$symbol$branch]($style) "
symbol = " "
style = "bold purple"
truncation_length = 0
truncation_symbol = "…"
disabled = false

[git_commit]
format = "[\\($hash$tag\\)]($style) "
style = "bold green"
only_detached = true
disabled = false

[git_state]
format = "\\([$state( $progress_current/$progress_total)]($style)\\) "
style = "bold yellow"
disabled = false

[git_status]
format = "([\\[$all_status$ahead_behind\\]]($style) )"
style = "bold red"
disabled = false

[cmd_duration]
min_time = 2000
format = "took [$duration]($style) "
style = "bold yellow"
show_milliseconds = false
disabled = false

[character]
format = "$symbol "
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"
disabled = false
```

## Styling

Styles inside `[text](style)` or module `style` settings support:

| Type          | Syntax                                                          | Examples                     |
| ------------- | --------------------------------------------------------------- | ---------------------------- |
| Modifiers     | bold, italic, underline, dimmed, blink, inverted, strikethrough | `bold italic`, `dimmed`      |
| Named Colors  | black, red, green, yellow, blue, magenta, purple, cyan, white   | `cyan`, `bold green`         |
| Bright Colors | bright-red, bright-green, bright-cyan, gray, grey               | `bright-cyan`, `gray`        |
| Hex TrueColor | #RGB or #RRGGBB                                                 | `#fff`, `#bf5700`, `#bd93f9` |
| ANSI 256      | 0 to 255                                                        | `240`, `fg:27`, `bg:200`     |
| Prefixes      | fg:color, bg:color                                              | `fg:#50fa7b bg:#282a36`      |

## Format & Templating

Zap supports a rich template engine for prompt layout and module formatting.

### Variables & Modules
* **Modules**: `$directory`, `$git_branch`, `$git_commit`, `$git_state`, `$git_status`, `$cmd_duration`, `$character`
* **Module inner variables**: `$path`, `$branch`, `$remote_branch`, `$hash`, `$tag`, `$state`, `$progress_current`, `$progress_total`, `$all_status`, `$ahead_behind`, `$staged`, `$modified`, `$untracked`, `$renamed`, `$deleted`, `$stashed`, `$duration`, `$symbol`, `$style`

### Escape Character (`\`)
Use a backslash `\` before any character to escape it and output it literally without triggering template processing:

| Syntax | Output | Description |
| :--- | :--- | :--- |
| `\$` | `$` | Literal dollar sign (prevents variable expansion) |
| `\[` | `[` | Literal open bracket (prevents styled block) |
| `\]` | `]` | Literal close bracket |
| `\(` | `(` | Literal open parenthesis (prevents conditional group) |
| `\)` | `)` | Literal close parenthesis |
| `\\` | `\` | Literal backslash |
| `\n` | *(newline)* | Line break |
| `\t` | *(tab)* | Tabulation |

> **TOML Note:** In TOML strings with double quotes (`"..."`), escape the backslash: `"\\$"`. In single-quoted literal strings (`'...'`), you can write `'\\$'` or `'\$'`.

### Blocks & Grouping
* **Styled Blocks**: `[text](style)` applies ANSI styling (e.g. `[➜](bold green)` or `[$path]($style)`).
* **Conditional Groups**: `(content with $var)` renders the inner content only if `$var` is non-empty.

Example with literal `$` in prompt:

```toml
format = "[$path](bold cyan) \\$ "
```

## License

MIT
