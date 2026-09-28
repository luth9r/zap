# Configuration

Zap is configured via a single TOML file.

## Configuration Search Order

When starting up, zap searches for a configuration file in the following order:

1. `$ZAP_CONFIG` (custom file path)
2. `$XDG_CONFIG_HOME/zap/config.toml`
3. `~/.config/zap/config.toml` (or `%APPDATA%\zap\config.toml` on Windows)

If no configuration file is found, zap runs with sensible default settings.

---

## Editor Autocompletion ($schema)

Zap provides an official JSON Schema. Adding the `$schema` key to the top of your `config.toml` gives you instant type validation, field documentation, and auto-completion in VS Code, Neovim, Helix, and any LSP-enabled editor:

```toml
"$schema" = "https://raw.githubusercontent.com/luth9r/zap/main/zap.schema.json"
```

---

## Root Options

| Option | Type | Default | Description |
|---|---|---|---|
| `format` | `string` | `"$directory$character"` | Root prompt format string. Determines module ordering, custom text, and layout. |
| `add_newline` | `boolean` | `true` | Inserts an empty line before rendering the prompt. |

---

## Minimal Configuration

```toml
"$schema" = "https://raw.githubusercontent.com/luth9r/zap/main/zap.schema.json"

add_newline = true
format = "$directory$git_branch$git_status$character"
```

---

## Two-Line Prompt Example

```toml
"$schema" = "https://raw.githubusercontent.com/luth9r/zap/main/zap.schema.json"

add_newline = true

format = """
[┌─](bold purple)[ 󰌾 ](bold purple)$directory$git_branch$git_commit$git_state$git_status$cmd_duration
[└─](bold purple)[ 󱐋 ](bold yellow)$character"""

[directory]
style = "bold cyan"
home_symbol = "~"
truncation_length = 3
truncation_symbol = "…/"
truncate_to_repo = true

[git_branch]
symbol = " "
style = "bold purple"

[git_status]
style = "bold red"
staged = "+"
modified = "!"
untracked = "?"

[cmd_duration]
min_time = 2000
style = "bold yellow"

[character]
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"
```
