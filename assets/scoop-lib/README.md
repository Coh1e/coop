# Pinned Scoop compatibility library

This directory is a verbatim copy of the Scoop PowerShell library that Coop loads in every
lifecycle hook host. Coop does not implement its own reduced `ensure`/`info`/`warn` set: the real
Scoop helpers (`ensure`, `info`, `warn`, `error`, `abort`, `success`, `appdir`, `env_add_path`,
`env_set`, `Expand-*Archive`, `Get-EnvVar`, `Set-EnvVar`, `Invoke-ExternalCommand`, `is_admin`, …)
are the implementation, so a Manifest script that works in Scoop gets the same helper semantics.

| Item | Value |
| --- | --- |
| Upstream | [ScoopInstaller/Scoop](https://github.com/ScoopInstaller/Scoop) |
| Version | v0.6.0 |
| Commit | `e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f` (`chore(release): Bump to version 0.6.0 (#6659)`) |
| License | MIT, see [`LICENSE`](LICENSE) (copied from the same commit) |
| Modifications | None. Every committed file is byte-identical to the upstream repository blob at that commit (LF line endings); `.gitattributes` marks this directory `-text` so no checkout or commit step rewrites it. |

The files are the union of the library preludes Scoop's own `bin/scoop.ps1`, `scoop-install.ps1`,
`scoop-update.ps1` and `scoop-uninstall.ps1` load before a lifecycle hook runs. Coop loads them in
that order: `bin/scoop.ps1` first (`core`, `buckets`, `commands`, `help`), then the command libraries
(`getopt`, `json`, `autoupdate`, `manifest`, `system`, `install`, `download`, `decompress`,
`shortcuts`, `psmodules`, `versions`, `depends`).

Each Git blob below is identical to `git rev-parse e6aa3b3:lib/<name>.ps1`; the SHA256 is computed
over the committed bytes and is also what the build copies beside `coop.exe`, so an accidental edit
is detectable with either hash.

| File | Git blob at `e6aa3b3` | SHA256 |
| --- | --- | --- |
| `core.ps1` | `7ca74cebf15f6e01b66c8a1f501ad4b7f3b9b591` | `b9e3d44ed444fba9f8e4934d5631ad6b1f1c2b573001955564c42c54756c3679` |
| `buckets.ps1` | `4b29feae5293e5e7b0de95a0bbc266909cd91241` | `db24d975f1c4bc958cf299c9174d5aca3ee5b6915d0a3dc02f8e58d7a5640157` |
| `commands.ps1` | `6812aebd5299c55787b560e01a0adc418e280df8` | `db325aebaf1c77a8728abcfb762e274d7244f59cacef6a6b10818d575ab6f143` |
| `help.ps1` | `a9640841432994086df6c65d9a1e6e707568d57a` | `14a291958fdfd0e964f17298548074dddd71732f8140b4d5795f7a29e4d94224` |
| `getopt.ps1` | `0ba80965ea74195cd8212baf68eaff491146311d` | `eebcd0d73efdc37dd819c0939f08462486007bee1e90406cf8c0f69c11f16d0b` |
| `json.ps1` | `d82dbb9b73361ed24b04e51039e477f40a561478` | `93107fcbfd42f89aa01e98f74b726722268d3b3ac5c28d1a51a17f2d4ed55a30` |
| `autoupdate.ps1` | `6caa30efa6406423cf1107e42e361fb5c9beec3d` | `6b06a5aea1ed36efd1235deba468ae2e7c9022fcc417841358a6b2262f64d4d3` |
| `manifest.ps1` | `b0c00421f1587022daa4136bc1c96eb062967a14` | `919103aeacd8f815242b7867df73355bc2088e4ab94798df7848b12ed5a1f7ae` |
| `system.ps1` | `692cb40275f0cdce8e7358232f9c1a950fc47453` | `4088b7b42a8915a39715f9f48ba389bc38d9fa9574ebf03098911deb03cb573e` |
| `install.ps1` | `7b242278d173b8f5c9797fd22b2abd93184a0980` | `a4aad174a6d8360ceace9cf1e3a3ca0239531b8e0c17c8f7086f74133e010129` |
| `download.ps1` | `326d9d815c1195b75dcc50e84bb66f625a676725` | `c8d6b8b90255611dad50048a18006552a26b211b9e7318a4f3bf14b527d32455` |
| `decompress.ps1` | `87562490f0336fa245cd59afadb985bdbad317b7` | `a85272a35ff53d4b5c2736beb57225717e2284f6987235ab3f21548b677999dc` |
| `shortcuts.ps1` | `edb6357480707b0bb15cbf0445561371ce5c3ec1` | `1ffbe27e9476309ee98b979619f3d7943f1a1854ca5b05854a6bbb21c50a702f` |
| `psmodules.ps1` | `9d0cb7ce8a7392fc99323d9051a6ff2e7e73b791` | `2a429288214835b0c15de50f86a0789c41f1ca9e1fdc3f3e4b8a3ba8f7ae669f` |
| `versions.ps1` | `54783b3cba0f9459214f6cbbd62633f629fa62b6` | `062261ae41f24699991fc6fd8f1b941ce78a81764bcae921e058b68637e5e454` |
| `depends.ps1` | `bc832d7bafb21c19805c43ce1849339bbfd58649` | `6101f7e2224aa745f35139d325b10de4ddb9bdd13cc1de100f9634d962bbb25d` |
| `LICENSE` | `68b7fd92d6c6b99cdf0748b51a91bfde6eec962a` | `92c2b8f7e3b344a307889ff5f55dc3d7fa048f846845549df0e33e44e5939476` |

## Runtime lookup

Coop looks for this directory in two places, in order:

1. `COOP_SCOOP_LIB` when set to a directory that contains `core.ps1`; this is a per-subprocess
   override used by isolated tests and does not change the user or system environment.
2. `scoop-lib` next to `coop.exe`; the build copies this directory there, and a distribution must
   ship it beside the executable.

Coop never reads the library out of a Scoop installation chosen as the management root, so hook
semantics stay pinned instead of silently following whatever Scoop version happens to be installed.
`COOP_POWERSHELL` may pin the PowerShell interpreter; otherwise `pwsh.exe` is preferred and Windows
PowerShell is the fallback.
