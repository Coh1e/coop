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
| Scoop compatibility library | 0.6.0, commit `e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f` | [`lib/*.ps1`](https://github.com/ScoopInstaller/Scoop/tree/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/lib), MIT; verbatim copy committed in `assets/scoop-lib` with the upstream `LICENSE`, per-file Git blob/SHA256 provenance and the loading order, copied beside `coop.exe` at build time and distributed with it |
| ripgrep test archives | 14.1.1 and 15.2.0 | Official release ZIPs from [BurntSushi/ripgrep](https://github.com/BurntSushi/ripgrep/releases), MIT or Unlicense; test-only fixed assets, not distributed |
| air test archives | 1.67.3 and 1.67.4 | Official release tar.gz files from [air-verse/air](https://github.com/air-verse/air/releases), MIT; test-only fixed assets, not distributed |
| archive format test assets | luajit tar.zst, tidy ZIP, curl tar.xz, unzip 7z SFX, 7-Zip 26.05/26.03 x64 MSI, GNU Units 2.26/2.27 Inno Setup setups, rizin 0.9.1 Inno Setup installer, innounp 2.71.2 package archive | Official MSYS2, tidy-html5, curl, ScoopInstaller/Binary, ip7z/7zip, GNU Units, rizinorg/rizin and jrathlev/InnoUnpacker-Windows-GUI releases; test-only fixed assets with pinned SHA256, not distributed. Their upstream licenses remain with the original projects |

The Scoop shim is a test-only fixture: `scripts/fetch-deps.ps1` downloads it and Scoop's license into the ignored `.local/deps/test-fixtures` with pinned SHA256 values. Tests use it to prove that adoption preserves the behavior of original Scoop command entries. It is not compiled into, linked with or distributed alongside Coop.

The ripgrep, air, luajit, tidy, curl, unzip, 7-Zip MSI, GNU Units, rizin and innounp release archives are likewise test-only fixtures in the ignored `.local/deps/test-archives`; `scripts/fetch-deps.ps1` pins their SHA256 values. They exercise real ZIP, tar.gz/tar.xz/tar.zst, 7z, 7z SFX, MSI database/cabinet extraction, Inno Setup extraction, and layered lifecycle behavior (install, update, persist, uninstall) and are not distributed with Coop. The MSI backend uses only Windows system APIs (`msi.dll` database access, `cabinet.dll` decompression); it adds no third-party MSI reader and no executable helper. Inno Setup extraction intentionally uses the separately installed innounp helper (the Scoop package `innounp`, GPL-3.0-only); Coop neither bundles nor redistributes it, and the helper is a package-mechanism software dependency rather than a Coop core dependency. The pinned innounp archive is provisioned only in the project-local test root so the helper itself can be proven unchanged.

The libgit2 build uses WinHTTP, Windows hash facilities, and its bundled parser, regex, zlib and SHA1 collision detection. SSH, the upstream CLI and upstream tests are disabled.

The libarchive build uses the zlib, liblzma, zstd and bzip2 sources listed above. It enables ordinary ZIP, tar and 7z reading for plain tar, gzip, xz, lzma, bzip2 and zstd streams, including the extracted tree behind a 7z self-extracting stub. Keep the complete accompanying notices with any distribution; the build copies them alongside the executable. This document does not assign a license to Coop itself.
