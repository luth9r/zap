# Zig Language Module (`zig_lang`)

The `zig_lang` module displays a symbol when the current working directory or its parent directories (up to the Git repository root or `$HOME`) belong to a Zig project.

---

## Detection Triggers

The module activates automatically when any of the following are found:
- **Files**: `build.zig`, `build.zig.zon`
- **Extensions**: `*.zig`, `*.zon`

---

## Configuration

| Option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `format` | `string` | `"[$symbol]($style) "` | Format template for the Zig indicator |
| `symbol` | `string` | `"↯ "` | Symbol shown when Zig project is detected |
| `style` | `string` | `"bold yellow"` | ANSI color and style formatting |
| `version` | `string` | `""` | Optional static version string override |
| `disabled` | `boolean` | `false` | Disables the module completely when `true` |

---

## Examples

### Default usage
```toml
format = "$directory$zig_lang$character"
```

### Custom Symbol and Style
```toml
[zig_lang]
symbol = "⚡ "
style = "bold yellow"
```

### Completely Disabled
```toml
[zig_lang]
disabled = true
```
