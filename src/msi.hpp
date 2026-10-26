#pragma once
#include "package.hpp"

namespace coop {
// Coop's MSI backend extracts the administrative image data of an installer database instead of
// running it. The database is read through the Windows Installer database API, and embedded
// cabinets are decompressed through the Windows cabinet decompression API (both are Windows system
// components). No msiexec.exe process starts, no product is registered, nothing is elevated, no
// reboot is scheduled and the machine-level Windows Installer cache is not written.
//
// The boundary is explicit: only embedded cabinets (#name in the Media table) and uncompressed
// files stored in the MSI can be extracted. External cabinets, multi-part cabinets and
// vendor-specific installer payloads fail with a named error before a version is published.
std::optional<fs::path> msi_database_api();
std::optional<fs::path> cabinet_api();
// Extract the image into an empty, Coop-owned directory. The work directory holds temporary
// cabinet files and lives inside the Coop transaction. Returns the journal record describing what
// was read; on failure the destination is removed and the error names the failing table or file.
Json extract_msi_image(const fs::path& msi, const fs::path& destination, const fs::path& work_directory);
}
