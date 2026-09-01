# Testing strategy

Book Read tests behavior at the narrowest layer that owns it. A feature is not
complete until its normal behavior, expected failures, and relevant boundaries
are represented in the matrix below.

| Owner | Happy paths | Failure paths | Boundary and lifecycle cases |
| --- | --- | --- | --- |
| `reader.zig` | Open, navigation, zoom, bookmarks | Empty documents, allocation failure | Closed state, page and zoom limits, bookmark wraparound, reopen |
| `annotations.zig` | Pen, erase, undo, clear, option cycles, round trip | Invalid points, corrupt fields, allocation failure | Empty notes, duplicate points, wrong pages, size limits, transactional restore, stable tags |
| `progress.zig`, `preferences.zig` | Round trips | Corrupt lines | Legacy theme lines, closed readers |
| `path_helpers.zig` | Unix and Windows names | Empty input | Roots, trailing and repeated separators, Unicode bytes |
| `main.zig` | Interactive, direct PDF, smoke mode | Unknown and incomplete options | Extra arguments, option-shaped paths, empty argument vector |
| `application.zig` | Open, restore, replace, commands, timers, autosave, theme and tool persistence | Open, render, storage, and allocation failures | Rollback, corrupt notes, wait timeouts, hover repaints, stale page scale, smoke requirements |
| `ui/layout.zig` | Toolbar, panel, rail, page rectangle | Points outside every region | No overlapping buttons at any width, quarter edges, scroll clamps |
| `ui/input.zig` | Keys, clicks, wheel, drags, files | Unknown keys, empty paths | Strokes closed by hovers, hidden rail, page rectangle edges |
| `ui/renderer.zig` and caches | Every surface, cache hits, budgets | Text creation failure, render failure | Eviction, invalidation, codepoint-safe truncation |
| `storage.zig` | Read, atomic write, environment resolution | Unavailable directory | Overwrite, missing files, stable names |
| `platform.zig` and `bridge.c` | Raw input, PDF render, text and icons, screenshots | Missing PDF, invalid page, oversized scale | Poll sentinel, density, window ids |
| `check_style.zig` | Clean files and exact limit | Expected CLI rejection | Long lines, tabs, spaces, and CRLF endings |
| `build.zig` and CI | Every declared test and build step executes | Invalid style fixture must fail | Debug tests plus `ReleaseSafe` compilation |

## Test layers

```bash
zig build test:unit
zig build test:application
zig build test:tools
zig build test:native
zig build test:integration
zig build check:release
```

`zig build ci --summary all` is authoritative. It runs formatting and style
checks, strict C compilation, all test layers, the end-to-end PDF smoke test,
and the optimized safety-enabled build. The native tests leave one screenshot
per interface surface in `.zig-cache/screenshots` for visual review.

## Expectations for changes

1. Add the happy-path test that proves the requested behavior.
2. Force every recoverable failure introduced by the change.
3. Test minimum, maximum, empty, invalid, and repeated inputs when relevant.
4. Assert state rollback and resource cleanup after failures.
5. Prefer pure tests, then injected-backend tests, and use native integration
   tests only for contracts that genuinely cross the operating-system boundary.
6. Log handled failures as warnings. The test runner fails a test that logs an
   error, so `std.log.err` is reserved for conditions nobody recovers from.
