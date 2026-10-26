/* bzip2 1.0.8 asks the embedding application for this callback when BZ_NO_STDIO is
 * used. The archive path never writes to stdio; an internal consistency failure is fatal
 * for the current extraction and is surfaced as a normal archive failure. */
#include <stdlib.h>

void bz_internal_error(int errcode) {
    (void)errcode;
    abort();
}
