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
| *(default / `all` / `modules`)* | Inspects the diagnostic state of all registered modules. |
| `<module_name>` | Inspects a single specific module (e.g. `zap debug zig_lang`, `zap debug directory`). |
| `git` | Inspects Git modules (`git_branch`, `git_commit`, `git_state`, `git_status`). Use `-v` for full index and modified/untracked file lists. |
| `config` | Dumps the active configuration, resolved path, `format` / `right_format`, and active/inactive module bitmask (use `-v` for all module fields). |
| `prompt` | Inspects isolated module outputs, byte length, visible character width, and raw escaped ANSI sequences (`\x1b[...]`). |
| `timings` / `profile` | Runs a single-pass per-module and pipeline execution profiler (µs) without multi-pass stress benchmarking. |
| `bench` | Runs a multi-pass statistical benchmark (min, p50, p95, p99, mean, max, throughput, and latency histogram). |
| `style` / `colors` | Renders a live ANSI 16-color palette, text modifiers, and previews every module's configured `style`. |
| `env` | Diagnoses terminal capabilities (`$TERM`, TrueColor, UTF-8 locale) and key environment variables. |
| `shell` | Inspects shell RC integration hooks (`bash`, `zsh`, `fish`, `powershell`), supported features, and previews init scripts with `-v`. |

---

## Options & Flags

- `-v`, `--verbose`: Enables detailed inspection mode:
  - **Git**: Lists exact modified, untracked, deleted, and conflicted files.
  - **Prompt**: Shows raw escaped ANSI sequences for every active module.
  - **Style**: Shows compiled ANSI escape sequences next to each module's sample preview.
  - **Shell**: Prints the generated initialization script for the current shell.
  - **Languages / Tools**: Shows trigger files, matched extensions, and directory scan depth.
  - **Config**: Dumps detailed struct fields and values for every module.
- `--json`: Outputs diagnostic reports in structured JSON format (ideal for CI and tool integration).
- `-n <num>`, `--iterations <num>`: Sets the number of benchmark iterations for `zap debug bench` (default: `100`, max: `2000`).
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
⚡ Zap Prompt Engine Profiler & Benchmark

Configuration:
  Add Newline:      true
  Buffer Usage:     108 / 4096 bytes (2.6% utilized)

Per-Module Execution Breakdown (Single Pass):
  ✔ directory           27 µs  [  0%]  (15 bytes)  [····················]
  ✔ git_branch          22 µs  [  0%]  (55 bytes)  [····················]
  · git_commit           0 µs  (inactive)
  · git_state            0 µs  (inactive)
  ✔ git_status        2928 µs  [ 98%]  (15 bytes)  [■■■■■■■■■■■■■■■■■■■·]
  ✔ cmd_duration         0 µs  [  0%]  ( 0 bytes)  [····················]
  ✔ character            4 µs  [  0%]  (19 bytes)  [····················]
  · os                   0 µs  (inactive)
  · zig_lang             0 µs  (inactive)

Pipeline Stages:
  Git Resolution:        8 µs  [  0%]  [····················]
  Render Modules:     2965 µs  [ 99%]  [■■■■■■■■■■■■■■■■■■■·]
  Template Format:       2 µs  [  0%]  [····················]
  Total Single-Run:   2975 µs (2.975 ms)

Multi-Pass Benchmark (100 iterations):
  Fastest (Min):      2285 µs (2.285 ms)
  Average (Mean):     2705 µs (2.705 ms)
  Slowest (Max):      4760 µs (4.760 ms)
  Throughput:       369 renders/sec

Latency Distribution (100 runs):
   2285 - 2780 µs:   [ 75 runs]  [■■■■■■■■■■■■■■■■■■······]
   2780 - 3275 µs:   [ 16 runs]  [■■■■····················]
   3275 - 3770 µs:   [  3 runs]  [■·······················]
   3770 - 4265 µs:   [  5 runs]  [■·······················]
   4265 - 4760 µs:   [  1 runs]  [■·······················]
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
