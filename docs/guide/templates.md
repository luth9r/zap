# Template Engine

Zap includes a zero-heap-allocation template engine for both root prompt formatting and individual module configurations.

## Variables

Variables are prefixed with `$` and expanded dynamically during rendering.

### Root Modules

| Variable | Description |
|---|---|
| `$os` | Operating system / distribution logo module |
| `$directory` | Current working directory module |
| `$git_branch` | Active Git branch module |
| `$git_commit` | Git commit hash and tag module |
| `$git_state` | In-progress Git operation module (rebase/merge/etc.) |
| `$git_status` | Working tree status module |
| `$cmd_duration` | Previous command duration module |
| `$character` | Shell prompt indicator module |

---

## Styled Blocks `[content](style)`

Wrap any string or variable in brackets `[...]` followed by style definitions in parentheses `(...)`:

```toml
format = "[❯](bold green) [$path](bold cyan) "
```

You can nest variables inside styled blocks:
```toml
format = "[$symbol$branch]($style) "
```

---

## Conditional Groups `(...)`

Enclosing content in parentheses creates a conditional group. The inner text is rendered **only if all variables inside the group are non-empty**:

```toml
# Only renders ( REBASING 2/5 ) if $state has a value:
format = "\\([$state( $progress_current/$progress_total)]($style)\\) "

# Hides brackets completely when the git repository is clean:
format = "([\\[$all_status$ahead_behind\\]]($style) )"
```

---

## Escape Sequences

Use a backslash `\` to prevent template interpretation and output literal characters:

| Syntax | Output | Purpose |
|---|---|---|
| `\$` | `$` | Literal dollar sign (does not trigger variable expansion) |
| `\[` | `[` | Literal open bracket (prevents styled block) |
| `\]` | `]` | Literal close bracket |
| `\(` | `(` | Literal open parenthesis (prevents conditional group) |
| `\)` | `)` | Literal close parenthesis |
| `\\` | `\` | Literal backslash |
| `\n` | *(newline)* | Explicit line break |
| `\t` | *(tab)* | Tabulation character |

::: tip TOML Escaping Rule
In standard double-quoted TOML strings (`"..."`) or triple-quoted strings (`"""..."""`), backslashes must be doubled: `"\\$"`.
In single-quoted literal TOML strings (`'...'`), you can write `'\\$'` or `'\$'`.
:::
