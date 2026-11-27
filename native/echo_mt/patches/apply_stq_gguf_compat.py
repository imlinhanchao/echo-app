#!/usr/bin/env python3
"""Idempotent compatibility patch for legacy STQ1_0 GGUF files (tensor type 42 -> 43)."""

from __future__ import annotations

import pathlib
import sys

MARKER = "ECHO_MT_STQ1_0_COMPAT_PATCH"

ANCHOR = "    // compute the total size of the data section, taking into account the alignment"

COMPAT_BLOCK = """    // ECHO_MT_STQ1_0_COMPAT_PATCH: Early AngelSlim Hy-MT1.5-1.8B-1.25bit GGUFs
    // encoded STQ1_0 tensors as type id 42 (GGML_TYPE_Q2_0 after upstream rebase),
    // whereas current STQ_0 uses id 43 (GGML_TYPE_STQ1_0). Only remap when raw
    // offsets fail validation AND remapping all Q2_0 tensors to STQ1_0 matches
    // every tensor offset exactly.
    {
        bool raw_offsets_valid = true;
        bool has_q2_0 = false;
        size_t probe_raw_size = 0;
        for (size_t i = 0; i < ctx->info.size(); ++i) {
            const gguf_tensor_info & ti = ctx->info[i];
            if (ti.t.type == GGML_TYPE_Q2_0) {
                has_q2_0 = true;
            }
            const size_t padded_size = GGML_PAD(ggml_nbytes(&ti.t), ctx->alignment);
            if (ti.offset != probe_raw_size || SIZE_MAX - probe_raw_size < padded_size) {
                raw_offsets_valid = false;
            }
            if (raw_offsets_valid) {
                probe_raw_size += padded_size;
            }
        }

        if (!raw_offsets_valid && has_q2_0) {
            bool remap_valid = true;
            size_t probe_remap_size = 0;
            size_t remap_count = 0;
            const size_t stq_ts = ggml_type_size(GGML_TYPE_STQ1_0);
            const int64_t stq_blck = ggml_blck_size(GGML_TYPE_STQ1_0);

            for (size_t i = 0; i < ctx->info.size(); ++i) {
                const gguf_tensor_info & ti = ctx->info[i];
                ggml_tensor tmp = ti.t;
                if (tmp.type == GGML_TYPE_Q2_0) {
                    if (stq_blck == 0 || tmp.ne[0] % stq_blck != 0 ||
                        uint64_t(ggml_nelements(&tmp) / stq_blck) > SIZE_MAX / stq_ts) {
                        remap_valid = false;
                        break;
                    }
                    tmp.type = GGML_TYPE_STQ1_0;
                    tmp.nb[0] = stq_ts;
                    tmp.nb[1] = tmp.nb[0] * (tmp.ne[0] / stq_blck);
                    for (int j = 2; j < GGML_MAX_DIMS; ++j) {
                        tmp.nb[j] = tmp.nb[j - 1] * tmp.ne[j - 1];
                    }
                    ++remap_count;
                }
                const size_t padded_size = GGML_PAD(ggml_nbytes(&tmp), ctx->alignment);
                if (ti.offset != probe_remap_size || SIZE_MAX - probe_remap_size < padded_size) {
                    remap_valid = false;
                    break;
                }
                probe_remap_size += padded_size;
            }

            if (remap_valid && remap_count > 0) {
                GGML_LOG_WARN(
                    "%s: detected legacy STQ1_0 tensor type id (%d -> %d), remapping %zu tensor(s)\\n",
                    __func__, (int) GGML_TYPE_Q2_0, (int) GGML_TYPE_STQ1_0, remap_count);
                for (size_t i = 0; i < ctx->info.size(); ++i) {
                    gguf_tensor_info & ti = ctx->info[i];
                    if (ti.t.type == GGML_TYPE_Q2_0) {
                        ti.t.type = GGML_TYPE_STQ1_0;
                        ti.t.nb[0] = stq_ts;
                        ti.t.nb[1] = ti.t.nb[0] * (ti.t.ne[0] / stq_blck);
                        for (int j = 2; j < GGML_MAX_DIMS; ++j) {
                            ti.t.nb[j] = ti.t.nb[j - 1] * ti.t.ne[j - 1];
                        }
                    }
                }
            }
        }
    }

"""


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <llama_cpp_dir>", file=sys.stderr)
        return 2

    gguf_path = pathlib.Path(sys.argv[1]) / "ggml" / "src" / "gguf.cpp"
    if not gguf_path.is_file():
        print(f"Error: {gguf_path} not found", file=sys.stderr)
        return 1

    text = gguf_path.read_text(encoding="utf-8")
    if MARKER in text:
        print(f"Patch already present in {gguf_path}")
        return 0

    if ANCHOR not in text:
        print(f"Error: anchor not found in {gguf_path}", file=sys.stderr)
        return 1

    updated = text.replace(ANCHOR, COMPAT_BLOCK + ANCHOR, 1)
    gguf_path.write_text(updated, encoding="utf-8")
    print(f"Applied STQ1_0 GGUF compat patch to {gguf_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
