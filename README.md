<div align="center">

# <img src="docs/public/favicon.svg" width="30" height="30" valign="middle" /> zap

<p align="center">
  <a href="https://github.com/luth9r/zap/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-yellow.svg?style=flat-square" alt="License: MIT"></a>
  <a href="https://ziglang.org/"><img src="https://img.shields.io/badge/zig-0.16-orange.svg?style=flat-square&logo=zig" alt="Zig 0.16"></a>
  <a href="#"><img src="https://img.shields.io/badge/memory-~1.2MB-brightgreen.svg?style=flat-square" alt="Memory Usage"></a>
  <a href="#"><img src="https://img.shields.io/badge/latency-%3C1ms-blue.svg?style=flat-square" alt="Latency"></a>
</p>

**A minimalist, zero-allocation shell prompt written in Zig**

~1.2 MB RSS · sub-millisecond latency · zero heap allocations on render

[Documentation](https://luth9r.github.io/zap/) • [Installation](#installation) • [Shell Setup](#shell-setup) • [Configuration](#configuration) • [License](#license)

</div>

---

## Installation

### Binaries

Pre-compiled static binaries are available on the [Releases](https://github.com/luth9r/zap/releases) page.

```bash
# Linux x86_64
curl -sSL https://github.com/luth9r/zap/releases/latest/download/zap-v1.0.0-x86_64-linux.tar.gz | tar -xz
mkdir -p ~/.local/bin && mv zap ~/.local/bin/
```

### Nix (Home Manager)

```nix
# flake.nix
inputs.zap.url = "github:luth9r/zap";

# home.nix
programs.zap = {
  enable = true;
  settings = {
    add_newline = false;
    format = "$directory$git_branch$git_status$character";
    directory.style = "bold cyan";
  };
};
```

### Build from source

Requires **Zig 0.16**:

```bash
git clone https://github.com/luth9r/zap.git
cd zap
zig build -Doptimize=ReleaseFast
cp zig-out/bin/zap ~/.local/bin/
```

---

## Shell Setup

Add the init line to your shell configuration:

### Fish

```fish
# ~/.config/fish/config.fish
zap init fish | source
```

### Zsh

```zsh
# ~/.zshrc
eval "$(zap init zsh)"
```

### Bash

```bash
# ~/.bashrc
eval "$(zap init bash)"
```

### PowerShell

```powershell
# $PROFILE
(&zap init powershell | Out-String) | Invoke-Expression
```

---

## Configuration

zap searches for configuration in `~/.config/zap/config.toml` (or `$ZAP_CONFIG`).

```toml
"$schema" = "https://raw.githubusercontent.com/luth9r/zap/main/zap.schema.json"

add_newline = false
format = "$directory$git_branch$git_status$cmd_duration$character"

[directory]
style = "bold cyan"
truncation_length = 3
truncate_to_repo = true

[git_branch]
symbol = " "
style = "bold purple"

[git_status]
style = "bold red"

[cmd_duration]
min_time = 2000
style = "bold yellow"

[character]
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"
```

Full configuration options, module references, styling, and template engine guides are available in the **[Documentation](https://luth9r.github.io/zap/)**.

---

## License

[MIT](LICENSE)
