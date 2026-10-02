# Zig Language (`$zig_lang`)

The `zig_lang` module renders the Zig language indicator symbol whenever the current working directory or any of its parent directories (up to the Git repository root or `$HOME`) is part of a Zig project.

---

## Detection Triggers

The module activates automatically when any of the following files or extensions are detected:

- **Manifest & build files**: `build.zig`, `build.zig.zon` (searched in current directory and parent directories up to git root)
- **File extensions**: `*.zig`, `*.zon` (searched in current working directory)

---

## Format Variables

| Variable | Description |
|---|---|
| `$symbol` | Symbol defined in the `symbol` configuration option |
| `$version` | Version string defined in the `version` configuration option |
| `$style` | Style string defined in the `style` configuration option |

---

## Configuration Options

| Option | Type | Default | Description |
|---|---|---|---|
| `format` | `string` | `"[$symbol$version]($style) "` | Format template for the module |
| `symbol` | `string` | `"↯ "` | Symbol shown when a Zig project is detected |
| `style` | `style` | `"bold yellow"` | ANSI color and style formatting |
| `version` | `string` | `""` | Optional static version string override |
| `disabled` | `boolean` | `false` | Disables the module completely when set to `true` |

---

## Examples

### Adding to the prompt format
```toml
format = "$directory$zig_lang$character"
```

### Custom Symbol and Style
```toml
[zig_lang]
symbol = "⚡ "
style = "bold #f1fa8c"
```

### With Version String
```toml
[zig_lang]
symbol = "↯ "
version = "0.16.0"
format = "[$symbol($version )]($style)"
style = "bold yellow"
```

### Completely Disabled
```toml
[zig_lang]
disabled = true
```
