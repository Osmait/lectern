# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

Book Read primarily serves students, researchers, and focused readers working
through long PDF documents. They need to read without distraction, preserve
their place, and add handwritten notes without altering the source document.

## Product Purpose

Book Read makes sustained PDF reading and annotation feel fast, private, and
effortless. Success means a reader can open a document, immediately resume the
same reading context, navigate confidently, and capture notes without leaving
the reading flow.

## Positioning

Book Read combines a focused native reading experience with local-first,
non-destructive annotations: the reader owns the files and state, the source
PDF remains untouched, and essential reading and note-taking do not depend on
an account or remote service.

## Operating Context

- The primary workflow is reading and annotating long-form PDFs on a desktop.
- Readers use both keyboard shortcuts and mouse controls.
- Reading progress, bookmarks, theme, zoom, and per-page annotations persist
  locally between sessions.
- Annotations use page-relative coordinates so they stay aligned when the page
  or window size changes.
- The current production environment is native Linux.

## Capabilities and Constraints

- Open PDFs from a file dialog, a command-line path, or drag and drop.
- Resume the last page, navigate pages, zoom, and manage bookmarks.
- Preview every page in a collapsible thumbnail rail and jump directly to it.
- Support light and dark reading modes.
- Draw and erase freehand notes with selectable colors and stroke widths.
- Undo or clear annotations on the current page.
- Autosave annotations in a versioned sidecar format without changing the
  original PDF.
- Keep the reading core independent from native desktop services so future
  Windows and macOS backends can reuse reader behavior.
- Preserve a narrow native boundary around SDL3, Poppler GLib, and Cairo.
- Use Zig 0.16.x and keep the existing correctness-focused CI, linting, unit,
  failure-path, boundary, native, integration, and ReleaseSafe checks.
- Linux is the first supported platform. Windows and macOS are planned future
  platforms; their delivery order and schedule remain open decisions.

## Brand Commitments

- The product name is Book Read.
- The product should feel focused and trustworthy rather than distracting.
- Native performance, privacy, and user ownership of documents and notes are
  part of the product identity.

## Evidence on Hand

- The working native application and its product behavior live in `src/`.
- Current user-facing capabilities and shortcuts are documented in
  `README.md`.
- Architecture and extension boundaries are documented in
  `docs/architecture.md`.
- Engineering quality requirements are documented in `STYLE.md`,
  `CONTRIBUTING.md`, and `docs/testing.md`.
- Automated CI is defined in `.github/workflows/ci.yml` and `build.zig`.
- No testimonials, usage metrics, customer claims, or independent performance
  benchmarks are currently available; future work must not fabricate them.

## Product Principles

1. Keep the reader in flow: frequent reading and annotation actions should be
   immediately understandable and require minimal interruption.
2. Preserve user ownership: documents, progress, and notes remain local, and
   the original PDF is never silently modified.
3. Make state unmistakable: the active tool, selection, page, and save status
   should always be clear.
4. Earn trust through reliability: failures must preserve the current document
   and user work, and important behavior must remain covered by automated tests.
5. Grow without weakening the core: new desktop platforms and capabilities
   should extend the existing inward-pointing architecture.
