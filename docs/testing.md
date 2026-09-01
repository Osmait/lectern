# Testing strategy

Book Read tests behavior at the narrowest layer that owns it. A feature is not
complete until its normal behavior, expected failures, and relevant boundaries
are represented in the matrix below.

| Owner | Happy paths | Failure paths | Boundary and lifecycle cases |
| --- | --- | --- | --- |
| `reader.zig` | Open, navigation, zoom, bookmarks | Empty documents, allocation failure | Closed state, page and zoom limits, bookmark wraparound, reopen |
| `annotations.zig` | Pen, erase, undo, clear, option cycles, round trip, revision | Invalid points, corrupt fields, allocation failure | Empty notes, duplicate points, pages beyond a shorter document, size limits, transactional restore, stable tags |
| `progress.zig`, `preferences.zig`, `key_value.zig` | Round trips | Corrupt lines | Legacy theme lines, closed readers, empty input |
| `path_helpers.zig` | Unix and Windows names | Empty input | Roots, trailing and repeated separators, Unicode bytes |
| `arguments.zig` | Interactive, direct PDF, smoke mode | Unknown and incomplete options | Extra arguments, option-shaped paths, empty argument vector |
| `application.zig` | Open, restore, replace, commands, timers, autosave, theme and tool persistence, page cache, prefetch | Open, render, storage, and allocation failures | Dropped results of replaced documents, failed pages reported once, corrupt and oversized notes, wait timeouts, hover repaints, cached layout, resize debounce, repaint-only-on-change, smoke requirements |
| `rendering.zig`, `page_cache.zig` | Job ordering, cache hits within tolerance | Zero scales | Priority ties, bounded eviction, page replacement |
| `ui/layout.zig` | Toolbar, panel, rail, page rectangle, hover | Points outside every region | No overlapping buttons at any width, panel rows that never overlap from the minimum window height upward, quarter edges, scroll clamps |
| `ui/input.zig` | Keys, clicks, wheel, drags, files | Unknown keys, empty paths | Strokes closed by hovers, hidden rail, page rectangle edges, wake and leave events |
| `ui/renderer.zig` and caches | Every surface, cache hits, stroke geometry reuse, batched swatches | Text creation failure, render failure | Eviction, invalidation, late thumbnail results, placeholder pages, codepoint-safe truncation |
| `ui/geometry.zig` | Circles, strips, caps and joins | Degenerate strokes | Join threshold, gentle bends without joins |
| `storage.zig` | Read, queued atomic writes, completions, environment resolution, temporary directories | Unavailable directory, unwritable names | Coalesced writes, reads after queued writes, missing files, stable names |
| `platform.zig` and `bridge.c` | Raw input, PDF render, worker thread rendering and wake-ups, text and icons, screenshots | Missing PDF, invalid page, oversized scale | Poll sentinel, density, window ids, document identity after reopen |
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
and the optimized safety-enabled build. The application tests run on the
in-memory backend and link no native library. The native tests leave one
screenshot per interface surface in `.zig-cache/screenshots` for visual
review, including one at the minimum window size.

## Expectations for changes

1. Add the happy-path test that proves the requested behavior.
2. Force every recoverable failure introduced by the change.
3. Test minimum, maximum, empty, invalid, and repeated inputs when relevant.
4. Assert state rollback and resource cleanup after failures.
5. Prefer pure tests, then injected-backend tests, and use native integration
   tests only for contracts that genuinely cross the operating-system boundary.
6. Log handled failures as warnings. The test runner fails a test that logs an
   error, so `std.log.err` is reserved for conditions nobody recovers from.
