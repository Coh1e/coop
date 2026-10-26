#pragma once
#include "app.hpp"
#include "data.hpp"
#include <vector>

namespace coop {
// Coop does not reimplement the NSIS installer format. Scoop's Expand-7zipArchive hands an NSIS
// installer payload to the separately installed 7-Zip helper, because 7-Zip itself understands the
// NSIS container, and Coop follows the same route: the helper found under apps/7zip/current unpacks
// the payload with Scoop's arguments, and Coop publishes the extracted tree. The helper is
// detected, never downloaded, installed or bundled, and the vendor setup.exe is never executed, so
// its install directory, registry, service, shortcut, [Run] and uninstall-registration effects do
// not happen.
struct NsisHelper {
    fs::path path;
    std::string problem;
};
// Local root first, then the optional global root, matching Scoop's Get-AppFilePath for 7zip.
NsisHelper nsis_helper(const Context& context);

// Content detection, not the declared file name, decides whether a downloaded archive payload is
// an NSIS installer: NSIS writes the FirstHeader magic DE AD BE EF followed by the ASCII signature
// "NullsoftInst". The byte offset is kept as evidence in the transaction journal.
struct NsisPayload {
    bool detected = false;
    std::uint64_t signature_offset = 0;
};
NsisPayload inspect_nsis_payload(const fs::path& path);

// The argument list Scoop 0.6.0's Expand-7zipArchive builds for one artifact. The extract_dir
// selection is reported separately so preview and journal state what was selected instead of only
// naming the rule.
struct NsisArguments {
    std::vector<std::string> arguments;
    std::string selection;
};
NsisArguments nsis_arguments(const fs::path& payload, const fs::path& destination,
                             const std::string& extract_directory);

// Unpack the NSIS installer payload into an empty, Coop-owned directory and return the journal
// record. stdout and stderr are kept in the transaction, and a non-zero helper exit fails the
// operation before any version is published.
Json extract_nsis_archive(const Context& context, const fs::path& helper, const fs::path& payload,
                          const fs::path& destination, const std::string& extract_directory,
                          const fs::path& transaction, std::size_t index);
}
