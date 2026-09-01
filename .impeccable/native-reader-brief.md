# Native reader surface

Scope: the Linux desktop reading window implemented across `src/bridge.c`,
`src/platform.zig`, and `src/application.zig`.

Mode: Operate.

Audience and task: focused readers navigating and annotating long PDFs with
keyboard and mouse while keeping the source file untouched.

Constraints: preserve all existing behavior, local persistence, light and dark
reading modes, native performance, and current automated test contracts.

## Direction contract

THESIS: The annotation margin extends the paper only when needed; refuse the
permanent heavy control sidebar.

OWN-WORLD: Linen-dark shell, warm paper, graphite hairlines, ultramarine active
ink, coral destructive state, thin icons, and clearly projected selections.

STORY: The reader sees the document first, enters annotation mode without
losing place, chooses ink confidently, writes, and sees local save confirmation.

FIRST VIEWPORT: A 56px dark folio bar sits above an almost full-height PDF; a
200px light margin folds from its right edge and carries the Done action.

FORM: Scholar's Margin, grounded candidate 1, fold-out composition; seed
affce247.

FINISH: unreviewed and undocumented is unfinished; this build ends with the
finish review, the verdict, DESIGN.md, and every shipping raster carrying its
provenance.

Unresolved: the closest available native UI typeface may differ from the comp.
