<div align="center">

# zap 󱐋

<p align="center">
  <a href="https://github.com/luth9r/zap/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-yellow.svg?style=flat-square" alt="License: MIT"></a>
  <a href="https://ziglang.org/"><img src="https://img.shields.io/badge/zig-0.16-orange.svg?style=flat-square&logo=zig" alt="Zig 0.16"></a>
  <a href="#"><img src="https://img.shields.io/badge/memory-~1.2MB-brightgreen.svg?style=flat-square" alt="Memory Usage"></a>
  <a href="#"><img src="https://img.shields.io/badge/latency-%3C1ms-blue.svg?style=flat-square" alt="Latency"></a>
</p>

**A minimalist shell prompt written in Zig**

~1.2 MB RSS · zero heap allocations on render · sub-millisecond latency

[Documentation](https://luth9r.github.io/zap/) • [Installation](#installation) • [Shell Setup](#shell-setup) • [Configuration](#configuration) • [Modules](#modules) • [Styling](#styling) • [Format & Templating](#format--templating) • [Inspired By](#-inspired-by) • [License](#license)

</div>

---

## Features

- **Sub-Millisecond Latency**: Optimized prompt rendering pipeline in < 1ms to keep the terminal responsive.
- **Zero Heap Allocations**: Zero heap allocations on the hot render path, using ~1.2 MB Max RSS memory.
- **Deep Git Integration**: Real-time tracking of branch, status, detached commits, stash, ahead/behind, rebase/merge states.
- **Full Styling Engine**: Modifiers, 16 named/bright colors, 256 ANSI color codes, 24-bit TrueColor Hex (`#RGB` / `#RRGGBB`), background/foreground prefixes.
- **Dynamic Template Engine**: Conditional groups `(...)`, styled blocks `[text](style)`, escaping, and custom formatting per module.
- **Cross-Shell**: Support for Fish, Zsh, Bash, and PowerShell with proper non-printing escape delimiter wrapping.

---

## Prerequisites

A **[Nerd Font](https://www.nerdfonts.com/)** installed and enabled in your terminal (for example, [JetBrains Mono Nerd Font](https://www.nerdfonts.com/font-downloads) or [FiraCode Nerd Font](https://www.nerdfonts.com/font-downloads)).

---

## Installation

### Step 1. Install zap

#### Pre-built Binaries

Download from [GitHub Releases](https://github.com/luth9r/zap/releases):

| Platform | Archive |
|---|---|
| Linux (x86_64) | `zap-v0.1.0-x86_64-linux.tar.gz` |
| Windows (x86_64) | `zap-v0.1.0-x86_64-windows.zip` |

```bash
# Linux
curl -sSL https://github.com/luth9r/zap/releases/latest/download/zap-v0.1.0-x86_64-linux.tar.gz | tar -xz
mkdir -p ~/.local/bin && mv zap ~/.local/bin/
```

#### Nix (Home Manager Module)

In your `flake.nix`:

```nix
inputs.zap.url = "github:luth9r/zap";
```

In your `home.nix`:

```nix
{
  programs.zap = {
    enable = true;
    
    # Automatically writes ~/.config/zap/config.toml from Nix attributes:
    settings = {
      add_newline = true;
      format = "$directory$git_branch$git_status$character";

      directory = {
        style = "bold cyan";
        truncation_length = 3;
      };

      character = {
        success_symbol = "[❯](bold green)";
        error_symbol = "[❯](bold red)";
      };
    };
  };
}
```

#### Build from Source

Requires **Zig 0.16**.

```bash
git clone https://github.com/luth9r/zap.git
cd zap
zig build -Doptimize=ReleaseFast
```

The compiled binary will be placed at `zig-out/bin/zap`.

Run test suite:

```bash
zig build test
```

---

### Step 2. Set up your shell to use zap

#### Fish

Add to `~/.config/fish/config.fish`:

```fish
zap init fish | source
```

#### Zsh

Add to `~/.zshrc`:

```zsh
eval "$(zap init zsh)"
```

#### Bash

Add to `~/.bashrc`:

```bash
eval "$(zap init bash)"
```

#### PowerShell

Add to your `$PROFILE`:

```powershell
(&zap init powershell | Out-String) | Invoke-Expression
```

---

### Step 3. Configure zap

Start a new shell session, and your prompt is ready! To customize colors, symbols, and formatting, see the [Configuration Guide](#configuration).

---

## Testing `zap init`

You can test zap immediately in your active session without changing your shell config:

- **Fish**: `zap init fish | source`
- **Zsh**: `eval "$(zap init zsh)"`
- **Bash**: `eval "$(zap init bash)"`
- **PowerShell**: `(&zap init powershell | Out-String) | Invoke-Expression`

To inspect the generated shell hook code:

```bash
zap init zsh
zap init bash
zap init fish
zap init powershell
```

---

## Configuration

zap searches for its configuration file in the following order:

1. `$ZAP_CONFIG` (custom file path)
2. `$XDG_CONFIG_HOME/zap/config.toml`
3. `~/.config/zap/config.toml` (or `%APPDATA%\zap\config.toml` on Windows)

### Root Options

| Option | Type | Default | Description |
|---|---|---|---|
| `format` | `string` | `"$directory$character"` | Root prompt format string. Determines module ordering and layout. |
| `add_newline` | `boolean` | `true` | Inserts a blank line before rendering the prompt. |
| `"$schema"` | `string` | — | Path/URL to JSON Schema for editor validation & autocompletion. |

> **Tip:** Add `"$schema" = "https://raw.githubusercontent.com/luth9r/zap/main/zap.schema.json"` at the top of your config to get instant IntelliSense / autocompletion in VS Code and other editors.

### Minimal Example

```toml
"$schema" = "https://raw.githubusercontent.com/luth9r/zap/main/zap.schema.json"

add_newline = true
format = "$directory$git_branch$git_status$character"
```

### Full Example

```toml
"$schema" = "https://raw.githubusercontent.com/luth9r/zap/main/zap.schema.json"

add_newline = true

format = """
[┌─](bold purple)[ 󰌾 ](bold purple)$directory$git_branch$git_commit$git_state$git_status$cmd_duration
[└─](bold purple)[ 󱐋 ](bold yellow)$character"""

[directory]
format = "[$path]($style)[$read_only]($read_only_style) "
style = "bold cyan"
home_symbol = "~"
read_only = " 󰌾"
read_only_style = "bold red"
truncation_length = 3
truncation_symbol = "…/"
truncate_to_repo = true
disabled = false

[git_branch]
format = "on [$symbol$branch]($style) "
symbol = " "
style = "bold purple"
truncation_length = 0
truncation_symbol = "…"
disabled = false

[git_commit]
format = "[\\($hash$tag\\)]($style) "
style = "bold green"
commit_hash_length = 7
only_detached = true
tag_symbol = "  "
tag_disabled = true
disabled = false

[git_state]
format = "\\([$state( $progress_current/$progress_total)]($style)\\) "
style = "bold yellow"
rebase = "REBASING"
merge = "MERGING"
revert = "REVERTING"
cherry_pick = "CHERRY-PICKING"
bisect = "BISECTING"
am = "AM"
am_or_rebase = "AM/REBASE"
disabled = false

[git_status]
format = "([\\[$all_status$ahead_behind\\]]($style) )"
style = "bold red"
staged = "+"
modified = "!"
untracked = "?"
renamed = "»"
deleted = "✘"
stashed = "$"
ahead = "⇡"
behind = "⇣"
diverged = "⇕"
conflicted = "="
up_to_date = ""
disabled = false

[cmd_duration]
min_time = 2000
format = "took [$duration]($style) "
style = "bold yellow"
show_milliseconds = false
disabled = false

[character]
format = "$symbol "
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"
disabled = false
```

---

## Modules

- [`$directory`](#directory) — Working directory path and read-only status
- [`$git_branch`](#git_branch) — Active Git branch
- [`$git_commit`](#git_commit) — Commit hash and tag on detached HEAD
- [`$git_state`](#git_state) — In-progress Git operations (rebase, merge, bisect, etc.)
- [`$git_status`](#git_status) — Staged, modified, untracked files and remote sync status
- [`$cmd_duration`](#cmd_duration) — Execution duration of the previous command
- [`$character`](#character) — Exit status indicator

---

### `directory`

Renders the current working directory path with intelligent truncation and home directory replacement.

**Format Variables:**
- `$path`: The resolved directory path.
- `$read_only`: The read-only symbol (if the current directory is write-protected).
- `$style`: The style defined in `style`.
- `$read_only_style`: The style defined in `read_only_style`.

**Options:**

| Option | Type | Default | Description |
|---|---|---|---|
| `format` | `string` | `"[$path]($style)[$read_only]($read_only_style) "` | Format template for rendering the directory. |
| `style` | `style` | `"bold cyan"` | Style applied to the path. |
| `home_symbol` | `string` | `"~"` | String replacing the user's home directory path. |
| `read_only` | `string` | `" 󰌾"` | Symbol displayed when the directory is read-only. |
| `read_only_style` | `style` | `"bold red"` | Style for the read-only symbol. |
| `truncation_length` | `integer` | `3` | Number of directory segments to retain before truncating (`0` disables truncation). |
| `truncation_symbol` | `string` | `"…/"` | Symbol prefix replacing truncated parent segments. |
| `truncate_to_repo` | `boolean` | `true` | Truncate path relative to the root of the current Git repository. |
| `disabled` | `boolean` | `false` | Disables the directory module. |

```toml
[directory]
style = "bold #8be9fd"
home_symbol = "~"
truncation_length = 4
truncation_symbol = "…/"
truncate_to_repo = true
```

---

### `git_branch`

Displays the active Git branch name.

**Format Variables:**
- `$symbol`: The symbol defined in `symbol`.
- `$branch`: The name of the current branch.
- `$remote_branch`: The upstream tracking branch name.
- `$style`: The style defined in `style`.

**Options:**

| Option | Type | Default | Description |
|---|---|---|---|
| `format` | `string` | `"on [$symbol$branch]($style) "` | Format template for the branch. |
| `symbol` | `string` | `" "` | Symbol prepended to the branch name. |
| `style` | `style` | `"bold purple"` | Style for the branch string. |
| `truncation_length` | `integer` | `0` | Maximum character length for branch name before truncation (`0` disables). |
| `truncation_symbol` | `string` | `"…"` | Symbol appended when branch name is truncated. |
| `disabled` | `boolean` | `false` | Disables the git_branch module. |

```toml
[git_branch]
symbol = " "
style = "bold #bd93f9"
truncation_length = 20
truncation_symbol = "…"
```

---

### `git_commit`

Displays the short commit hash and active tag, primarily when in detached `HEAD` state.

**Format Variables:**
- `$hash`: The Git commit SHA hash (truncated to `commit_hash_length`).
- `$tag`: The active Git tag (if enabled and present).
- `$style`: The style defined in `style`.

**Options:**

| Option | Type | Default | Description |
|---|---|---|---|
| `format` | `string` | `"[\\($hash$tag\\)]($style) "` | Format template for commit info. |
| `style` | `style` | `"bold green"` | Style for the commit hash and tag. |
| `commit_hash_length` | `integer` | `7` | Number of characters of the commit hash to show (`0` for full SHA). |
| `only_detached` | `boolean` | `true` | Only render when `HEAD` is detached. |
| `tag_symbol` | `string` | `"  "` | Symbol prepended to the tag name. |
| `tag_disabled` | `boolean` | `true` | Whether to suppress displaying git tags. |
| `disabled` | `boolean` | `false` | Disables the git_commit module. |

```toml
[git_commit]
commit_hash_length = 8
only_detached = false
tag_disabled = false
tag_symbol = "  "
```

---

### `git_state`

Displays active operations such as rebase, merge, cherry-pick, revert, or bisect with step progress counters.

**Format Variables:**
- `$state`: Operation name label (e.g. `REBASING`, `MERGING`).
- `$progress_current`: Current step number.
- `$progress_total`: Total number of steps.
- `$style`: The style defined in `style`.

**Options:**

| Option | Type | Default | Description |
|---|---|---|---|
| `format` | `string` | `"\\([$state( $progress_current/$progress_total)]($style)\\) "` | Format template. |
| `style` | `style` | `"bold yellow"` | Style for the state message. |
| `rebase` | `string` | `"REBASING"` | Label for interactive / standard rebase. |
| `merge` | `string` | `"MERGING"` | Label during merge resolution. |
| `revert` | `string` | `"REVERTING"` | Label during revert operation. |
| `cherry_pick` | `string` | `"CHERRY-PICKING"` | Label during cherry-pick. |
| `bisect` | `string` | `"BISECTING"` | Label during git bisect. |
| `am` | `string` | `"AM"` | Label when applying mailbox patches. |
| `am_or_rebase` | `string` | `"AM/REBASE"` | Label when state is ambiguous between AM and rebase. |
| `disabled` | `boolean` | `false` | Disables the git_state module. |

```toml
[git_state]
rebase = "REBASE"
merge = "MERGE"
style = "bold #ffb86c"
```

---

### `git_status`

Displays working tree modifications, untracked files, staged changes, stashes, and remote divergence indicators.

**Format Variables:**
- `$all_status`: Combined string of active file status flags (`$staged`, `$modified`, etc.).
- `$ahead_behind`: Combined remote divergence flags (`$ahead`, `$behind`, `$diverged`).
- `$staged`, `$modified`, `$untracked`, `$renamed`, `$deleted`, `$stashed`, `$conflicted`: Individual status flags.
- `$style`: The style defined in `style`.

**Options:**

| Option | Type | Default | Description |
|---|---|---|---|
| `format` | `string` | `"([\\[$all_status$ahead_behind\\]]($style) )"` | Format template (wrapped in `(...)` conditional to hide when clean). |
| `style` | `style` | `"bold red"` | Style for status indicators. |
| `staged` | `string` | `"+"` | Symbol displayed for staged changes. |
| `modified` | `string` | `"!"` | Symbol displayed for unstaged modifications. |
| `untracked` | `string` | `"?"` | Symbol displayed when untracked files exist. |
| `renamed` | `string` | `"»"` | Symbol displayed for renamed files. |
| `deleted` | `string` | `"✘"` | Symbol displayed for deleted files. |
| `stashed` | `string` | `"$"` | Symbol displayed when stashes exist. |
| `ahead` | `string` | `"⇡"` | Symbol displayed when ahead of upstream. |
| `behind` | `string` | `"⇣"` | Symbol displayed when behind upstream. |
| `diverged` | `string` | `"⇕"` | Symbol displayed when diverged from upstream. |
| `conflicted` | `string` | `"="` | Symbol displayed on merge conflicts. |
| `up_to_date` | `string` | `""` | Symbol displayed when repository is clean and synced. |
| `disabled` | `boolean` | `false` | Disables the git_status module. |

```toml
[git_status]
staged = "+"
modified = "!"
untracked = "?"
deleted = "✘"
ahead = "⇡"
behind = "⇣"
diverged = "⇕"
style = "bold #ff5555"
```

---

### `cmd_duration`

Displays how long the previous command took to execute.

**Format Variables:**
- `$duration`: Formatted duration string (e.g. `2s`, `1m 32s`).
- `$style`: The style defined in `style`.

**Options:**

| Option | Type | Default | Description |
|---|---|---|---|
| `min_time` | `integer` | `2000` | Minimum execution time in **milliseconds** before showing duration. |
| `format` | `string` | `"took [$duration]($style) "` | Format template. |
| `style` | `style` | `"bold yellow"` | Style for the duration string. |
| `show_milliseconds` | `boolean` | `false` | Render milliseconds when execution is under 1 minute. |
| `disabled` | `boolean` | `false` | Disables the cmd_duration module. |

```toml
[cmd_duration]
min_time = 1000
show_milliseconds = true
format = "took [󰅐 $duration]($style) "
style = "bold #f1fa8c"
```

---

### `character`

The interactive prompt indicator. Changes symbol and style based on command exit code (success `0` vs error non-zero).

**Format Variables:**
- `$symbol`: The resolved `success_symbol` or `error_symbol`.
- `$style`: The style defined in `style`.

**Options:**

| Option | Type | Default | Description |
|---|---|---|---|
| `format` | `string` | `"$symbol "` | Format template for the prompt character. |
| `success_symbol` | `string` | `"[❯](bold green)"` | Indicator displayed on exit code 0. Supports `[symbol](style)`. |
| `error_symbol` | `string` | `"[❯](bold red)"` | Indicator displayed on non-zero exit code. Supports `[symbol](style)`. |
| `disabled` | `boolean` | `false` | Disables the character module. |

```toml
[character]
success_symbol = "[❯](bold #50fa7b)"
error_symbol = "[❯](bold #ff5555)"
```

---

## Styling

Styles can be used in any `style` option as well as inline styled blocks `[text](style)`.

### Modifiers

| Modifier | Aliases | Effect |
|---|---|---|
| `bold` | — | Bold text weight |
| `dimmed` | `dim` | Decreased intensity / faint |
| `italic` | — | Italic text |
| `underline` | `underlined` | Single underline |
| `blink` | — | Blinking text |
| `inverted` | `invert` | Swap foreground and background |
| `hidden` | — | Invisible text |
| `strikethrough` | — | Line-through text |
| `reset` | — | Reset text formatting |
| `none` | — | No styling applied |

### Colors

| Color Format | Syntax | Examples |
|---|---|---|
| **Named 8-Color** | `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `purple`, `cyan`, `white` | `cyan`, `bold green` |
| **Bright Colors** | `bright-red`, `bright-green`, `bright-cyan`, `gray`, `grey` | `bright-cyan`, `gray` |
| **24-bit TrueColor Hex** | `#RGB` or `#RRGGBB` | `#fff`, `#bf5700`, `#bd93f9` |
| **ANSI 256 Colors** | Integer index `0` to `255` | `240`, `fg:27`, `bg:200` |
| **Foreground Prefix** | `fg:<color>` | `fg:#50fa7b`, `fg:cyan`, `fg:27` |
| **Background Prefix** | `bg:<color>` | `bg:#282a36`, `bg:blue`, `bg:235` |

### Combining Styles

Multiple tokens can be combined separated by spaces:

```toml
style = "bold cyan"
style = "bold italic fg:#50fa7b bg:#282a36"
style = "underline bg:#bf5700 fg:white"
style = "dimmed 240"
style = "bold fg:27 bg:235"
```

---

## Format & Templating

Zap features an allocation-free template engine for prompt layouts and individual module formats.

### Modules and Variables

| Module | Inner Variables |
|---|---|
| `$directory` | `$path`, `$read_only`, `$style`, `$read_only_style` |
| `$git_branch` | `$symbol`, `$branch`, `$remote_branch`, `$style` |
| `$git_commit` | `$hash`, `$tag`, `$style` |
| `$git_state` | `$state`, `$progress_current`, `$progress_total`, `$style` |
| `$git_status` | `$all_status`, `$ahead_behind`, `$staged`, `$modified`, `$untracked`, `$renamed`, `$deleted`, `$stashed`, `$conflicted`, `$style` |
| `$cmd_duration` | `$duration`, `$style` |
| `$character` | `$symbol`, `$style` |

### Styled Blocks (`[text](style)`)

Wrap any text or variable in brackets followed by style in parentheses to apply ANSI styling:

```toml
format = "[❯](bold green) [$path](bold cyan) "
```

### Conditional Groups (`(...)`)

Content inside parentheses is conditionally rendered **only if the enclosed variables are non-empty**:

```toml
# Only renders ( REBASING 2/5 ) if $state is active:
format = "\\([$state( $progress_current/$progress_total)]($style)\\) "

# Hides brackets completely if git status is clean:
format = "([\\[$all_status$ahead_behind\\]]($style) )"
```

### Escaping Special Characters

Use backslash `\` to escape template syntax and output literal characters:

| Syntax | Rendered Output | Purpose |
|---|---|---|
| `\$` | `$` | Literal dollar sign (prevents variable evaluation) |
| `\[` | `[` | Literal open bracket (prevents styled block) |
| `\]` | `]` | Literal close bracket |
| `\(` | `(` | Literal open parenthesis (prevents conditional group) |
| `\)` | `)` | Literal close parenthesis |
| `\\` | `\` | Literal backslash |
| `\n` | *(newline)* | Line break |
| `\t` | *(tab)* | Tabulation |

> **TOML Note:** In double-quoted TOML strings (`"..."`) or triple-quoted strings (`"""..."""`), escape the backslash: `"\\$"`. In single-quoted literal strings (`'...'`), you can write `'\$'`.

### Multi-Line Prompts

Use TOML multi-line strings (`"""..."""`) for clean multi-line prompt definitions:

```toml
format = """
[┌─](bold purple)[ 󰌾 ](bold purple)$directory$git_branch$git_status$cmd_duration
[└─](bold purple)[ 󱐋 ](bold yellow)$character"""
```

---

## 󱐋 Inspired By

Please check out these previous works that helped inspire the creation of zap:

- **[Starship](https://starship.rs/)** — The minimal, blazing-fast, and infinitely customizable prompt for any shell.
- **[denysdovhan/spaceship-prompt](https://github.com/denysdovhan/spaceship-prompt)** — A ZSH prompt for astronauts.
- **[denysdovhan/robbyrussell-node](https://github.com/denysdovhan/robbyrussell-node)** — Cross-shell robbyrussell theme written in JavaScript.
- **[reujab/silver](https://github.com/reujab/silver)** — A cross-shell customizable powerline-like prompt with icons.

---

## License

[MIT](LICENSE) © 2026 luth9r
