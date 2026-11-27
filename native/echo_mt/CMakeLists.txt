cmake_minimum_required(VERSION 3.18)
project(echo_mt LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if (NOT DEFINED LLAMA_CPP_DIR OR NOT EXISTS "${LLAMA_CPP_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "Please pass -DLLAMA_CPP_DIR=<path to llama.cpp STQ_0>")
endif()

# 全静态编入单一共享库，避免携带多余 .so
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_TOOLS_INSTALL OFF CACHE BOOL "" FORCE)
set(LLAMA_TESTS_INSTALL OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(LLAMA_HTTPLIB OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_CPU_REPACK ON CACHE BOOL "" FORCE)

set(ECHO_MT_ARM_ARCH "armv8-a" CACHE STRING "ARM64 architecture target for ggml-cpu")
set(ECHO_MT_OUTPUT_NAME "echo_mt" CACHE STRING "Output shared library base name")
set(ECHO_MT_BUILD_ARCH_LABEL "host" CACHE STRING "Build variant identifier exposed via echo_mt_build_arch")
option(ECHO_MT_ENABLE_KLEIDIAI "Enable KleidiAI optimized ARM kernels" OFF)

if (ANDROID AND ANDROID_ABI STREQUAL "arm64-v8a")
    set(GGML_CPU_ARM_ARCH "${ECHO_MT_ARM_ARCH}" CACHE STRING "" FORCE)
    if (ECHO_MT_ENABLE_KLEIDIAI)
        set(GGML_CPU_KLEIDIAI ON CACHE BOOL "" FORCE)
    else()
        set(GGML_CPU_KLEIDIAI OFF CACHE BOOL "" FORCE)
    endif()
endif()

add_subdirectory("${LLAMA_CPP_DIR}" llama_cpp_build EXCLUDE_FROM_ALL)

add_library(echo_mt SHARED
    echo_mt_capi.cpp
    echo_mt_capi.h
)

set_target_properties(echo_mt PROPERTIES OUTPUT_NAME "${ECHO_MT_OUTPUT_NAME}")

target_compile_definitions(echo_mt PRIVATE
    ECHO_MT_BUILD_ARCH_LABEL="${ECHO_MT_BUILD_ARCH_LABEL}"
)

target_include_directories(echo_mt PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${LLAMA_CPP_DIR}/include"
)

target_link_libraries(echo_mt PRIVATE llama)

if (ANDROID)
    target_link_libraries(echo_mt PRIVATE log)
    # 兼容 Android 15 16KB 页大小对齐要求，并隔离内部 ggml/llama 符号防止多变体互相抢占
    target_link_options(echo_mt PRIVATE
        "-Wl,-z,max-page-size=16384"
        "-Wl,-Bsymbolic"
        "-Wl,--exclude-libs,ALL"
    )
endif()
