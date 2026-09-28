# Git State (`$git_state`)

The `git_state` module displays in-progress Git operations (rebase, merge, cherry-pick, revert, bisect, etc.) along with step progress counters.

## Format Variables

| Variable | Description |
|---|---|
| `$state` | Operation name label (e.g. `REBASING`, `MERGING`) |
| `$progress_current` | Current step index |
| `$progress_total` | Total steps in the operation |
| `$style` | Style string defined in `style` |

---

## Configuration Options

| Option | Type | Default | Description |
|---|---|---|---|
| `format` | `string` | `"\\([$state( $progress_current/$progress_total)]($style)\\) "` | Format template |
| `style` | `style` | `"bold yellow"` | Style for the state message |
| `rebase` | `string` | `"REBASING"` | Label for interactive or standard rebase |
| `merge` | `string` | `"MERGING"` | Label during merge resolution |
| `revert` | `string` | `"REVERTING"` | Label during revert operation |
| `cherry_pick` | `string` | `"CHERRY-PICKING"` | Label during cherry-pick |
| `bisect` | `string` | `"BISECTING"` | Label during git bisect |
| `am` | `string` | `"AM"` | Label when applying mailbox patches |
| `am_or_rebase` | `string` | `"AM/REBASE"` | Label when state is ambiguous between AM and rebase |
| `disabled` | `boolean` | `false` | Disables the git_state module |

---

## Example

```toml
[git_state]
rebase = "REBASE"
merge = "MERGE"
revert = "REVERT"
cherry_pick = "CHERRY-PICK"
style = "bold #ffb86c"
disabled = false
```
