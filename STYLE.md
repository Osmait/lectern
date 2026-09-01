# Book Read code style

Book Read follows Zig's standard style and borrows a small set of proven
conventions from TigerBeetle and Ghostty.

## Principles

- Correctness comes before cleverness. Make invalid transitions explicit.
- Use descriptive names. Avoid abbreviations that require domain knowledge.
- Use `snake_case` for files, functions, and variables.
- Use named option structs when same-typed arguments could be confused.
- Keep source lines at or below 100 bytes.
- Use four spaces, no tabs, and no trailing whitespace.
- Use braces for multi-line control flow.
- Comments are complete sentences and explain why or how.
- Keep the toolbox small: prefer Zig build steps and Zig utilities.

## Architecture rules

- The core cannot import the interface, platform, or C modules.
- The native bridge exposes primitives only. Layout, hit testing, theming,
  caches, and persistence live in Zig, where they are unit tested.
- Native resources have one clear owner and an explicit `deinit` method.
- Resource replacement should be transactional: prepare the replacement before
  releasing the working resource.
- Platform APIs expose domain values, not raw C types. Enums that mirror
  native constants are checked at compile time.
- Enum tags that are written to disk carry explicit values and a comment
  saying so; never renumber them.
- Failures that the user already sees are logged as warnings. `std.log.err` is
  reserved for conditions nobody recovers from, because the test runner fails
  any test that logs an error.
- New state transitions require focused unit tests.
- Native behavior requires an integration test or a documented manual test.

## Formatting and linting

Run:

```bash
zig build fmt
zig build lint
```

The build treats C compiler warnings as errors. Do not silence a warning unless
the code documents why the warning is incorrect for that call site. The style
checker discovers every source file under `src`, `tests`, and `tools` on its
own, so new files are checked automatically.

## Reference projects

- [TigerBeetle Tiger Style](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md)
- [Ghostty development guide](https://github.com/ghostty-org/ghostty/blob/main/HACKING.md)
- [Zig 0.16 language reference](https://ziglang.org/documentation/0.16.0/)
