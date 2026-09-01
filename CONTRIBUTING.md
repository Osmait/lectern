# Contributing to Book Read

Thank you for helping improve Book Read. Changes should be understandable,
testable, and small enough to review with confidence.

## Development setup

Install Zig 0.16.x, SDL3, Poppler GLib, and Cairo. On Arch Linux:

```bash
sudo pacman -S zig sdl3 poppler-glib cairo
```

Build and run the application:

```bash
zig build
zig build run
```

## Required checks

Run the same command used by GitHub Actions before opening a pull request:

```bash
zig build ci --summary all
```

The CI contract includes:

- `zig fmt --check --ast-check` for formatting and syntax
- The repository style checker for line length, tabs, and trailing whitespace
  over every source file under `src`, `tests`, and `tools`
- C compilation with `-Wall -Wextra -Wpedantic -Werror`
- Pure-Zig unit tests for the core
- Application, interface, and storage tests with an in-memory backend
- Native bridge and platform contract tests with SDL's dummy video backend,
  which also write one screenshot per surface to `.zig-cache/screenshots`
- A headless end-to-end PDF rendering and annotation test
- A `ReleaseSafe` build

Useful targeted commands:

```bash
zig build fmt
zig build lint
zig build test:unit
zig build test:application
zig build test:tools
zig build test:native
zig build test:integration
zig build test -Dtest-filter=bookmark
zig build check:release
```

## Change guidelines

1. Put reading rules and state transitions in the pure Zig core.
2. Put layout, hit testing, theming, and drawing decisions in `src/ui`.
3. Keep SDL, Poppler, Cairo, and C types behind `src/platform.zig`, and keep
   the native bridge limited to primitives.
4. Add tests for valid inputs, invalid inputs, and boundary transitions.
5. Explain why a non-obvious decision exists; do not narrate obvious code.
6. Keep unrelated changes out of the same pull request.
7. Update user or architecture documentation when behavior or boundaries change.

Read [STYLE.md](STYLE.md), [docs/architecture.md](docs/architecture.md), and the
[testing strategy](docs/testing.md) before making structural changes.
