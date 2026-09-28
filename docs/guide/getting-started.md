# Getting Started

## Prerequisites

A **[Nerd Font](https://www.nerdfonts.com/)** installed and enabled in your terminal (for example, [JetBrains Mono Nerd Font](https://www.nerdfonts.com/font-downloads) or [FiraCode Nerd Font](https://www.nerdfonts.com/font-downloads)).

---

## Step 1. Install zap

Choose your operating system or package manager below:

::: code-group

```bash [Linux (x86_64)]
# Download and extract the latest static binary
curl -sSL https://github.com/luth9r/zap/releases/latest/download/zap-v1.0.0-x86_64-linux.tar.gz | tar -xz
# Move binary to your PATH
mkdir -p ~/.local/bin && mv zap ~/.local/bin/
```

```powershell [Windows (x86_64)]
# Download the latest release zip from GitHub Releases
Invoke-WebRequest -Uri "https://github.com/luth9r/zap/releases/latest/download/zap-v1.0.0-x86_64-windows.zip" -OutFile "$env:TEMP\zap.zip"
Expand-Archive -Path "$env:TEMP\zap.zip" -DestinationPath "$env:USERPROFILE\bin" -Force
```

```nix [Nix (Home Manager Module)]
# 1. In flake.nix:
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    zap.url = "github:luth9r/zap";
  };

  outputs = { nixpkgs, home-manager, zap, ... }: {
    homeConfigurations."username" = home-manager.lib.homeManagerConfiguration {
      modules = [
        zap.homeManagerModules.default
        ./home.nix
      ];
    };
  };
}

# 2. In home.nix, enable and configure declaratively:
{
  programs.zap = {
    enable = true;
    
    # Automatically generates ~/.config/zap/config.toml from Nix!
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

```bash [Build from Source]
# Requires Zig 0.16
git clone https://github.com/luth9r/zap.git
cd zap
zig build -Doptimize=ReleaseFast

# Binary is placed at zig-out/bin/zap
cp zig-out/bin/zap ~/.local/bin/
```

:::

---

## Step 2. Set up your shell to use zap

> *(Note: If you are using the Home Manager module above, shell integration for Bash, Zsh, and Fish is enabled automatically!)*

Configure your shell to initialize zap on startup. Choose your shell from the list below:

::: code-group

```fish [Fish]
# Add to ~/.config/fish/config.fish:
zap init fish | source
```

```zsh [Zsh]
# Add to ~/.zshrc:
eval "$(zap init zsh)"
```

```bash [Bash]
# Add to ~/.bashrc:
eval "$(zap init bash)"
```

```powershell [PowerShell]
# Add to your $PROFILE:
(&zap init powershell | Out-String) | Invoke-Expression
```

:::

---

## Step 3. Configure zap

Start a new shell session, and you should see your new minimalist prompt.

If you are looking to further customize zap:
- **[Configuration](/guide/configuration)** — Learn how to set up your `config.toml`, customize formatting, and enable schema auto-completion.
- **[Styling & Colors](/guide/styling)** — Explore 24-bit TrueColor, ANSI 256 colors, text modifiers, and background/foreground styling.
- **[Modules](/config/directory)** — Detailed option reference for each prompt module (`$directory`, `$git_branch`, `$git_status`, etc.).

---

## Testing `zap init`

You can test zap immediately without restarting your terminal or modifying your config files:

### 1. Instant Test in Current Shell Session

Simply paste the init one-liner into your current active terminal:

::: code-group

```fish [Fish]
zap init fish | source
```

```zsh [Zsh]
eval "$(zap init zsh)"
```

```bash [Bash]
eval "$(zap init bash)"
```

```powershell [PowerShell]
(&zap init powershell | Out-String) | Invoke-Expression
```

:::

### 2. Inspecting the Generated Integration Script

To see the exact code injected into your shell, run:

```bash
zap init zsh
# or
zap init bash
# or
zap init fish
# or
zap init powershell
```

### 3. Testing in Isolated Shells with Nix

If you have Nix installed, zap provides isolated sandbox testing environments for all supported shells:

```bash
# Enter an isolated interactive Bash with Zap loaded:
nix run github:luth9r/zap#bash

# Enter an isolated interactive Zsh with Zap loaded:
nix run github:luth9r/zap#zsh

# Enter an isolated interactive Fish with Zap loaded:
nix run github:luth9r/zap#fish

# Enter an isolated interactive PowerShell with Zap loaded:
nix run github:luth9r/zap#pwsh
```

---

## How `zap init` Works Under the Hood

Running `zap init <shell>` outputs a shell-native integration script that hooks into your shell's event lifecycle:

1. **Duration Tracking**:
   - Before executing a command (`preexec` hook in Zsh/Fish or `DEBUG` trap in Bash), it records the starting timestamp in nanoseconds/milliseconds.
   - When the command finishes, it calculates the elapsed time.

2. **Exit Code Capture**:
   - Captures the previous command's exit code (`$?` / `$status`).

3. **Zero-Width Escape Sequence Delimiters**:
   - Terminal color escape codes take up zero visual width on the screen. If the shell is unaware of this, it miscalculates line lengths and breaks multiline wrapping.
   - `zap init` tells the prompt renderer which shell is active so it wraps all ANSI escape sequences in the appropriate shell-specific non-printing markers:
     - **Bash**: `\001...\002` (`\[...\]`)
     - **Zsh**: `%{...%}`
     - **Fish / PowerShell**: Native format handling

4. **Prompt Update**:
   - Sets `PS1`, `PROMPT`, or `fish_prompt` to call `zap prompt --status "$exit_code" --duration "$duration" --shell <shell>`.

---

## 󱐋 Inspired By

Please check out these previous works that helped inspire the creation of zap:

- **[Starship](https://starship.rs/)** — The minimal, blazing-fast, and infinitely customizable prompt for any shell.
- **[denysdovhan/spaceship-prompt](https://github.com/denysdovhan/spaceship-prompt)** — A ZSH prompt for astronauts.
- **[denysdovhan/robbyrussell-node](https://github.com/denysdovhan/robbyrussell-node)** — Cross-shell robbyrussell theme written in JavaScript.
- **[reujab/silver](https://github.com/reujab/silver)** — A cross-shell customizable powerline-like prompt with icons.
