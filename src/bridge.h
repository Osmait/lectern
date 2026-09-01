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
 *
 * Threading: every function takes the main thread unless noted. Rendering a
 * page to a LECTERN_Image needs no context and may run on a worker thread; the
 * image becomes a texture on the main thread. A document must be used by one
 * thread at a time.
 */

typedef struct LECTERN_Context LECTERN_Context;
typedef struct LECTERN_Document LECTERN_Document;
typedef struct LECTERN_Texture LECTERN_Texture;
/* A rasterized page that has not been uploaded to the window yet. */
typedef struct LECTERN_Image LECTERN_Image;

enum {
    LECTERN_INPUT_NONE = 0,
    LECTERN_INPUT_QUIT,
    LECTERN_INPUT_KEY_DOWN,
    LECTERN_INPUT_MOUSE_DOWN,
    LECTERN_INPUT_MOUSE_UP,
    LECTERN_INPUT_MOUSE_MOTION,
    LECTERN_INPUT_MOUSE_WHEEL,
    LECTERN_INPUT_FILE,
    LECTERN_INPUT_DIALOG_CLOSED,
    LECTERN_INPUT_WINDOW,
    LECTERN_INPUT_MOUSE_LEAVE,
    LECTERN_INPUT_RENDER_READY
};

/* Keys the reader reacts to. Navigation keys are matched by physical position
 * so they work on every keyboard layout; letters use the layout keycode. */
enum {
    LECTERN_KEY_NONE = 0,
    LECTERN_KEY_ESCAPE,
    LECTERN_KEY_LEFT,
    LECTERN_KEY_RIGHT,
    LECTERN_KEY_PAGE_UP,
    LECTERN_KEY_PAGE_DOWN,
    LECTERN_KEY_SPACE,
    LECTERN_KEY_COMMA,
    LECTERN_KEY_PERIOD,
    LECTERN_KEY_HOME,
    LECTERN_KEY_END,
    LECTERN_KEY_PLUS,
    LECTERN_KEY_MINUS,
    LECTERN_KEY_ZERO,
    LECTERN_KEY_B,
    LECTERN_KEY_C,
    LECTERN_KEY_D,
    LECTERN_KEY_E,
    LECTERN_KEY_J,
    LECTERN_KEY_N,
    LECTERN_KEY_O,
    LECTERN_KEY_P,
    LECTERN_KEY_S,
    LECTERN_KEY_T,
    LECTERN_KEY_U,
    LECTERN_KEY_X
};

enum {
    LECTERN_BUTTON_NONE = 0,
    LECTERN_BUTTON_LEFT,
    LECTERN_BUTTON_OTHER
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
} LECTERN_Input;

typedef struct {
    float x;
    float y;
} LECTERN_Point;

typedef struct {
    float x;
    float y;
    float w;
    float h;
} LECTERN_Rect;

typedef struct {
    uint8_t r;
    uint8_t g;
    uint8_t b;
    uint8_t a;
} LECTERN_Color;

/* A vertex color, in SDL's layout so meshes are drawn without conversion. */
typedef struct {
    float r;
    float g;
    float b;
    float a;
} LECTERN_FColor;

enum {
    LECTERN_ICON_OPEN = 0,
    LECTERN_ICON_PREVIOUS,
    LECTERN_ICON_NEXT,
    LECTERN_ICON_BOOKMARK,
    LECTERN_ICON_JUMP,
    LECTERN_ICON_THEME,
    LECTERN_ICON_MINUS,
    LECTERN_ICON_PLUS,
    LECTERN_ICON_RESET,
    LECTERN_ICON_PEN,
    LECTERN_ICON_ERASER,
    LECTERN_ICON_UNDO,
    LECTERN_ICON_CLEAR,
    LECTERN_ICON_DONE,
    LECTERN_ICON_PAGES,
    LECTERN_ICON_CLOSE,
    LECTERN_ICON_SAVED,
    LECTERN_ICON_ALERT
};

#define LECTERN_ICON_SIZE 40

/* The Zig layout mirrors these; the platform adapter checks them. */
#define LECTERN_DEFAULT_WINDOW_WIDTH 1100
#define LECTERN_DEFAULT_WINDOW_HEIGHT 820
#define LECTERN_MINIMUM_WINDOW_WIDTH 900
#define LECTERN_MINIMUM_WINDOW_HEIGHT 600
/* Hard limit on a rasterized page side; the Zig display policy stays below. */
#define LECTERN_MAXIMUM_PAGE_PIXELS 8192

LECTERN_Context *lectern_init(char **error_message);
void lectern_shutdown(LECTERN_Context *context);
const char *lectern_last_error(const LECTERN_Context *context);
void lectern_free(void *memory);
uint64_t lectern_ticks_ms(void);

int lectern_poll_input(LECTERN_Context *context, LECTERN_Input *input);
/* A negative timeout waits until an event arrives. */
int lectern_wait_input(LECTERN_Context *context, int timeout_ms, LECTERN_Input *input);
/* Ends a wait from any thread with a LECTERN_INPUT_RENDER_READY event. */
void lectern_wake(void);

void lectern_window_size(const LECTERN_Context *context, float *width, float *height);
uint32_t lectern_window_id(const LECTERN_Context *context);
float lectern_pixel_density(const LECTERN_Context *context);
int lectern_set_window_size(LECTERN_Context *context, int width, int height);
void lectern_set_title(LECTERN_Context *context, const char *title);
void lectern_show_error(LECTERN_Context *context, const char *message);
void lectern_open_dialog(LECTERN_Context *context);
int lectern_save_screenshot(LECTERN_Context *context, const char *path);

void lectern_frame_begin(LECTERN_Context *context,
                    LECTERN_Color clear_color,
                    float *width,
                    float *height,
                    float *density);
void lectern_frame_end(LECTERN_Context *context);
/* Consecutive rectangles are collected and drawn as one triangle list; any
 * other drawing command, a clip change, or the end of the frame draws the
 * collected ones first, so the painter's order is kept. */
void lectern_fill_rect(LECTERN_Context *context, LECTERN_Rect rect, LECTERN_Color color);
void lectern_stroke_rect(LECTERN_Context *context, LECTERN_Rect rect, LECTERN_Color color);
void lectern_set_clip(LECTERN_Context *context, const LECTERN_Rect *rect);
void lectern_draw_texture(LECTERN_Context *context,
                     LECTERN_Texture *texture,
                     LECTERN_Rect destination,
                     LECTERN_Color tint);
/* One color per point; the arrays are handed to SDL as they are. */
void lectern_draw_triangles(LECTERN_Context *context,
                       const LECTERN_Point *points,
                       const LECTERN_FColor *colors,
                       size_t point_count,
                       const int *indices,
                       size_t index_count);

LECTERN_Texture *lectern_create_text(LECTERN_Context *context,
                           const char *text,
                           int size,
                           int strong,
                           float *logical_width,
                           float *logical_height);
float lectern_measure_text(LECTERN_Context *context, const char *text, int size, int strong);
LECTERN_Texture *lectern_create_icon(LECTERN_Context *context, int icon, LECTERN_Color color);
LECTERN_Texture *lectern_texture_from_image(LECTERN_Context *context, const LECTERN_Image *image);
void lectern_texture_size(const LECTERN_Texture *texture, int *width, int *height);
void lectern_texture_destroy(LECTERN_Texture *texture);

LECTERN_Document *lectern_pdf_open(LECTERN_Context *context, const char *path);
void lectern_pdf_close(LECTERN_Document *document);
const char *lectern_pdf_path(const LECTERN_Document *document);
/* Unique for every open, unlike the address of the handle. */
uint64_t lectern_pdf_identity(const LECTERN_Document *document);
int lectern_pdf_page_count(const LECTERN_Document *document);
int lectern_pdf_page_size(const LECTERN_Document *document,
                     int page_index,
                     float *width,
                     float *height);
/* Rasterizes on the calling thread without touching any context; returns
 * NULL when the page or the requested size is invalid. */
LECTERN_Image *lectern_pdf_render_image(const LECTERN_Document *document,
                              int page_index,
                              float scale,
                              int dark_mode);
void lectern_image_destroy(LECTERN_Image *image);
/* Rasterizes and uploads in one step on the main thread. */
LECTERN_Texture *lectern_pdf_render(LECTERN_Context *context,
                          const LECTERN_Document *document,
                          int page_index,
                          float scale,
                          int dark_mode);
