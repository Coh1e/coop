#pragma once
#include "package.hpp"
#include <cstdint>
#include <functional>
#include <string>

namespace coop {
// One downloaded artifact, as the execution layer knows it. The execution layer no longer decides
// which mechanism applies extract_dir, and no longer knows whether a mechanism unpacks into its own
// working tree first: both are facts about the payload, not about the install plan.
struct ArtifactPublication {
    ir::ArchiveFormat format;
    fs::path downloaded;
    std::string filename;          // the declared artifact name, as journal records name it
    fs::path extract_directory;    // Scoop's extract_dir; consumed here exactly once
    fs::path extract_destination;  // Scoop's extract_to; a relative root below the staging directory
};

// Called once for an artifact that an external mechanism unpacked, before its tree is merged, so a
// crash between unpacking and merging still leaves the record recovery needs. The key names the
// journal array the entry belongs to, because only this seam knows which mechanism unpacked what.
using PublicationRecorder = std::function<void(const std::string& journal_key, Json entry)>;

// Publish one artifact's payload into the package staging directory. Every artifact format crosses
// this seam: the native reader writes its entries straight into the destination, once, while the
// MSI image, Inno Setup and NSIS backends unpack into their own working tree and have that tree
// merged afterwards. extract_dir and extract_to are applied exactly once, whichever mechanism
// unpacked the payload, and the selection rules the backends disagree about (-c for Inno Setup,
// -ir! for NSIS) stay beside the code that builds those argument lists.
void publish_artifact(const Context& context, const ArtifactPublication& publication,
                      const fs::path& stage, const fs::path& transaction, std::uint64_t index,
                      const PublicationRecorder& record);
}
