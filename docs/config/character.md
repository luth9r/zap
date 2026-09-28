# Character (`$character`)

The `character` module renders the prompt's interactive symbol, switching appearance based on whether the last command succeeded (exit code `0`) or failed (non-zero).

## Format Variables

| Variable | Description |
|---|---|
| `$symbol` | Resolved `success_symbol` or `error_symbol` string |
| `$style` | Style string defined in `style` |

---

## Configuration Options

| Option | Type | Default | Description |
|---|---|---|---|
| `format` | `string` | `"$symbol "` | Format template for the character module |
| `success_symbol` | `string` | `"[❯](bold green)"` | Symbol displayed on exit code 0. Supports `[symbol](style)` |
| `error_symbol` | `string` | `"[❯](bold red)"` | Symbol displayed on non-zero exit code. Supports `[symbol](style)` |
| `disabled` | `boolean` | `false` | Disables the character module |

---

## Example

```toml
[character]
format = "$symbol "
success_symbol = "[❯](bold #50fa7b)"
error_symbol = "[❯](bold #ff5555)"
disabled = false
```
