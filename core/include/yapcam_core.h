// Yapcam core C ABI. Owned by Lead — change only together with docs/FORMATS.md
// and both the Rust implementation (core/src/ffi.rs) and Sources/YapcamCore.
#ifndef YAPCAM_CORE_H
#define YAPCAM_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define YC_ABI_VERSION 3

typedef enum {
    YC_OK = 0,
    YC_ERR_INVALID_ARGUMENT = 1,
    YC_ERR_PARSE = 2,
    YC_ERR_UNSUPPORTED_VERSION = 3,
    YC_ERR_IO = 4,
    YC_ERR_MISSING_MEDIA = 5,
    YC_ERR_STATE = 6,
    YC_ERR_INTERNAL = 99,
} YcStatus;

typedef struct YcProject YcProject;

typedef struct { double x, y, w, h; } YcRect;

// Which file and file-local time to sample for one track. present == 0 → draw nothing.
typedef struct {
    uint8_t present;
    uint32_t segment;      // index into session.json segments
    int64_t file_ns;       // time inside that segment's file (track_start_ns applied)
    int64_t src_ns;        // global source time, for diagnostics
} YcSample;

// Everything needed to draw one output frame. Canvas pixels, origin top-left.
typedef struct {
    int64_t tl_ns;
    uint32_t canvas_w, canvas_h;

    uint32_t background_kind;          // 0 solid, 1 linear gradient, 2 image, 3 blurred screen
    float background_color[4];         // RGBA, sRGB
    float background_color2[4];
    float background_angle_deg;
    uint32_t background_asset;         // project asset index for kind 2
    float background_blur;

    YcSample screen;
    YcRect screen_crop;                // normalized 0..1 source rect actually shown (zoom)
    YcRect screen_dest;                // canvas rect the crop is drawn into
    float screen_corner_radius;
    float shadow_radius, shadow_opacity, shadow_offset_y;
    float inset_width;
    float inset_color[4];
    float motion_blur;                 // 0..1, strength during zoom/pan movement

    uint8_t cursor_visible;
    double cursor_x, cursor_y;         // canvas px of the hotspot
    float cursor_scale;                // multiplier on native cursor size in canvas px
    uint32_t cursor_id;                // id from cursors.json of the active segment
    float cursor_opacity;
    float click_progress;              // <0 no click effect, else 0..1
    double click_x, click_y;

    YcSample camera;
    YcRect camera_dest;
    float camera_corner_radius;
    uint32_t camera_shape;             // 0 rounded rect, 1 circle, 2 squircle
    float camera_opacity;
    uint8_t camera_mirror;

    float mic_gain;                    // linear
    float system_gain;
} YcFrame;

// ABI v2 adds these types; YcFrame and all v1 signatures are unchanged.
#define YC_MAX_FRAME_HIGHLIGHTS 32

// Evaluated drawing instruction in canvas pixels. Array order defines stacking.
// Opaque fill masks the region; transparent fill + dim_opacity creates a spotlight.
typedef struct {
    YcRect rect;
    float corner_radius, opacity, dim_opacity;
    float fill[4];                     // RGBA, sRGB
    float stroke[4];
    float stroke_width;
} YcFrameHighlight;

typedef struct {
    int64_t tl_ns;
    uint32_t cursor_style;             // 0 recorded, 1 pointer, 2 touch, 3 arrow
    float cursor_motion_blur;          // 0..1
    float cursor_spotlight_radius;     // canvas pixels, 0 disables
    float background_noise;            // 0..1
    uint8_t window_chrome;
    uint8_t camera_background_removal;
    uint8_t camera_face_framing;
    uint8_t reserved;                  // always zero
    float camera_shadow_radius;        // canvas pixels
    float fade_opacity;                // black overlay after all layers, 0..1
    uint32_t highlight_count;          // valid prefix of highlights; never truncated
    YcFrameHighlight highlights[YC_MAX_FRAME_HIGHLIGHTS];
} YcFrameExtras;

// ABI v3 appends motion outputs; v1/v2 types and signatures are unchanged.
typedef struct {
    int64_t tl_ns;
    float cursor_rotation_rad;
    float cursor_motion_blur;
    float zoom_motion_blur;
    float pan_motion_blur;
} YcFrameMotion;

uint32_t yc_abi_version(void);
const char *yc_last_error(void);       // thread-local, valid until next call on this thread
void yc_string_free(char *s);

// Create a new project inside an existing package directory that contains
// recording/session.json. Writes nothing until yc_project_save.
YcStatus yc_project_create(const char *package_path, YcProject **out);
// Open package_path/project.json (falls back to project.json.prev if corrupt; migrates old versions).
YcStatus yc_project_open(const char *package_path, YcProject **out);
// Atomic save to package_path/project.json, keeping the previous file as project.json.prev.
YcStatus yc_project_save(YcProject *p, const char *package_path);
YcStatus yc_project_to_json(const YcProject *p, char **out_json);
YcStatus yc_project_clone(const YcProject *p, YcProject **out);   // snapshot for export threads
void yc_project_free(YcProject *p);

// Apply an edit command (docs/FORMATS.md). out_json receives {"changed":[…]}; may be NULL.
YcStatus yc_apply(YcProject *p, const char *command_json, char **out_json);
YcStatus yc_undo(YcProject *p, uint8_t *did_undo);
YcStatus yc_redo(YcProject *p, uint8_t *did_redo);
uint8_t yc_can_undo(const YcProject *p);
uint8_t yc_can_redo(const YcProject *p);

YcStatus yc_timeline_duration(const YcProject *p, int64_t *out_ns);
// Hot path: no allocation. Safe to call concurrently on the same handle (read-only).
YcStatus yc_frame_at(const YcProject *p, int64_t tl_ns, YcFrame *out);
// ABI v2 hot path: no allocation/file IO. Same time validation as yc_frame_at.
// Call on an immutable snapshot when frame and extras must reflect one edit state.
YcStatus yc_frame_extras_at(const YcProject *p, int64_t tl_ns, YcFrameExtras *out);
// ABI v3 hot path: evaluated tilt and per-kind strengths, no allocation or IO.
YcStatus yc_frame_motion_at(const YcProject *p, int64_t tl_ns, YcFrameMotion *out);
// Read-only structured queries for UI, e.g. {"q":"clips"}, {"q":"zooms"}, {"q":"audio_ranges"}.
YcStatus yc_query(const YcProject *p, const char *query_json, char **out_json);

#ifdef __cplusplus
}
#endif

#endif
