# Git Commit (`$git_commit`)

The `git_commit` module displays the short commit hash and git tag, primarily when working on detached `HEAD`.

## Format Variables

| Variable | Description |
|---|---|
| `$hash` | Git commit SHA hash (truncated to `commit_hash_length`) |
| `$tag` | Active Git tag name (if present) |
| `$style` | Style string defined in `style` |

---

## Configuration Options

| Option | Type | Default | Description |
|---|---|---|---|
| `format` | `string` | `"[\\($hash$tag\\)]($style) "` | Format template for the commit info |
| `style` | `style` | `"bold green"` | Style for the commit hash and tag |
| `commit_hash_length` | `integer` | `7` | Number of SHA characters to show (`0` for full SHA) |
| `only_detached` | `boolean` | `true` | Only render when HEAD is detached |
| `tag_symbol` | `string` | `"  "` | Symbol prepended to tag name |
| `tag_disabled` | `boolean` | `true` | Suppress tag display |
| `disabled` | `boolean` | `false` | Disables the git_commit module |

---

## Example

```toml
[git_commit]
commit_hash_length = 8
only_detached = false
tag_disabled = false
tag_symbol = "  "
style = "bold green"
disabled = false
```
