# Third-party source dependencies

Dependencies are fetched at fixed versions into the ignored project-local dependency directory. No global package manager configuration is required.

| Dependency | Version | Source / license |
| --- | --- | --- |
| nlohmann/json | 3.12.0 | [Official release](https://github.com/nlohmann/json/releases/tag/v3.12.0), MIT; original license fetched and hash-checked with the header |
| libgit2 | 1.9.7 | [Official release](https://github.com/libgit2/libgit2/releases/tag/v1.9.7), GPLv2 with linking exception; complete upstream COPYING includes bundled dependency notices |
| Scoop native test shim | 0.6.0, commit `e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f` | [`supporting/shims/kiennq/shim.exe`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/supporting/shims/kiennq/shim.exe), Unlicense or MIT at the recipient's option; license file fetched and hash-checked beside the binary |

The Scoop shim is a test-only fixture: `scripts/fetch-deps.ps1` downloads it and Scoop's license into the ignored `.local/deps/test-fixtures` with pinned SHA256 values. Tests use it to prove that adoption preserves the behavior of original Scoop command entries. It is not compiled into, linked with or distributed alongside Coop.

The libgit2 build uses WinHTTP, Windows hash facilities, and its bundled parser, regex, zlib and SHA1 collision detection. SSH, the upstream CLI and upstream tests are disabled. Keep the complete accompanying notices with any distribution; the build copies them alongside the executable. This document does not assign a license to Coop itself.
