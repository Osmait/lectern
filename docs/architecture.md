# Architecture

Book Read separates portable reading behavior from native desktop services.

```text
src/main.zig
    |
    v
src/desktop.zig -----> src/application.zig -----> src/ui/*.zig
    |                        |                     layout, input, theme,
    |                        |                     geometry, caches, renderer
    |                        v
    |                  src/root.zig (core)
    |                    |-- src/reader.zig
    |                    |-- src/annotations.zig
    |                    |-- src/progress.zig
    |                    |-- src/preferences.zig
    |                    `-- src/path_helpers.zig
    |
    |----> src/platform.zig -----> src/bridge.c   SDL3, Poppler GLib, Cairo
    `----> src/storage.zig  -----> std.Io         state directory
```

## Dependency rule

Dependencies point inward. The core never imports the interface, the
application, the platform, or the native bridge. The interface layer imports
only the core and reaches the backend through a comptime type, so unit tests
run without a display server or system PDF libraries.

## Modules

### Core

`reader.zig` owns page position, zoom, and bookmarks for one document. Zoom is
an integer step so repeated operations never drift. `annotations.zig` owns
tools, per-page strokes with bounding boxes, editing operations, and the
versioned binary note format; its enum tags are explicit because they are
persisted. `progress.zig` and `preferences.zig` parse and serialize the text
formats for per-document progress and application preferences.
`path_helpers.zig` contains portable path behavior.

`root.zig` is the public core module. Future reusable features should be
exported here only when they do not depend on the desktop backend.

### Interface

`ui/layout.zig` computes every rectangle from the window size and three state
flags, and answers hit tests from the same data, so drawing and clicking can
never disagree. `ui/input.zig` turns raw window input into typed `Command`
values. `ui/theme.zig` holds the palettes and icon identities.
`ui/geometry.zig` converts strokes and circles into triangle lists.
`ui/renderer.zig` paints a `Frame` through the backend primitives and owns the
text, icon, and thumbnail caches (`ui/text_cache.zig`, `ui/icon_cache.zig`,
`ui/thumbnails.zig`).

The renderer is generic over the backend type. Production uses the SDL adapter;
tests use `testing/mock_backend.zig`, which counts every primitive call.

### Application

`application.zig` coordinates user commands, documents, page rendering,
annotations, and persistence. It owns the lifecycle of every resource.

The frame loop sleeps until input arrives or a timer is due:

1. Poll pending input; if none and nothing needs repainting, wait with a
   timeout derived from the earliest timer.
2. Translate every input into commands and execute them.
3. Run due timers: deferred page re-render, and note, progress, and preference
   saves.
4. Repaint only when something changed. Mouse motion repaints only when the
   hovered control changes.

Opening a document is transactional:

1. Open the candidate PDF.
2. Allocate its reader state and restore progress.
3. Prepare a notebook that keeps the current tool settings and restore notes.
4. Render its current page at the size it will occupy on screen.
5. Flush and release the previous document.
6. Commit the candidate resources.

An error in steps 1–4 leaves the current document usable.

Pages are rasterized at the scale they are displayed, multiplied by the display
density and capped at 3072 device pixels on the longest side. Zoom and resize
schedule one re-render after a short pause instead of re-rendering per frame.

Persistence is coalesced. Edits mark state dirty and arm a 750 ms timer; the
state is also flushed when a document is replaced and when the application
exits. Save failures are shown in the annotation margin and retried on the next
edit.

### Platform adapter

`platform.zig` converts raw C handles and integer constants into typed Zig
values. No other Zig module imports `bridge.h`. Every enum that mirrors a
native constant is verified at compile time, field by field.

### Storage

`storage.zig` resolves the state directory from `XDG_STATE_HOME` or `HOME`,
and reads and writes files atomically through `std.Io`. Per-document file names
derive from an FNV-1a hash of the absolute document path, which matches the
names written by earlier versions. The `preferences` file holds the reading
theme; per-document `.state` files hold the page and bookmarks, and
`.state.notes` files hold annotations. A legacy `dark` line in a `.state` file
is adopted once when no preferences file exists yet.

### Native bridge

`bridge.c` integrates SDL3, Poppler GLib, and Cairo. The bridge exists because
their macro-heavy headers currently exceed Zig 0.16's reliable `translate-c`
surface. It exposes only primitives: raw input events, window queries, frame
begin and end, rectangles, tinted textures, triangle lists, text and icon
rasterization, and PDF page rasterization at a requested scale. Text is
rasterized white and tinted at draw time so one texture serves every color.
Dark mode inverts page pixels through a lookup table.

Window coordinates remain logical while the bridge queries the real renderer
framebuffer density. It scales SDL drawing to that framebuffer and reports the
density to Zig, which rasterizes text, icons, thumbnails, and pages to match.

## Testing layers

| Layer | Build step | Purpose |
| --- | --- | --- |
| Core | `test:unit` | Exhaustive state transitions, formats, and boundaries |
| Application | `test:application` | Commands, orchestration, timers, interface, storage |
| Tooling | `test:tools` | Style-checker acceptance and rejection contracts |
| Native contracts | `test:native` | Raw input, PDF rendering, text rasterization, screenshots |
| End to end | `test:integration` | PDF render and note persistence with a dummy display |
| Release | `check:release` | Optimized safety-enabled compilation |

`zig build ci` is the authoritative local and remote quality gate. The native
tests write one screenshot per interface surface to `.zig-cache/screenshots`
for manual review.

## Planned extension points

- A library/catalog module can depend on the core and the storage module.
- Search and text selection can be added to the document adapter.
- Additional desktop backends implement the same primitive set as `platform.zig`.
- PDF export can flatten the versioned annotation sidecar into a new document
  without changing the core editing model.
