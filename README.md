# CC Pilot

English | [简体中文](README.zh-CN.md)

Switch between your own Claude Code subscription accounts on one Mac, and see each account's remaining usage in the menu bar.

> **Disclaimer**: cc-pilot is an independent open-source project. It is not affiliated with, endorsed by,
> or supported by Anthropic. Every account you manage with cc-pilot should belong to you. cc-pilot must
> not be used to share accounts with other people, or to get around the usage limits of a single account.

## What it does

Switching accounts in Claude Code normally means `/logout` and then `/login`: a browser sign-in every time, the previous account is signed out on this Mac, and different terminals can't use different accounts at the same time.

cc-pilot gives each account its own **profile**:

- **Profiles don't affect each other's sign-in.** Each profile keeps its own login, so switching never requires signing in again.
- **Switching only affects sessions started afterwards.** A running Claude Code keeps the profile it started with, so different terminals can use different accounts at the same time.
- **Use another profile in one terminal, once**: `CLAUDE_PROFILE=work claude`, without changing the current profile.
- **One shared working environment.** `CLAUDE.md`, skills, subagents, custom commands, plugins and project session history are shared by all profiles. Settings (`settings.json`) and prompt history (what ↑ recalls) are kept per profile.
- **Your existing setup is the default profile.** Your `~/.claude` stays exactly as it is, under the name `default`. Nothing is migrated.
- **No automatic switching, ever.** You always switch by hand.

There are two equal ways to use it:

- **The `ccp` command line tool**: manage profiles and switch the current profile.
- **The CC Pilot menu bar app**: everything `ccp` does, plus each account's usage, fetched when you click refresh.

### The menu bar app

- The menu bar shows two lines: the current profile's subscription tier (such as Max 5x or Pro; the profile name when the tier isn't known), and the remaining 5-hour usage of that profile's account ("—" until you refresh). You can also make it show only an icon.
- The panel lists every profile, showing the signed-in account's email first and the profile name below it, together with the organization and subscription tier. Profiles that aren't signed in show "Not signed in"; when two profiles are signed in to the same account, the list says "Same account as …".
- Click a profile to make it the current profile, exactly like `ccp use`. To add or delete a profile, the app opens Terminal and runs `ccp add` / `ccp rm`, so the flow is identical to the command line. Changes made with `ccp` show up in the app right away.
- Usage: click "Refresh All", or the refresh button next to one account, to get the **remaining** percentage and reset time of the 5-hour window and the weekly window for all models. Expand an account to see weekly windows per model and extra usage.
  - Every number is the percentage left, not the percentage used shown by Claude Code's `/usage`.
  - Colors follow the percentage left: red at 20% or less, amber at 50% or less, green otherwise.
  - Every number shows when it was fetched and turns gray after 30 minutes. Windows past their reset time show "Reset, refresh to update".
  - Profiles signed in to the same account are fetched only once.
  - A profile whose short-lived credential has expired shows **Needs renewal**: open that profile's `claude` once to restore it (the app sends no request and never renews anything itself). A profile whose credential can no longer be renewed shows **Needs to sign in again**.
- The interface is in English or Simplified Chinese, following your system language. It lives only in the menu bar, with no Dock icon. "Launch at Login" is available and off by default.

## Network and privacy

CC Pilot only connects to these two addresses:

| Address | When |
| --- | --- |
| Usage API `https://api.anthropic.com/api/oauth/usage` | **Only when you click** "Refresh All" or an account's refresh button. Launching the app, opening the panel and switching profiles send no request. Requests honestly identify themselves with `User-Agent: cc-pilot/<version>` and do not pretend to be the official client. |
| Update feed `https://raw.githubusercontent.com/xshowee/cc-pilot/main/appcast.xml` | Fetched by [Sparkle](https://sparkle-project.org): once a day while "Automatically Check for Updates" is on (the default), which can happen shortly after launch when the last check was more than a day ago; and immediately when you click "Check for Updates…". No system information is sent. |

When you choose to install an update, Sparkle downloads the new DMG from this repository's GitHub Releases. To turn off automatic checks, uncheck "Automatically Check for Updates" in the gear menu at the bottom right of the panel.

- **No usage data is collected.** No crash reports, no analytics or telemetry of any kind.
- **Credentials are read-only.** The app reads the credentials Claude Code stores in the keychain through the system's own `/usr/bin/security`, keeps them in memory only for a single request, and never writes them to logs, cache files or error messages. cc-pilot **never writes, deletes or renews** credentials: renewal is always done by Claude Code itself, and signing out is done by you with `/logout` in Claude Code.
- `ccp` doesn't read credentials. The only keychain access is in `ccp rm`, which checks whether the profile's keychain item still exists, without reading its contents.
- Reading credentials should never show a keychain access prompt. If one ever appears, don't click "Allow": it means cc-pilot is incompatible with your Claude Code version, and the app will tell you so.

## What it touches

| Location | What cc-pilot does |
| --- | --- |
| `~/.zshrc` | With your consent, appends **one line** at the end (see "Install" below). Running it again never adds a second line; uninstalling removes only that line. Nothing else in the file is touched. |
| `~/.cc-pilot/` | Where the `ccp` command and the `claude` wrapper function are installed. The app installs and updates it. |
| `~/.claude-profiles/` | Every profile other than the default one, one directory each (`~/.claude-profiles/<name>/`), plus the file recording the current profile, `~/.claude-profiles/active`. |
| `~/.claude/`, `~/.claude.json` (default profile) | **Read only.** When a profile is created, its MCP servers and project trust settings are copied from `~/.claude.json` and its settings from `~/.claude/settings.json`; the new profile's shared resources are symlinks into `~/.claude/`; the app reads account info (email, organization, tier) from `.claude.json` to display it. |
| Keychain | **Read only**, see "Network and privacy" above. |
| Terminal | When you add or delete a profile in the app, it opens a new Terminal window to run `ccp add` / `ccp rm`. macOS asks once whether CC Pilot may control Terminal; if you'd rather not allow it, the app gives you the command to copy and run yourself. |

cc-pilot does **not**:

- modify or replace the Claude Code executable. The wrapper calls the real Claude Code with `command claude`, and Claude Code's auto-update keeps working;
- change anything in the default profile, or migrate it;
- interfere with other Claude Code wrapper functions or aliases already in your `~/.zshrc`;
- change anything about `claude` while you only have the default profile, or while the default profile is current: it then behaves exactly as before.

Note that shared resources are symlinks. When you install a skill or plugin in any profile, it changes the copy in `~/.claude/`, which all profiles see. Settings aren't a shared resource: when Claude Code changes a setting in a profile (for example with `/model` or `/advisor`), only that profile is affected.

## Requirements

- macOS 13 or later, Apple Silicon or Intel.
- zsh (the default shell on macOS).
- Claude Code installed, with `claude` runnable from zsh.

## Install

1. Download `CCPilot-<version>.dmg` from [GitHub Releases](https://github.com/xshowee/cc-pilot/releases/latest). The app is signed with a Developer ID and notarized by Apple.
2. Open the DMG, drag CC Pilot into **Applications**, and launch it.
3. On first launch the app explains and asks whether to set up zsh. Choose "Add to ~/.zshrc": the app installs `ccp` and the `claude` wrapper function into `~/.cc-pilot/`, then adds this line to the end of `~/.zshrc`:

   ```zsh
   source "$HOME/.cc-pilot/cc-pilot.zsh"  # cc-pilot
   ```

   "Not Now" changes no files; you can start again later from the gear menu at the bottom right of the panel › "Set Up zsh Integration…".
4. Open a new terminal window (or run `source ~/.zshrc` in an open one) and `ccp` is ready.

Each time the app is updated, it updates `~/.cc-pilot/` to the new version without asking, and without touching `~/.zshrc` again.

**Command line only, without the app**: copy this repository's `shell/` directory to `~/.cc-pilot/`, then run `~/.cc-pilot/bin/ccp init`. It shows the line it will add and asks first; only `y` writes it.

## Getting started

```zsh
ccp add work        # create profile "work" and go straight into its Claude Code to onboard and sign in; exit when done
ccp use work        # switch: claude sessions started from now on use "work"
claude              # in a new terminal, this is the "work" account
ccp use default     # switch back to your original setup

CLAUDE_PROFILE=work claude   # use "work" just this once, in this terminal, without changing the current profile
```

A new profile's first launch goes through Claude Code's own onboarding and sign-in, just like a fresh install. Only the new profile is signed in to the new account; the default profile's sign-in is unaffected.

`claude` picks the profile in this order, highest first:

1. `CLAUDE_CONFIG_DIR` is already set in the environment: cc-pilot stays out of the way and runs Claude Code unchanged.
2. `CLAUDE_PROFILE` is set: use that profile.
3. Otherwise use the current profile.

If the current profile points to a profile that no longer exists, `claude` stops with an error that explains how to fix it. It never silently falls back to the default profile, so you don't spend the wrong account's usage without knowing.

## `ccp` commands

| Command | What it does |
| --- | --- |
| `ccp ls` | List all profiles, with `*` before the current one. The first line is always `default`. |
| `ccp current` | Print only the current profile's name, for scripts and prompts. Reads the current profile only, ignoring `CLAUDE_PROFILE`. |
| `ccp use <name>` | Switch the current profile; `ccp use default` switches back to the default profile. Only affects sessions started afterwards. |
| `ccp add <name>` | Create a profile and go straight into its Claude Code to onboard and sign in. Doesn't change the current profile. Claude Code starts in an empty directory reserved for ccp inside the profile directory (`.ccp-workdir`), not in your current directory; if it asks whether to trust that directory, it's safe to answer Yes, and `ccp rm` won't ask again for this profile. |
| `ccp rm <name>` | Delete a profile: asks for confirmation, opens that profile's Claude Code for you to run `/logout` and exit, and deletes it only once it's confirmed signed out. The default profile and the current profile can't be deleted. Claude Code starts in the profile's `.ccp-workdir` here too, which is deleted along with the profile. |
| `ccp init [--yes]` | Set up zsh: with your consent, add the line to the end of `~/.zshrc`; `--yes` skips the question. Does nothing if it's already there. |
| `ccp uninstall` | Remove the line `ccp init` added from `~/.zshrc`, leaving everything else as it was. |

Profile names may contain only letters, digits, `.`, `_` and `-`, and must start with a letter or digit. `default` and `active` are reserved.

## Known limitations

- **What switching doesn't reach**: switching works through the `claude` wrapper function in zsh, so Claude Code started any other way isn't affected and always uses the default profile. That includes:
  - IDE plugins (for example Claude Code in VS Code or JetBrains);
  - Claude Desktop;
  - shells other than zsh (bash, fish, …).
- **MCP servers and project trust settings are copied once, at creation.** `ccp add` copies only `mcpServers` (user-level MCP servers) and `projects` (project trust settings) from the default profile's `~/.claude.json` as the new profile's starting point. After that each profile changes on its own; they are not kept in sync. An MCP server added to the default profile later won't appear in profiles that already exist, and vice versa. Connectors configured in your claude.ai account follow the account and aren't part of the copy.
- **Settings are copied once, at creation.** `ccp add` copies the default profile's `~/.claude/settings.json` as the new profile's starting settings. After that each profile changes on its own: a theme, status line or hook changed in one profile doesn't reach the others. This lets profiles on different subscription tiers use different models and advisors. Plugins are shared, but whether a plugin is enabled is part of each profile's settings: a plugin installed and enabled in one profile has to be enabled again with `/plugin` in the others.
- **Profiles can't be renamed.** The keychain item holding a profile's credentials is named after the profile directory's path, so renaming would lose the sign-in. To change a name: `ccp add` a profile with the new name and sign in, then `ccp rm` the old one (which walks you through signing out first).
- **It depends on Claude Code internals.** How keychain items are named, the structure of account info in `.claude.json`, and the usage API's address and fields are undocumented; cc-pilot follows the actual behavior of Claude Code 2.1.309. If a Claude Code update breaks compatibility, the app says "Incompatible with the current Claude Code version" or "The usage API may have changed. Please update cc-pilot." instead of showing a guessed number.
- Usage isn't available when signed in with an API key or a long-lived token from `setup-token`.

## Uninstall

1. (Optional) If you no longer need the other profiles, switch back with `ccp use default`, then delete each one with `ccp rm <name>` (the current profile can't be deleted). Each profile is signed out first, so no valid credentials are left in the keychain.
2. Run `ccp uninstall` (or use the gear menu at the bottom right of the panel › "Remove zsh Integration…") to remove the line from `~/.zshrc`.
3. Quit CC Pilot and delete it from **Applications**.

The default profile (`~/.claude`, `~/.claude.json` and its sign-in) is never affected. After uninstalling, `claude` in a new terminal behaves exactly as it did before cc-pilot was installed.

To remove every trace, you can also delete by hand:

- `~/.cc-pilot/`: `ccp` and the wrapper function (`ccp uninstall` keeps it);
- `~/.claude-profiles/`: the other profiles and the current-profile record. If you delete it without running `ccp rm` first, those profiles' credentials stay in the keychain (items named `Claude Code-credentials-` followed by 8 hex digits); you can delete them in Keychain Access;
- the app's preferences: `defaults delete com.ccpilot.app`.

## Building from source

Requires Xcode or the Command Line Tools (`swiftc`). No Xcode project is needed:

```zsh
./scripts/check.sh        # all checks: zsh syntax, shell black-box tests, the app core's check program, app type-check
./scripts/build-app.sh    # development build for this Mac's architecture, ad-hoc signed → build/CC Pilot.app
open "build/CC Pilot.app"
```

The first build downloads a pinned version of Sparkle into `build/deps/` and verifies its SHA-256; later builds stay offline. Layout:

```
shell/          zsh wrapper function and ccp (installed as-is to ~/.cc-pilot/, see shell/README.md)
Sources/Core/   app core: profiles, switching, credential reading, usage fetching and parsing (no UI)
Sources/App/    SwiftUI menu bar interface
Resources/      Info.plist, localized strings, entitlements
tests/          shell black-box tests, the app core's check program, fake claude / security
docs/           design decisions (docs/adr/) and the release process (docs/release.md)
```

Terminology is in [GLOSSARY.md](GLOSSARY.md), design decisions in [docs/adr/](docs/adr/), and signing, notarization and releasing in [docs/release.md](docs/release.md) (all in Chinese).

## License

[MIT](LICENSE)
