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

Requires **Zig 0.16**:

```bash
git clone https://github.com/luth9r/zap.git
cd zap
zig build -Doptimize=ReleaseFast

```

The compiled binary will be located at `zig-out/bin/zap`.

## Configuration

Config path: `~/.config/zap/config.toml` (or `%APPDATA%\zap\config.toml` on Windows).

```toml
"$schema" = "https://raw.githubusercontent.com/luth9r/zap/main/zap.schema.json"

add_newline = true

[directory]
home_symbol = "~"
home_color = "cyan"

[character]
success_symbol = "➜"
success_color = "bold green"
error_symbol = "➜"
error_color = "bold red"

```

## License

Copyright © 2026-present, [luth9r](https://github.com/luth9r).

This project is [MIT](https://github.com/luth9r/zap/blob/main/LICENSE) licensed.
