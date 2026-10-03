# Debugging & Diagnostics

Zap provides built-in, zero-allocation diagnostic and profiling utilities to inspect your prompt rendering, validate configuration files, verify git repository parsing, diagnose shell hooks, and benchmark prompt rendering speed.

---

## The `zap debug` Command

Run `zap debug` with an optional target and flags:

```bash
zap debug [target] [options]
```

### Available Targets

| Target | Description |
| :--- | :--- |
| *(default / `all`)* | Runs a full diagnostic report (configuration, git repository, prompt output). |
| `config` | Dumps the active configuration, resolved path, format tokens, and custom module fields. |
| `git` | Inspects git branch, commit hash, repository status, ahead/behind counts, and stash count. |
| `env` / `shell` | Diagnoses shell detection, TrueColor support, UTF-8 locale, and shell rc integration hooks. |
| `bench` / `profile` | Runs a 100-iteration benchmark and outputs a microsecond breakdown by phase and module. |
| `<module_name>` | Inspects a specific module (e.g. `zap debug zig_lang`, `zap debug directory`). |

---

## Options & Flags

- `-v`, `--verbose`: Enables detailed inspection mode:
  - **Git**: Lists exact modified, untracked, deleted, and conflicted files.
  - **Languages / Tools**: Shows trigger files, matched extensions, and directory scan depth.
  - **Config**: Dumps detailed struct fields and values.
- `--json`: Outputs diagnostic reports in structured JSON format (ideal for CI and tool integration).
- `-o <file>`, `--output <file>`: Writes the diagnostic output directly to the specified file.

---

## Examples

### 1. Inspecting Git Repository & File Changes

```bash
# General git diagnostics:
zap debug git

# Detailed file breakdown:
zap debug git --verbose
```

Output:
```text
=== Git Diagnostics ===
  Discovered Git Dir:  .git
  Branch:              main
  Head Commit:         a1b2c3d
  State:               clean
  Ahead / Behind:      +1 / -0
  Stash Count:         0
  Dirty Status:
    ● Modified:    2
    … Untracked:   1
    ✖ Deleted:     0
    ⇕ Conflicted:  0

=== Detailed Git Files (Verbose) ===
  Modified:
    - src/main.zig
    - src/cli/args.zig
  Untracked:
    - test_output.txt
```

---

### 2. Prompt Profiling & Micro-benchmarking

Measure render performance down to the microsecond:

```bash
zap debug bench
```

Output:
```text
=== Prompt Rendering Benchmark & Profile ===
  Benchmark (100 iterations):
    Min:   12 µs
    Max:   45 µs
    Mean:  18 µs

  Stage Breakdown:
    findGitDir:        3 µs  (16.7%)
    readConfig:        1 µs  ( 5.5%)
    renderModules:    14 µs  (77.8%)

  Per-Module Execution Breakdown (Single Pass):
    ✔ directory          6 µs  [ 42%]  (12 bytes)
    ✔ git_branch         3 µs  [ 21%]  ( 8 bytes)
    ✔ git_status         2 µs  [ 14%]  ( 4 bytes)
    ✔ cmd_duration       1 µs  [  7%]  ( 0 bytes)
    ✔ character          2 µs  [ 14%]  (19 bytes)
    · os                 0 µs  (inactive)
    · zig_lang           0 µs  (inactive)
```

---

### 3. Environment & Shell Hook Diagnostics

Check if your shell and terminal environment are configured properly:

```bash
zap debug env
```

Output:
```text
=== Shell & Environment Diagnostics ===
  Detected Shell:      zsh
  Shell Version:       5.9
  Terminal (TERM):     xterm-256color
  TrueColor:           enabled (COLORTERM=truecolor)
  UTF-8 Support:       yes (en_US.UTF-8)

  Shell Hook Integrations:
    ~/.bashrc:                         not installed
    ~/.zshrc:                          installed (zap init zsh)
    ~/.config/fish/config.fish:        not installed
    PowerShell profile:                not installed
```

---

### 4. Language Module Match Inspection

Verify why a language module is or isn't triggering in the current folder:

```bash
zap debug zig_lang --verbose
```

Output:
```text
=== Module Debug: zig_lang ===
  Active in format:    yes
  Config disabled:     false
  Match Trigger:       detected
  Matched File:        build.zig.zon
  Matched Extension:   .zon
  Matched Directory:   /home/user/project
  Scan Depth:          0 levels up
```

---

### 5. Exporting JSON Diagnostics for CI / Scripts

```bash
zap debug git --json -o git-debug.json
```
