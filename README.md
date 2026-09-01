# Book Read

A native Linux PDF reader written in Zig. It renders real PDF pages with
Poppler and Cairo and uses SDL3 for the desktop interface.

The reading state, the interface, and the application logic live in Zig. A
narrow C bridge exposes only rendering and input primitives, keeping the
macro-heavy SDL/Poppler headers away from Zig 0.16's C translator while still
using their native APIs directly.

## Features

- Open PDFs with a file dialog, a command-line path, or drag and drop
- Automatically resume at the last page
- Add bookmarks and jump between them
- Dark and light reading modes, remembered across documents and launches
- High-DPI text, vector icons, and pages rasterized at the size they are shown
- Page navigation and zoom that re-renders crisply once you pause
- A collapsible, scrollable thumbnail rail for previewing and jumping to pages
- Freehand PDF notes with pen and eraser tools
- Six ink colors, three pen sizes, per-page undo, and clear-page controls
- Annotation autosave without modifying the original PDF
- Mouse controls: clickable toolbar, page-edge clicks, and the scroll wheel
- An idle window costs no CPU: the reader sleeps until input or a timer wakes it
- Progress stored under `$XDG_STATE_HOME/book-read` or
  `~/.local/state/book-read`

## Supported platform

The current production target is Linux. The reading core and the interface are
platform independent, and native services are isolated so other desktop
backends can be added without rewriting reader behavior.

## Requirements

- Zig 0.16.x
- SDL3
- Poppler GLib
- Cairo

On Arch Linux / Omarchy:

```bash
sudo pacman -S zig sdl3 poppler-glib cairo
```

## Build and run

```bash
zig build
zig build run
```

You can also open a PDF directly:

```bash
zig build run -- /path/to/book.pdf
```

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| `O` | Open a PDF |
| `Left` / `Page Up` / `<` | Previous page |
| `Right` / `Page Down` / `Space` / `>` | Next page |
| `B` | Toggle bookmark |
| `J` | Jump to the next bookmark |
| `D` | Toggle dark mode |
| `+` / `-` | Zoom in / out |
| `0` | Reset zoom |
| `Home` / `End` | First / last page |
| `P` | Toggle the pen |
| `E` | Toggle the eraser |
| `C` | Cycle the annotation color |
| `T` | Cycle the pen size |
| `U` | Undo the latest stroke on the current page |
| `X` | Clear annotations from the current page |
| `N` | Leave annotation mode |
| `S` | Show or hide the Pages rail |
| `Esc` | Quit |

You can also use the Pages icon in the top bar to show or hide the left rail,
click a page preview, click the **left or right quarter** of the reading area to
change pages, click the other toolbar controls, or use the mouse wheel.
Scrolling over the thumbnail rail browses the full page list without changing
the open page; scrolling over the document changes the current page. Select
**PEN**, then hold the left mouse button and drag over the page to write.
Select **ERASE** and drag across a stroke to remove it.

The contextual annotation margin folds out beside the page. It provides five
direct color swatches, visual stroke-width buttons, pen and eraser tabs, undo,
clear, and a save indicator that also reports when notes could not be written.
Black remains available in the six-color keyboard cycle and is drawn as light
ink in dark mode. Selected tools and options use a highlighted state, while
buttons show hover feedback and vector icons. Keyboard shortcuts continue to
work alongside the visual controls. Your pen color and size stay selected when
you open another document.

Annotations use normalized page coordinates, so they stay aligned while the
window or page zoom changes. They are stored in a versioned sidecar file next
to the reading-state record and written a moment after each edit. The source
PDF is never changed.

## Stored files

Everything lives in the state directory:

| File | Contents |
| --- | --- |
| `preferences` | The reading theme |
| `<hash>.state` | Current page and bookmarks of one document |
| `<hash>.state.notes` | Annotations of one document |

Files are written atomically, so an interrupted save never damages the previous
version.

## Development

Run every local quality gate with:

```bash
zig build ci --summary all
```

The native tests leave a screenshot of every interface surface in
`.zig-cache/screenshots` for visual review.

See [CONTRIBUTING.md](CONTRIBUTING.md), [STYLE.md](STYLE.md), and the
[architecture guide](docs/architecture.md) for the project structure and
engineering conventions. The [testing strategy](docs/testing.md) records the
happy-path, failure-path, and boundary coverage required for every module.
