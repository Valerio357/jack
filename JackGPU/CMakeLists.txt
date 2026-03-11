cmake_minimum_required(VERSION 3.20)
project(JackGPU C)

set(CMAKE_C_STANDARD 11)

# Find Vulkan headers only (we don't link against the loader)
# Try find_package first, fall back to manual path
find_package(Vulkan QUIET)
if(NOT Vulkan_FOUND)
    # MoltenVK or manual Vulkan SDK headers
    find_path(Vulkan_INCLUDE_DIRS vulkan/vulkan.h
        PATHS
            /usr/local/Cellar/molten-vk/1.4.1/libexec/include
            /usr/local/include
            /opt/homebrew/include
            $ENV{VULKAN_SDK}/include
    )
    if(NOT Vulkan_INCLUDE_DIRS)
        message(FATAL_ERROR "Vulkan headers not found")
    endif()
endif()

# ── Userspace Vulkan ICD DLL ──────────────────────────────────

add_library(jackgpu SHARED
    # ICD entry points and dispatch
    driver/icd.c
    driver/instance.c
    driver/physical_device.c
    driver/device.c
    driver/queue.c
    driver/memory.c
    driver/command_buffer.c
    driver/dispatch.c
    driver/sync.c

    # Venus wire protocol
    venus/encoder.c
    venus/decoder.c

    # Transport (guest ↔ host)
    transport/virtgpu.c
    transport/ring.c
    transport/d3dkmt.c
)

target_include_directories(jackgpu PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${Vulkan_INCLUDE_DIRS}
)

# Only export ICD entry points
if(WIN32)
    set_target_properties(jackgpu PROPERTIES
        PREFIX ""
        OUTPUT_NAME "jackgpu"
    )
    # Use .def file for exports
    target_sources(jackgpu PRIVATE driver/jackgpu.def)
else()
    # For development/testing on macOS/Linux
    target_compile_definitions(jackgpu PRIVATE JACKGPU_STUB_TRANSPORT=1)
    set_target_properties(jackgpu PROPERTIES
        C_VISIBILITY_PRESET hidden
    )
endif()

target_compile_definitions(jackgpu PRIVATE
    VK_NO_PROTOTYPES
    JACKGPU_ICD_BUILD
)

# ── Install ───────────────────────────────────────────────────

install(TARGETS jackgpu DESTINATION lib)
install(FILES manifest/jackgpu_x64.json DESTINATION share/vulkan/icd.d)
