# Architecture

Book Read separates portable reading behavior from native desktop services.

```text
src/main.zig  (owns the window, the storage, and the render queue)
    |
    v
src/desktop.zig -----> src/application.zig -----> src/ui/*.zig
    |                        |                     layout, input, theme,
    |                        |                     geometry, caches, renderer
    |                        |-- src/page_cache.zig
    |                        |-- src/rendering.zig   render job vocabulary
    |                        v
    |                  src/root.zig (core)
    |                    |-- src/reader.zig
    |                    |-- src/annotations.zig
    |                    |-- src/progress.zig
    |                    |-- src/preferences.zig
    |                    |-- src/key_value.zig
    |                    `-- src/path_helpers.zig
    |
    |----> src/platform.zig -----> src/bridge.c   SDL3, Poppler GLib, Cairo
    `----> src/storage.zig  -----> std.Io         state directory
```

## Dependency rule

Dependencies point inward. The core never imports the interface, the
application, the platform, or the native bridge, and it knows nothing about
how an annotation looks: ink colors, pen widths, and labels belong to the
interface. The interface layer imports only the core and reaches the backend
through a comptime type, so unit tests run without a display server or system
PDF libraries. The application checks at compile time that a backend declares
every function it needs, so a missing piece is reported by name.

## Ownership

`main.zig` creates the window context, the storage, and the render queue and
releases them in reverse order. The application borrows them through pointers
and never destroys them; it only releases what it created itself: documents,
textures, and caches. Resources that own a thread, the storage and the render
queue, must not move after their first use.

## Modules

### Core

`reader.zig` owns page position, zoom, and bookmarks for one document. Zoom is
an integer step so repeated operations never drift. `annotations.zig` owns
tools, per-page strokes with bounding boxes, editing operations, and the
versioned binary note format; its enum tags are explicit because they are
persisted. Every change to finished strokes moves a revision counter, which
lets the renderer reuse stroke geometry between frames. Notes on pages that
the open document no longer has are skipped and counted, like progress
entries for missing pages. `progress.zig` and `preferences.zig` parse and
serialize the text formats for per-document progress and application
preferences on top of `key_value.zig`. `path_helpers.zig` contains portable
path behavior.

`root.zig` is the public core module. Future reusable features should be
exported here only when they do not depend on the desktop backend.

### Interface

`ui/layout.zig` computes every rectangle from the window size and three state
flags, and answers hit tests from the same data, so drawing and clicking can
never disagree. The annotation margin is a vertical flow of fixed-height rows
whose gaps stretch or shrink together, so every control fits from the minimum
window height upward. The layout also resolves what the pointer is over once;
the application stores that hover and hands it to the renderer inside the
`Frame`, so repaint decisions and highlights always agree. `ui/input.zig`
turns raw window input into typed `Command` values. `ui/theme.zig` holds the
palettes, the ink colors and pen widths of annotations, and icon identities.
`ui/geometry.zig` converts strokes and circles into colored triangle lists
whose vertex colors already have the bridge's float layout; the unit circle
is computed at compile time and round joins are only added where a stroke
turns sharply. Its `StrokeBuilder` extends the stroke being drawn one point
at a time, rebuilding only the tail. `ui/renderer.zig` paints a `Frame`
through the backend primitives and owns the text, icon, and thumbnail caches
(`ui/text_cache.zig`, `ui/icon_cache.zig`, `ui/thumbnails.zig`). Finished
strokes are tessellated once per page revision and drawn as a single batch,
the active stroke grows incrementally, and the swatches of the margin are
one cached batch that changes only with the selection, the hover, or the
theme. The text cache finds entries by a hash of text, size, weight, and
density.

The renderer is generic over the backend type. Production uses the SDL adapter;
tests use `testing/mock_backend.zig`, which counts every primitive call.

### Application

`application.zig` coordinates user commands, documents, page rendering,
annotations, and persistence.

The frame loop sleeps until input arrives, a timer is due, or a background
render finishes:

1. Poll pending input; if none and nothing needs repainting, wait with a
   timeout derived from the earliest timer, or indefinitely when nothing is
   pending. A finished render wakes the wait with a `render_ready` event.
2. Translate every input into commands and execute them. Only commands that
   changed something visible schedule a repaint; pointer moves repaint only
   when the hovered control changes.
3. Run due timers: the deferred page re-render, and the note, progress, and
   preference saves. Collect finished renders and write completions.
4. Repaint when something changed.

The layout is recomputed when the window size or one of its three flags
changes and read everywhere else, so pointer moves never ask the window for
its size.

### Rendering

Rasterization runs on the backend's render queue, a worker thread in
production, so the interface never blocks on Poppler:

- The page on screen has the highest priority, then visible thumbnails, then
  the neighbors of the current page, which are rendered ahead of time into a
  small page cache. A page turn to a cached page is instant; otherwise paper
  is shown until the render lands, with the page's notes already on it.
- Zoom and theme changes keep the old texture on screen, stretched, until the
  replacement arrives. A resize or zoom burst re-renders once, after the user
  pauses: the delay restarts only while the target scale keeps changing.
- Every job carries the document generation. Results of a replaced document
  are released unseen, and a result for a page the reader already left goes
  to the page cache instead of the screen.
- A page that fails to render is reported once and not requested again until
  the page, zoom, or theme changes.

Pages are rasterized at the scale they are displayed, multiplied by the display
density and capped at 3072 device pixels on the longest side.

### Opening a document

Opening is transactional:

1. Open the candidate PDF and read every page size.
2. Allocate its reader state.
3. Flush pending edits of the current document, so reopening the same file
   sees its latest notes.
4. Restore the candidate's progress and prepare a notebook that keeps the
   current tool settings and restores its notes.
5. Render its current page at the size it will occupy on screen, on the main
   thread, before the worker takes over.
6. Wait for the worker to finish with the current document, release it, and
   commit the candidate resources. A theme stored by an earlier version in
   the document's progress is adopted only now.

An error in steps 1–5 leaves the current document usable.

### Persistence

Persistence is coalesced. Edits mark state dirty and arm a 750 ms timer; the
state is also flushed when a document is replaced and when the application
exits. Writes are queued to the storage thread; the annotation margin shows
the notes as pending until the storage confirms the write, and a failed write
marks the notes dirty again so the next edit retries.

The `--smoke-test` mode opens the document, records one note, checks that it
round trips, and exits. It uses a temporary state directory that is deleted
afterwards, so it can never read or overwrite the user's real state.

### Platform adapter

`platform.zig` converts raw C handles and integer constants into typed Zig
values. No other Zig module imports `bridge.h`. Every enum that mirrors a
native constant is verified at compile time, field by field, and so are the
memory layouts of points, rectangles, colors, and triangle indices, the
window sizes, and the page pixel limits.

The adapter also owns the native render queue: one worker thread that
rasterizes pages into images while the main thread turns finished images into
textures. After a document is opened, only the worker calls Poppler for it;
page sizes are read once at open time, so the main thread never waits for a
render in progress. Documents are identified by a serial that the bridge
assigns on every open, never by an address that could be reused.

### Storage

`storage.zig` resolves the state directory from `XDG_STATE_HOME` or `HOME`,
and reads and writes files atomically through `std.Io`. Writes are queued and
performed on a storage thread, because every write syncs to disk; only the
newest queued write per file name is kept, and each finished write is
reported as a completion. Reads wait for queued writes first. Per-document
file names derive from an FNV-1a hash of the absolute document path, which
matches the names written by earlier versions. The `preferences` file holds
the reading theme; per-document `.state` files hold the page and bookmarks,
and `.state.notes` files hold annotations. A legacy `dark` line in a `.state`
file is adopted once when no preferences file exists yet.

### Native bridge

`bridge.c` integrates SDL3, Poppler GLib, and Cairo. The bridge exists because
their macro-heavy headers currently exceed Zig 0.16's reliable `translate-c`
surface. It exposes only primitives: raw input events, window queries, frame
begin and end, rectangles, tinted textures, colored triangle lists, text and
icon rasterization, and PDF page rasterization at a requested scale, either
straight to a texture on the main thread or to an image that any thread may
produce and the main thread uploads later. A wake call from any thread ends
the input wait. Text is rasterized white and tinted at draw time so one
texture serves every color, and a texture remembers its last tint so
repeated draws skip the modulation calls. Consecutive rectangles are
collected and drawn as one triangle list; any other command flushes them
first, so the painter's order holds. Triangle lists arrive in SDL's own
vertex layout and are drawn without copying. Dark mode inverts page pixels
with word arithmetic that the compiler vectorizes.

Window coordinates remain logical while the bridge queries the real renderer
framebuffer density. It scales SDL drawing to that framebuffer and reports the
density to Zig, which rasterizes text, icons, thumbnails, and pages to match.

## Testing layers

| Layer | Build step | Purpose |
| --- | --- | --- |
| Core | `test:unit` | Exhaustive state transitions, formats, and boundaries |
| Application | `test:application` | Commands, orchestration, timers, render queue, interface, storage; links no native library |
| Tooling | `test:tools` | Style-checker acceptance and rejection contracts |
| Native contracts | `test:native` | Raw input, PDF rendering, worker thread, text rasterization, screenshots compared with `tests/golden` |
| End to end | `test:e2e` | The production application with the real window, worker threads, and files, driven by synthetic events |
| Smoke run | `test:integration` | The installed binary renders a PDF and persists a note with a dummy display |
| Release | `check:release` | Optimized safety-enabled compilation |

`zig build ci` is the authoritative local and remote quality gate. The native
tests write one screenshot per interface surface to `.zig-cache/screenshots`
and compare each with its reference image; `-Dupdate-golden` rewrites the
references after an intended change.

## Planned extension points

- A library/catalog module can depend on the core and the storage module.
- Search and text selection can be added to the document adapter.
- Additional desktop backends implement the same primitive set as `platform.zig`.
- PDF export can flatten the versioned annotation sidecar into a new document
  without changing the core editing model.
