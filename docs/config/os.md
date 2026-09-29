# OS (`$os`)

The `os` module displays an icon representing the current operating system or Linux distribution. It automatically detects the host OS (Linux distributions via `/etc/os-release`, macOS, and Windows) using Nerd Font glyphs, or allows setting a custom symbol override.

## Format Variables

| Variable  | Description                                         |
| --------- | --------------------------------------------------- |
| `$symbol` | The detected operating system icon or custom symbol |
| `$style`  | Style string defined in `style`                     |

---

## Configuration Options

| Option     | Type      | Default                | Description                                                              |
| ---------- | --------- | ---------------------- | ------------------------------------------------------------------------ |
| `format`   | `string`  | `"[$symbol]($style) "` | Format template for the os module                                        |
| `style`    | `style`   | `"bold white"`         | Style applied to the OS symbol                                           |
| `symbol`   | `string`  | `""`                   | Custom symbol override. If empty, automatically detected from the system |
| `disabled` | `boolean` | `true`                 | Disables the os module (`true` by default)                               |

---

## Supported Auto-Detection

Zap includes built-in Nerd Font symbols for:

| Operating System / Distro                         | Default Symbol        |
| ------------------------------------------------- | --------------------- |
| **NixOS**                                         | ``                   |
| **Arch Linux** / **Archcraft** / **Artix**        | `󰣇` / `` / ``       |
| **Ubuntu** / **Debian** / **Mint** / **Pop!\_OS** | `󰕈` / `` / `󰣭` / `` |
| **Fedora** / **CentOS** / **RHEL** / **Rocky**    | `` / `` / `󱄛` / `` |
| **Alpine Linux**                                  | ``                   |
| **Gentoo**                                        | `󰣨`                   |
| **Manjaro**                                       | ``                   |
| **openSUSE**                                      | ``                   |
| **Void Linux**                                    | ``                   |
| **Slackware** / **Raspbian** / **Kali**           | `` / `` / ``       |
| **macOS**                                         | `󰀵`                   |
| **Windows**                                       | ``                   |
| **Generic Linux**                                 | ``                   |

---

## Example

```toml
format = "$os$directory$character"

[os]
disabled = false
style = "bold #8be9fd"
```

### Custom Symbol Override

If you want to use a specific icon or emoji regardless of the host OS:

```toml
[os]
disabled = false
symbol = ""
style = "bold cyan"
```
