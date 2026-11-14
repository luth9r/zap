---
name: zap-dev
description: >-
  Fast development workflow, architecture conventions, Zig 0.16 patterns, and
  cross-platform rules for the zap shell prompt project. Activate when building,
  testing, refactoring, or adding shells/modules in zap.
---

# Zap Development Guide

## Fast Build & Test Workflow

- **Zig 0.16.0:** Ensure `zig` (`0.16.x`) is available on `PATH`.
- **Fast iteration (unit tests only, ~0.5s, skips `zap.exe` install):**
  ```pwsh
  zig build test-unit --summary all
  ```
- **Targeted filter:**
  ```pwsh
  zig build test -- --filter=<substring>
  ```
- **Full parallel E2E suite (8 workers, ~25s):**
  ```pwsh
  zig build test --summary all
  ```
- **Integration tests only:**
  ```pwsh
  zig build test-integration --summary all
  ```
- **Nix dev shell shortcuts:** `test-unit`, `test-integration`, `test-all`.

## Cross-Platform & Architecture Rules

1. **No scattered `builtin.os.tag` checks:**
   - Put all OS constants, path separators, env var names (`platform.env.*`), path joining (`platform.joinPath`, `platform.joinParts`), stream reading (`platform.readStreamToBuf`), and env-isolated spawning (`platform.spawnWithEnv`) in `src/utils/platform.zig`.
   - Use `std.Io.Clock.awake.now(io)` for timing (never raw `std.os.linux.clock_gettime`).
2. **Test harness & isolation:**
   - Use `Harness` (`src/tests/harness.zig`), `Fixture` (`src/tests/fixture.zig`), and `assertions.zig`.
   - Use `h.runShellScript(...)` for shell session tests instead of duplicating `PATH`/`HOME`/`spawn` boilerplate.
   - `Harness.setupGit()` clones a cached `--allow-empty` template repo (with `config.toml` in `.git/info/exclude`). Any test that overwrites `.git/info/exclude` MUST keep `config.toml` in it.
   - Keep `test "internal: cleanup git template"` in `harness.zig` — `src/tests/runner.zig` runs it in `defer` per worker.
3. **Zig 0.16 idioms:**
   - Use `@splat(null)` instead of `.{null} ** N` for array initialization to avoid false ZLS diagnostics.
   - Use `std.Io.Dir` / `std.Io.File` APIs (`openDir`, `copyFile`, `createDirPathOpen`, `deleteTree`).
   - Watch for CRLF files on Windows if string-matching edits fail.

## New Shell Checklist

When adding or updating a shell in `Shell` (`src/init/root.zig`):
1. `src/init/<shell>.zig` (script, `HOOK_TEMPLATE`, unit tests)
2. `src/init/root.zig` (`Shell` enum, `parse`, `renderInitScript`, test arrays)
3. `src/init/install.zig` (profile constant, `resolveShellConfigFile`, `getHookSnippet`, unit tests)
4. `src/engine/formatter.zig` (ANSI wrapping branch)
5. `src/cli/commands/debug/env_reporter.zig` (`inspectShellHook`, `printEnvDebug`, `printShellDebug`)
6. `src/cli/commands/help.zig` & `README.md`
7. `src/tests/fixture.zig` & `src/tests/harness.zig` (`assertValidShellAnsi`, `execInShell`, `shells` matrices)
