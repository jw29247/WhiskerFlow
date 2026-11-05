#include "WhiskerFlowCleanupSupport.h"
#include <llama/llama.h>
#include <atomic>
#include <algorithm>
#include <chrono>
#include <cstring>
#include <mutex>
#include <vector>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <malloc/malloc.h>

using clock_type = std::chrono::steady_clock;
int wf_cleanup_has_headroom(uint64_t required_bytes) {
    int pressure = 1;
    size_t size = sizeof(pressure);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nullptr, 0) == 0 && pressure != 1) return 0;
    vm_statistics64_data_t vm{};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    auto host = mach_host_self();
    auto result = host_statistics64(host, HOST_VM_INFO64, reinterpret_cast<host_info64_t>(&vm), &count);
    mach_port_deallocate(mach_task_self(), host);
    if (result != KERN_SUCCESS) return 0;
    // Free and reclaimable file-backed pages. Keep an extra 1 GiB for context,
    // runtime allocations and other applications rather than consume it all.
    uint64_t available = (uint64_t(vm.free_count) + vm.inactive_count) * vm_kernel_page_size;
    return available >= required_bytes + 1024ULL * 1024ULL * 1024ULL;
}
struct wf_cleanup_control {
    std::atomic<bool> cancelled{false};
    clock_type::time_point deadline;
};
struct wf_cleanup_model {
    llama_model *model;
    llama_context *context;
};
static bool abort_cleanup(void *data) {
    auto *control = static_cast<wf_cleanup_control *>(data);
    return control->cancelled.load() || clock_type::now() >= control->deadline;
}
wf_cleanup_control *wf_cleanup_control_create(void) { return new wf_cleanup_control; }
void wf_cleanup_control_cancel(wf_cleanup_control *control) { control->cancelled.store(true); }
void wf_cleanup_control_free(wf_cleanup_control *control) { delete control; }

wf_cleanup_model *wf_cleanup_load(const char *path, int threads, wf_cleanup_control *control) {
    static std::once_flag initialized;
    std::call_once(initialized, [] {
        // The residency-set path runs a 200 Hz keep-alive loop. This supported
        // Metal fallback leaves residency to the driver and has no idle poller.
        setenv("GGML_METAL_NO_RESIDENCY", "1", 1);
        // Runtime messages contain filesystem paths and prompt fragments in
        // some failure modes. Our caller reports bounded outcomes instead.
        llama_log_set([](ggml_log_level, const char *, void *) {}, nullptr);
        ggml_log_set([](ggml_log_level, const char *, void *) {}, nullptr);
        llama_backend_init();
    });
    auto parameters = llama_model_default_params();
    parameters.n_gpu_layers = 99;
    parameters.load_mode = LLAMA_LOAD_MODE_MMAP;
    control->deadline = clock_type::now() + std::chrono::seconds(15);
    parameters.progress_callback = [](float, void *data) { return !abort_cleanup(data); };
    parameters.progress_callback_user_data = control;
    auto *model = llama_model_load_from_file(path, parameters);
    if (!model) return nullptr;
    auto context_parameters = llama_context_default_params();
    context_parameters.n_ctx = 4096;
    context_parameters.n_batch = 256;
    context_parameters.n_ubatch = 256;
    context_parameters.n_threads = threads;
    context_parameters.n_threads_batch = threads;
    context_parameters.offload_kqv = true;
    context_parameters.no_perf = true;
    auto *context = llama_init_from_model(model, context_parameters);
    if (!context) { llama_model_free(model); return nullptr; }
    llama_set_abort_callback(context, abort_cleanup, control);
    // Pay Metal pipeline setup while the user is speaking, then erase the KV.
    llama_token token = llama_vocab_bos(llama_model_get_vocab(model));
    if (llama_decode(context, llama_batch_get_one(&token, 1)) != 0) {
        llama_free(context); llama_model_free(model); return nullptr;
    }
    llama_memory_clear(llama_get_memory(context), true);
    llama_set_abort_callback(context, nullptr, nullptr);
    return new wf_cleanup_model{model, context};
}
void wf_cleanup_free(wf_cleanup_model *model) {
    if (!model) return;
    llama_free(model->context);
    llama_model_free(model->model);
    delete model;
    // The tokenizer allocates many small objects. Return cached free heap pages
    // too, rather than retain them throughout the idle period.
    malloc_zone_pressure_relief(nullptr, 0);
}
int wf_cleanup_generate(wf_cleanup_model *model, const char *prompt, char *output,
                        int capacity, int max_tokens, double seconds, wf_cleanup_control *control) {
    auto *ctx = model->context;
    auto *vocab = llama_model_get_vocab(model->model);
    control->deadline = clock_type::now() + std::chrono::milliseconds(static_cast<int>(seconds * 1000));
    llama_set_abort_callback(ctx, abort_cleanup, control);
    llama_memory_clear(llama_get_memory(ctx), true);
    output[0] = '\0';
    int result = 2;
    int used = 0;
    const int needed = -llama_tokenize(vocab, prompt, static_cast<int>(strlen(prompt)), nullptr, 0, true, true);
    if (needed <= 0 || needed + max_tokens > static_cast<int>(llama_n_ctx(ctx))) {
        llama_set_abort_callback(ctx, nullptr, nullptr); return 2;
    }
    std::vector<llama_token> tokens(needed);
    const int count = llama_tokenize(vocab, prompt, static_cast<int>(strlen(prompt)), tokens.data(), needed, true, true);
    auto *sampler = llama_sampler_init_greedy();
    for (int offset = 0; offset < count;) {
        if (abort_cleanup(control)) { result = 1; goto done; }
        int batch_size = std::min(256, count - offset);
        if (llama_decode(ctx, llama_batch_get_one(tokens.data() + offset, batch_size)) != 0) {
            result = abort_cleanup(control) ? 1 : 2; goto done;
        }
        offset += batch_size;
    }
    for (int index = 0; index < max_tokens; ++index) {
        if (abort_cleanup(control)) { result = 1; break; }
        llama_token token = llama_sampler_sample(sampler, ctx, -1);
        if (llama_vocab_is_eog(vocab, token)) { result = 0; break; }
        char piece[512];
        const int size = llama_token_to_piece(vocab, token, piece, sizeof(piece), 0, false);
        if (size < 0 || used + size >= capacity) break;
        memcpy(output + used, piece, size);
        used += size;
        output[used] = '\0';
        if (llama_decode(ctx, llama_batch_get_one(&token, 1)) != 0) {
            result = abort_cleanup(control) ? 1 : 2; break;
        }
    }
done:
    llama_sampler_free(sampler);
    llama_memory_clear(llama_get_memory(ctx), true);
    llama_set_abort_callback(ctx, nullptr, nullptr);
    return result;
}
