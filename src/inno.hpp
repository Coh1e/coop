#pragma once
#include "app.hpp"
#include "data.hpp"
#include <vector>

namespace coop {
// Coop does not reimplement the Inno Setup archive format. The declared external helper that Scoop
// itself uses (innounp, a separate software dependency installed in the selected root) unpacks the
// vendor installer's file payload, and Coop then publishes the same layout Scoop's
// Expand-InnoArchive produces: the files below the selected Inno directory, without running the
// vendor installer. The helper is detected, never downloaded or installed, and the vendor
// installer's own [Run], [Registry], service, shell and uninstall-registration effects are not
// executed. File timestamps and attributes are whatever innounp writes.
struct InnoHelper {
    fs::path path;
    std::string problem;
};
// Local root first, then the optional global root, matching Scoop's Get-AppFilePath lookup for
// innounp-unicode and then innounp under apps/<helper>/current.
InnoHelper inno_helper(const Context& context);

// The -c switch value Scoop's Expand-InnoArchive derives from the declared extract_dir. Preview and
// journal report the concrete selection, not only the rule.
std::string inno_selection(const std::string& extract_directory);

// The argument list Scoop 0.6.0's Expand-InnoArchive builds for one artifact. The selection switch
// is reported separately so the preview and journal can state which Inno directory was chosen.
struct InnoArguments {
    std::vector<std::string> arguments;
    std::string selection;
};
InnoArguments inno_arguments(const fs::path& setup, const fs::path& destination,
                             const std::string& extract_directory);

// Unpack the vendor installer payload into an empty, Coop-owned directory and return the journal
// record. stdout and stderr are kept in the transaction, and a non-zero helper exit fails the
// operation before any version is published.
Json extract_inno_archive(const Context& context, const fs::path& helper, const fs::path& setup,
                          const fs::path& destination, const std::string& extract_directory,
                          const fs::path& transaction, std::size_t index);
}
