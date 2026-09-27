<div align="center">

# zap ⚡︎

<p align="center">
  <a href="https://github.com/luth9r/zap/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-yellow.svg?style=flat-square" alt="License: MIT"></a>
  <a href="https://ziglang.org/"><img src="https://img.shields.io/badge/zig-0.16-orange.svg?style=flat-square&logo=zig" alt="Zig 0.16"></a>
  <a href="#"><img src="https://img.shields.io/badge/memory-%3C1MB-brightgreen.svg?style=flat-square" alt="Memory Usage"></a>
</p>

[Build](#build) • [Configuration](#configuration) • [License](#license)

</div>

**A minimalist shell prompt written in Zig**
Takes under 1 MB of memory (~800 KB RSS) and renders with virtually no latency.

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
function fish_prompt
    /path/to/zap $status
end
```

### Zsh

Add to `~/.zshrc`:

```zsh
setopt PROMPT_SUBST
PROMPT='$(/path/to/zap $?)'
```

### Bash

Add to `~/.bashrc`:

```bash
PROMPT_COMMAND='PS1="$(/path/to/zap $?)"'
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
[┌─](bold purple)[ X ](bold purple)$directory
[└─](bold purple)[ ⚡ ](bold yellow)$character"""

[directory]
format = "[$path]($style)[$read_only]($read_only_style) "
style = "bold cyan"
home_symbol = "~"
read_only = " 󰌾"
read_only_style = "bold red"
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

## License

MIT
