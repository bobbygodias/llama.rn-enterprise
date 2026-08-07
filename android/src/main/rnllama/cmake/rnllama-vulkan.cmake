include_guard(GLOBAL)

include(ExternalProject)

# Adds the prefixed llama.cpp Vulkan backend to one rnllama target.
#
# The target compiler is the Android NDK toolchain, while vulkan-shaders-gen
# must execute on the build host. This mirrors upstream llama.cpp's split
# without importing its ggml_add_backend_library CMake framework.
function(rnllama_enable_vulkan target_name)
    set(VULKAN_SOURCE_DIR "${RNLLAMA_LIB_DIR}/ggml-vulkan")
    set(VULKAN_BACKEND_SOURCE "${VULKAN_SOURCE_DIR}/ggml-vulkan.cpp")
    set(VULKAN_SHADER_SOURCE_DIR "${VULKAN_SOURCE_DIR}/vulkan-shaders")

    if (NOT EXISTS "${VULKAN_BACKEND_SOURCE}" OR
        NOT EXISTS "${RNLLAMA_LIB_DIR}/ggml-vulkan.h" OR
        NOT EXISTS "${VULKAN_SHADER_SOURCE_DIR}/vulkan-shaders-gen.cpp")
        message(FATAL_ERROR
            "The generated Vulkan source tree is missing. Run "
            "scripts/bootstrap-enterprise-vulkan.sh after the normal bootstrap.")
    endif()

    # libvulkan.so and the C/C++ Vulkan headers come from the Android NDK.
    find_library(RNLLAMA_VULKAN_LIBRARY vulkan)
    if (NOT RNLLAMA_VULKAN_LIBRARY)
        message(FATAL_ERROR "Android NDK Vulkan loader library was not found")
    endif()

    # Shader compilation runs on the host. VULKAN_SDK is preferred, while
    # distro packages remain usable on Linux CI.
    find_program(
        RNLLAMA_GLSLC_EXECUTABLE
        NAMES glslc
        HINTS "$ENV{VULKAN_SDK}/bin"
        NO_CMAKE_FIND_ROOT_PATH
    )
    if (NOT RNLLAMA_GLSLC_EXECUTABLE)
        message(FATAL_ERROR
            "glslc was not found on the build host. Install the Vulkan SDK or "
            "place glslc on PATH before building the Vulkan variant.")
    endif()

    # ggml-vulkan.cpp uses SPIR-V enum definitions at compile time. They are
    # header-only and may safely come from the host Vulkan SDK during an Android
    # cross-build.
    find_path(
        RNLLAMA_SPIRV_INCLUDE_DIR
        NAMES
            spirv/unified1/spirv.hpp
            spirv-headers/spirv.hpp
            spirv.hpp
        HINTS
            "$ENV{VULKAN_SDK}/include"
            /usr/include
            /usr/local/include
        NO_CMAKE_FIND_ROOT_PATH
    )
    if (NOT RNLLAMA_SPIRV_INCLUDE_DIR)
        message(FATAL_ERROR
            "SPIR-V Headers were not found. Install SPIRV-Headers or provide "
            "them through VULKAN_SDK/include.")
    endif()

    set(HOST_TOOLCHAIN_FILE "")
    if (CMAKE_CROSSCOMPILING)
        find_program(
            HOST_C_COMPILER
            NAMES clang gcc cc
            NO_CMAKE_FIND_ROOT_PATH
        )
        find_program(
            HOST_CXX_COMPILER
            NAMES clang++ g++ c++
            NO_CMAKE_FIND_ROOT_PATH
        )
        if (NOT HOST_C_COMPILER OR NOT HOST_CXX_COMPILER)
            message(FATAL_ERROR
                "Host C/C++ compilers are required to build vulkan-shaders-gen")
        endif()

        set(CMAKE_RUNTIME_OUTPUT_DIRECTORY
            "${CMAKE_CURRENT_BINARY_DIR}/${target_name}-vulkan-host")
        set(HOST_TOOLCHAIN_FILE
            "${CMAKE_CURRENT_BINARY_DIR}/${target_name}-host-toolchain.cmake")
        configure_file(
            "${VULKAN_SOURCE_DIR}/cmake/host-toolchain.cmake.in"
            "${HOST_TOOLCHAIN_FILE}"
            @ONLY
        )
    endif()

    set(VULKAN_SHADER_GEN_ARGS
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX=${CMAKE_CURRENT_BINARY_DIR}/${target_name}-vulkan-host
        -DCMAKE_INSTALL_BINDIR=.
    )
    if (HOST_TOOLCHAIN_FILE)
        list(APPEND VULKAN_SHADER_GEN_ARGS
            -DCMAKE_TOOLCHAIN_FILE=${HOST_TOOLCHAIN_FILE})
    endif()

    set(VULKAN_SHADER_GEN_TARGET "${target_name}_vulkan_shaders_gen")
    ExternalProject_Add(
        ${VULKAN_SHADER_GEN_TARGET}
        SOURCE_DIR "${VULKAN_SHADER_SOURCE_DIR}"
        BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/${target_name}-vulkan-shaders-gen"
        CMAKE_ARGS ${VULKAN_SHADER_GEN_ARGS}
        BUILD_COMMAND ${CMAKE_COMMAND} --build . --config Release
        INSTALL_COMMAND ${CMAKE_COMMAND} -E env --unset=DESTDIR
                        ${CMAKE_COMMAND} --install . --config Release
        BUILD_ALWAYS TRUE
    )

    if (CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows")
        set(VULKAN_SHADER_GEN_SUFFIX ".exe")
    else()
        set(VULKAN_SHADER_GEN_SUFFIX "")
    endif()

    set(VULKAN_SHADER_GEN_EXECUTABLE
        "${CMAKE_CURRENT_BINARY_DIR}/${target_name}-vulkan-host/"
        "vulkan-shaders-gen${VULKAN_SHADER_GEN_SUFFIX}")
    string(CONCAT VULKAN_SHADER_GEN_EXECUTABLE ${VULKAN_SHADER_GEN_EXECUTABLE})

    set(VULKAN_GENERATED_DIR
        "${CMAKE_CURRENT_BINARY_DIR}/${target_name}-vulkan-generated")
    set(VULKAN_SPV_DIR "${VULKAN_GENERATED_DIR}/spv")
    set(VULKAN_SHADER_HEADER
        "${VULKAN_GENERATED_DIR}/ggml-vulkan-shaders.hpp")

    file(MAKE_DIRECTORY "${VULKAN_GENERATED_DIR}" "${VULKAN_SPV_DIR}")
    file(GLOB VULKAN_SHADER_FILES CONFIGURE_DEPENDS
        "${VULKAN_SHADER_SOURCE_DIR}/*.comp")
    file(GLOB VULKAN_SHADER_GEN_SOURCES CONFIGURE_DEPENDS
        "${VULKAN_SHADER_SOURCE_DIR}/*.cpp"
        "${VULKAN_SHADER_SOURCE_DIR}/*.h")

    add_custom_command(
        OUTPUT "${VULKAN_SHADER_HEADER}"
        COMMAND "${VULKAN_SHADER_GEN_EXECUTABLE}"
            --output-dir "${VULKAN_SPV_DIR}"
            --target-hpp "${VULKAN_SHADER_HEADER}"
        DEPENDS
            ${VULKAN_SHADER_GEN_SOURCES}
            ${VULKAN_SHADER_GEN_TARGET}
        COMMENT "Generating Vulkan shader registry for ${target_name}"
        VERBATIM
    )

    set(VULKAN_GENERATED_SOURCES "")
    foreach(VULKAN_SHADER_FILE_FULL ${VULKAN_SHADER_FILES})
        get_filename_component(VULKAN_SHADER_FILE
            "${VULKAN_SHADER_FILE_FULL}" NAME)
        set(VULKAN_SHADER_CPP
            "${VULKAN_GENERATED_DIR}/${VULKAN_SHADER_FILE}.cpp")

        add_custom_command(
            OUTPUT "${VULKAN_SHADER_CPP}"
            DEPFILE "${VULKAN_SHADER_CPP}.d"
            COMMAND "${VULKAN_SHADER_GEN_EXECUTABLE}"
                --glslc "${RNLLAMA_GLSLC_EXECUTABLE}"
                --source "${VULKAN_SHADER_FILE_FULL}"
                --output-dir "${VULKAN_SPV_DIR}"
                --target-hpp "${VULKAN_SHADER_HEADER}"
                --target-cpp "${VULKAN_SHADER_CPP}"
            DEPENDS
                "${VULKAN_SHADER_FILE_FULL}"
                ${VULKAN_SHADER_GEN_SOURCES}
                ${VULKAN_SHADER_GEN_TARGET}
            COMMENT "Compiling Vulkan shader ${VULKAN_SHADER_FILE}"
            VERBATIM
        )
        list(APPEND VULKAN_GENERATED_SOURCES "${VULKAN_SHADER_CPP}")
    endforeach()

    target_sources(${target_name} PRIVATE
        "${VULKAN_BACKEND_SOURCE}"
        "${VULKAN_SHADER_HEADER}"
        ${VULKAN_GENERATED_SOURCES}
    )
    target_include_directories(${target_name} PRIVATE
        "${VULKAN_GENERATED_DIR}"
        "${RNLLAMA_SPIRV_INCLUDE_DIR}"
    )
    target_compile_definitions(${target_name} PRIVATE LM_GGML_USE_VULKAN)
    target_link_libraries(${target_name} PRIVATE "${RNLLAMA_VULKAN_LIBRARY}")

    message(STATUS
        "Vulkan enabled for ${target_name}; glslc=${RNLLAMA_GLSLC_EXECUTABLE}")
endfunction()
