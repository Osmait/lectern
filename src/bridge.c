#define _XOPEN_SOURCE 700
#include "bridge.h"

#include <SDL3/SDL.h>
#include <cairo/cairo.h>
#include <glib.h>
#include <limits.h>
#include <glib-object.h>
#include <poppler/glib/poppler.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BR_FONT_FAMILY "Noto Sans"

/* Codes of the SDL user events the bridge posts to itself. */
enum {
    BR_USER_EVENT_DIALOG = 0,
    BR_USER_EVENT_WAKE = 1
};

struct BR_Context {
    SDL_Window *window;
    SDL_Renderer *renderer;
    float pixel_density;
    char *last_error;
    cairo_surface_t *measure_surface;
    cairo_t *measure;
    cairo_font_options_t *font_options;
    /* Rectangles waiting to be drawn as one triangle list. */
    BR_Point *quad_points;
    BR_FColor *quad_colors;
    int *quad_indices;
    size_t quad_count;
    size_t quad_capacity;
};

struct BR_Document {
    PopplerDocument *document;
    char *path;
    uint64_t serial;
};

struct BR_Image {
    cairo_surface_t *surface;
    int width;
    int height;
};


struct BR_Texture {
    SDL_Texture *texture;
    int width;
    int height;
    /* The tint last applied, so repeated draws skip two SDL calls. */
    BR_Color tint;
    int tint_known;
};

static void flush_quads(BR_Context *context);

static char *copy_string(const char *text) {
    return strdup(text ? text : "Unknown native error");
}

static void set_error(BR_Context *context, const char *message) {
    if (!context) return;
    free(context->last_error);
    context->last_error = copy_string(message);
}

const char *br_last_error(const BR_Context *context) {
    return context && context->last_error ? context->last_error : "";
}

void br_free(void *memory) {
    free(memory);
}

uint64_t br_ticks_ms(void) {
    return SDL_GetTicks();
}

static void configure_font(cairo_t *cr,
                           const cairo_font_options_t *font_options,
                           int size,
                           int strong) {
    cairo_select_font_face(cr, BR_FONT_FAMILY, CAIRO_FONT_SLANT_NORMAL,
                           strong ? CAIRO_FONT_WEIGHT_BOLD
                                  : CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_options(cr, font_options);
    cairo_set_font_size(cr, size);
}

BR_Context *br_init(char **error_message) {
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        if (error_message) *error_message = copy_string(SDL_GetError());
        return NULL;
    }

    BR_Context *context = calloc(1, sizeof(*context));
    if (!context || !SDL_CreateWindowAndRenderer(
            "Book Read", BR_DEFAULT_WINDOW_WIDTH, BR_DEFAULT_WINDOW_HEIGHT,
            SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY,
            &context->window, &context->renderer)) {
        if (error_message) {
            *error_message = copy_string(context ? SDL_GetError() : "Out of memory.");
        }
        free(context);
        SDL_Quit();
        return NULL;
    }
    context->pixel_density = 1.0f;
    SDL_SetWindowMinimumSize(context->window,
                             BR_MINIMUM_WINDOW_WIDTH, BR_MINIMUM_WINDOW_HEIGHT);
    /* Presenting waits for the display instead of spinning the CPU. */
    SDL_SetRenderVSync(context->renderer, 1);

    context->font_options = cairo_font_options_create();
    cairo_font_options_set_antialias(context->font_options, CAIRO_ANTIALIAS_GRAY);
    cairo_font_options_set_hint_style(context->font_options, CAIRO_HINT_STYLE_FULL);
    cairo_font_options_set_hint_metrics(context->font_options, CAIRO_HINT_METRICS_ON);
    context->measure_surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
    context->measure = cairo_create(context->measure_surface);
    return context;
}

void br_shutdown(BR_Context *context) {
    if (!context) return;
    cairo_destroy(context->measure);
    cairo_surface_destroy(context->measure_surface);
    cairo_font_options_destroy(context->font_options);
    free(context->quad_points);
    free(context->quad_colors);
    free(context->quad_indices);
    free(context->last_error);
    SDL_DestroyRenderer(context->renderer);
    SDL_DestroyWindow(context->window);
    free(context);
    SDL_Quit();
}

/* ---------------------------------------------------------------- input */

static void SDLCALL dialog_callback(void *userdata,
                                    const char *const *files,
                                    int filter) {
    (void)userdata;
    (void)filter;
    SDL_Event event;
    SDL_zero(event);
    event.type = SDL_EVENT_USER;
    event.user.code = BR_USER_EVENT_DIALOG;
    event.user.data1 = (files && files[0]) ? strdup(files[0]) : NULL;
    if (!SDL_PushEvent(&event)) free(event.user.data1);
}

void br_wake(void) {
    SDL_Event event;
    SDL_zero(event);
    event.type = SDL_EVENT_USER;
    event.user.code = BR_USER_EVENT_WAKE;
    /* Pushing events is one of the few SDL calls allowed from any thread. */
    SDL_PushEvent(&event);
}

void br_open_dialog(BR_Context *context) {
    if (!context) return;
    static const SDL_DialogFileFilter filters[] = {{"PDF books", "pdf"}};
    SDL_ShowOpenFileDialog(dialog_callback, NULL, context->window,
                           filters, 1, NULL, false);
}

static int key_from_event(const SDL_KeyboardEvent *keyboard) {
    switch (keyboard->scancode) {
        case SDL_SCANCODE_ESCAPE: return BR_KEY_ESCAPE;
        case SDL_SCANCODE_LEFT: return BR_KEY_LEFT;
        case SDL_SCANCODE_RIGHT: return BR_KEY_RIGHT;
        case SDL_SCANCODE_PAGEUP: return BR_KEY_PAGE_UP;
        case SDL_SCANCODE_PAGEDOWN: return BR_KEY_PAGE_DOWN;
        case SDL_SCANCODE_SPACE: return BR_KEY_SPACE;
        case SDL_SCANCODE_COMMA: return BR_KEY_COMMA;
        case SDL_SCANCODE_PERIOD: return BR_KEY_PERIOD;
        case SDL_SCANCODE_HOME: return BR_KEY_HOME;
        case SDL_SCANCODE_END: return BR_KEY_END;
        default: break;
    }
    switch (keyboard->key) {
        case SDLK_PLUS:
        case SDLK_EQUALS: return BR_KEY_PLUS;
        case SDLK_MINUS: return BR_KEY_MINUS;
        case SDLK_0: return BR_KEY_ZERO;
        case SDLK_B: return BR_KEY_B;
        case SDLK_C: return BR_KEY_C;
        case SDLK_D: return BR_KEY_D;
        case SDLK_E: return BR_KEY_E;
        case SDLK_J: return BR_KEY_J;
        case SDLK_N: return BR_KEY_N;
        case SDLK_O: return BR_KEY_O;
        case SDLK_P: return BR_KEY_P;
        case SDLK_S: return BR_KEY_S;
        case SDLK_T: return BR_KEY_T;
        case SDLK_U: return BR_KEY_U;
        case SDLK_X: return BR_KEY_X;
        default: return BR_KEY_NONE;
    }
}

static int button_from_event(const SDL_MouseButtonEvent *button) {
    return button->button == SDL_BUTTON_LEFT ? BR_BUTTON_LEFT : BR_BUTTON_OTHER;
}

static void translate_event(const SDL_Event *event, BR_Input *input) {
    memset(input, 0, sizeof(*input));
    switch (event->type) {
        case SDL_EVENT_QUIT:
            input->kind = BR_INPUT_QUIT;
            break;
        case SDL_EVENT_KEY_DOWN:
            input->kind = BR_INPUT_KEY_DOWN;
            input->key = key_from_event(&event->key);
            break;
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
        case SDL_EVENT_MOUSE_BUTTON_UP:
            input->kind = event->type == SDL_EVENT_MOUSE_BUTTON_DOWN
                ? BR_INPUT_MOUSE_DOWN : BR_INPUT_MOUSE_UP;
            input->x = event->button.x;
            input->y = event->button.y;
            input->button = button_from_event(&event->button);
            break;
        case SDL_EVENT_MOUSE_MOTION:
            input->kind = BR_INPUT_MOUSE_MOTION;
            input->x = event->motion.x;
            input->y = event->motion.y;
            input->left_held = (event->motion.state & SDL_BUTTON_LMASK) != 0;
            break;
        case SDL_EVENT_MOUSE_WHEEL:
            input->kind = BR_INPUT_MOUSE_WHEEL;
            input->x = event->wheel.mouse_x;
            input->y = event->wheel.mouse_y;
            input->wheel = event->wheel.direction == SDL_MOUSEWHEEL_FLIPPED
                ? -event->wheel.y : event->wheel.y;
            break;
        case SDL_EVENT_DROP_FILE:
            if (event->drop.data) {
                input->kind = BR_INPUT_FILE;
                input->path = strdup(event->drop.data);
            }
            break;
        case SDL_EVENT_USER:
            if (event->user.code == BR_USER_EVENT_WAKE) {
                input->kind = BR_INPUT_RENDER_READY;
                break;
            }
            input->kind = event->user.data1 ? BR_INPUT_FILE : BR_INPUT_DIALOG_CLOSED;
            input->path = event->user.data1;
            break;
        case SDL_EVENT_WINDOW_MOUSE_LEAVE:
            input->kind = BR_INPUT_MOUSE_LEAVE;
            break;
        case SDL_EVENT_WINDOW_RESIZED:
        case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
        case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
        case SDL_EVENT_WINDOW_EXPOSED:
        case SDL_EVENT_WINDOW_SHOWN:
        case SDL_EVENT_WINDOW_RESTORED:
        case SDL_EVENT_WINDOW_MAXIMIZED:
        case SDL_EVENT_WINDOW_MOUSE_ENTER:
            input->kind = BR_INPUT_WINDOW;
            break;
        default:
            input->kind = BR_INPUT_NONE;
            break;
    }
}

int br_poll_input(BR_Context *context, BR_Input *input) {
    (void)context;
    SDL_Event event;
    if (!SDL_PollEvent(&event)) return 0;
    translate_event(&event, input);
    return 1;
}

int br_wait_input(BR_Context *context, int timeout_ms, BR_Input *input) {
    (void)context;
    SDL_Event event;
    if (!SDL_WaitEventTimeout(&event, timeout_ms)) return 0;
    translate_event(&event, input);
    return 1;
}

/* --------------------------------------------------------------- window */

static float clamp_float(float value, float minimum, float maximum) {
    if (value < minimum) return minimum;
    if (value > maximum) return maximum;
    return value;
}

static float density_from_sizes(int logical_width,
                                int logical_height,
                                int pixel_width,
                                int pixel_height) {
    if (logical_width <= 0 || logical_height <= 0 ||
        pixel_width <= 0 || pixel_height <= 0) return 1.0f;
    const float scale_x = (float)pixel_width / logical_width;
    const float scale_y = (float)pixel_height / logical_height;
    return clamp_float(scale_x < scale_y ? scale_x : scale_y, 1.0f, 4.0f);
}

static void update_render_density(BR_Context *context) {
    int logical_width = 0, logical_height = 0;
    int pixel_width = 0, pixel_height = 0;
    SDL_GetWindowSize(context->window, &logical_width, &logical_height);
    SDL_GetRenderOutputSize(context->renderer, &pixel_width, &pixel_height);
    context->pixel_density = density_from_sizes(
        logical_width, logical_height, pixel_width, pixel_height);
    SDL_SetRenderScale(context->renderer,
                       context->pixel_density, context->pixel_density);
}

void br_window_size(const BR_Context *context, float *width, float *height) {
    int logical_width = 0, logical_height = 0;
    SDL_GetWindowSize(context->window, &logical_width, &logical_height);
    *width = (float)logical_width;
    *height = (float)logical_height;
}

uint32_t br_window_id(const BR_Context *context) {
    return SDL_GetWindowID(context->window);
}

float br_pixel_density(const BR_Context *context) {
    return context->pixel_density;
}

int br_set_window_size(BR_Context *context, int width, int height) {
    return SDL_SetWindowSize(context->window, width, height);
}

void br_set_title(BR_Context *context, const char *title) {
    SDL_SetWindowTitle(context->window, title);
}

void br_show_error(BR_Context *context, const char *message) {
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "Book Read", message,
                             context ? context->window : NULL);
}

int br_save_screenshot(BR_Context *context, const char *path) {
    flush_quads(context);
    SDL_Surface *surface = SDL_RenderReadPixels(context->renderer, NULL);
    if (!surface) return 0;
    const int saved = SDL_SaveBMP(surface, path);
    SDL_DestroySurface(surface);
    return saved;
}

/* -------------------------------------------------------------- drawing */

static void set_color(SDL_Renderer *renderer, BR_Color color) {
    SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);
}

static SDL_FRect to_sdl_rect(BR_Rect rect) {
    return (SDL_FRect){rect.x, rect.y, rect.w, rect.h};
}

static SDL_FColor float_color(BR_Color color) {
    const SDL_FColor result = {
        color.r / 255.0f, color.g / 255.0f, color.b / 255.0f, color.a / 255.0f
    };
    return result;
}

/* The pending rectangles become one geometry command. */
static void flush_quads(BR_Context *context) {
    if (context->quad_count == 0) return;
    static const float shared_uv[2] = {0.0f, 0.0f};
    SDL_SetRenderDrawBlendMode(context->renderer, SDL_BLENDMODE_BLEND);
    SDL_RenderGeometryRaw(context->renderer, NULL,
                          (const float *)context->quad_points, (int)sizeof(BR_Point),
                          (const SDL_FColor *)context->quad_colors, (int)sizeof(BR_FColor),
                          shared_uv, 0,
                          (int)(context->quad_count * 4),
                          context->quad_indices, (int)(context->quad_count * 6),
                          (int)sizeof(int));
    context->quad_count = 0;
}

static int reserve_quads(BR_Context *context, size_t needed) {
    if (context->quad_capacity >= needed) return 1;
    size_t capacity = context->quad_capacity ? context->quad_capacity : 64;
    while (capacity < needed) capacity *= 2;
    BR_Point *points = realloc(context->quad_points, capacity * 4 * sizeof(*points));
    if (!points) return 0;
    context->quad_points = points;
    BR_FColor *colors = realloc(context->quad_colors, capacity * 4 * sizeof(*colors));
    if (!colors) return 0;
    context->quad_colors = colors;
    int *indices = realloc(context->quad_indices, capacity * 6 * sizeof(*indices));
    if (!indices) return 0;
    context->quad_indices = indices;
    context->quad_capacity = capacity;
    return 1;
}

static void queue_quad(BR_Context *context, float x, float y, float w, float h, BR_Color color) {
    if (w <= 0 || h <= 0) return;
    if (context->quad_count * 4 + 4 > INT_MAX / 2 ||
        !reserve_quads(context, context->quad_count + 1)) {
        /* Out of memory: draw what is queued and this one directly. */
        flush_quads(context);
        const SDL_FRect sdl_rect = {x, y, w, h};
        set_color(context->renderer, color);
        SDL_RenderFillRect(context->renderer, &sdl_rect);
        return;
    }
    const size_t base = context->quad_count * 4;
    BR_Point *points = context->quad_points + base;
    points[0].x = x; points[0].y = y;
    points[1].x = x + w; points[1].y = y;
    points[2].x = x + w; points[2].y = y + h;
    points[3].x = x; points[3].y = y + h;
    const SDL_FColor fill = float_color(color);
    for (size_t corner = 0; corner < 4; ++corner) {
        context->quad_colors[base + corner].r = fill.r;
        context->quad_colors[base + corner].g = fill.g;
        context->quad_colors[base + corner].b = fill.b;
        context->quad_colors[base + corner].a = fill.a;
    }
    int *indices = context->quad_indices + context->quad_count * 6;
    const int first = (int)base;
    indices[0] = first; indices[1] = first + 1; indices[2] = first + 2;
    indices[3] = first; indices[4] = first + 2; indices[5] = first + 3;
    context->quad_count += 1;
}

void br_frame_begin(BR_Context *context,
                    BR_Color clear_color,
                    float *width,
                    float *height,
                    float *density) {
    update_render_density(context);
    br_window_size(context, width, height);
    *density = context->pixel_density;
    context->quad_count = 0;
    SDL_SetRenderDrawBlendMode(context->renderer, SDL_BLENDMODE_BLEND);
    set_color(context->renderer, clear_color);
    SDL_RenderClear(context->renderer);
}

void br_frame_end(BR_Context *context) {
    flush_quads(context);
    SDL_RenderPresent(context->renderer);
}

void br_fill_rect(BR_Context *context, BR_Rect rect, BR_Color color) {
    queue_quad(context, rect.x, rect.y, rect.w, rect.h, color);
}

/* The outline covers the same pixels SDL_RenderRect would: one pixel wide,
 * inside the rectangle. */
void br_stroke_rect(BR_Context *context, BR_Rect rect, BR_Color color) {
    if (rect.w < 1 || rect.h < 1) return;
    queue_quad(context, rect.x, rect.y, rect.w, 1, color);
    queue_quad(context, rect.x, rect.y + rect.h - 1, rect.w, 1, color);
    if (rect.h <= 2) return;
    queue_quad(context, rect.x, rect.y + 1, 1, rect.h - 2, color);
    queue_quad(context, rect.x + rect.w - 1, rect.y + 1, 1, rect.h - 2, color);
}

void br_set_clip(BR_Context *context, const BR_Rect *rect) {
    flush_quads(context);
    if (!rect) {
        SDL_SetRenderClipRect(context->renderer, NULL);
        return;
    }
    const SDL_Rect clip = {(int)rect->x, (int)rect->y, (int)rect->w, (int)rect->h};
    SDL_SetRenderClipRect(context->renderer, &clip);
}

void br_draw_texture(BR_Context *context,
                     BR_Texture *texture,
                     BR_Rect destination,
                     BR_Color tint) {
    if (!texture) return;
    flush_quads(context);
    const SDL_FRect sdl_rect = to_sdl_rect(destination);
    if (!texture->tint_known || texture->tint.r != tint.r || texture->tint.g != tint.g ||
        texture->tint.b != tint.b || texture->tint.a != tint.a) {
        SDL_SetTextureColorMod(texture->texture, tint.r, tint.g, tint.b);
        SDL_SetTextureAlphaMod(texture->texture, tint.a);
        texture->tint = tint;
        texture->tint_known = 1;
    }
    SDL_RenderTexture(context->renderer, texture->texture, NULL, &sdl_rect);
}

void br_draw_triangles(BR_Context *context,
                       const BR_Point *points,
                       const BR_FColor *colors,
                       size_t point_count,
                       const int *indices,
                       size_t index_count) {
    if (point_count == 0 || index_count == 0 || point_count > INT_MAX ||
        index_count > INT_MAX) return;
    flush_quads(context);
    static const float shared_uv[2] = {0.0f, 0.0f};
    SDL_SetRenderDrawBlendMode(context->renderer, SDL_BLENDMODE_BLEND);
    SDL_RenderGeometryRaw(context->renderer, NULL,
                          (const float *)points, (int)sizeof(*points),
                          (const SDL_FColor *)colors, (int)sizeof(*colors),
                          shared_uv, 0,
                          (int)point_count, indices, (int)index_count,
                          (int)sizeof(*indices));
}

/* ------------------------------------------------------------- textures */

static BR_Texture *texture_from_surface(BR_Context *context,
                                        cairo_surface_t *surface,
                                        int width,
                                        int height) {
    cairo_surface_flush(surface);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        set_error(context, "Could not rasterize the image.");
        return NULL;
    }
    SDL_Texture *sdl_texture = SDL_CreateTexture(
        context->renderer, SDL_PIXELFORMAT_ARGB8888,
        SDL_TEXTUREACCESS_STATIC, width, height);
    if (!sdl_texture || !SDL_UpdateTexture(
            sdl_texture, NULL, cairo_image_surface_get_data(surface),
            cairo_image_surface_get_stride(surface))) {
        set_error(context, SDL_GetError());
        if (sdl_texture) SDL_DestroyTexture(sdl_texture);
        return NULL;
    }
    BR_Texture *texture = malloc(sizeof(*texture));
    if (!texture) {
        set_error(context, "Out of memory.");
        SDL_DestroyTexture(sdl_texture);
        return NULL;
    }
    texture->texture = sdl_texture;
    texture->width = width;
    texture->height = height;
    texture->tint_known = 0;
    return texture;
}

static int logical_text_width(const cairo_text_extents_t *extents) {
    return (int)(extents->x_advance + 8.999);
}

BR_Texture *br_create_text(BR_Context *context,
                           const char *text,
                           int size,
                           int strong,
                           float *logical_width,
                           float *logical_height) {
    configure_font(context->measure, context->font_options, size, strong);
    cairo_text_extents_t text_extents;
    cairo_font_extents_t font_extents;
    cairo_text_extents(context->measure, text, &text_extents);
    cairo_font_extents(context->measure, &font_extents);
    const int width = logical_text_width(&text_extents);
    const int height = (int)(font_extents.height + 6.999);
    const float density = context->pixel_density;
    const int pixel_width = (int)(width * density + 0.999f);
    const int pixel_height = (int)(height * density + 0.999f);

    cairo_surface_t *surface = cairo_image_surface_create(
        CAIRO_FORMAT_ARGB32, pixel_width, pixel_height);
    cairo_t *cr = cairo_create(surface);
    if (cairo_status(cr) != CAIRO_STATUS_SUCCESS) {
        set_error(context, "Could not allocate the text image.");
        cairo_destroy(cr);
        cairo_surface_destroy(surface);
        return NULL;
    }
    cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
    cairo_set_source_rgba(cr, 0, 0, 0, 0);
    cairo_paint(cr);
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
    cairo_scale(cr, density, density);
    configure_font(cr, context->font_options, size, strong);
    /* Text is rasterized white and tinted at draw time, so one texture serves
     * every color the interface needs. */
    cairo_set_source_rgba(cr, 1, 1, 1, 1);
    cairo_move_to(cr, 4, 3 + font_extents.ascent);
    cairo_show_text(cr, text);

    BR_Texture *texture = texture_from_surface(context, surface,
                                               pixel_width, pixel_height);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    if (!texture) return NULL;
    SDL_SetTextureBlendMode(texture->texture, SDL_BLENDMODE_BLEND_PREMULTIPLIED);
    *logical_width = (float)width;
    *logical_height = (float)height;
    return texture;
}

float br_measure_text(BR_Context *context, const char *text, int size, int strong) {
    configure_font(context->measure, context->font_options, size, strong);
    cairo_text_extents_t extents;
    cairo_text_extents(context->measure, text, &extents);
    return (float)logical_text_width(&extents);
}

static void icon_move(cairo_t *cr, double x, double y) {
    cairo_move_to(cr, 20 + x, 20 + y);
}

static void icon_line(cairo_t *cr, double x, double y) {
    cairo_line_to(cr, 20 + x, 20 + y);
}

static void draw_icon_paths(cairo_t *cr, int icon, BR_Color color) {
    cairo_set_source_rgba(cr, color.r / 255.0, color.g / 255.0,
                          color.b / 255.0, color.a / 255.0);
    cairo_set_line_width(cr, 1.6);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
    switch (icon) {
        case BR_ICON_OPEN:
            icon_move(cr, -9, -5);
            icon_line(cr, -2, -5);
            icon_line(cr, 1, -2);
            icon_line(cr, 9, -2);
            icon_line(cr, 9, 7);
            icon_line(cr, -9, 7);
            cairo_close_path(cr);
            cairo_stroke(cr);
            break;
        case BR_ICON_PREVIOUS:
            icon_move(cr, 5, -8);
            icon_line(cr, -5, 0);
            icon_line(cr, 5, 8);
            cairo_stroke(cr);
            break;
        case BR_ICON_NEXT:
            icon_move(cr, -5, -8);
            icon_line(cr, 5, 0);
            icon_line(cr, -5, 8);
            cairo_stroke(cr);
            break;
        case BR_ICON_BOOKMARK:
            icon_move(cr, -6, -8);
            icon_line(cr, 6, -8);
            icon_line(cr, 6, 8);
            icon_line(cr, 0, 3);
            icon_line(cr, -6, 8);
            cairo_close_path(cr);
            cairo_stroke(cr);
            break;
        case BR_ICON_JUMP:
            icon_move(cr, -8, 0);
            icon_line(cr, 7, 0);
            icon_move(cr, 2, -5);
            icon_line(cr, 7, 0);
            icon_line(cr, 2, 5);
            cairo_stroke(cr);
            break;
        case BR_ICON_THEME:
            cairo_set_source_rgb(cr, 1.0, 0.76, 0.22);
            cairo_arc(cr, 20, 20, 5, 0, 2 * 3.141592653589793);
            cairo_fill(cr);
            cairo_set_line_width(cr, 1.6);
            icon_move(cr, 0, -11);
            icon_line(cr, 0, -8);
            icon_move(cr, 0, 8);
            icon_line(cr, 0, 11);
            icon_move(cr, -11, 0);
            icon_line(cr, -8, 0);
            icon_move(cr, 8, 0);
            icon_line(cr, 11, 0);
            cairo_stroke(cr);
            break;
        case BR_ICON_MINUS:
            icon_move(cr, -7, 0);
            icon_line(cr, 7, 0);
            cairo_stroke(cr);
            break;
        case BR_ICON_PLUS:
            icon_move(cr, -7, 0);
            icon_line(cr, 7, 0);
            icon_move(cr, 0, -7);
            icon_line(cr, 0, 7);
            cairo_stroke(cr);
            break;
        case BR_ICON_RESET:
            icon_move(cr, -2, -5);
            icon_line(cr, -7, -1);
            icon_line(cr, -7, 6);
            icon_line(cr, 6, 6);
            icon_line(cr, 6, -6);
            icon_line(cr, -7, -6);
            cairo_stroke(cr);
            break;
        case BR_ICON_PEN:
            icon_move(cr, -13, 8);
            icon_line(cr, 8, -13);
            icon_line(cr, 13, -8);
            icon_line(cr, -8, 13);
            icon_line(cr, -14, 15);
            icon_line(cr, -13, 8);
            cairo_stroke(cr);
            icon_move(cr, -14, 15);
            icon_line(cr, -5, 10);
            cairo_stroke(cr);
            break;
        case BR_ICON_ERASER:
            icon_move(cr, -13, 6);
            icon_line(cr, 4, -12);
            icon_line(cr, 13, -3);
            icon_line(cr, -4, 13);
            cairo_close_path(cr);
            icon_move(cr, -9, 2);
            icon_line(cr, -1, 9);
            cairo_stroke(cr);
            break;
        case BR_ICON_UNDO:
            icon_move(cr, -2, -7);
            icon_line(cr, -8, -1);
            icon_line(cr, -1, 3);
            icon_move(cr, -7, -1);
            icon_line(cr, 4, -1);
            icon_line(cr, 8, 5);
            cairo_stroke(cr);
            break;
        case BR_ICON_CLEAR:
            cairo_rectangle(cr, 14, 15, 12, 14);
            cairo_stroke(cr);
            icon_move(cr, -8, -7);
            icon_line(cr, 8, -7);
            icon_move(cr, -3, -10);
            icon_line(cr, 3, -10);
            cairo_stroke(cr);
            break;
        case BR_ICON_DONE:
            icon_move(cr, -8, 0);
            icon_line(cr, -2, 6);
            icon_line(cr, 9, -7);
            cairo_stroke(cr);
            break;
        case BR_ICON_PAGES:
            cairo_rectangle(cr, 12, 11, 12, 15);
            cairo_stroke(cr);
            cairo_rectangle(cr, 16, 15, 12, 15);
            cairo_stroke(cr);
            break;
        case BR_ICON_CLOSE:
            icon_move(cr, -7, -7);
            icon_line(cr, 7, 7);
            icon_move(cr, 7, -7);
            icon_line(cr, -7, 7);
            cairo_stroke(cr);
            break;
        case BR_ICON_SAVED:
            cairo_arc(cr, 20, 20, 9, 0, 2 * 3.141592653589793);
            cairo_stroke(cr);
            icon_move(cr, -4, 0);
            icon_line(cr, -1, 3);
            icon_line(cr, 5, -4);
            cairo_stroke(cr);
            break;
        case BR_ICON_ALERT:
            icon_move(cr, 0, -9);
            icon_line(cr, 10, 8);
            icon_line(cr, -10, 8);
            cairo_close_path(cr);
            cairo_stroke(cr);
            icon_move(cr, 0, -3);
            icon_line(cr, 0, 2);
            cairo_stroke(cr);
            icon_move(cr, 0, 5);
            icon_line(cr, 0, 5.5);
            cairo_stroke(cr);
            break;
        default:
            break;
    }
}

BR_Texture *br_create_icon(BR_Context *context, int icon, BR_Color color) {
    const float density = context->pixel_density;
    const int pixel_size = (int)(BR_ICON_SIZE * density + 0.999f);
    cairo_surface_t *surface = cairo_image_surface_create(
        CAIRO_FORMAT_ARGB32, pixel_size, pixel_size);
    cairo_t *cr = cairo_create(surface);
    if (cairo_status(cr) != CAIRO_STATUS_SUCCESS) {
        set_error(context, "Could not allocate the icon image.");
        cairo_destroy(cr);
        cairo_surface_destroy(surface);
        return NULL;
    }
    cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
    cairo_set_source_rgba(cr, 0, 0, 0, 0);
    cairo_paint(cr);
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
    cairo_scale(cr, density, density);
    cairo_set_antialias(cr, CAIRO_ANTIALIAS_BEST);
    draw_icon_paths(cr, icon, color);

    BR_Texture *texture = texture_from_surface(context, surface,
                                               pixel_size, pixel_size);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    if (!texture) return NULL;
    SDL_SetTextureBlendMode(texture->texture, SDL_BLENDMODE_BLEND_PREMULTIPLIED);
    SDL_SetTextureScaleMode(texture->texture, SDL_SCALEMODE_LINEAR);
    return texture;
}

void br_texture_size(const BR_Texture *texture, int *width, int *height) {
    *width = texture ? texture->width : 0;
    *height = texture ? texture->height : 0;
}

void br_texture_destroy(BR_Texture *texture) {
    if (!texture) return;
    SDL_DestroyTexture(texture->texture);
    free(texture);
}

/* ------------------------------------------------------------ documents */

BR_Document *br_pdf_open(BR_Context *context, const char *path) {
    char *absolute = realpath(path, NULL);
    if (!absolute) {
        set_error(context, "The PDF path does not exist.");
        return NULL;
    }

    GError *error = NULL;
    char *uri = g_filename_to_uri(absolute, NULL, &error);
    if (!uri) {
        set_error(context, error ? error->message : "Invalid PDF path.");
        if (error) g_error_free(error);
        free(absolute);
        return NULL;
    }

    PopplerDocument *poppler = poppler_document_new_from_file(uri, NULL, &error);
    g_free(uri);
    if (!poppler) {
        set_error(context, error ? error->message : "Invalid PDF file.");
        if (error) g_error_free(error);
        free(absolute);
        return NULL;
    }

    BR_Document *document = calloc(1, sizeof(*document));
    if (!document) {
        set_error(context, "Out of memory.");
        g_object_unref(poppler);
        free(absolute);
        return NULL;
    }
    /* Addresses get reused after a close; a serial never does, so caches
     * keyed by identity can never mistake a new document for an old one. */
    static uint64_t next_serial = 0;
    document->document = poppler;
    document->path = absolute;
    document->serial = ++next_serial;
    return document;
}

uint64_t br_pdf_identity(const BR_Document *document) {
    return document ? document->serial : 0;
}

void br_pdf_close(BR_Document *document) {
    if (!document) return;
    g_object_unref(document->document);
    free(document->path);
    free(document);
}

const char *br_pdf_path(const BR_Document *document) {
    return document ? document->path : "";
}

int br_pdf_page_count(const BR_Document *document) {
    return document ? poppler_document_get_n_pages(document->document) : 0;
}

static PopplerPage *load_page(BR_Context *context,
                              const BR_Document *document,
                              int page_index) {
    if (!document || page_index < 0 ||
        page_index >= poppler_document_get_n_pages(document->document)) {
        set_error(context, "Page index is out of range.");
        return NULL;
    }
    PopplerPage *page = poppler_document_get_page(document->document, page_index);
    if (!page) set_error(context, "Could not load this page.");
    return page;
}

int br_pdf_page_size(const BR_Document *document,
                     int page_index,
                     float *width,
                     float *height) {
    PopplerPage *page = load_page(NULL, document, page_index);
    if (!page) return 0;
    double width_points = 0, height_points = 0;
    poppler_page_get_size(page, &width_points, &height_points);
    g_object_unref(page);
    if (width_points <= 0 || height_points <= 0) return 0;
    *width = (float)width_points;
    *height = (float)height_points;
    return 1;
}

/* Dark mode inverts the page so white paper becomes a dark surface and ink
 * stays readable: every channel becomes 235 - value * 220 / 255. Two
 * channels of a pixel are processed at once in the halves of one word, with
 * the division in its exact shift-and-add form, so the compiler vectorizes
 * the loop and a page costs one pass over memory; a lookup table cannot be
 * vectorized and took more than twice as long. The page is opaque, so the
 * alpha byte is simply set. */
static inline uint32_t darken_lanes(uint32_t lanes) {
    const uint32_t scaled = lanes * 220u;
    const uint32_t quotient =
        ((scaled + 0x00010001u + ((scaled >> 8) & 0x00FF00FFu)) >> 8) & 0x00FF00FFu;
    return 0x00EB00EBu - quotient;
}

static void darken_surface(unsigned char *pixels, int width, int height, int stride) {
    for (int y = 0; y < height; ++y) {
        uint32_t *row = (uint32_t *)(pixels + (size_t)y * stride);
        for (int x = 0; x < width; ++x) {
            const uint32_t pixel = row[x];
            const uint32_t even = darken_lanes(pixel & 0x00FF00FFu);
            const uint32_t odd = darken_lanes((pixel >> 8) & 0x00FF00FFu);
            row[x] = (even | (odd << 8)) | 0xFF000000u;
        }
    }
}

/* Loads a page without reporting errors to a context, so it can run on a
 * worker thread. */
static PopplerPage *load_page_quietly(const BR_Document *document, int page_index) {
    if (!document || page_index < 0 ||
        page_index >= poppler_document_get_n_pages(document->document)) {
        return NULL;
    }
    return poppler_document_get_page(document->document, page_index);
}

BR_Image *br_pdf_render_image(const BR_Document *document,
                              int page_index,
                              float scale,
                              int dark_mode) {
    PopplerPage *page = load_page_quietly(document, page_index);
    if (!page) return NULL;

    double width_points = 0, height_points = 0;
    poppler_page_get_size(page, &width_points, &height_points);
    const int width = (int)(width_points * scale + 0.999);
    const int height = (int)(height_points * scale + 0.999);
    if (scale <= 0 || width <= 0 || height <= 0 ||
        width > BR_MAXIMUM_PAGE_PIXELS || height > BR_MAXIMUM_PAGE_PIXELS) {
        g_object_unref(page);
        return NULL;
    }

    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    cairo_t *cr = cairo_create(surface);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS ||
        cairo_status(cr) != CAIRO_STATUS_SUCCESS) {
        cairo_destroy(cr);
        cairo_surface_destroy(surface);
        g_object_unref(page);
        return NULL;
    }

    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_paint(cr);
    cairo_scale(cr, scale, scale);
    poppler_page_render(page, cr);
    cairo_destroy(cr);
    g_object_unref(page);
    cairo_surface_flush(surface);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        return NULL;
    }
    if (dark_mode) {
        darken_surface(cairo_image_surface_get_data(surface), width, height,
                       cairo_image_surface_get_stride(surface));
        cairo_surface_mark_dirty(surface);
    }

    BR_Image *image = malloc(sizeof(*image));
    if (!image) {
        cairo_surface_destroy(surface);
        return NULL;
    }
    image->surface = surface;
    image->width = width;
    image->height = height;
    return image;
}

void br_image_destroy(BR_Image *image) {
    if (!image) return;
    cairo_surface_destroy(image->surface);
    free(image);
}

BR_Texture *br_texture_from_image(BR_Context *context, const BR_Image *image) {
    if (!image) {
        set_error(context, "No page image to upload.");
        return NULL;
    }
    BR_Texture *texture = texture_from_surface(context, image->surface,
                                               image->width, image->height);
    if (texture) SDL_SetTextureScaleMode(texture->texture, SDL_SCALEMODE_LINEAR);
    return texture;
}

BR_Texture *br_pdf_render(BR_Context *context,
                          const BR_Document *document,
                          int page_index,
                          float scale,
                          int dark_mode) {
    PopplerPage *page = load_page(context, document, page_index);
    if (!page) return NULL;
    g_object_unref(page);

    BR_Image *image = br_pdf_render_image(document, page_index, scale, dark_mode);
    if (!image) {
        set_error(context, "Page render size is out of range.");
        return NULL;
    }
    BR_Texture *texture = br_texture_from_image(context, image);
    br_image_destroy(image);
    return texture;
}
