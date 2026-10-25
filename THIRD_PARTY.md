# Third-party source dependencies

Dependencies are fetched at fixed versions into the ignored project-local dependency directory. No global package manager configuration is required.

| Dependency | Version | Source / license |
| --- | --- | --- |
| nlohmann/json | 3.12.0 | [Official release](https://github.com/nlohmann/json/releases/tag/v3.12.0), MIT; original license fetched and hash-checked with the header |
| libgit2 | 1.9.7 | [Official release](https://github.com/libgit2/libgit2/releases/tag/v1.9.7), GPLv2 with linking exception; complete upstream COPYING includes bundled dependency notices |

The libgit2 build uses WinHTTP, Windows hash facilities, and its bundled parser, regex, zlib and SHA1 collision detection. SSH, the upstream CLI and upstream tests are disabled. Keep the complete accompanying notices with any distribution; the build copies them alongside the executable. This document does not assign a license to Coop itself.
