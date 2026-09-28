# Directory (`$directory`)

The `directory` module renders the current working directory path with intelligent parent-path truncation, repository-root anchoring, and read-only detection.

## Format Variables

| Variable | Description |
|---|---|
| `$path` | Resolved directory path (with home symbol and truncation applied) |
| `$read_only` | Read-only indicator symbol (rendered only when directory is not writable) |
| `$style` | Style string defined in `style` |
| `$read_only_style` | Style string defined in `read_only_style` |

---

## Configuration Options

| Option | Type | Default | Description |
|---|---|---|---|
| `format` | `string` | `"[$path]($style)[$read_only]($read_only_style) "` | Format template for the module |
| `style` | `style` | `"bold cyan"` | Style applied to the path |
| `home_symbol` | `string` | `"~"` | String replacing the user's home directory path |
| `read_only` | `string` | `" 󰌾"` | Symbol displayed when the directory is read-only |
| `read_only_style` | `style` | `"bold red"` | Style for the read-only symbol |
| `truncation_length` | `integer` | `3` | Number of directory segments to keep (`0` disables truncation) |
| `truncation_symbol` | `string` | `"…/"` | Prefix replacing truncated parent directory segments |
| `truncate_to_repo` | `boolean` | `true` | When inside a Git repo, truncate relative to the repo root |
| `disabled` | `boolean` | `false` | Disables the directory module |

---

## Example

```toml
[directory]
style = "bold #8be9fd"
home_symbol = "~"
read_only = " 󰌾"
read_only_style = "bold red"
truncation_length = 3
truncation_symbol = "…/"
truncate_to_repo = true
disabled = false
```
