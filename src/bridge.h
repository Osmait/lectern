#pragma once

#include <stddef.h>
#include <stdint.h>

/*
 * Narrow native bridge over SDL3, Poppler GLib, and Cairo.
 *
 * The bridge only exposes primitives: raw input events, window queries,
 * drawing commands, texture creation, and PDF rasterization. Everything that
 * gives those primitives meaning (layout, hit testing, theming, caches, and
 * persistence) lives in Zig where it can be unit tested without a display.
 */

typedef struct BR_Context BR_Context;
typedef struct BR_Document BR_Document;
typedef struct BR_Texture BR_Texture;

enum {
    BR_INPUT_NONE = 0,
    BR_INPUT_QUIT,
    BR_INPUT_KEY_DOWN,
    BR_INPUT_MOUSE_DOWN,
    BR_INPUT_MOUSE_UP,
    BR_INPUT_MOUSE_MOTION,
    BR_INPUT_MOUSE_WHEEL,
    BR_INPUT_FILE,
    BR_INPUT_DIALOG_CLOSED,
    BR_INPUT_WINDOW
};

/* Keys the reader reacts to. Navigation keys are matched by physical position
 * so they work on every keyboard layout; letters use the layout keycode. */
enum {
    BR_KEY_NONE = 0,
    BR_KEY_ESCAPE,
    BR_KEY_LEFT,
    BR_KEY_RIGHT,
    BR_KEY_PAGE_UP,
    BR_KEY_PAGE_DOWN,
    BR_KEY_SPACE,
    BR_KEY_COMMA,
    BR_KEY_PERIOD,
    BR_KEY_HOME,
    BR_KEY_END,
    BR_KEY_PLUS,
    BR_KEY_MINUS,
    BR_KEY_ZERO,
    BR_KEY_B,
    BR_KEY_C,
    BR_KEY_D,
    BR_KEY_E,
    BR_KEY_J,
    BR_KEY_N,
    BR_KEY_O,
    BR_KEY_P,
    BR_KEY_S,
    BR_KEY_T,
    BR_KEY_U,
    BR_KEY_X
};

enum {
    BR_BUTTON_NONE = 0,
    BR_BUTTON_LEFT,
    BR_BUTTON_OTHER
};

typedef struct {
    int kind;
    float x;
    float y;
    float wheel;
    int key;
    int button;
    int left_held;
    char *path;
} BR_Input;

typedef struct {
    float x;
    float y;
} BR_Point;

typedef struct {
    float x;
    float y;
    float w;
    float h;
} BR_Rect;

typedef struct {
    uint8_t r;
    uint8_t g;
    uint8_t b;
    uint8_t a;
} BR_Color;

enum {
    BR_ICON_OPEN = 0,
    BR_ICON_PREVIOUS,
    BR_ICON_NEXT,
    BR_ICON_BOOKMARK,
    BR_ICON_JUMP,
    BR_ICON_THEME,
    BR_ICON_MINUS,
    BR_ICON_PLUS,
    BR_ICON_RESET,
    BR_ICON_PEN,
    BR_ICON_ERASER,
    BR_ICON_UNDO,
    BR_ICON_CLEAR,
    BR_ICON_DONE,
    BR_ICON_PAGES,
    BR_ICON_CLOSE,
    BR_ICON_SAVED,
    BR_ICON_ALERT
};

#define BR_ICON_SIZE 40

BR_Context *br_init(char **error_message);
void br_shutdown(BR_Context *context);
const char *br_last_error(const BR_Context *context);
void br_free(void *memory);
uint64_t br_ticks_ms(void);

int br_poll_input(BR_Context *context, BR_Input *input);
int br_wait_input(BR_Context *context, int timeout_ms, BR_Input *input);

void br_window_size(const BR_Context *context, float *width, float *height);
uint32_t br_window_id(const BR_Context *context);
float br_pixel_density(const BR_Context *context);
int br_set_window_size(BR_Context *context, int width, int height);
void br_set_title(BR_Context *context, const char *title);
void br_show_error(BR_Context *context, const char *message);
void br_open_dialog(BR_Context *context);
int br_save_screenshot(BR_Context *context, const char *path);

void br_frame_begin(BR_Context *context,
                    BR_Color clear_color,
                    float *width,
                    float *height,
                    float *density);
void br_frame_end(BR_Context *context);
void br_fill_rect(BR_Context *context, BR_Rect rect, BR_Color color);
void br_stroke_rect(BR_Context *context, BR_Rect rect, BR_Color color);
void br_set_clip(BR_Context *context, const BR_Rect *rect);
void br_draw_texture(BR_Context *context,
                     BR_Texture *texture,
                     BR_Rect destination,
                     BR_Color tint);
void br_draw_triangles(BR_Context *context,
                       const BR_Point *points,
                       size_t point_count,
                       const int *indices,
                       size_t index_count,
                       BR_Color color);

BR_Texture *br_create_text(BR_Context *context,
                           const char *text,
                           int size,
                           int strong,
                           float *logical_width,
                           float *logical_height);
float br_measure_text(BR_Context *context, const char *text, int size, int strong);
BR_Texture *br_create_icon(BR_Context *context, int icon, BR_Color color);
void br_texture_size(const BR_Texture *texture, int *width, int *height);
void br_texture_destroy(BR_Texture *texture);

BR_Document *br_pdf_open(BR_Context *context, const char *path);
void br_pdf_close(BR_Document *document);
const char *br_pdf_path(const BR_Document *document);
int br_pdf_page_count(const BR_Document *document);
int br_pdf_page_size(const BR_Document *document,
                     int page_index,
                     float *width,
                     float *height);
BR_Texture *br_pdf_render(BR_Context *context,
                          const BR_Document *document,
                          int page_index,
                          float scale,
                          int dark_mode);
