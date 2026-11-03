// Help text from Scoop 0.6.0 (e6aa3b3), MIT; see THIRD_PARTY.md.
// Client invocations use coop; behavioral differences are documented separately.
{"alias",R"coophelp(Available subcommands: add, rm, list.

Aliases are custom coop subcommands that can be created to make common tasks easier.

To add an alias:

    coop alias add <name> <command> [<description>]

e.g.,

    coop alias add rm 'coop uninstall $args[0]' 'Uninstall an app'
    coop alias add upgrade 'coop update *' 'Update all apps, just like "brew" or "apt"'

To remove an alias:

    coop alias rm <name>

To list all aliases:

    coop alias list [-v|--verbose]

Options:
  -v, --verbose  Show alias description and table headers (works only for "list"))coophelp"},
{"bucket",R"coophelp(Add, list or remove buckets.

Buckets are repositories of apps available to install. coop comes with
a default bucket, but you can also add buckets that you or others have
published.

To add a bucket:
    coop bucket add <name> [<repo>]

e.g.:
    coop bucket add extras https://github.com/ScoopInstaller/Extras.git

Since the 'extras' bucket is known to Scoop, this can be shortened to:
    coop bucket add extras

To list all known buckets, use:
    coop bucket known)coophelp"},
{"cache",R"coophelp(coop caches downloads so you don't need to download the same files
when you uninstall and re-install the same version of an app.

You can use
    coop cache show
to see what's in the cache, and
    coop cache rm <app> to remove downloads for a specific app.

To clear everything in your cache, use:
    coop cache rm *
You can also use the `-a/--all` switch in place of `*` here)coophelp"},
{"cat",R"coophelp(Show content of specified manifest.
If configured, `bat` will be used to pretty-print the JSON.
See `cat_style` in `coop help config` for further information.)coophelp"},
{"checkup",R"coophelp(Performs a series of diagnostic tests to try to identify things that may
cause problems with Scoop.)coophelp"},
{"cleanup",R"coophelp('coop cleanup' cleans coop apps by removing old versions.
'coop cleanup <app>' cleans up the old versions of that app if said versions exist.

You can use '*' in place of <app> or `-a`/`--all` switch to cleanup all apps.

Options:
  -a, --all          Cleanup all apps (alternative to '*')
  -g, --global       Cleanup a globally installed app
  -k, --cache        Remove outdated download cache)coophelp"},
{"config",R"coophelp(The coop configuration file is saved at ~/.config/scoop/config.json.

To get all configuration settings:

    coop config

To get a configuration setting:

    coop config <name>

To set a configuration setting:

    coop config <name> <value>

To remove a configuration setting:

    coop config rm <name>

Settings
--------

use_external_7zip: $true|$false
      External 7zip (from path) will be used for archives extraction.

use_lessmsi: $true|$false
      Prefer lessmsi utility over native msiexec.

use_sqlite_cache: $true|$false
      Use SQLite database for caching. This is useful for speeding up 'coop search' and 'coop shim' commands.

use_git_history: $true|$false
      Enable searching for specific versions in git history when installing apps with version specifiers.
      When enabled, coop will first search the bucket's git history for the exact version before falling back to autoupdate.
      (Default is $true)

no_junction: $true|$false
      The 'current' version alias will not be used. Shims and shortcuts will point to specific version instead.

scoop_repo: https://github.com/ScoopInstaller/Scoop
      Git repository containing coop source code.
      This configuration is useful for custom forks.

scoop_branch: master|develop
      Allow to use different branch than master.
      Could be used for testing specific functionalities before released into all users.
      If you want to receive updates earlier to test new functionalities use develop (see: 'https://github.com/ScoopInstaller/Scoop/issues/2939')

proxy: [username:password@]host:port
      By default, coop will use the proxy settings from Internet Options, but with anonymous authentication.

      * To use the credentials for the current logged-in user, use 'currentuser' in place of username:password
      * To use the system proxy settings configured in Internet Options, use 'default' in place of host:port
      * An empty or unset value for proxy is equivalent to 'default' (with no username or password)
      * To bypass the system proxy and connect directly, use 'none' (with no username or password)

autostash_on_conflict: $true|$false
      When a conflict is detected during updating, coop will auto-stash the uncommitted changes.
      (Default is $false, which will abort the update)

default_architecture: 64bit|32bit|arm64
      Allow to configure preferred architecture for application installation.
      If not specified, architecture is determined by system.

debug: $true|$false
      Additional and detailed output will be shown.

force_update: $true|$false
      Force apps updating to bucket's version.

show_update_log: $true|$false
      Do not show changed commits on 'coop update'

show_manifest: $true|$false
      Displays the manifest of every app that's about to
      be installed, then asks user if they wish to proceed.

shim: kiennq|scoopcs|71
      Choose coop shim build.

root_path: $Env:UserProfile\scoop
      Path to coop root directory.

global_path: $Env:ProgramData\scoop
      Path to coop root directory for global apps.

cache_path:
      For downloads, defaults to 'cache' folder under coop root directory.

gh_token:
      GitHub API token used to make authenticated requests.
      This is essential for checkver and similar functions to run without
      incurring rate limits and download from private repositories.

virustotal_api_key:
      API key used for uploading/scanning files using virustotal.
      See: 'https://support.virustotal.com/hc/en-us/articles/115002088769-Please-give-me-an-API-key'

cat_style:
      When set to a non-empty string, coop will use 'bat' to display the manifest for
      the `coop cat` command and while doing manifest review. This requires 'bat' to be
      installed (run `coop install bat` to install it), otherwise errors will be thrown.
      The accepted values are the same as ones passed to the --style flag of 'bat'.

ignore_running_processes: $true|$false
      When set to $false (default), coop would stop its procedure immediately if it detects
      any target app process is running. Procedure here refers to reset/uninstall/update.
      When set to $true, coop only displays a warning message and continues procedure.

private_hosts:
      Array of private hosts that need additional authentication.
      For example, if you want to access a private GitHub repository,
      you need to add the host to this list with 'match' and 'headers' strings.

hold_update_until:
      Disable/Hold coop self-updates, until the specified date.
      `coop hold scoop` will set the value to one day later.
      Should be in the format 'YYYY-MM-DD', 'YYYY/MM/DD' or any other forms that accepted by '[System.DateTime]::Parse()'.
      Ref: https://docs.microsoft.com/dotnet/api/system.datetime.parse?view=netframework-4.5#StringToParse

update_nightly: $true|$false
      Nightly version is formatted as 'nightly-yyyyMMdd' and will be updated after one day if this is set to $true.
      Otherwise, nightly version will not be updated unless `--force` is used.

use_isolated_path: $true|$false|[string]
      When set to $true, coop will use `SCOOP_PATH` environment variable to store apps' `PATH`s.
      When set to arbitrary non-empty string, coop will use that string as the environment variable name instead.
      This is useful when you want to isolate coop from the system `PATH`.

ARIA2 configuration
-------------------

aria2-enabled: $true|$false
      Aria2c will be used for downloading of artifacts.
      (Default is $true)

aria2-warning-enabled: $true|$false
      Disable Aria2c warning which is shown while downloading.
      (Default is $true)

aria2-fallback-enabled: $true|$false
      Automatically falls back to the default downloader when Aria2c download fails.
      (Default is $true)

aria2-retry-wait: 2
      Number of seconds to wait between retries.
      See: 'https://aria2.github.io/manual/en/html/aria2c.html#cmdoption-retry-wait'

aria2-split: 5
      Number of connections used for download.
      See: 'https://aria2.github.io/manual/en/html/aria2c.html#cmdoption-s'

aria2-max-connection-per-server: 5
      The maximum number of connections to one server for each download.
      See: 'https://aria2.github.io/manual/en/html/aria2c.html#cmdoption-x'

aria2-min-split-size: 5M
      Downloaded files will be split by this configured size and downloaded using multiple connections.
      See: 'https://aria2.github.io/manual/en/html/aria2c.html#cmdoption-k'

aria2-options:
      Array of additional aria2 options.
      See: 'https://aria2.github.io/manual/en/html/aria2c.html#options')coophelp"},
{"create",R"coophelp(Create your own custom app manifest)coophelp"},
{"download",R"coophelp(e.g. The usual way to download an app, without installing it (uses your local 'buckets'):
     coop download git

To download a different version of the app
(note that this will auto-generate the manifest using current version):
     coop download gh@2.7.0

To download an app from a manifest at a URL:
     coop download https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/runat.json

To download an app from a manifest on your computer
     coop download path\to\app.json

Options:
  -f, --force                     Force download (overwrite cache)
  -s, --skip-hash-check           Skip hash verification (use with caution!)
  -u, --no-update-scoop           Don't update coop before downloading if it's outdated
  -a, --arch <32bit|64bit|arm64>  Use the specified architecture, if the app supports it)coophelp"},
{"export",R"coophelp(Options:
  -c, --config       Export the coop configuration file too)coophelp"},
{"hold",R"coophelp(To hold a user-scoped app:
     coop hold <app>

To hold a global app:
     coop hold -g <app>

Options:
  -g, --global  Hold globally installed apps)coophelp"},
{"import",R"coophelp(To replicate a coop installation from a file stored on Desktop, run
     coop import Desktop\scoopfile.json)coophelp"},
{"info",R"coophelp(Options:
  -v, --verbose   Show full paths and URLs)coophelp"},
{"install",R"coophelp(e.g. The usual way to install an app (uses your local 'buckets'):
     coop install git

To install a different version of the app
(will search sqlite cache if enabled, then git history (if use_git_history is $true), then auto-generate manifest as fallback):
     coop install gh@2.7.0

To install an app from a manifest at a URL:
     coop install https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/runat.json

To install a different version of the app from a URL:
      coop install https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/neovim.json@0.9.0

To install an app from a manifest on your computer
     coop install \path\to\app.json

To install an app from a manifest on your computer
     coop install \path\to\app.json@version

Options:
  -g, --global                    Install the app globally
  -i, --independent               Don't install dependencies automatically
  -k, --no-cache                  Don't use the download cache
  -s, --skip-hash-check           Skip hash validation (use with caution!)
  -u, --no-update-scoop           Don't update coop before installing if it's outdated
  -a, --arch <32bit|64bit|arm64>  Use the specified architecture, if the app supports it)coophelp"},
{"list",R"coophelp(Lists all installed apps, or the apps matching the supplied query.)coophelp"},
{"reset",R"coophelp(Used to resolve conflicts in favor of a particular app. For example,
if you've installed 'python' and 'python27', you can use 'coop reset' to switch between
using one or the other.

You can use '*' in place of <app> or `-a`/`--all` switch to reset all apps.)coophelp"},
{"search",R"coophelp(Searches for apps that are available to install.

If used with [query], shows app names that match the query.
  - With 'use_sqlite_cache' enabled, [query] is partially matched against app names, binaries, and shortcuts.
  - Without 'use_sqlite_cache', [query] can be a regular expression to match against app names and binaries.
Without [query], shows all the available apps.)coophelp"},
{"shim",R"coophelp(Available subcommands: add, rm, list, info, alter.

To add a custom shim, use the 'add' subcommand:

    coop shim add <shim_name> <command_path> [[--|--%] <args>...]

To remove shims, use the 'rm' subcommand: (CAUTION: this could remove shims added by an app manifest)

    coop shim rm <shim_name> [<shim_name>...]

To list all shims or matching shims, use the 'list' subcommand:

    coop shim list [<regex_pattern>...]

To show a shim's information, use the 'info' subcommand:

    coop shim info <shim_name>

To alternate a shim's target source, use the 'alter' subcommand:

    coop shim alter <shim_name>

Options:
  -g, --global       Manipulate global shim(s)

HINT: The FIRST terminator token ('--' or PowerShell '--%'), if any, is treated as the option
terminator and will NOT be included; everything after it is passed to the shim.
So if you want to pass arguments like '-g' or '--global' to the shim, put them after a '--' or '--%'.
Examples:
    POSIX-style:    coop shim add myapp 'D:\path\myapp.exe' '--' myapp_args --global
    PowerShell:     coop shim add myapp D:\path\myapp.exe --% myapp_args --global
Notes:
  - In PowerShell, '--' should be quoted to avoid parsing.
  - '--%' disables PowerShell parsing of the remainder; pass literals as needed.)coophelp"},
{"status",R"coophelp(Options:
  -l, --local         Checks the status for only the locally installed apps,
                      and disables remote checks for Coop and installed Scoop.
Notes:
  Bare status checks Coop releases and the same-root Scoop branch.
  --json preserves the local package status array; it does not check clients.
  -l --json=2 reports local clients, buckets and all apps in one document.
  Remote JSON v2 and update JSON v2 are not available yet.
  Checks do not update clients, buckets or installed apps.)coophelp"},
{"unhold",R"coophelp(To unhold a user-scoped app:
     coop unhold <app>

To unhold a global app:
     coop unhold -g <app>

Options:
  -g, --global  Unhold globally installed apps)coophelp"},
{"uninstall",R"coophelp(e.g. coop uninstall git

Options:
  -g, --global   Uninstall a globally installed app
  -p, --purge    Remove all persistent data)coophelp"},
{"update",R"coophelp('coop update' updates coop to the latest version.
'coop update <app>' installs a new version of that app, if there is one.

You can use '*' in place of <app> to update all apps.

Options:
  -f, --force            Force update even when there isn't a newer version
  -g, --global           Update a globally installed app
  -i, --independent      Don't install dependencies automatically
  -k, --no-cache         Don't use the download cache
  -s, --skip-hash-check  Skip hash validation (use with caution!)
  -q, --quiet            Hide extraneous messages
  -a, --all              Update all apps (alternative to '*'))coophelp"},
{"virustotal",R"coophelp(Look for app's hash or url on virustotal.com

Use a single '*' or the '-a/--all' switch to check all installed apps.

To use this command, you have to sign up to VirusTotal's community,
and get an API key. Then, tell coop about your API key with:

  coop config virustotal_api_key <your API key: 64 lower case hex digits>

Exit codes:
 0 -> success
 1 -> problem parsing arguments
 2 -> at least one package was marked unsafe by VirusTotal
 4 -> at least one exception was raised while looking for info
 8 -> at least one package couldn't be queried because the manifest couldn't be found
16 -> VirusTotal API key is not configured
Note: the exit codes (2, 4 & 8) may be combined, e.g. 6 -> exit codes
      2 & 4 combined

Options:
  -a, --all                 Check for all installed apps
  -s, --scan                For packages where VirusTotal has no information, send download URL
                            for analysis (and future retrieval). This requires you to configure
                            your virustotal_api_key.
  -n, --no-depends          By default, all dependencies are checked too. This flag avoids it.
  -u, --no-update-scoop     Don't update coop before checking if it's outdated
  -p, --passthru            Return reports as objects)coophelp"},
{"which",R"coophelp(Locate the path to a shim/executable that was installed with Scoop (similar to 'which' on Linux))coophelp"},
