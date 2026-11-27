#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd "${APP_ROOT}/.." && pwd)"

LLAMA_DIR="${LLAMA_CPP_DIR:-${WORKSPACE_ROOT}/.tmp/llama_cpp_stq}"
KLEIDIAI_DIR="${KLEIDIAI_SRC_DIR:-${WORKSPACE_ROOT}/.tmp/kleidiai_v1.24.0}"
NDK_DIR="${ANDROID_NDK_HOME:-${HOME}/Android/Sdk/ndk/28.2.13676358}"
OUT_DIR="${APP_ROOT}/android/app/src/main/jniLibs/arm64-v8a"
STQ_COMMIT="1e411d8f5a1e23525fa3265dfb4bd76265465397"
STRIP_BIN="${NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"

if [ ! -d "${NDK_DIR}" ]; then
  echo "Android NDK not found at ${NDK_DIR}" >&2
  exit 1
fi

if [ ! -f "${LLAMA_DIR}/CMakeLists.txt" ]; then
  echo "Fetching sjl623/llama.cpp STQ_0 (${STQ_COMMIT})..."
  rm -rf "${LLAMA_DIR}"
  mkdir -p "${LLAMA_DIR}"
  ARCHIVE_TGZ="${WORKSPACE_ROOT}/.tmp/llama_stq.tar.gz"
  curl -fL --connect-timeout 15 --max-time 240 \
    "https://ghfast.top/https://github.com/sjl623/llama.cpp/archive/${STQ_COMMIT}.tar.gz" \
    -o "${ARCHIVE_TGZ}" \
    || curl -fL --connect-timeout 15 --max-time 240 \
      "https://github.com/sjl623/llama.cpp/archive/${STQ_COMMIT}.tar.gz" \
      -o "${ARCHIVE_TGZ}"
  tar -xzf "${ARCHIVE_TGZ}" -C "${LLAMA_DIR}" --strip-components=1
  rm -f "${ARCHIVE_TGZ}"
fi

python3 "${APP_ROOT}/native/echo_mt/patches/apply_stq_gguf_compat.py" "${LLAMA_DIR}"

HAS_KLEIDIAI="OFF"
if [ -f "${KLEIDIAI_DIR}/CMakeLists.txt" ]; then
  HAS_KLEIDIAI="ON"
else
  echo "Fetching KleidiAI v1.24.0..."
  mkdir -p "${KLEIDIAI_DIR}"
  KAI_TGZ="${WORKSPACE_ROOT}/.tmp/kleidiai.tar.gz"
  if curl -fL --connect-timeout 15 --max-time 180 \
      "https://ghfast.top/https://github.com/ARM-software/kleidiai/releases/download/v1.24.0/kleidiai-v1.24.0-src.tar.gz" \
      -o "${KAI_TGZ}" \
    || curl -fL --connect-timeout 15 --max-time 180 \
      "https://github.com/ARM-software/kleidiai/releases/download/v1.24.0/kleidiai-v1.24.0-src.tar.gz" \
      -o "${KAI_TGZ}"; then
    tar -xzf "${KAI_TGZ}" -C "${KLEIDIAI_DIR}" --strip-components=1
    rm -f "${KAI_TGZ}"
    if [ -f "${KLEIDIAI_DIR}/CMakeLists.txt" ]; then
      HAS_KLEIDIAI="ON"
    fi
  else
    rm -rf "${KLEIDIAI_DIR}" "${KAI_TGZ}"
    echo "Warning: KleidiAI fetch failed, continuing with native ARM SIMD kernels only." >&2
  fi
fi

mkdir -p "${OUT_DIR}"

build_variant() {
  local arm_arch="$1"
  local out_name="$2"
  local label="$3"
  local enable_kai="$4"
  local build_dir="${WORKSPACE_ROOT}/.tmp/build_${out_name}_arm64"
  local out_so="${OUT_DIR}/lib${out_name}.so"

  echo "=== Building ${out_so} (${arm_arch}, kleidiai=${enable_kai}) ==="
  rm -rf "${build_dir}"

  local kai_args=()
  if [ "${enable_kai}" = "ON" ] && [ "${HAS_KLEIDIAI}" = "ON" ]; then
    kai_args+=(-DECHO_MT_ENABLE_KLEIDIAI=ON "-DFETCHCONTENT_SOURCE_DIR_KLEIDIAI_DOWNLOAD=${KLEIDIAI_DIR}")
  else
    kai_args+=(-DECHO_MT_ENABLE_KLEIDIAI=OFF)
  fi

  if ! cmake -S "${APP_ROOT}/native/echo_mt" -B "${build_dir}" \
      -DCMAKE_TOOLCHAIN_FILE="${NDK_DIR}/build/cmake/android.toolchain.cmake" \
      -DANDROID_ABI=arm64-v8a \
      -DANDROID_PLATFORM=android-24 \
      -DANDROID_STL=c++_static \
      -DCMAKE_BUILD_TYPE=Release \
      -DLLAMA_CPP_DIR="${LLAMA_DIR}" \
      -DECHO_MT_ARM_ARCH="${arm_arch}" \
      -DECHO_MT_OUTPUT_NAME="${out_name}" \
      -DECHO_MT_BUILD_ARCH_LABEL="${label}" \
      "${kai_args[@]}" || \
     ! cmake --build "${build_dir}" --target echo_mt -j"$(nproc)"; then
    if [ "${enable_kai}" = "ON" ]; then
      echo "KleidiAI build failed for ${out_name}, retrying with native ARM SIMD only..." >&2
      rm -rf "${build_dir}"
      cmake -S "${APP_ROOT}/native/echo_mt" -B "${build_dir}" \
        -DCMAKE_TOOLCHAIN_FILE="${NDK_DIR}/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI=arm64-v8a \
        -DANDROID_PLATFORM=android-24 \
        -DANDROID_STL=c++_static \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLAMA_CPP_DIR="${LLAMA_DIR}" \
        -DECHO_MT_ARM_ARCH="${arm_arch}" \
        -DECHO_MT_OUTPUT_NAME="${out_name}" \
        -DECHO_MT_BUILD_ARCH_LABEL="${label}" \
        -DECHO_MT_ENABLE_KLEIDIAI=OFF
      cmake --build "${build_dir}" --target echo_mt -j"$(nproc)"
    else
      return 1
    fi
  fi

  cp "${build_dir}/lib${out_name}.so" "${out_so}"
  if [ -x "${STRIP_BIN}" ]; then
    "${STRIP_BIN}" --strip-unneeded "${out_so}"
  fi
}

build_variant "armv8-a"                     "echo_mt"         "arm64-v8"      "OFF"
build_variant "armv8.2-a+fp16+dotprod"      "echo_mt_dotprod" "arm64-dotprod" "ON"
build_variant "armv8.6-a+fp16+dotprod+i8mm" "echo_mt_i8mm"    "arm64-i8mm"    "ON"

ls -lh "${OUT_DIR}"/libecho_mt*.so
