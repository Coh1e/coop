# Third-party source dependencies

Dependencies are fetched at fixed versions into the ignored project-local dependency directory. No global package manager configuration is required.

| Dependency | Version | Source / license |
| --- | --- | --- |
| nlohmann/json | 3.12.0 | [Official release](https://github.com/nlohmann/json/releases/tag/v3.12.0), MIT; original license fetched and hash-checked with the header |
| libgit2 | 1.9.7 | [Official release](https://github.com/libgit2/libgit2/releases/tag/v1.9.7), GPLv2 with linking exception; complete upstream COPYING includes bundled dependency notices |
| libarchive | 3.7.7 | [Official release](https://github.com/libarchive/libarchive/releases/tag/v3.7.7), BSD-2-Clause; complete upstream COPYING is copied beside the build |
| zlib | 1.3.1 | [Official release](https://github.com/madler/zlib/releases/tag/v1.3.1), zlib license; upstream LICENSE is copied beside the build |
| xz / liblzma | 5.6.4 | [Official release](https://github.com/tukaani-project/xz/releases/tag/v5.6.4), 0BSD; upstream 0BSD notice is copied beside the build |
| zstd | 1.5.7 | [Official release](https://github.com/facebook/zstd/releases/tag/v1.5.7), BSD-3-Clause; upstream LICENSE is copied beside the build |
| bzip2 | 1.0.8 | [Official release](https://sourceware.org/pub/bzip2/), bzip2 license; upstream LICENSE is copied beside the build |
| Scoop native test shim | 0.6.0, commit `e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f` | [`supporting/shims/kiennq/shim.exe`](https://github.com/ScoopInstaller/Scoop/blob/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/supporting/shims/kiennq/shim.exe), Unlicense or MIT at the recipient's option; license file fetched and hash-checked beside the binary |
| ripgrep test archives | 14.1.1 and 15.2.0 | Official release ZIPs from [BurntSushi/ripgrep](https://github.com/BurntSushi/ripgrep/releases), MIT or Unlicense; test-only fixed assets, not distributed |
| air test archives | 1.67.3 and 1.67.4 | Official release tar.gz files from [air-verse/air](https://github.com/air-verse/air/releases), MIT; test-only fixed assets, not distributed |
| archive format test assets | luajit tar.zst, tidy ZIP, curl tar.xz, unzip 7z SFX | Official MSYS2, tidy-html5, curl and ScoopInstaller/Binary releases; test-only fixed assets with pinned SHA256, not distributed. Their upstream licenses remain with the original projects |

The Scoop shim is a test-only fixture: `scripts/fetch-deps.ps1` downloads it and Scoop's license into the ignored `.local/deps/test-fixtures` with pinned SHA256 values. Tests use it to prove that adoption preserves the behavior of original Scoop command entries. It is not compiled into, linked with or distributed alongside Coop.

The ripgrep, air, luajit, tidy, curl and unzip release archives are likewise test-only fixtures in the ignored `.local/deps/test-archives`; `scripts/fetch-deps.ps1` pins their SHA256 values. They exercise real ZIP, tar.gz/tar.xz/tar.zst, 7z and 7z SFX extraction, nested layout, entry execution, update and uninstall behavior and are not distributed with Coop.

The libgit2 build uses WinHTTP, Windows hash facilities, and its bundled parser, regex, zlib and SHA1 collision detection. SSH, the upstream CLI and upstream tests are disabled.

The libarchive build uses the zlib, liblzma, zstd and bzip2 sources listed above. It enables ordinary ZIP, tar and 7z reading for plain tar, gzip, xz, lzma, bzip2 and zstd streams, including the extracted tree behind a 7z self-extracting stub. Keep the complete accompanying notices with any distribution; the build copies them alongside the executable. This document does not assign a license to Coop itself.
