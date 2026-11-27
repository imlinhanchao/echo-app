#ifndef ECHO_MT_CAPI_H
#define ECHO_MT_CAPI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define ECHO_MT_API __declspec(dllexport)
#else
#define ECHO_MT_API __attribute__((visibility("default")))
#endif

/// 初始化底层 llama/ggml 后端（幂等）。
ECHO_MT_API void echo_mt_backend_init(void);

/// 加载 GGUF 模型并返回句柄；调用者需负责调用 echo_mt_unload_model 释放。
/// 若返回 non-null，请通过 echo_mt_is_ready 检查加载状态，失败时可通过 echo_mt_last_error 读取原因。
ECHO_MT_API void* echo_mt_load_model(
    const char* model_path,
    int32_t n_threads,
    int32_t n_ctx);

/// 判断模型句柄是否已成功加载就绪（1 = 就绪，0 = 失败或无效）。
ECHO_MT_API int32_t echo_mt_is_ready(void* handle);

/// 执行单段文本推理，将 UTF-8 结果写入 out_buf（保证以 '\0' 结尾）。
/// 返回值：>= 0 表示写入 out_buf 的字节数；-1 表示参数或运行错误；-2 表示被主动取消。
ECHO_MT_API int32_t echo_mt_translate(
    void* handle,
    const char* prompt,
    int32_t max_tokens,
    char* out_buf,
    int32_t out_buf_len);

/// 取消当前正在进行的推理（线程安全，可由其他线程调用）。
ECHO_MT_API void echo_mt_cancel(void* handle);

/// 释放模型、上下文与引擎句柄。
ECHO_MT_API void echo_mt_unload_model(void* handle);

/// 获取当前编译变体标识（如 arm64-v8 / arm64-dotprod / arm64-i8mm）。
ECHO_MT_API const char* echo_mt_build_arch(void);

/// 探测运行设备 CPU 硬件扩展能力位掩码：
/// bit0 (1): ASIMDHP(fp16), bit1 (2): ASIMDDP(dotprod), bit2 (4): I8MM。
ECHO_MT_API uint32_t echo_mt_cpu_caps(void);

/// 获取最近一次错误描述（返回内部只读缓冲，生命周期绑定 handle）。
ECHO_MT_API const char* echo_mt_last_error(void* handle);

#ifdef __cplusplus
}
#endif

#endif  // ECHO_MT_CAPI_H
