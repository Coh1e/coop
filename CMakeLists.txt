cmake_minimum_required(VERSION 3.25)
project(coop VERSION 0.2.4 LANGUAGES C CXX)
if(NOT EXISTS "${PROJECT_SOURCE_DIR}/.local/deps/include/nlohmann/json.hpp")
  message(FATAL_ERROR "Run scripts/fetch-deps.ps1 to fetch pinned project-local dependencies")
endif()
if(NOT WIN32)
  message(FATAL_ERROR "Coop currently supports Windows only")
endif()
if(NOT EXISTS "${PROJECT_SOURCE_DIR}/.local/deps/sources/libgit2-1.9.7/CMakeLists.txt")
  message(FATAL_ERROR "Run scripts/fetch-deps.ps1 to fetch libgit2")
endif()
foreach(dependency IN ITEMS zlib-1.3.1/CMakeLists.txt xz-5.6.4/CMakeLists.txt
    zstd-1.5.7/build/cmake/CMakeLists.txt bzip2-1.0.8/bzlib.c libarchive-3.7.7/CMakeLists.txt)
  if(NOT EXISTS "${PROJECT_SOURCE_DIR}/.local/deps/sources/${dependency}")
    message(FATAL_ERROR "Run scripts/fetch-deps.ps1 to fetch archive dependencies")
  endif()
endforeach()
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_CLI OFF CACHE BOOL "" FORCE)
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(USE_HTTPS WinHTTP CACHE STRING "" FORCE)
set(USE_SSH OFF CACHE STRING "" FORCE)
set(USE_BUNDLED_ZLIB ON CACHE BOOL "" FORCE)
set(REGEX_BACKEND builtin CACHE STRING "" FORCE)
set(STATIC_CRT ON CACHE BOOL "" FORCE)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
set(CMAKE_FIND_USE_PACKAGE_REGISTRY OFF)
set(CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY OFF)
add_subdirectory("${PROJECT_SOURCE_DIR}/.local/deps/sources/libgit2-1.9.7" "${PROJECT_BINARY_DIR}/git2" EXCLUDE_FROM_ALL)
set(CMAKE_POLICY_VERSION_MINIMUM 3.5 CACHE STRING "" FORCE)
set(ZLIB_SOURCE "${PROJECT_SOURCE_DIR}/.local/deps/sources/zlib-1.3.1")
set(ZLIB_BINARY "${PROJECT_BINARY_DIR}/zlib")
file(MAKE_DIRECTORY "${ZLIB_BINARY}")
configure_file("${ZLIB_SOURCE}/zconf.h.cmakein" "${ZLIB_BINARY}/zconf.h" @ONLY)
add_library(coop_zlib STATIC
  "${ZLIB_SOURCE}/adler32.c" "${ZLIB_SOURCE}/compress.c" "${ZLIB_SOURCE}/crc32.c"
  "${ZLIB_SOURCE}/deflate.c" "${ZLIB_SOURCE}/gzclose.c" "${ZLIB_SOURCE}/gzlib.c"
  "${ZLIB_SOURCE}/gzread.c" "${ZLIB_SOURCE}/gzwrite.c" "${ZLIB_SOURCE}/inflate.c"
  "${ZLIB_SOURCE}/infback.c" "${ZLIB_SOURCE}/inftrees.c" "${ZLIB_SOURCE}/inffast.c"
  "${ZLIB_SOURCE}/trees.c" "${ZLIB_SOURCE}/uncompr.c" "${ZLIB_SOURCE}/zutil.c")
target_include_directories(coop_zlib PUBLIC "${ZLIB_SOURCE}" "${ZLIB_BINARY}")
target_compile_definitions(coop_zlib PRIVATE _CRT_SECURE_NO_DEPRECATE)
set_property(TARGET coop_zlib PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
set(ZLIB_INCLUDE_DIR "${ZLIB_SOURCE};${ZLIB_BINARY}" CACHE STRING "" FORCE)
set(ZLIB_LIBRARY "$<TARGET_FILE:coop_zlib>" CACHE STRING "" FORCE)
set(ZLIB_LIBRARIES "$<TARGET_FILE:coop_zlib>" CACHE STRING "" FORCE)
set(ZLIB_FOUND TRUE CACHE BOOL "" FORCE)
set(ZLIB_WINAPI FALSE CACHE BOOL "" FORCE)
set(ZLIB_WINAPI_WITH_LIB "$<TARGET_FILE:coop_zlib>" CACHE STRING "" FORCE)
set(ZLIB_DLL FALSE CACHE BOOL "" FORCE)
set(ZLIB_DLL_WITH_LIB "$<TARGET_FILE:coop_zlib>" CACHE STRING "" FORCE)
set(WITHOUT_ZLIB_DLL TRUE CACHE BOOL "" FORCE)
set(WITHOUT_ZLIB_DLL_WITH_LIB "$<TARGET_FILE:coop_zlib>" CACHE STRING "" FORCE)
set(ENABLE_NLS OFF CACHE BOOL "" FORCE)
set(CREATE_XZ_SYMLINKS OFF CACHE BOOL "" FORCE)
set(CREATE_LZMA_SYMLINKS OFF CACHE BOOL "" FORCE)
add_subdirectory("${PROJECT_SOURCE_DIR}/.local/deps/sources/xz-5.6.4" "${PROJECT_BINARY_DIR}/xz" EXCLUDE_FROM_ALL)
set(LIBLZMA_INCLUDE_DIR "${PROJECT_SOURCE_DIR}/.local/deps/sources/xz-5.6.4/src/liblzma/api" CACHE PATH "" FORCE)
set(LIBLZMA_LIBRARY "$<TARGET_FILE:liblzma>" CACHE STRING "" FORCE)
set(LIBLZMA_LIBRARIES "$<TARGET_FILE:liblzma>" CACHE STRING "" FORCE)
set(LIBLZMA_FOUND TRUE CACHE BOOL "" FORCE)
set(LIBLZMA_HAS_AUTO_DECODER TRUE CACHE BOOL "" FORCE)
set(LIBLZMA_HAS_EASY_ENCODER TRUE CACHE BOOL "" FORCE)
set(LIBLZMA_HAS_LZMA_PRESET TRUE CACHE BOOL "" FORCE)
set(LZMA_API_STATIC TRUE CACHE BOOL "" FORCE)
set(LZMA_API_STATIC_WITH_LIB "$<TARGET_FILE:liblzma>" CACHE STRING "" FORCE)
set(WITHOUT_LZMA_API_STATIC FALSE CACHE BOOL "" FORCE)
set(WITHOUT_LZMA_API_STATIC_WITH_LIB "$<TARGET_FILE:liblzma>" CACHE STRING "" FORCE)
set(HAVE_LZMA_STREAM_ENCODER_MT TRUE CACHE BOOL "" FORCE)
set(HAVE_WCSCMP TRUE CACHE BOOL "" FORCE)
set(HAVE_WCSCPY TRUE CACHE BOOL "" FORCE)
set(HAVE_WCSLEN TRUE CACHE BOOL "" FORCE)
set(HAVE_WMEMCMP TRUE CACHE BOOL "" FORCE)
# bzip2 has no CMake build of its own. Compile the fixed release sources directly so the core
# archive path needs neither bzip2.exe nor a system SDK.
set(BZIP2_SOURCE "${PROJECT_SOURCE_DIR}/.local/deps/sources/bzip2-1.0.8")
add_library(coop_bzip2 STATIC
  "${BZIP2_SOURCE}/blocksort.c" "${BZIP2_SOURCE}/bzlib.c" "${BZIP2_SOURCE}/compress.c"
  "${BZIP2_SOURCE}/crctable.c" "${BZIP2_SOURCE}/decompress.c" "${BZIP2_SOURCE}/huffman.c"
  "${BZIP2_SOURCE}/randtable.c" "${PROJECT_SOURCE_DIR}/src/bzip2_glue.c")
target_include_directories(coop_bzip2 PUBLIC "${BZIP2_SOURCE}")
target_compile_definitions(coop_bzip2 PRIVATE BZ_NO_STDIO _CRT_SECURE_NO_WARNINGS)
set_target_properties(coop_bzip2 PROPERTIES ARCHIVE_OUTPUT_DIRECTORY "${PROJECT_BINARY_DIR}/bzip2"
  MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
set(BZIP2_INCLUDE_DIR "${BZIP2_SOURCE}" CACHE STRING "" FORCE)
set(BZIP2_LIBRARIES "${PROJECT_BINARY_DIR}/bzip2/coop_bzip2.lib" CACHE STRING "" FORCE)
set(BZIP2_FOUND TRUE CACHE BOOL "" FORCE)
# zstd is built from its pinned CMake project and only its static library is linked. Configure the
# feature probes up front because the static archive does not exist until the build phase.
set(ZSTD_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(ZSTD_BUILD_SHARED OFF CACHE BOOL "" FORCE)
set(ZSTD_BUILD_STATIC ON CACHE BOOL "" FORCE)
set(ZSTD_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(ZSTD_BUILD_CONTRIB OFF CACHE BOOL "" FORCE)
set(ZSTD_LEGACY_SUPPORT OFF CACHE BOOL "" FORCE)
set(ZSTD_MULTITHREAD_SUPPORT OFF CACHE BOOL "" FORCE)
add_subdirectory("${PROJECT_SOURCE_DIR}/.local/deps/sources/zstd-1.5.7/build/cmake" "${PROJECT_BINARY_DIR}/zstd" EXCLUDE_FROM_ALL)
set(ZSTD_INCLUDE_DIR "${PROJECT_SOURCE_DIR}/.local/deps/sources/zstd-1.5.7/lib" CACHE PATH "" FORCE)
set(ZSTD_LIBRARY "${PROJECT_BINARY_DIR}/zstd/lib/zstd_static.lib" CACHE STRING "" FORCE)
set(ZSTD_FOUND TRUE CACHE BOOL "" FORCE)
set(HAVE_ZSTD_H 1 CACHE INTERNAL "" FORCE)
set(HAVE_LIBZSTD 1 CACHE INTERNAL "" FORCE)
set(HAVE_ZSTD_compressStream 1 CACHE INTERNAL "" FORCE)
set(ENABLE_BZip2 ON CACHE BOOL "" FORCE)
set(ENABLE_ZSTD ON CACHE BOOL "" FORCE)
set(ENABLE_LZ4 OFF CACHE BOOL "" FORCE)
set(ENABLE_LZO OFF CACHE BOOL "" FORCE)
set(ENABLE_OPENSSL OFF CACHE BOOL "" FORCE)
set(ENABLE_MBEDTLS OFF CACHE BOOL "" FORCE)
set(ENABLE_NETTLE OFF CACHE BOOL "" FORCE)
set(ENABLE_LIBXML2 OFF CACHE BOOL "" FORCE)
set(ENABLE_EXPAT OFF CACHE BOOL "" FORCE)
set(ENABLE_PCREPOSIX OFF CACHE BOOL "" FORCE)
set(ENABLE_PCRE2POSIX OFF CACHE BOOL "" FORCE)
set(ENABLE_LIBB2 OFF CACHE BOOL "" FORCE)
set(ENABLE_CNG OFF CACHE BOOL "" FORCE)
set(ENABLE_TAR OFF CACHE BOOL "" FORCE)
set(ENABLE_CPIO OFF CACHE BOOL "" FORCE)
set(ENABLE_CAT OFF CACHE BOOL "" FORCE)
set(ENABLE_UNZIP OFF CACHE BOOL "" FORCE)
set(ENABLE_TEST OFF CACHE BOOL "" FORCE)
set(ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory("${PROJECT_SOURCE_DIR}/.local/deps/sources/libarchive-3.7.7" "${PROJECT_BINARY_DIR}/archive" EXCLUDE_FROM_ALL)
add_dependencies(archive_static coop_bzip2 libzstd_static)
add_executable(coop src/main.cpp src/init.cpp src/data.cpp src/query.cpp src/cache.cpp src/appstate.cpp src/config.cpp src/tools.cpp src/runrecord.cpp src/catalog_index.cpp src/bucket.cpp src/git_bucket.cpp src/crypto.cpp src/ir_adapter.cpp src/ir_validate.cpp src/ir_plan.cpp src/ir_dependencies.cpp src/plan.cpp src/native.cpp src/archive.cpp src/msi.cpp src/inno.cpp src/nsis.cpp src/publish.cpp src/persist.cpp src/execute.cpp src/exposure.cpp src/user_environment.cpp src/shim.cpp src/script.cpp src/versions.cpp src/recovery.cpp src/faults.cpp src/progress.cpp src/timings.cpp)
# Lifecycle hook hosts load the pinned Scoop compatibility library from disk. It is shipped beside
# the executable so its provenance, version and license stay inspectable instead of being compiled
# into an opaque blob. The copy runs on every build because the library is data, not a compiled
# input: editing it must not require relinking coop.exe to update the runtime copy.
add_custom_target(coop_scoop_lib ALL
  COMMAND "${CMAKE_COMMAND}" -E copy_directory
    "${PROJECT_SOURCE_DIR}/assets/scoop-lib" "$<TARGET_FILE_DIR:coop>/scoop-lib"
  COMMENT "Copying the pinned Scoop compatibility library beside coop.exe")
add_dependencies(coop coop_scoop_lib)
target_include_directories(coop SYSTEM PRIVATE "${PROJECT_SOURCE_DIR}/.local/deps/include")
target_include_directories(coop SYSTEM PRIVATE "${PROJECT_SOURCE_DIR}/.local/deps/sources/libgit2-1.9.7/include")
target_include_directories(coop SYSTEM PRIVATE "${PROJECT_SOURCE_DIR}/.local/deps/sources/libarchive-3.7.7/libarchive")
target_link_libraries(coop PRIVATE libgit2package archive_static coop_zlib liblzma coop_bzip2 libzstd_static bcrypt winhttp shlwapi shell32 ole32 uuid msi cabinet)
configure_file("${PROJECT_SOURCE_DIR}/.local/deps/include/nlohmann/LICENSE.MIT"
  "${PROJECT_BINARY_DIR}/licenses/nlohmann-json.txt" COPYONLY)
configure_file("${PROJECT_SOURCE_DIR}/.local/deps/sources/libgit2-1.9.7/COPYING"
  "${PROJECT_BINARY_DIR}/licenses/libgit2.txt" COPYONLY)
configure_file("${PROJECT_SOURCE_DIR}/.local/deps/sources/libarchive-3.7.7/COPYING"
  "${PROJECT_BINARY_DIR}/licenses/libarchive.txt" COPYONLY)
configure_file("${PROJECT_SOURCE_DIR}/.local/deps/sources/zlib-1.3.1/LICENSE"
  "${PROJECT_BINARY_DIR}/licenses/zlib.txt" COPYONLY)
configure_file("${PROJECT_SOURCE_DIR}/.local/deps/sources/xz-5.6.4/COPYING.0BSD"
  "${PROJECT_BINARY_DIR}/licenses/xz.txt" COPYONLY)
configure_file("${PROJECT_SOURCE_DIR}/.local/deps/sources/zstd-1.5.7/LICENSE"
  "${PROJECT_BINARY_DIR}/licenses/zstd.txt" COPYONLY)
configure_file("${PROJECT_SOURCE_DIR}/.local/deps/sources/bzip2-1.0.8/LICENSE"
  "${PROJECT_BINARY_DIR}/licenses/bzip2.txt" COPYONLY)
target_compile_features(coop PRIVATE cxx_std_20)
target_compile_definitions(coop PRIVATE UNICODE _UNICODE LIBARCHIVE_STATIC COOP_VERSION="${PROJECT_VERSION}")
if(MSVC)
  target_compile_options(coop PRIVATE /W4 /WX /utf-8 /permissive-)
  set_property(TARGET coop PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()
include(CTest)
if(BUILD_TESTING)
  foreach(version IN ITEMS 1 2)
    add_executable(fixture-${version} tests/package_fixture.cpp)
    target_compile_definitions(fixture-${version} PRIVATE FIXTURE_VERSION="${version}")
    set_property(TARGET fixture-${version} PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    add_executable(persist-fixture-${version} tests/persist_fixture.cpp)
    target_compile_definitions(persist-fixture-${version} PRIVATE FIXTURE_VERSION="${version}" UNICODE _UNICODE)
    target_compile_features(persist-fixture-${version} PRIVATE cxx_std_20)
    if(MSVC)
      target_compile_options(persist-fixture-${version} PRIVATE /W4 /WX /utf-8 /permissive-)
    endif()
    set_property(TARGET persist-fixture-${version} PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
  endforeach()
  add_executable(process_guard tests/process_guard.cpp)
  target_compile_features(process_guard PRIVATE cxx_std_20)
  target_compile_definitions(process_guard PRIVATE UNICODE _UNICODE)
  if(MSVC)
    target_compile_options(process_guard PRIVATE /W4 /WX /utf-8 /permissive-)
    set_property(TARGET process_guard PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
  endif()
  add_executable(fixture-gui tests/gui_fixture.cpp)
  if(MSVC)
    target_compile_options(fixture-gui PRIVATE /W4 /WX /utf-8 /permissive-)
  endif()
  set_target_properties(fixture-gui PROPERTIES MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>"
    LINK_FLAGS "/SUBSYSTEM:WINDOWS /ENTRY:wWinMainCRTStartup")
  add_executable(fixture-env tests/env_fixture.cpp)
  if(MSVC)
    target_compile_options(fixture-env PRIVATE /W4 /WX /utf-8 /permissive-)
  endif()
  set_property(TARGET fixture-env PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
  add_test(NAME cli COMMAND "${CMAKE_COMMAND}" "-DCOOP_EXE=$<TARGET_FILE:coop>"
    "-DTEST_ROOT=${PROJECT_SOURCE_DIR}/.local/tests/测试 space" -P "${PROJECT_SOURCE_DIR}/tests/cli.cmake")
  foreach(option IN ITEMS version help)
    add_test(NAME cli_no_children_${option} COMMAND process_guard "$<TARGET_FILE:coop>" "--${option}")
  endforeach()
  # Either PowerShell runs the suite: pwsh is preferred, and Windows PowerShell 5.1 (which ships with
  # Windows) is a valid fallback so a fresh machine needs no extra runtime to configure and test.
  find_program(POWERSHELL_EXECUTABLE NAMES pwsh powershell REQUIRED)
  add_test(NAME source_hygiene COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/scripts/check-source-hygiene.ps1"
    -Root "${PROJECT_SOURCE_DIR}")
  add_test(NAME coverage_features COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/coverage-features.ps1")
  add_test(NAME coverage_gaps COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/coverage-gaps.ps1")
  add_test(NAME query COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/query.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/query 中文 space")
  add_test(NAME query_text COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/query-text.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/query-text")
  add_test(NAME update_bare COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/update-bare.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/update-bare")
  add_test(NAME cache COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/cache.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/cache")
  add_test(NAME inspect COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/inspect.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/inspect")
  add_test(NAME config COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/config.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/config")
  add_test(NAME import COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/import.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/import")
  add_test(NAME shim COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/shim.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/shim")
  add_test(NAME tools COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/tools.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/tools")
  add_test(NAME adhoc COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/adhoc.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/adhoc")
  add_test(NAME info_git COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/info-git.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/info-git")
  add_test(NAME stall COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/stall.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/stall")
  add_test(NAME switches COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/switches.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/switches")
  add_test(NAME force_recovery COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/force-recovery.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/force-recovery")
  add_test(NAME run_record COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/run-record.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/run-record")
  add_test(NAME search_index COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/search-index.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/search-index")
  add_test(NAME bucket_crlf COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/bucket-crlf.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/bucket-crlf")
  add_test(NAME seven_zip_sfx COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/seven-zip-sfx.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/seven-zip-sfx")
  add_test(NAME publish_lock COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/publish-lock.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/publish-lock")
  add_test(NAME search_remote COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/search-remote.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/search-remote")
  add_test(NAME preview_text COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/preview-text.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/preview-text")
  add_test(NAME path_batch COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/path-batch.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/path-batch 中文 space")
  add_test(NAME initialization COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/initialization.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/initialization 中文 space")
  add_test(NAME init_no_children COMMAND process_guard "$<TARGET_FILE:coop>" --root "${PROJECT_SOURCE_DIR}/.local/tests/initialization no children" init)
  foreach(command IN ITEMS list search info)
    set(query_args "--root" "${PROJECT_SOURCE_DIR}/.local/tests/query 中文 space/core" "${command}" "--json")
    if(NOT command STREQUAL "list")
      list(APPEND query_args "jq")
    endif()
    add_test(NAME query_no_children_${command} COMMAND process_guard "$<TARGET_FILE:coop>" ${query_args})
    set_tests_properties(query_no_children_${command} PROPERTIES DEPENDS query)
  endforeach()
  add_test(NAME bucket COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/bucket.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/bucket 中文")
  add_test(NAME performance COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/perf.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/performance 中文 space")
  add_test(NAME acceptance COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/acceptance.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/acceptance 中文 space")
  add_test(NAME plan COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/plan.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/plan 中文")
  add_test(NAME ir_pipeline COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/ir-pipeline.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/ir-pipeline 中文 space")
  add_test(NAME lifecycle COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/lifecycle.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/lifecycle 中文")
  add_test(NAME archive_lifecycle COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/archive-lifecycle.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/archive 中文 space")
  add_test(NAME archive_safety COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/archive-safety.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/archive-safety 中文 space")
  add_test(NAME publish_baseline COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/publish-baseline.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/publish baseline")
  add_test(NAME publish_contracts COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/publish-contracts.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/publish contracts")
  add_test(NAME publish_write_once COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/publish-write-once.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/publish write-once")
  add_test(NAME reinstall_refusal COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/reinstall-refusal.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/reinstall refusal")
  add_test(NAME cross_version COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/cross-version.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/cross version")
  add_test(NAME command_lines COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/command-lines.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/command lines")
  add_test(NAME suggest_notes COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/suggest-notes.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/suggest notes")
  add_test(NAME ansi_colors COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/ansi-colors.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/ansi colours")
  add_test(NAME update_lines COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/update-lines.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/update lines")
  add_test(NAME perf_attribution COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/perf-attribution.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/perf attribution")
  add_test(NAME sync_points COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/sync-points.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/sync points")
  add_test(NAME progress_coverage COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/progress-coverage.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/progress coverage")
  add_test(NAME output_gaps COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/output-gaps.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/output gaps")
  foreach(scenario IN ITEMS interrupt race)
    add_test(NAME lifecycle_${scenario} COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/lifecycle-${scenario}.ps1"
      -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/lifecycle-${scenario}")
  endforeach()
  add_test(NAME cleanup COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/cleanup.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/cleanup 中文 space")
  add_test(NAME old_versions COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/old-versions.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/old-versions 中文 space")
  add_test(NAME update COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/update.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/update 中文")
  add_test(NAME multi_artifact COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/multi-artifact.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/multi-artifact 中文 space")
  add_test(NAME persistence COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/persist.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/persist 中文 space")
  add_test(NAME dependencies COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/dependencies.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/dependencies 中文 space")
  add_test(NAME versions_bucket COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/versions-bucket.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/versions-bucket 中文 space")
  add_test(NAME update_input_change COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/update-input-change.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/update-input-change 中文")
  add_test(NAME scoop_interop COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/scoop-interop.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/scoop-interop 中文")
  add_test(NAME recovery COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/recovery.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/recovery 中文 space")
  add_test(NAME recovery_matrix COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/recovery-matrix.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/recovery-matrix 中文 space")
  add_test(NAME exposure COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/exposure.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/exposure 中文 space")
  add_test(NAME user_environment COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/user-environment.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/user-environment 中文 space")
  add_test(NAME psmodule COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/psmodule.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/psmodule 中文 space")
  # The generated Scoop bash wrapper substitutes its target without quoting the cygpath result,
  # exactly like Scoop; a root with spaces cannot exercise that branch, so this test uses a plain path.
  add_test(NAME command_entry_host COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/command-entry-host.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/command-entry-host" -RequirePythonHost)
  add_test(NAME manifest_shape COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/manifest-shape.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/manifest-shape")
  # These tests read and snapshot the real current-user environment. A shared resource lock keeps
  # ctest -j from interleaving their snapshots/writes; they must also not be run in parallel by
  # separate ctest invocations.
  set_tests_properties(acceptance exposure user_environment psmodule old_versions recovery_matrix PROPERTIES RESOURCE_LOCK coop_user_environment)
  add_test(NAME hooks COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/hooks.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/hooks 中文 space")
  add_test(NAME installers COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/installers.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/installers 中文 space")
  add_test(NAME installer_programs COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/installer-programs.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/installer-programs 中文 space")
  add_test(NAME msi_lifecycle COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/msi-lifecycle.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/msi-lifecycle 中文 space")
  add_test(NAME inno_lifecycle COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/inno-lifecycle.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/inno-lifecycle 中文 space")
  add_test(NAME nsis_lifecycle COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -NonInteractive -File "${PROJECT_SOURCE_DIR}/tests/nsis-lifecycle.ps1"
    -CoopExe "$<TARGET_FILE:coop>" -TestRoot "${PROJECT_SOURCE_DIR}/.local/tests/nsis-lifecycle 中文 space")
  add_executable(ir_reuse tests/ir_reuse_fixture.cpp src/ir_validate.cpp src/ir_plan.cpp src/ir_dependencies.cpp)
  target_include_directories(ir_reuse PRIVATE "${PROJECT_SOURCE_DIR}/src")
  target_compile_features(ir_reuse PRIVATE cxx_std_20)
  target_compile_options(ir_reuse PRIVATE /W4 /WX /utf-8 /permissive-)
  set_property(TARGET ir_reuse PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
  add_test(NAME ir_reuse COMMAND ir_reuse)

  # The fast lane: the tests that finish in a couple of seconds and cover the output contract, the
  # plan pipeline and the small helpers. `scripts/build.ps1 -Action test-fast` runs exactly these;
  # the full suite stays the closing step.
  set_property(TEST source_hygiene coverage_features coverage_gaps query plan ir_pipeline ir_reuse
    manifest_shape command_lines update_lines output_gaps progress_coverage suggest_notes ansi_colors
    reinstall_refusal cross_version sync_points perf_attribution publish_contracts publish_write_once
    bucket cleanup dependencies path_batch
    PROPERTY LABELS fast)
endif()
