---
name: Lectern
description: A calm native PDF desk with a contextual scholar's margin.
colors:
  linen-shell: "#171717"
  warm-paper: "#F8F7F1"
  reading-field: "#E7E5E0"
  graphite: "#2A2A2A"
  muted-graphite: "#505052"
  paper-rule: "#DEDBD5"
  header-ink: "#F2F2EF"
  ultramarine: "#2363D8"
  coral: "#CA332E"
  saved-green: "#299B63"
  night-panel: "#191B20"
  night-rule: "#3A3F49"
  ink-blue: "#2F6FDB"
  ink-red: "#D94F4A"
  ink-green: "#3E9965"
  ink-purple: "#845BAD"
  ink-yellow: "#F3C341"
typography:
  brand:
    fontFamily: "Noto Sans, sans-serif"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.25
    letterSpacing: "normal"
  title:
    fontFamily: "Noto Sans, sans-serif"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.25
    letterSpacing: "normal"
  label:
    fontFamily: "Noto Sans, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.25
    letterSpacing: "normal"
  micro:
    fontFamily: "Noto Sans, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.2
    letterSpacing: "normal"
  emphasis:
    fontFamily: "Noto Sans, sans-serif"
    fontSize: "15px"
    fontWeight: 700
    lineHeight: 1.25
    letterSpacing: "normal"
rounded:
  none: "0px"
  circle: "999px"
spacing:
  compact: "8px"
  standard: "16px"
  generous: "24px"
components:
  toolbar-control:
    backgroundColor: "{colors.linen-shell}"
    textColor: "{colors.header-ink}"
    typography: "{typography.label}"
    rounded: "{rounded.none}"
    size: "44px"
  tool-tab:
    backgroundColor: "{colors.warm-paper}"
    textColor: "{colors.graphite}"
    typography: "{typography.title}"
    rounded: "{rounded.none}"
    height: "60px"
  tool-tab-selected:
    backgroundColor: "{colors.warm-paper}"
    textColor: "{colors.ultramarine}"
    typography: "{typography.emphasis}"
    rounded: "{rounded.none}"
    height: "60px"
  width-control:
    backgroundColor: "{colors.warm-paper}"
    textColor: "{colors.graphite}"
    rounded: "{rounded.none}"
    height: "58px"
  action-destructive:
    backgroundColor: "{colors.warm-paper}"
    textColor: "{colors.coral}"
    typography: "{typography.title}"
    rounded: "{rounded.none}"
    height: "44px"
---

# Design System: Lectern

## Overview

**Creative North Star: "The Scholar's Margin"**

Lectern is a calm native reading desk. The PDF stays dominant while a
contextual paper margin carries the tools needed to write, erase, undo, and
confirm local persistence. The visual world combines a linen-dark application
shell with warm uncoated paper, graphite rules, and precise editorial color.

The interface is restrained rather than sparse. Controls remain directly
labeled where meaning matters, selected states move decisively forward, and
destructive actions are unmistakable without becoming loud.

**Key Characteristics:**

- Document-first composition with a fold-out annotation margin.
- Flat paper surfaces separated by value and one-pixel graphite rules.
- Ultramarine selection, coral destruction, and green persistence feedback.
- Antialiased vector icons paired with short, direct labels.
- Immediate state feedback that preserves low-latency pen input.

## Colors

The palette treats the shell as dark linen, controls as warm paper, and color
as functional ink rather than decoration.

### Primary

- **Ultramarine:** active tools, selected widths, selected ink rings, and Done.

### Secondary

- **Coral:** destructive actions such as Clear page.
- **Saved Green:** local persistence confirmation only.

### Tertiary

- **Ink Blue, Red, Green, Purple, and Yellow:** direct annotation choices.
  Black remains a supported annotation value for persisted documents and
  keyboard color cycling.

### Neutral

- **Linen Shell:** the top folio bar and the anchor for both reading themes.
- **Warm Paper:** the annotation margin and resting controls.
- **Reading Field:** the quiet area surrounding the live PDF page.
- **Graphite, Muted Graphite, and Paper Rule:** text hierarchy and separators.
- **Night Panel and Night Rule:** corresponding dark-mode surfaces.

**The Functional Ink Rule.** Accent colors always communicate a tool, edit,
or persistence state. They are not ambient decoration.

## Typography

**Display Font:** Noto Sans (with a generic sans-serif fallback)

**Body Font:** The PDF owns its embedded typography; application chrome uses
Noto Sans.

**Character:** Neutral native sans-serif labels defer to the book while staying
clear at compact sizes. Resting labels remain regular; selection, section
headings, and direct actions use a controlled bold weight. Text is rasterized
at the window's real pixel density with grayscale antialiasing and full native
hinting, so small labels remain crisp on standard and high-DPI displays.

### Hierarchy

- **Brand** (400, 15px, 1.25): the product name in the folio bar.
- **Title** (400, 16px, 1.25): tool tabs, actions, and saved state.
- **Label** (400, 14px, 1.25): Ink, Width, zoom, and supporting controls.
- **Micro** (400, 13px, 1.2): the annotation margin title.
- **Emphasis** (700, 15px, 1.25): active tools, action labels, the brand, and
  compact section headings.

**The Book Owns the Type Rule.** Never restyle rendered PDF text to match the
application chrome; the document's typography is user content.

## Layout

The top folio bar is 64px high. When annotation mode is active, the margin
occupies 22.9% of the window, clamped between 300px and 352px. The PDF uses the
remaining width after a compact page rail and fits within 24px horizontal and
16px vertical breathing room. The rail appears only while a document is open,
uses 10.5% of the window clamped between 124px and 148px, and scrolls
independently from the reading canvas. A persistent Pages control in the folio
bar collapses the rail and returns its full width to the document.

Margin groups use 24px leading space, an 8px intra-group rhythm, and vertical
positions proportional to the available window height. The minimum supported
window is 900×600. At compact widths, the filename truncates while page state,
tool controls, and all edit actions remain visible.

**The Contextual Margin Rule.** The annotation margin exists only while a note
tool is active. Reading mode returns that width to the document.

**The Index Rail Rule.** Page previews form a narrow index, not a second tool
sidebar. They show document content, page number, current selection, and a
quiet scroll position—nothing else.

## Elevation & Depth

The system is flat by design. It uses tonal separation and one-pixel rules, not
shadows, to distinguish the shell, live document, and annotation margin. Hover
states change surface value without lifting controls off the paper.

**The Paper Stack Rule.** Depth is expressed through adjacency and value;
never add card shadows or glass effects to the reader.

## Shapes

Toolbar targets, tool tabs, width selectors, and action rows are square and
edge-aligned. Circular geometry is reserved for ink swatches and the saved
status mark. Icons use a consistent authored vector stroke with rounded joins.

## Components

### Navigation

- **Folio bar:** 64px linen-dark strip with 44px hit targets.
- **State:** hover uses a subtle tonal fill; active annotation entry receives
  an ultramarine underline when visible.
- **Icons:** every authored toolbar glyph uses the same optical box and
  optical stroke treatment, including diagonals and rectangular outlines.
  Icons are antialiased Cairo vectors cached at the active display density;
  raw SDL pixel lines are not part of the icon system.
- **Responsive behavior:** the document title truncates before navigation or
  action controls collide.

### Page Index Rail

- **Surface:** warm paper in light mode and night panel in dark mode, separated
  from the reading field by a one-pixel rule.
- **Preview:** page thumbnails retain their source aspect ratio inside a fixed
  vertical rhythm; the selected page uses a two-line ultramarine frame.
- **Behavior:** the rail scrolls independently, lazily renders visible pages,
  keeps externally selected pages in view, and preserves its scroll position
  while collapsed.
- **State:** hover uses the standard surface value, page numbers remain visible,
  and a two-pixel position indicator communicates long-document progress.
- **Toggle:** the authored Pages icon remains in the folio bar. Ultramarine icon
  and underline mean open; a neutral icon means collapsed. The `S` shortcut
  exposes the same action without pointer input.

### Tool Tabs

- **Shape:** two flat 60px rows sharing a quiet baseline.
- **Selected state:** ultramarine icon, label, and two-pixel underline.
- **Unselected state:** graphite icon and label on warm paper.

### Ink Swatches

- **Shape:** 38px resting circles; the selected swatch gains a 44px
  ultramarine ring with a paper gap.
- **State:** hover adds a temporary graphite ring. The color itself remains
  visible and never relies on a text-only state.

### Width Controls

- **Shape:** three square 58px controls with real 1px, 3px, and 7px previews.
- **Selected state:** a one-pixel ultramarine outline.

### Annotation Actions

- **Rows:** 44px for Undo and Clear page; 48px for Done.
- **Color:** graphite for reversible editing, coral for Clear page,
  ultramarine for Done, and saved green for local persistence.

## Do's and Don'ts

### Do:

- **Do** keep the PDF as the largest and quietest surface.
- **Do** pair unfamiliar annotation icons with direct labels.
- **Do** make active tool, color, width, and save state visible at a glance.
- **Do** preserve 44px or larger pointer targets at every supported width.
- **Do** let readers scan and jump through long documents without losing the
  current page until they select a preview.

### Don't:

- **Don't** turn the annotation margin into a permanent heavy sidebar.
- **Don't** use color decoratively or weaken the coral destructive state.
- **Don't** introduce rounded cards, drop shadows, gradients, or glass.
- **Don't** replace authored icons with Unicode glyphs or emoji.
