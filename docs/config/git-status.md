# Git Status (`$git_status`)

The `git_status` module displays working tree modifications, untracked files, staged changes, stashes, and remote divergence indicators.

## Format Variables

| Variable | Description |
|---|---|
| `$all_status` | Combined string of active status symbols (`$staged`, `$modified`, etc.) |
| `$ahead_behind` | Combined divergence flags (`$ahead`, `$behind`, `$diverged`) |
| `$staged`, `$modified`, `$untracked`, `$renamed`, `$deleted`, `$stashed`, `$conflicted` | Individual status flags |
| `$style` | Style string defined in `style` |

---

## Configuration Options

| Option | Type | Default | Description |
|---|---|---|---|
| `format` | `string` | `"([\\[$all_status$ahead_behind\\]]($style) )"` | Format template (hidden when repository is clean) |
| `style` | `style` | `"bold red"` | Style for all status indicators |
| `staged` | `string` | `"+"` | Symbol displayed for staged changes |
| `modified` | `string` | `"!"` | Symbol displayed for unstaged modifications |
| `untracked` | `string` | `"?"` | Symbol displayed when untracked files exist |
| `renamed` | `string` | `"»"` | Symbol displayed for renamed files |
| `deleted` | `string` | `"✘"` | Symbol displayed for deleted files |
| `stashed` | `string` | `"$"` | Symbol displayed when stashes exist |
| `ahead` | `string` | `"⇡"` | Symbol displayed when ahead of upstream |
| `behind` | `string` | `"⇣"` | Symbol displayed when behind upstream |
| `diverged` | `string` | `"⇕"` | Symbol displayed when diverged from upstream |
| `conflicted` | `string` | `"="` | Symbol displayed on merge conflicts |
| `up_to_date` | `string` | `""` | Symbol displayed when clean and synced |
| `disabled` | `boolean` | `false` | Disables the git_status module |

---

## Example

```toml
[git_status]
staged = "●"
modified = "▲"
untracked = "…"
deleted = "✖"
stashed = "$"
ahead = "⇡"
behind = "⇣"
diverged = "⇕"
conflicted = "="
style = "bold #ff5555"
disabled = false
```
