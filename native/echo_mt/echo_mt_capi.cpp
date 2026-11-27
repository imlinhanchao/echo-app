#include "echo_mt_capi.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#ifdef __ANDROID__
#include <android/log.h>
#if defined(__aarch64__)
#include <sys/auxv.h>
#endif
#endif

#ifndef ECHO_MT_BUILD_ARCH_LABEL
#define ECHO_MT_BUILD_ARCH_LABEL "unknown"
#endif

#include "llama.h"

namespace {

std::string trim_copy(const std::string& s) {
  size_t start = 0;
  while (start < s.size() &&
         (s[start] == ' ' || s[start] == '\t' || s[start] == '\n' ||
          s[start] == '\r')) {
    ++start;
  }
  size_t end = s.size();
  while (end > start &&
         (s[end - 1] == ' ' || s[end - 1] == '\t' || s[end - 1] == '\n' ||
          s[end - 1] == '\r')) {
    --end;
  }
  return s.substr(start, end - start);
}

std::mutex g_log_mutex;
std::string g_last_llama_error;
bool g_last_log_is_error = false;

void echo_mt_log_callback(
    enum ggml_log_level level,
    const char* text,
    void* /*user_data*/) {
  if (text == nullptr) return;
#ifdef __ANDROID__
  if (level == GGML_LOG_LEVEL_ERROR || level == GGML_LOG_LEVEL_WARN ||
      (level == GGML_LOG_LEVEL_CONT && g_last_log_is_error)) {
    const int prio =
        (level == GGML_LOG_LEVEL_ERROR ||
         (level == GGML_LOG_LEVEL_CONT && g_last_log_is_error))
            ? ANDROID_LOG_ERROR
            : ANDROID_LOG_WARN;
    __android_log_print(prio, "echo_mt", "%s", text);
  }
#endif
  std::lock_guard<std::mutex> lock(g_log_mutex);
  if (level != GGML_LOG_LEVEL_CONT) {
    g_last_log_is_error = (level == GGML_LOG_LEVEL_ERROR);
  }
  if (g_last_log_is_error && g_last_llama_error.size() < 1024) {
    if (!g_last_llama_error.empty() && g_last_llama_error.back() != '\n') {
      g_last_llama_error.push_back(' ');
    }
    g_last_llama_error.append(text);
  }
}

void clear_last_llama_error() {
  std::lock_guard<std::mutex> lock(g_log_mutex);
  g_last_llama_error.clear();
  g_last_log_is_error = false;
}

std::string take_last_llama_error() {
  std::lock_guard<std::mutex> lock(g_log_mutex);
  std::string out = trim_copy(g_last_llama_error);
  g_last_llama_error.clear();
  g_last_log_is_error = false;
  return out;
}

struct EchoMtEngineHandle {
  llama_model* model = nullptr;
  llama_context* ctx = nullptr;
  const llama_vocab* vocab = nullptr;
  int32_t n_ctx = 1024;
  int32_t n_batch = 512;
  int32_t n_threads = 4;
  std::vector<llama_token> cached_prompt_tokens;
  std::atomic<bool> cancelled{false};
  std::mutex infer_mutex;
  std::string last_error;
};

struct FormattedPrompt {
  std::string text;
  bool add_special = false;
};

bool abort_callback_fn(void* data) {
  auto* h = static_cast<EchoMtEngineHandle*>(data);
  return h != nullptr && h->cancelled.load(std::memory_order_relaxed);
}

FormattedPrompt format_chat_prompt(llama_model* model, const char* user_prompt) {
  const char* model_tmpl = llama_model_chat_template(model, nullptr);
  const bool is_empty_tmpl =
      (model_tmpl == nullptr || std::strlen(model_tmpl) == 0);
  const std::string tmpl_str = is_empty_tmpl ? std::string() : std::string(model_tmpl);
  const bool is_hunyuan_dense =
      is_empty_tmpl ||
      (tmpl_str.find("hy_User") != std::string::npos &&
       tmpl_str.find("hy_Assistant") != std::string::npos);

  if (is_hunyuan_dense) {
    // Directly assemble HY-MT1.5 / Hunyuan-Dense prompt to bypass llama_chat_detect_template's
    // HUNYUAN_VL misdetection on HF tokenizer.chat_template and guarantee single BOS + Assistant tag.
    FormattedPrompt out;
    out.text =
        std::string("<\xef\xbd\x9c" "hy_begin\xe2\x96\x81" "of\xe2\x96\x81" "sentence\xef\xbd\x9c>") +
        "<\xef\xbd\x9c" "hy_User\xef\xbd\x9c>" + user_prompt +
        "<\xef\xbd\x9c" "hy_Assistant\xef\xbd\x9c>";
    out.add_special = false;
    return out;
  }

  llama_chat_message msg{};
  msg.role = "user";
  msg.content = user_prompt;

  std::vector<char> buf(std::strlen(user_prompt) * 2 + 256);
  int32_t res = llama_chat_apply_template(
      model_tmpl, &msg, 1, true, buf.data(), static_cast<int32_t>(buf.size()));

  if (res > static_cast<int32_t>(buf.size())) {
    buf.resize(static_cast<size_t>(res) + 16);
    res = llama_chat_apply_template(
        model_tmpl, &msg, 1, true, buf.data(), static_cast<int32_t>(buf.size()));
  }

  if (res > 0) {
    return FormattedPrompt{std::string(buf.data(), static_cast<size_t>(res)), true};
  }

  FormattedPrompt fallback;
  fallback.text =
      std::string("<\xef\xbd\x9c" "hy_begin\xe2\x96\x81" "of\xe2\x96\x81" "sentence\xef\xbd\x9c>") +
      "<\xef\xbd\x9c" "hy_User\xef\xbd\x9c>" + user_prompt +
      "<\xef\xbd\x9c" "hy_Assistant\xef\xbd\x9c>";
  fallback.add_special = false;
  return fallback;
}

// 保证截断写入 out_buf 时不劈裂多字节 UTF-8 字符
int32_t copy_utf8_safe(const std::string& src, char* out_buf, int32_t max_len) {
  if (out_buf == nullptr || max_len <= 0) return -1;
  size_t limit = static_cast<size_t>(max_len - 1);
  if (src.size() <= limit) {
    std::memcpy(out_buf, src.data(), src.size());
    out_buf[src.size()] = '\0';
    return static_cast<int32_t>(src.size());
  }
  while (limit > 0 && (static_cast<unsigned char>(src[limit]) & 0xC0) == 0x80) {
    --limit;
  }
  std::memcpy(out_buf, src.data(), limit);
  out_buf[limit] = '\0';
  return static_cast<int32_t>(limit);
}

std::once_flag g_backend_init_once;

}  // namespace

extern "C" {

ECHO_MT_API void echo_mt_backend_init(void) {
  std::call_once(g_backend_init_once, []() {
    ggml_log_set(echo_mt_log_callback, nullptr);
    llama_log_set(echo_mt_log_callback, nullptr);
    llama_backend_init();
  });
}

ECHO_MT_API void* echo_mt_load_model(
    const char* model_path,
    int32_t n_threads,
    int32_t n_ctx) {
  echo_mt_backend_init();

  auto* h = new (std::nothrow) EchoMtEngineHandle();
  if (h == nullptr) return nullptr;

  if (model_path == nullptr || std::strlen(model_path) == 0) {
    h->last_error = "model_path is empty";
    return h;
  }

  const int32_t threads = n_threads > 0 ? std::min(n_threads, 8) : 4;
  const int32_t ctx_size = n_ctx > 256 ? n_ctx : 1024;
  h->n_threads = threads;
  h->n_ctx = ctx_size;
  h->n_batch = 512;

  llama_model_params mparams = llama_model_default_params();
  mparams.n_gpu_layers = 0;

  clear_last_llama_error();
  h->model = llama_model_load_from_file(model_path, mparams);
  if (h->model == nullptr) {
    const std::string detail = take_last_llama_error();
    h->last_error = detail.empty()
        ? "failed to load GGUF model from path"
        : "failed to load GGUF model: " + detail;
    return h;
  }

  llama_context_params cparams = llama_context_default_params();
  cparams.n_ctx = static_cast<uint32_t>(ctx_size);
  cparams.n_batch = static_cast<uint32_t>(h->n_batch);
  cparams.n_ubatch = static_cast<uint32_t>(h->n_batch);
  cparams.n_threads = threads;
  cparams.n_threads_batch = threads;
  cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;
  cparams.no_perf = true;
  cparams.abort_callback = abort_callback_fn;
  cparams.abort_callback_data = h;

  clear_last_llama_error();
  h->ctx = llama_init_from_model(h->model, cparams);
  if (h->ctx == nullptr) {
    const std::string detail = take_last_llama_error();
    h->last_error = detail.empty()
        ? "failed to create llama_context"
        : "failed to create llama_context: " + detail;
    llama_model_free(h->model);
    h->model = nullptr;
    return h;
  }

  h->vocab = llama_model_get_vocab(h->model);
  if (h->vocab == nullptr) {
    h->last_error = "failed to obtain llama_vocab";
    llama_free(h->ctx);
    llama_model_free(h->model);
    h->ctx = nullptr;
    h->model = nullptr;
    return h;
  }

  clear_last_llama_error();
  return h;
}

ECHO_MT_API int32_t echo_mt_is_ready(void* handle) {
  auto* h = static_cast<EchoMtEngineHandle*>(handle);
  if (h == nullptr) return 0;
  return (h->model != nullptr && h->ctx != nullptr && h->vocab != nullptr) ? 1
                                                                           : 0;
}

ECHO_MT_API int32_t echo_mt_translate(
    void* handle,
    const char* prompt,
    int32_t max_tokens,
    char* out_buf,
    int32_t out_buf_len) {
  auto* h = static_cast<EchoMtEngineHandle*>(handle);
  if (h == nullptr || out_buf == nullptr || out_buf_len <= 0) {
    return -1;
  }
  out_buf[0] = '\0';

  if (echo_mt_is_ready(handle) == 0) {
    if (h->last_error.empty()) {
      h->last_error = "model is not loaded";
    }
    return -1;
  }
  if (prompt == nullptr || std::strlen(prompt) == 0) {
    h->last_error = "prompt is empty";
    return -1;
  }

  std::lock_guard<std::mutex> lock(h->infer_mutex);
  h->cancelled.store(false, std::memory_order_relaxed);
  h->last_error.clear();
  clear_last_llama_error();

  const FormattedPrompt formatted = format_chat_prompt(h->model, prompt);
  std::vector<llama_token> prompt_tokens(formatted.text.size() + 32);
  int32_t n_prompt = llama_tokenize(
      h->vocab,
      formatted.text.data(),
      static_cast<int32_t>(formatted.text.size()),
      prompt_tokens.data(),
      static_cast<int32_t>(prompt_tokens.size()),
      formatted.add_special,
      true);

  if (n_prompt < 0) {
    prompt_tokens.resize(static_cast<size_t>(-n_prompt) + 8);
    n_prompt = llama_tokenize(
        h->vocab,
        formatted.text.data(),
        static_cast<int32_t>(formatted.text.size()),
        prompt_tokens.data(),
        static_cast<int32_t>(prompt_tokens.size()),
        formatted.add_special,
        true);
  }
  if (n_prompt <= 0) {
    const std::string detail = take_last_llama_error();
    h->last_error = detail.empty()
        ? "failed to tokenize prompt"
        : "failed to tokenize prompt: " + detail;
    return -1;
  }
  prompt_tokens.resize(static_cast<size_t>(n_prompt));

  const int32_t max_prompt_tokens = h->n_ctx - 32;
  if (n_prompt > max_prompt_tokens) {
    h->last_error = "prompt exceeds context window";
    return -1;
  }

  llama_memory_t mem = llama_get_memory(h->ctx);
  int32_t common_prefix = 0;
  if (mem != nullptr && !h->cached_prompt_tokens.empty()) {
    const int32_t max_common = std::min(
        static_cast<int32_t>(h->cached_prompt_tokens.size()),
        std::max<int32_t>(0, n_prompt - 1));
    while (common_prefix < max_common &&
           h->cached_prompt_tokens[common_prefix] ==
               prompt_tokens[common_prefix]) {
      ++common_prefix;
    }
  }

  bool prefix_reused = false;
  if (common_prefix > 0 && mem != nullptr) {
    if (llama_memory_seq_rm(
            mem, 0, static_cast<llama_pos>(common_prefix), -1) &&
        llama_memory_seq_pos_max(mem, 0) ==
            static_cast<llama_pos>(common_prefix - 1)) {
      prefix_reused = true;
    }
  }
  if (!prefix_reused) {
    common_prefix = 0;
    h->cached_prompt_tokens.clear();
    if (mem != nullptr) {
      llama_memory_clear(mem, true);
    }
  }

  // 分块 prefill（仅计算未命中的提示词后缀部分，直接复用公共指令前缀 KV）
  const auto t_prefill0 = std::chrono::steady_clock::now();
  for (int32_t i = common_prefix; i < n_prompt; i += h->n_batch) {
    if (h->cancelled.load(std::memory_order_relaxed)) {
      h->cached_prompt_tokens.clear();
      return -2;
    }
    const int32_t chunk = std::min(h->n_batch, n_prompt - i);
    llama_batch batch = llama_batch_get_one(&prompt_tokens[i], chunk);
    const int32_t rc = llama_decode(h->ctx, batch);
    if (rc == 2 || h->cancelled.load(std::memory_order_relaxed)) {
      h->cached_prompt_tokens.clear();
      return -2;
    }
    if (rc != 0) {
      h->cached_prompt_tokens.clear();
      const std::string detail = take_last_llama_error();
      h->last_error = detail.empty()
          ? "llama_decode failed during prefill"
          : "llama_decode prefill failed: " + detail;
      return -1;
    }
  }
  h->cached_prompt_tokens = prompt_tokens;
  const auto t_prefill1 = std::chrono::steady_clock::now();

  llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
  sparams.no_perf = true;
  llama_sampler* smpl = llama_sampler_chain_init(sparams);
  const int32_t n_vocab = llama_vocab_n_tokens(h->vocab);
  // 翻译场景使用轻量重复惩罚 + 确定性贪心解码，大幅削减大词表每步采样开销并避免复读
  llama_sampler_chain_add(
      smpl, llama_sampler_init_penalties(n_vocab, 64, 1.05f, 0.0f, 0.0f));
  llama_sampler_chain_add(smpl, llama_sampler_init_greedy());

  const int32_t allowed_gen = std::min(
      max_tokens > 0 ? max_tokens : 512,
      std::max(1, h->n_ctx - n_prompt - 1));

  std::string output;
  output.reserve(static_cast<size_t>(allowed_gen) * 4);
  char piece_buf[256];
  int32_t gen_tokens = 0;
  const auto t_decode0 = std::chrono::steady_clock::now();

  for (int32_t step = 0; step < allowed_gen; ++step) {
    if (h->cancelled.load(std::memory_order_relaxed)) {
      llama_sampler_free(smpl);
      return -2;
    }

    llama_token next_tok = llama_sampler_sample(smpl, h->ctx, -1);
    if (llama_vocab_is_eog(h->vocab, next_tok)) {
      break;
    }
    ++gen_tokens;

    const int32_t n_bytes = llama_token_to_piece(
        h->vocab, next_tok, piece_buf, sizeof(piece_buf), 0, false);
    if (n_bytes > 0) {
      output.append(piece_buf, static_cast<size_t>(n_bytes));
    }

    llama_batch step_batch = llama_batch_get_one(&next_tok, 1);
    const int32_t rc = llama_decode(h->ctx, step_batch);
    if (rc == 2 || h->cancelled.load(std::memory_order_relaxed)) {
      llama_sampler_free(smpl);
      return -2;
    }
    if (rc != 0) {
      llama_sampler_free(smpl);
      h->cached_prompt_tokens.clear();
      const std::string detail = take_last_llama_error();
      h->last_error = detail.empty()
          ? "llama_decode failed during generation"
          : "llama_decode generation failed: " + detail;
      return -1;
    }
  }
  const auto t_decode1 = std::chrono::steady_clock::now();

  const long long prefill_ms =
      std::chrono::duration_cast<std::chrono::milliseconds>(
          t_prefill1 - t_prefill0).count();
  const long long decode_ms =
      std::chrono::duration_cast<std::chrono::milliseconds>(
          t_decode1 - t_decode0).count();
  const double tok_per_s = decode_ms > 0
      ? (static_cast<double>(gen_tokens) * 1000.0 / static_cast<double>(decode_ms))
      : 0.0;
#ifdef __ANDROID__
  __android_log_print(
      ANDROID_LOG_INFO,
      "echo_mt",
      "arch=%s threads=%d prompt=%d reused=%d prefill=%lldms gen=%d decode=%lldms (%.1f tok/s)",
      ECHO_MT_BUILD_ARCH_LABEL,
      h->n_threads,
      n_prompt,
      common_prefix,
      prefill_ms,
      gen_tokens,
      decode_ms,
      tok_per_s);
#else
  if (std::getenv("ECHO_MT_PERF_LOG") != nullptr) {
    std::fprintf(
        stderr,
        "[echo_mt] arch=%s threads=%d prompt=%d reused=%d prefill=%lldms gen=%d decode=%lldms (%.1f tok/s)\n",
        ECHO_MT_BUILD_ARCH_LABEL,
        h->n_threads,
        n_prompt,
        common_prefix,
        prefill_ms,
        gen_tokens,
        decode_ms,
        tok_per_s);
  }
#endif

  llama_sampler_free(smpl);
  const std::string cleaned = trim_copy(output);
  return copy_utf8_safe(cleaned, out_buf, out_buf_len);
}

ECHO_MT_API void echo_mt_cancel(void* handle) {
  auto* h = static_cast<EchoMtEngineHandle*>(handle);
  if (h != nullptr) {
    h->cancelled.store(true, std::memory_order_relaxed);
  }
}

ECHO_MT_API void echo_mt_unload_model(void* handle) {
  auto* h = static_cast<EchoMtEngineHandle*>(handle);
  if (h == nullptr) return;
  h->cancelled.store(true, std::memory_order_relaxed);
  std::lock_guard<std::mutex> lock(h->infer_mutex);
  if (h->ctx != nullptr) {
    llama_free(h->ctx);
    h->ctx = nullptr;
  }
  if (h->model != nullptr) {
    llama_model_free(h->model);
    h->model = nullptr;
  }
  h->vocab = nullptr;
  delete h;
}

ECHO_MT_API const char* echo_mt_build_arch(void) {
  return ECHO_MT_BUILD_ARCH_LABEL;
}

ECHO_MT_API uint32_t echo_mt_cpu_caps(void) {
  uint32_t caps = 0;
#if defined(__ANDROID__) && defined(__aarch64__)
#ifdef AT_HWCAP
  const unsigned long hwcap = getauxval(AT_HWCAP);
#else
  const unsigned long hwcap = getauxval(16);
#endif
#ifdef AT_HWCAP2
  const unsigned long hwcap2 = getauxval(AT_HWCAP2);
#else
  const unsigned long hwcap2 = getauxval(26);
#endif
  if ((hwcap & (1UL << 10)) != 0) caps |= 1u << 0;   // ASIMDHP (fp16)
  if ((hwcap & (1UL << 20)) != 0) caps |= 1u << 1;   // ASIMDDP (dotprod)
  if ((hwcap2 & (1UL << 13)) != 0) caps |= 1u << 2;  // I8MM
#endif
  return caps;
}

ECHO_MT_API const char* echo_mt_last_error(void* handle) {
  auto* h = static_cast<EchoMtEngineHandle*>(handle);
  if (h == nullptr) return "";
  return h->last_error.c_str();
}

}  // extern "C"
