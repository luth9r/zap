# Git Branch (`$git_branch`)

The `git_branch` module displays the active Git branch name.

## Format Variables

| Variable | Description |
|---|---|
| `$symbol` | Symbol defined in `symbol` |
| `$branch` | Name of the active branch |
| `$remote_branch` | Name of the upstream tracking branch |
| `$style` | Style string defined in `style` |

---

## Configuration Options

| Option | Type | Default | Description |
|---|---|---|---|
| `format` | `string` | `"on [$symbol$branch]($style) "` | Format template for the branch |
| `symbol` | `string` | `" "` | Symbol prepended to the branch name |
| `style` | `style` | `"bold purple"` | Style for the branch string |
| `truncation_length` | `integer` | `0` | Max character length for branch name before truncation (`0` disables) |
| `truncation_symbol` | `string` | `"…"` | Symbol appended when branch name is truncated |
| `disabled` | `boolean` | `false` | Disables the git_branch module |

---

## Example

```toml
[git_branch]
format = "on [$symbol$branch]($style) "
symbol = " "
style = "bold #bd93f9"
truncation_length = 24
truncation_symbol = "…"
disabled = false
```
