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
3. **Reuse Existing Helpers (No Duplicate Functions — Never Reimplement):**
   Before writing any utility, parser, file I/O, or git logic, reuse the canonical helpers:
   - **OS / Env / Paths / Streams / Time** (`src/utils/platform.zig`):
     - `env.*`, `isSep`, `pathStartsWith`, `pathEql`, `pathIsSubpath`, `joinPath`, `joinParts`, `fileExistsAbsolute`, `readStreamToBuf`, `spawnWithEnv`, `getLocalTime`, `testTempSubdir`.
   - **File I/O & Project Detection** (`src/utils/fs.zig`):
     - `fileExists`, `readFileRaw`, `readSmallFile`, `writeFile`, `writeFileAbsolute`, `findFirstSubpath`, `anySubpathExists`, `findFirstExtensionFile`, `hasFileWithExtension`, `scanParentDirsForFiles`, `detectDetailed`.
   - **Path Truncation** (`src/utils/path_utils.zig`):
     - `writePath`, `formatPathBuf`, `formatPathTruncatedBuf`.
   - **Template, JSON & ANSI Parsing** (`src/utils/parse_utils.zig`):
     - `extractVarName`, `findMatchingDelimiter`, `skipAnsiOrShellMarker`, `escapeJsonBuf`, `writeJsonEscaped`.
   - **TOML Config & Validation** (`src/config/toml_parser.zig`):
     - `loadConfigFromPath`, `loadConfigFile`, `splitKeyVal`, `unquoteRaw`, `stripInlineComment`, `extractMultilineValue`, `InlineTableIterator`, `resolveExistingConfigPath`.
   - **Prompt Engine & Context** (`src/engine/prompt.zig`, `src/engine/context.zig`):
     - `resolveHomePath`, `resolveCwdPath`, `PromptContext.getGitDir`, `computeActiveModulesMask`, `resolveGitContext`, `renderActiveModules` (with `ModuleBuffers`).
   - **Git Subsystem** (`src/utils/git_utils.zig` -> `src/utils/git/*`):
     - **Single-process status**: `resolveBranch`, `resolveCommit`, `getGitStatusForDir`, `collectDetailedGitFiles` (all backed by `runGitStatusPorcelain` with `git status --porcelain=v2 --branch --show-stash`).
     - **Repo/Worktree paths**: `findGitDir`, `findRepoRoot`, `gitDirToCommonDir`, `resolveRepoRoot`, `gitDirToRepoRoot`.
     - **Tags / State / Index / Debug**: `findTagForHash` (`git describe --tags --exact-match`), `getGitState`, `getIndexEntryCount` (`.git/index` header), `writeNotInGitRepo`.
   - **Test Harness & Assertions** (`src/tests/harness.zig`, `src/tests/fixture.zig`, `src/tests/assertions.zig`):
     - `Fixture.stripAnsi`, `Fixture.assertValidShellAnsi`, `assertions.*`, `Harness.runShellScript`, `Harness.collectAllShells`.
   - Always run `zig fmt --check src/ build.zig` (or `zig fmt src/ build.zig`) to keep Unix `LF` formatting.
4. **Zig 0.16 Paradigm & Idioms:**
   - **Comptime reflection over `registry`:** Use `@typeInfo(registry).@"struct".decls`, `inline for`, and `std.meta.DeclEnum(modules)` (`ModuleVar`) instead of hardcoded module lists or runtime dispatch.
   - **Comptime lookup tables over `if-else` chains:** Use `std.StaticStringMap` / `std.StaticStringMapWithEql(..., eqlAsciiIgnoreCase)` or `std.meta.stringToEnum` instead of `if (std.mem.eql(...))` chains.
   - **Zero-heap stack buffers:** Use `BufferWriter` (`src/utils/buffer_writer.zig`) and fixed stack arrays in all render/debug paths; never allocate in `render()`.
   - **Array init & Io:** Use `@splat(null)` instead of `.{null} ** N` for array initialization; use `std.Io.Dir` / `std.Io.File` APIs (`openDir`, `copyFile`, `createDirPathOpen`, `deleteTree`).
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
