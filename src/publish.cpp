#include "publish.hpp"
#include "archive.hpp"
#include "data.hpp"
#include "inno.hpp"
#include "msi.hpp"
#include "nsis.hpp"
#include <stdexcept>

namespace coop {
namespace {
// Every external mechanism reports the same two facts about the artifact it unpacked, next to its own
// record, so the journal entries stay uniform without repeating the decoration at each branch.
Json with_origin(Json entry,std::uint64_t index,const std::string& filename) {
    entry["index"] = index;
    entry["filename"] = filename;
    return entry;
}
}
void publish_artifact(const Context& context, const ArtifactPublication& publication,
                      const fs::path& stage, const fs::path& transaction, std::uint64_t index,
                      const PublicationRecorder& record) {
    const auto working = transaction/(L"extract-"+std::to_wstring(index));
    const auto destination = publication.extract_destination.empty()
        ? stage : stage/publication.extract_destination;
    bool extracted_directly = false;
    // Inno Setup extraction selects the declared Inno directory with innounp's own -c switch, so the
    // merge starts at the extracted root instead of applying extract_dir a second time.
    fs::path merge_directory = publication.extract_directory;
    if (publication.format == ir::ArchiveFormat::msi) {
        // MSI artifacts are extracted from a read-only view of the installer database and its
        // embedded cabinets. The journal records that no msiexec process, machine cache entry,
        // elevation or reboot is involved, next to what was actually read.
        auto entry = extract_msi_image(publication.downloaded,working,
            transaction/(L"msi-work-"+std::to_wstring(index)));
        record("msi_extractions",with_origin(std::move(entry),index,publication.filename));
    } else if (publication.format == ir::ArchiveFormat::inno_setup) {
        const auto helper = inno_helper(context);
        if (helper.path.empty()) throw std::runtime_error(helper.problem);
        auto entry = extract_inno_archive(context,helper.path,publication.downloaded,working,
            path_text(publication.extract_directory),transaction,index);
        record("inno_extractions",with_origin(std::move(entry),index,publication.filename));
        merge_directory.clear();
    } else if (publication.format == ir::ArchiveFormat::seven_zip &&
               inspect_seven_zip_sfx(publication.downloaded).detected) {
        // A 7z SFX carries a PE stub in front of the stream and often uses options the native reader
        // rejects, so it goes to the helper Scoop also uses. Without a helper the native reader is
        // still tried, and its own error says what happened.
        const auto helper = nsis_helper(context);
        if (helper.path.empty()) {
            extract_archive(publication.downloaded,destination,publication.extract_directory);
            extracted_directly = true;
        } else {
            auto entry = extract_seven_zip_sfx(context,helper.path,publication.downloaded,working,
                path_text(publication.extract_directory),transaction,index);
            record("seven_zip_sfx_extractions",with_origin(std::move(entry),index,publication.filename));
        }
    } else if ((publication.format == ir::ArchiveFormat::zip ||
                publication.format == ir::ArchiveFormat::seven_zip) &&
               inspect_nsis_payload(publication.downloaded).detected) {
        // The declared suffix only describes the transport. An NSIS installer is unpacked by the
        // 7-Zip helper that Scoop's Expand-7zipArchive also uses; the helper is detected in the
        // selected root and never downloaded.
        const auto helper = nsis_helper(context);
        if (helper.path.empty()) throw std::runtime_error(helper.problem);
        auto entry = extract_nsis_archive(context,helper.path,publication.downloaded,working,
            path_text(publication.extract_directory),transaction,index);
        record("nsis_extractions",with_origin(std::move(entry),index,publication.filename));
    } else {
        // The native reader publishes straight into the staging directory with extract_dir applied
        // on the way in, so the tree is written once instead of being copied afterwards.
        extract_archive(publication.downloaded,destination,publication.extract_directory);
        extracted_directly = true;
    }
    if (!extracted_directly) {
        // Installer-format extractors write their own working tree first, so only those payloads
        // still need the merge.
        merge_archive_tree(working,merge_directory,destination);
        erase_tree(working);
    }
}
}
