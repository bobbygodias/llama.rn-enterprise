# Build knobs shared by the two Android CMake entry points:
#   android/src/main/CMakeLists.txt          (AGP / build-from-source)
#   android/src/main/rnllama/CMakeLists.txt  (standalone, scripts/build-android.sh)
#
# A directory guard is intentional. The parent and rnllama subdirectory each
# schedule a different deferred Enterprise Vulkan target after their local
# build functions have been declared.
include_guard(DIRECTORY)

# --- ccache ------------------------------------------------------------------
# Each arm64 build compiles the whole llama.cpp tree once per CPU-feature
# variant, so a warm compiler cache is worth a lot on CI and on rebuilds.
option(RNLLAMA_CCACHE "Use ccache to speed up recompilation" ON)

if (RNLLAMA_CCACHE AND NOT CMAKE_C_COMPILER_LAUNCHER)
    find_program(RNLLAMA_CCACHE_BIN NAMES ccache sccache)
    if (RNLLAMA_CCACHE_BIN)
        # include() runs in the calling scope, so these reach the targets defined
        # there and any add_subdirectory() below it.
        set(CMAKE_C_COMPILER_LAUNCHER   ${RNLLAMA_CCACHE_BIN})
        set(CMAKE_CXX_COMPILER_LAUNCHER ${RNLLAMA_CCACHE_BIN})
        message(STATUS "rnllama: using compiler cache ${RNLLAMA_CCACHE_BIN}")
    else()
        message(STATUS "rnllama: ccache not found, compiling without a compiler cache")
    endif()
endif()

# --- variant selection -------------------------------------------------------
# Every variant is a full copy of the source tree built with different -march
# flags, so building all of them costs ~4 min each on a 4-core machine. An empty
# value (the default) builds the upstream variants; CI narrows this down to the
# variants that actually exercise distinct code paths.
set(RNLLAMA_ANDROID_VARIANTS "" CACHE STRING
    "Comma/semicolon-separated subset of rnllama library variants to build (empty = upstream defaults)")

if (RNLLAMA_ANDROID_VARIANTS)
    message(STATUS "rnllama: restricted to variants ${RNLLAMA_ANDROID_VARIANTS}")
endif()

# `name` is the library variant name (e.g. rnllama_v8_2_dotprod), which the JNI
# wrappers are keyed off as well.
function(rnllama_variant_enabled name result)
    if (RNLLAMA_ANDROID_VARIANTS STREQUAL "")
        set(${result} TRUE PARENT_SCOPE)
        return()
    endif()

    string(REPLACE "," ";" wanted "${RNLLAMA_ANDROID_VARIANTS}")
    if ("${name}" IN_LIST wanted)
        set(${result} TRUE PARENT_SCOPE)
    else()
        set(${result} FALSE PARENT_SCOPE)
    endif()
endfunction()

# --- PocketPal Enterprise Vulkan variant ------------------------------------
# Opt-in by naming the variant in RNLLAMA_ANDROID_VARIANTS. Keeping it out of
# the empty/default set means ordinary llama.rn builds do not suddenly require
# a host Vulkan SDK and do not pay the shader-generation cost.
set(RNLLAMA_ENTERPRISE_VULKAN_VARIANT
    "rnllama_v8_2_dotprod_vulkan")

string(REPLACE "," ";" RNLLAMA_REQUESTED_VARIANTS
    "${RNLLAMA_ANDROID_VARIANTS}")
if (RNLLAMA_ENTERPRISE_VULKAN_VARIANT IN_LIST RNLLAMA_REQUESTED_VARIANTS)
    set(RNLLAMA_ENTERPRISE_VULKAN ON)
else()
    set(RNLLAMA_ENTERPRISE_VULKAN OFF)
endif()

if (RNLLAMA_ENTERPRISE_VULKAN)
    if (CMAKE_VERSION VERSION_LESS 3.19)
        message(FATAL_ERROR
            "PocketPal Enterprise Vulkan requires CMake 3.19 or newer")
    endif()

    get_filename_component(RNLLAMA_CURRENT_DIR_NAME
        "${CMAKE_CURRENT_SOURCE_DIR}" NAME)

    if (RNLLAMA_CURRENT_DIR_NAME STREQUAL "rnllama")
        include("${CMAKE_CURRENT_LIST_DIR}/../rnllama/cmake/rnllama-vulkan.cmake")

        function(rnllama_add_enterprise_vulkan_library)
            if (ANDROID_ABI AND ANDROID_ABI STREQUAL "arm64-v8a")
                build_rnllama_library(
                    "rnllama_v8_2_dotprod_vulkan"
                    "arm"
                    "-march=armv8.2-a+dotprod"
                )
                if (TARGET rnllama_v8_2_dotprod_vulkan)
                    rnllama_enable_vulkan(rnllama_v8_2_dotprod_vulkan)
                endif()
            endif()
        endfunction()

        cmake_language(DEFER CALL rnllama_add_enterprise_vulkan_library)
    else()
        function(rnllama_add_enterprise_vulkan_jni)
            if (ANDROID_ABI AND ANDROID_ABI STREQUAL "arm64-v8a")
                build_rnllama_jni(
                    "rnllama_jni_v8_2_dotprod_vulkan"
                    "rnllama_v8_2_dotprod_vulkan"
                    "arm"
                    "-march=armv8.2-a+dotprod"
                )
            endif()
        endfunction()

        cmake_language(DEFER CALL rnllama_add_enterprise_vulkan_jni)
    endif()
endif()
