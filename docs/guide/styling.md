# Styling & Colors

Zap supports a rich styling engine across all modules and inline prompt blocks.

## Syntax

Styles can be specified in module `style` keys or within inline styled blocks `[text](style)`:

```toml
style = "bold cyan"
format = "[$path](bold italic fg:#50fa7b bg:#282a36) "
```

---

## Modifiers

Modifiers change font style and display behavior:

| Modifier | Aliases | Description |
|---|---|---|
| `bold` | — | Bold weight |
| `dimmed` | `dim` | Faint / lower brightness |
| `italic` | — | Italic text |
| `underline` | `underlined` | Single underline |
| `blink` | — | Slow blinking |
| `inverted` | `invert` | Invert foreground and background |
| `hidden` | — | Concealed / invisible |
| `strikethrough` | — | Crossed-out text |
| `reset` | — | Reset all attributes |
| `none` | — | No styling applied |

---

## Color Formats

### 1. Standard Named Colors (8-color)
`black`, `red`, `green`, `yellow`, `blue`, `magenta`, `purple`, `cyan`, `white`

### 2. Bright Named Colors (16-color)
`bright-black` (`gray`, `grey`), `bright-red`, `bright-green`, `bright-yellow`, `bright-blue`, `bright-magenta`, `bright-purple`, `bright-cyan`, `bright-white`

### 3. 24-bit TrueColor Hex
Hexadecimal RGB formats:
- Short syntax: `#RGB` (e.g. `#fff`, `#f00`)
- Full syntax: `#RRGGBB` (e.g. `#50fa7b`, `#282a36`, `#bd93f9`)

### 4. ANSI 256 Colors
Direct integer index from `0` to `255`:
- `240` (gray)
- `27` (blue)
- `200` (magenta)

### 5. Foreground and Background Prefixes
- `fg:<color>` (e.g. `fg:cyan`, `fg:#bd93f9`, `fg:27`)
- `bg:<color>` (e.g. `bg:black`, `bg:#282a36`, `bg:235`)

---

## Examples

```toml
# Bold cyan foreground
style = "bold cyan"

# TrueColor background and foreground with italic and bold
style = "bold italic fg:#50fa7b bg:#282a36"

# White text on rust/orange background with underline
style = "underline bg:#bf5700 fg:white"

# Dimmed ANSI-256 gray
style = "dimmed 240"
```

---

## Nerd Font Icons

Zap pairs exceptionally well with **JetBrains Mono Nerd Font** (and other Nerd Font-patched fonts). Recommended glyphs:

| Category | Glyph | Description |
|---|---|---|
| Read-only | `󰌾` | Lock icon (`\u{f031e}`) |
| Git Branch | `` | Git branch symbol (`\u{f418}`) |
| Git Commit | `󰊢` | Git commit node (`\u{f02a2}`) |
| Git Tag | `` | Tag symbol (`\u{f412}`) |
| Clock / Time | `󰅐` | Clock icon (`\u{f0150}`) |
| Lightning / Zap | `󱐋` | Bolt / lightning icon (`\u{f140b}`) |
| Directory / Home | `󰋽` | Folder / Home icon (`\u{f02fd}`) |
| Prompt Pointer | `❯` | Chevron pointer |
