#ifndef WHISKERFLOW_CLEANUP_SUPPORT_H
#define WHISKERFLOW_CLEANUP_SUPPORT_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct wf_cleanup_model wf_cleanup_model;
typedef struct wf_cleanup_control wf_cleanup_control;
typedef struct { uint64_t available_bytes; int pressure; } wf_cleanup_memory;
wf_cleanup_memory wf_cleanup_memory_state(void);
int wf_cleanup_can_load(uint64_t required_bytes, uint64_t available_bytes, int pressure, int foreground);
int wf_cleanup_has_headroom(uint64_t required_bytes, int foreground);
wf_cleanup_control *wf_cleanup_control_create(void);
void wf_cleanup_control_cancel(wf_cleanup_control *control);
void wf_cleanup_control_free(wf_cleanup_control *control);
wf_cleanup_model *wf_cleanup_load(const char *path, int threads, wf_cleanup_control *control);
void wf_cleanup_free(wf_cleanup_model *model);
// Returns 0 only after an end-of-generation token, 1 on timeout/cancel,
// and 2 on a decode, context or output limit. Partial output is never accepted.
int wf_cleanup_generate(wf_cleanup_model *model, const char *prompt, char *output,
                        int capacity, int max_tokens, double seconds, wf_cleanup_control *control);
#ifdef __cplusplus
}
#endif
#endif
