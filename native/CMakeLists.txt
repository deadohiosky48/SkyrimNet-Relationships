cmake_minimum_required(VERSION 3.21)

# ---------------------------------------------------------------------------
# SkyrimNetRelationships.dll: the dashboard's native host (design 6.5, 7.1).
#
# Modelled on SkyrimNet-Kinship's SKSE_Source/CMakeLists.txt, which is proven
# on this stack. Three deliberate differences:
#   1. /MD, not /MT (below);
#   2. no SKSE Menu Framework, so none of its defines or warning suppressions;
#   3. deployment lives in tools/build-dll.ps1, which reads the staging folder
#      from tools/local.settings.ps1, rather than in a cache variable here.
# ---------------------------------------------------------------------------

# /MD: STATIC LIBRARIES, DYNAMIC CRT. The DLL only hosts the dashboard today and
# needs none of SkyrimNet's C++ API, but that API crosses std::function and
# std::string over the DLL boundary and says both sides must share the CRT.
# Building /MD from day one means adding a native decorator later is a feature,
# not a CRT migration (STANDALONE_NATIVE_PLUGIN.md, "Build setup").
#
# Set BEFORE project(): the vcpkg toolchain installs the manifest's packages
# during the first project() call, so a triplet chosen afterwards is too late
# unless the command line also passes it. tools/build-dll.ps1 passes it too.
set(VCPKG_TARGET_TRIPLET "x64-windows-static-md" CACHE STRING "")
set(VCPKG_OVERLAY_TRIPLETS "${CMAKE_CURRENT_SOURCE_DIR}/cmake" CACHE STRING "")

project(SkyrimNetRelationships VERSION 2.0.1 LANGUAGES CXX)

set(CommonLibPath "extern/CommonLibSSE-NG")
set(CommonLibName "CommonLibSSE")

set(BUILD_TESTS OFF CACHE BOOL "" FORCE)

# Before add_subdirectory, so CommonLib's own translation units get it too. A
# mixed /MT and /MD link fails with LNK2038 at best.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL" CACHE STRING "" FORCE)

# ---------------------------------------------------------------------------
# Keep the builder's directory layout out of the shipped binary.
#
# __FILE__ and std::source_location bake the ABSOLUTE source path into the DLL,
# and CommonLibSSE-NG's logging and assert macros use both heavily. Kinship's
# first two releases shipped eight such paths each. /d1trimfile: is
# undocumented but stable, and it must come BEFORE add_subdirectory:
# add_compile_options only reaches subdirectories added after the call, and
# most of the leaked paths come from CommonLib's translation units, not ours.
# tools/package.ps1 still refuses to ship a DLL carrying a path, because an
# undocumented flag can stop working without failing the build.
# ---------------------------------------------------------------------------
if(MSVC)
    add_compile_options("/d1trimfile:${CMAKE_CURRENT_SOURCE_DIR}/")
endif()

if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${CommonLibPath}/CMakeLists.txt")
    message(FATAL_ERROR
        "CommonLibSSE-NG is missing at native/${CommonLibPath}.\n"
        "Fetch it first:\n"
        "  pwsh -ExecutionPolicy Bypass -File tools\\build-dll.ps1 -Setup\n"
        "See native/README.md.")
endif()

# CommonLibSSE-NG expects RAPIDCSV_INCLUDE_DIRS to be set by the CONSUMING
# project and fails at generate time with "set to NOTFOUND" if it is not, so
# this runs BEFORE add_subdirectory.
#
# directxtk and rapidcsv are CommonLibSSE-NG's dependencies, not ours. Kinship
# dropped both once on the assumption they were unused, and both had to come
# back. If a dependency looks unused, check whether CommonLib wants it first.
find_path(RAPIDCSV_INCLUDE_DIRS
    NAMES rapidcsv.h
    PATH_SUFFIXES rapidcsv
    REQUIRED
)

add_subdirectory(${CommonLibPath} ${CommonLibName} EXCLUDE_FROM_ALL)

find_package(nlohmann_json CONFIG REQUIRED)
find_package(spdlog CONFIG REQUIRED)

set(SOURCES
    plugin.cpp
    src/BioPlan.cpp
    src/Dashboard.cpp
    src/Display.cpp
    src/History.cpp
    src/Hotkey.cpp
    src/MeridianHost.cpp
    src/Model.cpp
    src/Natives.cpp
    src/Notices.cpp
    src/PrismaHost.cpp
    src/Settings.cpp
)

# add_commonlibsse_plugin, NOT add_library(SHARED).
#
# THIS IS WHAT MAKES SKSE LOAD THE DLL AT ALL. The helper generates the plugin
# version data SKSE reads at startup, and it is also what
# SKSE.GetPluginVersion("SkyrimNetRelationships") answers from, which is the
# Papyrus side's presence gate. A plain shared library builds, deploys, and is
# then rejected with "no version data" in skse64.log.
include("${CommonLibPath}/cmake/CommonLibSSE.cmake")
add_commonlibsse_plugin(${PROJECT_NAME} SOURCES ${SOURCES} ${CMAKE_CURRENT_SOURCE_DIR}/PCH.h)

target_compile_features(${PROJECT_NAME} PRIVATE cxx_std_23)
target_precompile_headers(${PROJECT_NAME} PRIVATE PCH.h)

target_include_directories(${PROJECT_NAME} PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_link_libraries(${PROJECT_NAME} PRIVATE
    CommonLibSSE::CommonLibSSE
    nlohmann_json::nlohmann_json
    spdlog::spdlog
)

# Kinship also defines UNICODE and _UNICODE, but only because
# SKSEMenuFramework.h calls GetModuleHandle with a wide literal. Nothing here
# does: the vendored Meridian loader calls GetModuleHandleW by name.
target_compile_definitions(${PROJECT_NAME} PRIVATE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
)

if(MSVC)
    target_compile_options(${PROJECT_NAME} PRIVATE
        /W4
        /permissive-
        /Zc:preprocessor
        /utf-8            # comments and log lines may carry non-ASCII
    )
endif()
