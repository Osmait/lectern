//! Typed user commands. Input translation produces them and the application
//! executes them, so neither side needs to know about SDL or window geometry.

const annotations = @import("book_read").annotations;

pub const Command = union(enum) {
    quit,
    redraw,
    next_page,
    previous_page,
    first_page,
    last_page,
    select_page: usize,
    jump_bookmark,
    toggle_bookmark,
    toggle_dark_mode,
    toggle_pages,
    scroll_thumbnails: f32,
    open_dialog,
    dialog_closed,
    /// The path is borrowed from the raw input that produced the command.
    open_path: []const u8,
    zoom_in,
    zoom_out,
    zoom_reset,
    pen,
    eraser,
    notes_off,
    cycle_color,
    cycle_size,
    select_color: annotations.Color,
    select_size: annotations.PenSize,
    note_undo,
    note_clear,
    draw_begin: annotations.Point,
    draw_move: annotations.Point,
    draw_end,
};
