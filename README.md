# zap ⚡

A blazing-fast, zero-allocation, minimalist shell prompt written in Zig.

## Features

- **Blazing Fast**: Renders in microseconds with under 1 MB of memory footprint (RSS ~800 KB).
- **Zero Heap Allocations**: Streamed terminal rendering and zero-overhead TOML parsing.
- **Configurable**: Simple TOML configuration with JSON Schema support for editor auto-completion.
- **Cross-platform**: Native support for Linux, macOS, and Windows.

## Installation

### Building from Source

Ensure you have **Zig 0.16+** installed.

```bash
git clone [https://github.com/username/zap.git](https://github.com/luth9r/zap.git)
cd zap
zig build -Doptimize=ReleaseFast
```
