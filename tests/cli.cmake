if(NOT EXISTS "${COOP_EXE}")
  message(FATAL_ERROR "Coop executable is not built")
endif()
file(MAKE_DIRECTORY "${TEST_ROOT}")
execute_process(COMMAND "${COOP_EXE}" unsupported-command WORKING_DIRECTORY "${TEST_ROOT}"
  RESULT_VARIABLE result OUTPUT_VARIABLE output ERROR_VARIABLE error)
if(NOT result EQUAL 2 OR NOT output STREQUAL "" OR NOT error MATCHES "unknown command")
  message(FATAL_ERROR "invalid command contract failed: ${result}, ${output}, ${error}")
endif()
execute_process(COMMAND "${COOP_EXE}" --version unexpected WORKING_DIRECTORY "${TEST_ROOT}"
  RESULT_VARIABLE result OUTPUT_VARIABLE output ERROR_VARIABLE error)
if(NOT result EQUAL 2 OR NOT output STREQUAL "")
  message(FATAL_ERROR "excess arguments were accepted: ${result}, ${output}, ${error}")
endif()
execute_process(COMMAND "${COOP_EXE}" --help WORKING_DIRECTORY "${TEST_ROOT}"
  RESULT_VARIABLE result OUTPUT_VARIABLE output ERROR_VARIABLE error)
if(NOT result EQUAL 0 OR NOT error STREQUAL "")
  message(FATAL_ERROR "help failed: ${result}, ${output}, ${error}")
endif()
if(NOT output MATCHES "^Usage: coop <command> \\[<args>\\]")
  message(FATAL_ERROR "help does not start with Scoop's usage line: ${output}")
endif()
# The page is `scoop help` with Coop's name: same rows, same summaries. A command that exists but is
# missing here (or a Coop-only row added here) means the page stopped matching Scoop.
foreach(command IN ITEMS alias bucket cache cat checkup cleanup config create depends download export
    help hold home import info install list prefix reset search shim status unhold uninstall update
    virustotal which)
  if(NOT output MATCHES "\n${command} +[A-Z]")
    message(FATAL_ERROR "help omitted ${command}: ${output}")
  endif()
endforeach()
if(output MATCHES "\n(init|recover) ")
  message(FATAL_ERROR "help listed a Coop-only command: ${output}")
endif()
execute_process(COMMAND "${COOP_EXE}" help WORKING_DIRECTORY "${TEST_ROOT}"
  RESULT_VARIABLE help_result OUTPUT_VARIABLE help_output ERROR_VARIABLE help_error)
if(NOT help_result EQUAL 0 OR NOT help_output STREQUAL output OR NOT help_error STREQUAL "")
  message(FATAL_ERROR "help and --help print different pages: ${help_output}")
endif()
execute_process(COMMAND "${COOP_EXE}" WORKING_DIRECTORY "${TEST_ROOT}"
  RESULT_VARIABLE bare_result OUTPUT_VARIABLE bare_output ERROR_VARIABLE bare_error)
if(NOT bare_result EQUAL 0 OR NOT bare_output STREQUAL output OR NOT bare_error STREQUAL "")
  message(FATAL_ERROR "the bare command does not print help: ${bare_output}")
endif()
execute_process(COMMAND "${COOP_EXE}" --version WORKING_DIRECTORY "${TEST_ROOT}"
  RESULT_VARIABLE result OUTPUT_VARIABLE output ERROR_VARIABLE error)
if(NOT result EQUAL 0 OR NOT output MATCHES "^coop [0-9]+\\.[0-9]+\\.[0-9]+" OR NOT error STREQUAL "")
  message(FATAL_ERROR "version failed: ${result}, ${output}, ${error}")
endif()
