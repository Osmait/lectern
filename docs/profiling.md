# Profiling

`zig build profile` builds `zig-out/bin/lectern-profile`: the production
application driven headlessly through a scripted session. It is compiled
`ReleaseFast` with frame pointers and debug information, so profilers can
attribute samples to functions. The session opens the given PDF and runs
these phases, printing the wall time of each:

| Phase | What it exercises |
| --- | --- |
| open document | Sync first render, page sizes, restore |
| page turns | Worker renders, page cache, prefetch, texture upload |
| zoom bursts | Debounced re-render after fifteen zoom steps |
| pen strokes | Stroke tessellation and repaints, then the notes save |
| thumbnail scroll | Rail repaints and thumbnail renders on the worker |
| theme toggles | Page and thumbnail re-renders with the dark lookup |
| resizes | Layout, debounce, one re-render after the drag |
| hover sweep | Hover resolution with repaints only on change |

Storage is a temporary directory; the user's state is never touched.

## Recording

With SDL's dummy video driver the run needs no display, but SDL then
rasterizes every frame on the CPU, which dominates the profile. Use a real
display when the question is about the application's own code:

```bash
zig build profile
# Headless: no window, SDL software rendering dominates.
SDL_VIDEODRIVER=dummy perf record -F 1999 -g --call-graph dwarf \
    -o perf.data -- zig-out/bin/lectern-profile book.pdf
# Real renderer: a window opens for the duration of the session.
perf record -F 1999 -g --call-graph dwarf \
    -o perf.data -- zig-out/bin/lectern-profile book.pdf
```

`perf_event_paranoid` must be 2 or lower for user-space sampling.

## Flamegraph

```bash
perf script -i perf.data | inferno-collapse-perf --tid > stacks.txt
inferno-flamegraph --width 1400 < stacks.txt > flamegraph.svg
```

`inferno` comes from `cargo install inferno`; the FlameGraph Perl scripts
work the same way. `--tid` gives every thread its own root: the main thread,
`lectern-render`, and `lectern-storage`.

## Reading the result

- Samples inside `lectern-profile` are the Zig code and the C bridge;
  `perf report --dso lectern-profile --sort symbol` lists them.
- `lectern-render` holds Poppler, Cairo, and the dark-mode lookup in
  `lectern_pdf_render_image`.
- System libraries on Arch ship without frame pointers and with internal
  symbols stripped, so stacks stop at the first SDL or Mesa frame and their
  internals appear as `[libSDL3.so]`. `DEBUGINFOD_URLS` can fetch symbols
  for `perf report`; frames above them stay attributed to the library.

Wall times printed by the workload include vertical sync waits: the dummy
renderer simulates a 60 Hz display by sleeping in `SDL_RenderPresent`.

## Baseline

Measured on a Ryzen 5 5600X with the NVIDIA driver and the eight-page
fixture, after the optimizations that followed the first profile. Shares
are of all samples of the session; the application sleeps most of the time,
so the whole session uses about a tenth of one core.

| Where | Share |
| --- | --- |
| GPU driver, EGL, and shader cache | about 44 % |
| SDL3 | about 12 % |
| Poppler, Cairo, pixman, FreeType, on `lectern-render` | about 15 % |
| Lectern, Zig and the C bridge | about 3 % |

The largest piece of Lectern's own time is the dark-mode inversion of a
freshly rendered page, on the render thread. On the main thread nothing
exceeds half a percent; the cost per frame is the draw commands SDL sends to
the driver, one per texture.
