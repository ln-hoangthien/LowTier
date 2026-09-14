# PACT runtime - coding style

Derived from the **Linux kernel** (`Documentation/process/coding-style.rst`)
and **QEMU** (`HACKING`/`CODING_STYLE.rst`) styles, with the deviations
listed below.

## How to enforce

| Command | What it does | Requires |
|---|---|---|
| `make check-style` | Coarse grep-based check that catches the most common **same-line** brace mistakes (`if (c) stmt;`, `else stmt;`) - not next-line braceless bodies or `for`/`while`. Runs in CI (`.github/workflows/ci.yml`). | bash + standard GNU utilities (grep, sed) |
| `make check-format` | Full clang-format `--dry-run` - the complete style gate. CI gate. Picks `clang-format-18` automatically when the unversioned binary is absent; errors with instructions if neither exists. | `clang-format` ≥ 16 |
| `make format` | Apply clang-format in-place across all `src/*.{c,h}` (excludes `khashl.h`, `minicoro.h`). | `clang-format` ≥ 16 |

Install on Ubuntu/Debian:

```
sudo apt install clang-format-18
```

Then add a pre-commit hook (one-time, from the repo root):

```
ln -sf ../../src/check-style.sh .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

## The rules that the grep gate catches

These are the violations the project has historically slipped on. The
grep gate only sees **same-line** cases in `src/*.{c,h}` (excluding
vendored headers); `make check-format` (clang-format) is the complete
gate and catches the rest.

### 1. Braces required on all if/else bodies - except top-of-function guards

```c
/* BAD - same-line body */
if (sig) printf("...\n");
else     printf("...\n");

/* BAD - next-line braceless body */
if (cond)
    do_something();
else
    do_other();

/* GOOD */
if (sig) {
    printf("...\n");
} else {
    printf("...\n");
}
```

### 2. Guard-clause exception

A single-statement `return`, `break`, `continue`, `goto`, or `exit()` at
the top of a function (or at the top of a loop iteration) MAY be
written on one line without braces:

```c
/* OK - guard clause at function top */
void destroy(ctx_t *ctx)
{
    if (!ctx) return;
    ...
}

/* OK - loop guard */
for (int i = 0; i < n; i++) {
    if (!entries[i].valid) continue;
    ...
}
```

This matches QEMU style and is the only same-line body the project permits.

## The rules that clang-format enforces

See `.clang-format` for the authoritative list. Highlights:

- **Indentation**: 4 spaces, no tabs. (Project deviation from kernel's 8.)
- **Column limit**: 100. (Project deviation from kernel's 80; many existing
  `log_*()` lines exceed 80 and 100 keeps them on one line.)
- **Pointer alignment**: `T *p`, not `T* p` (kernel style).
- **Function braces**: opening brace on its own line for top-level functions:
  ```c
  void foo(void)
  {
      ...
  }
  ```
  But on the same line for control flow: `if (cond) {`.
- **Pointer dereferences and unary ops**: no space (`*p`, `&x`, `!x`).
- **Binary operators**: spaces (`a + b`, `a == b`).
- **Spacing after control keyword**: `if (cond)` not `if(cond)`.
- **Trailing whitespace**: forbidden.
- **No reordering of includes** (some headers have load-bearing order).

## Naming

- **snake_case** for functions and variables.
- **UPPER_SNAKE_CASE** for macros and enum members.
- **Public functions** that are exported (non-static) use a `pact_` prefix
  (e.g., `pact_init`, `pact_destroy`). A handful of historical names
  (`update_pac_entry`, `migration_thread_fn`) lack the prefix - these
  are tracked for a future rename pass.
- **Struct typedefs** are POSIX-discouraged when they end in `_t`. The
  project has many `_t`-suffixed typedefs (`pact_context_t`, etc.); a
  dedicated rename pass is planned.

## Comments

- Use `/* ... */` for everything. Avoid `//`.
- WHY, not WHAT - well-named identifiers and code structure document
  the WHAT.
- Mark actionable future work with `TODO:` so it stays grep-friendly;
  prefer it over prose like "Future:".
- Comments describe what the code does and why, not its change history.
  Leave out refactor narrative (`Phase N`, `extracted from X`, dates,
  bug-ID tags) - `git log` and `git blame` are authoritative for that.
