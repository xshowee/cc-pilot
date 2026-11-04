# CC Pilot

English | [简体中文](README.zh-CN.md)

Switch between your own Claude Code and ChatGPT subscription accounts on one Mac, and see each account's remaining usage in the menu bar.

> **Disclaimer**: cc-pilot is an independent open-source project. It is not affiliated with, endorsed by,
> or supported by Anthropic or OpenAI. Every account you manage with cc-pilot should belong to you. cc-pilot
> must not be used to share accounts with other people, or to get around the usage limits of a single account.

## What it does

Switching accounts in Claude Code normally means `/logout` and then `/login`: a browser sign-in every time, the previous account is signed out on this Mac, and different terminals can't use different accounts at the same time.

cc-pilot gives each account its own **profile**:

- **Profiles don't affect each other's sign-in.** Each profile keeps its own login, so switching never requires signing in again.
- **Switching only affects sessions started afterwards.** A running Claude Code keeps the profile it started with, so different terminals can use different accounts at the same time.
- **Use another profile in one terminal, once**: `CLAUDE_PROFILE=work claude`, without changing the current profile.
- **One shared working environment.** `CLAUDE.md`, skills, subagents, custom commands, plugins and project session history are shared by all profiles. Settings (`settings.json`) and prompt history (what ↑ recalls) are kept per profile.
- **Your existing setup is the default profile.** Your `~/.claude` stays exactly as it is, under the name `default`. Nothing is migrated.
- **No automatic switching, ever.** You always switch by hand.

### ChatGPT

cc-pilot manages the ChatGPT accounts you use through the `codex` command line tool and the ChatGPT desktop app in the same way. Claude Code and ChatGPT profiles are independent: each tool has its own current profile, and both tools may have a profile with the same name.

- **Each ChatGPT profile is its own `CODEX_HOME` directory**, with its own sign-in. Your existing `~/.codex` is the ChatGPT profile `default` and stays exactly as it is; other profiles live in `~/.codex-profiles/<name>/`.
- **Switching reaches the apps too.** After `ccp chatgpt use work`, `codex` sessions started afterwards use `work`, and so do apps opened afterwards from the Dock, Spotlight or `open` (the ChatGPT desktop app, Zed, …): cc-pilot sets `CODEX_HOME` in launchd's environment. If the ChatGPT desktop app is running, cc-pilot asks before quitting and reopening it. Sessions that are already running keep their profile.
- **Use another profile in one terminal, once**: `CODEX_PROFILE=work codex`, without changing the current ChatGPT profile.
- **One shared working environment.** Session history, `AGENTS.md`, skills, plugins and rules are shared by all ChatGPT profiles, so a local session started in one profile can be continued in another. Sign-in, settings (`config.toml`), prompt history and the desktop app's own state are kept per profile.

There are two equal ways to use it:

- **The `ccp` command line tool**: manage profiles and switch the current profile (`ccp chatgpt …` for ChatGPT).
- **The CC Pilot menu bar app**: everything `ccp` does, plus each account's usage, fetched when you click refresh.

### The menu bar app

- The menu bar shows two lines: the current profile's subscription tier (such as Max 5x or Pro; the profile name when the tier isn't known), and the remaining 5-hour usage of that profile's account ("—" until you refresh or a running session reports its usage). You can also make it show only an icon.
- Once you have ChatGPT (a `~/.codex` directory), the menu bar shows one line per tool instead: the tool's icon and the remaining 5-hour usage of its current profile's account. In the gear menu, "Show Claude Code in the menu bar" and "Show ChatGPT in the menu bar" hide either one (the last one shown can't be hidden); with only one tool shown, the menu bar goes back to the two lines above. For ChatGPT the tier is the plan from the last refresh, otherwise the plan in the sign-in, otherwise the profile name.
- The panel lists Claude Code profiles first and ChatGPT profiles below them, separated by each tool's icon; the ChatGPT part only appears when `~/.codex` exists. Each profile shows the signed-in account's email first and the profile name below it, together with the organization and subscription tier (for ChatGPT, the plan). Profiles that aren't signed in show "Not signed in"; when two profiles are signed in to the same account, the list says "Same account as …". For ChatGPT, the same account means the same user in the same workspace. A ChatGPT profile signed in with an API key says so and shows no usage.
- Click a profile to make it the current profile, exactly like `ccp use` or `ccp chatgpt use`. If the ChatGPT desktop app is running when you switch ChatGPT profiles, the app asks whether to restart ChatGPT now; with "Later" the profile is switched anyway, and ChatGPT uses it the next time it opens. To add or delete a profile, the app opens Terminal and runs `ccp add` / `ccp rm` (`ccp chatgpt add` / `ccp chatgpt rm` for ChatGPT), so the flow is identical to the command line. Changes made with `ccp` show up in the app right away.
- Usage: click "Refresh All" (both tools), or the refresh button next to one account, to get the **remaining** percentage and reset time of the 5-hour window and the weekly window for all models. Expand a Claude Code account to see weekly windows per model and extra usage.
  - Every number is the percentage left, not the percentage used shown by Claude Code's `/usage`.
  - Colors follow the percentage left: red at 20% or less, amber at 50% or less, green otherwise.
  - Every number shows when it was fetched and turns gray after 30 minutes. Windows past their reset time show "Reset, refresh to update".
  - While a `claude` session is running, the 5-hour and all-models weekly numbers of its account update live from the usage Claude Code itself receives (passed on by its status line), with no extra request. Likewise, while a `codex` session or a session in the ChatGPT desktop app is running, its account's 5-hour and weekly numbers update live from the usage codex writes to its session transcript. When live and refreshed numbers describe the same window, the higher usage wins; a window with a later reset time replaces an older one.
  - Profiles signed in to the same account are fetched only once.
  - A profile whose short-lived credential has expired shows **Needs renewal**: open that profile's `claude` once (for ChatGPT, `codex` or ChatGPT in that profile) to restore it. The app sends no request and never renews anything itself. A Claude Code profile whose credential can no longer be renewed shows **Needs to sign in again**.
- Token usage: hover over an account in the panel to see, on its left, how many tokens this Mac has used on that account (input, output, cache write and cache read, broken down by model) in the current 5-hour window, the current weekly window and since a starting point, with a 24-hour and 30-day history. Claude Code's numbers are read from its local session transcripts; ChatGPT's from codex's session transcripts in `~/.codex/sessions` and `~/.codex/archived_sessions`, desktop app sessions included. Clearing moves the starting point to now, for one account or (from the settings menu) all of them, ChatGPT accounts included; Claude Code's and codex's files are never touched. Token usage is not the same thing as usage limits and can't be converted into them.
  - ChatGPT session history is shared by all profiles, so each usage event is counted once, even when a session is resumed or forked. A session is credited to the profile whose `CODEX_HOME` the codex process writing it has, otherwise to the profile whose prompt history (`history.jsonl`) has it. A session that can't be placed within an hour is left out rather than counted against the wrong account.
- The interface is in English or Simplified Chinese, following your system language. It lives only in the menu bar, with no Dock icon. "Launch at Login" is available and off by default.

## Network and privacy

CC Pilot only connects to these three addresses:

| Address | When |
| --- | --- |
| Claude Code usage API `https://api.anthropic.com/api/oauth/usage` | **Only when you click** "Refresh All" or an account's refresh button. Launching the app, opening the panel and switching profiles send no request. Requests honestly identify themselves with `User-Agent: cc-pilot/<version>` and do not pretend to be the official client. |
| ChatGPT usage API `https://chatgpt.com/backend-api/wham/usage` | Same as above: **only when you click** "Refresh All" or a ChatGPT account's refresh button. The request carries only the profile's access token (`Authorization`), its workspace ID (`ChatGPT-Account-Id`) and `User-Agent: cc-pilot/<version>`. |
| Update feed `https://raw.githubusercontent.com/xshowee/cc-pilot/main/appcast.xml` | Fetched by [Sparkle](https://sparkle-project.org): once a day while "Automatically Check for Updates" is on (the default), which can happen shortly after launch when the last check was more than a day ago; and immediately when you click "Check for Updates…". No system information is sent. |

When you choose to install an update, Sparkle downloads the new DMG from this repository's GitHub Releases. To turn off automatic checks, uncheck "Automatically Check for Updates" in the gear menu at the bottom right of the panel.

- **No usage data is collected.** No crash reports, no analytics or telemetry of any kind.
- **The app only reads credentials.** Claude Code's credentials are in the keychain: the app reads them through the system's own `/usr/bin/security`. ChatGPT's credentials are in each ChatGPT profile's `auth.json`: the app reads the email, plan, user and workspace IDs and when the access token expires. Either way, a token is kept in memory only for a single request and never written to logs, cache files or error messages.
- **cc-pilot never writes or renews credentials.** Renewal is always done by Claude Code or codex itself. Credentials are only removed by the tools themselves when signing out: in Claude Code you run `/logout` (`ccp rm` opens Claude Code for you to do it); `ccp chatgpt rm`, after you confirm, runs `codex logout` in that profile. Neither command deletes a profile whose credentials are still there.
- `ccp` doesn't read credentials, it only checks whether they exist: `ccp rm` whether the profile's keychain item is still there (without reading its contents), `ccp chatgpt add` and `ccp chatgpt rm` whether the profile's `auth.json` is.
- Reading credentials should never show a keychain access prompt. If one ever appears, don't click "Allow": it means cc-pilot is incompatible with your Claude Code version, and the app will tell you so.
- **Processes.** To tell which ChatGPT profile a running session belongs to, the app looks at your own processes whose name starts with `codex`: it reads each one's environment once and keeps only `CODEX_HOME`, and it lists the files they have open. It uses the same system interfaces as `lsof` (libproc and sysctl) and doesn't run any program for this. To find processes still using a profile, `ccp chatgpt rm` runs `ps -A -E` once and only looks for that profile's `CODEX_HOME`. Nothing else from a process's environment is kept.

## What it touches

| Location | What cc-pilot does |
| --- | --- |
| `~/.zshrc` | With your consent, appends **one line** at the end (see "Install" below). Running it again never adds a second line; uninstalling removes only that line. Nothing else in the file is touched. |
| `~/.cc-pilot/` | Where the `ccp` command and the `claude` and `codex` wrapper functions are installed. The app installs and updates it. |
| `~/.claude-profiles/` | Every profile other than the default one, one directory each (`~/.claude-profiles/<name>/`), plus the file recording the current profile, `~/.claude-profiles/active`, and `~/.claude-profiles/.live-quota/`, where the status line hand-off leaves the latest live quota of each profile. |
| `~/.claude/`, `~/.claude.json` (default profile) | **Read only.** When a profile is created, its MCP servers and project trust settings are copied from `~/.claude.json` and its settings from `~/.claude/settings.json`; the new profile's shared resources are symlinks into `~/.claude/`; the app reads account info (email, organization, tier) from `.claude.json` to display it. |
| Keychain | **Read only**, see "Network and privacy" above. |
| `~/.codex-profiles/` | Every ChatGPT profile other than the default one, one directory each (`~/.codex-profiles/<name>/`, its `CODEX_HOME`), plus the file recording the current ChatGPT profile, `~/.codex-profiles/active`. A new profile starts with a `config.toml` and symlinks into `~/.codex/`; its `auth.json` is written by `codex login`. |
| `~/.codex/` (default ChatGPT profile) | cc-pilot doesn't change the default profile's sign-in, settings or files. `ccp chatgpt add` creates `~/.codex/` and the shared directories in it (`sessions`, `archived_sessions`, `thread-writer-locks`, `.tmp`, `skills`, `plugins`, `rules`) when they're missing, and copies its `config.toml` into the new profile. After that, codex running in other profiles writes here too: its session databases through `sqlite_home` in the profile's `config.toml`, and its session files through the symlinks. The app reads the session transcripts in `sessions` and `archived_sessions`, and each ChatGPT profile's `auth.json` and `history.jsonl`. |
| launchd environment variable `CODEX_HOME` | `ccp chatgpt use` sets it with `launchctl setenv` to the current ChatGPT profile's directory, so apps opened afterwards use that profile; switching to `default` removes it with `launchctl unsetenv`. It lasts until you log out or restart; the app sets it again for the current ChatGPT profile each time it launches (only once `~/.codex-profiles/` exists). No LaunchAgent is installed. |
| ChatGPT desktop app | When you switch ChatGPT profiles while it's running, cc-pilot asks first and, only if you agree, quits it normally and opens it again. The first time, macOS asks for permission to control ChatGPT (Automation); if you don't allow it, the profile is still switched and you're told how to restart ChatGPT yourself. |
| ChatGPT background service | `ccp chatgpt rm`, after you confirm, stops the profile's `codex app-server` (which the desktop app leaves running after it quits) with a normal termination signal. No other process is ever stopped. |
| `~/Library/Application Support/cc-pilot/` | The app's token usage ledger (`token-usage.sqlite`): token counts per account and model, how far each session transcript has been read, and which profile each session belongs to. No conversation content. |
| Terminal | When you add or delete a profile in the app, it opens a new Terminal window to run `ccp add` / `ccp rm` (or `ccp chatgpt add` / `ccp chatgpt rm`). macOS asks once whether CC Pilot may control Terminal; if you'd rather not allow it, the app gives you the command to copy and run yourself. |

cc-pilot does **not**:

- modify or replace the Claude Code or codex executable. The wrappers call the real ones with `command claude` / `command codex`, and their auto-updates keep working;
- change anything in the default profiles, or migrate them (`ccp chatgpt add` only creates missing shared directories in `~/.codex`, see above);
- write, copy or renew `auth.json`;
- interfere with other Claude Code wrapper functions or aliases already in your `~/.zshrc`;
- change anything about `claude` while you only have the default profile, or while the default profile is current, other than the live quota hand-off: the wrapper adds a `--settings` override that points Claude Code's status line at `ccp statusline`, which passes your own status line through unchanged. It changes no `settings.json`; turn it off in the app's settings and `claude` behaves exactly as before;
- change anything about `codex` while the default ChatGPT profile is current and you haven't set `CODEX_HOME`: the wrapper just runs `command codex`.

Note that shared resources are symlinks. When you install a skill or plugin in any profile, it changes the copy in `~/.claude/` (or `~/.codex/` for ChatGPT), which all of that tool's profiles see. Settings aren't a shared resource: when Claude Code changes a setting in a profile (for example with `/model` or `/advisor`), only that profile is affected; the same goes for each ChatGPT profile's `config.toml`.

## Requirements

- macOS 13 or later, Apple Silicon or Intel.
- zsh (the default shell on macOS).
- Claude Code installed, with `claude` runnable from zsh.
- For ChatGPT profiles: the Codex CLI installed, with `codex` runnable from zsh (`ccp chatgpt add` and `ccp chatgpt rm` run `codex login` and `codex logout`). The ChatGPT desktop app is optional.

## Install

1. Download `CCPilot-<version>.dmg` from [GitHub Releases](https://github.com/xshowee/cc-pilot/releases/latest). The app is signed with a Developer ID and notarized by Apple.
2. Open the DMG, drag CC Pilot into **Applications**, and launch it.
3. On first launch the app explains and asks whether to set up zsh. Choose "Add to ~/.zshrc": the app installs `ccp` and the `claude` and `codex` wrapper functions into `~/.cc-pilot/`, then adds this line to the end of `~/.zshrc`:

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

ChatGPT works the same way (`ccp codex …` is the same as `ccp chatgpt …`):

```zsh
ccp chatgpt add work         # create ChatGPT profile "work" and run `codex login` in it
ccp chatgpt use work         # switch: codex sessions and apps opened from now on use "work"; asks before restarting ChatGPT
CODEX_PROFILE=work codex     # use "work" just this once, in this terminal, without changing the current ChatGPT profile
ccp chatgpt use default      # switch back to ~/.codex
```

`codex` picks the ChatGPT profile in this order, highest first:

1. `CODEX_PROFILE` is set: use that profile.
2. `CODEX_HOME` is set in the environment to a directory of your own (not `~/.codex` and not inside `~/.codex-profiles/`): cc-pilot stays out of the way and runs codex unchanged.
3. Otherwise use the current ChatGPT profile. A `CODEX_HOME` that points at `~/.codex` or into `~/.codex-profiles/` is treated as left over from cc-pilot (a terminal opened from the Dock inherits it from launchd, possibly from before you switched) and replaced.

As with `claude`, a profile that doesn't exist is an error; `codex` doesn't start and never falls back to the default profile.

## `ccp` commands

| Command | What it does |
| --- | --- |
| `ccp ls` | List all profiles, with `*` before the current one. The first line is always `default`. |
| `ccp current` | Print only the current profile's name, for scripts and prompts. Reads the current profile only, ignoring `CLAUDE_PROFILE`. |
| `ccp use <name>` | Switch the current profile; `ccp use default` switches back to the default profile. Only affects sessions started afterwards. |
| `ccp add <name>` | Create a profile and go straight into its Claude Code to onboard and sign in. Doesn't change the current profile. Claude Code starts in an empty directory reserved for ccp inside the profile directory (`.ccp-workdir`), not in your current directory; if it asks whether to trust that directory, it's safe to answer Yes, and `ccp rm` won't ask again for this profile. |
| `ccp rm <name>` | Delete a profile: asks for confirmation, opens that profile's Claude Code for you to run `/logout` and exit, and deletes it only once it's confirmed signed out. The default profile and the current profile can't be deleted. Claude Code starts in the profile's `.ccp-workdir` here too, which is deleted along with the profile. |
| `ccp chatgpt ls` | List all ChatGPT profiles (`~/.codex` is `default`, others live in `~/.codex-profiles/`), with `*` before the current one. `ccp codex ls` is the same. |
| `ccp chatgpt use <name>` | Switch the current ChatGPT profile: new `codex` sessions and apps opened afterwards (ChatGPT, Zed, …, via `launchctl setenv CODEX_HOME`) use it. If the ChatGPT app is running, asks whether to restart it; `--restart` / `--no-restart` skip the question. For one terminal only: `CODEX_PROFILE=<name> codex`. |
| `ccp chatgpt add <name>` | Create a ChatGPT profile and run `codex login` in it. Its `config.toml` starts as a copy of `~/.codex/config.toml` (pointing `sqlite_home` at `~/.codex`), and sessions, `AGENTS.md`, skills, plugins and rules are symlinks into `~/.codex`, so all profiles share them; sign-in and settings are per profile. If sign-in doesn't finish, the profile is kept and ccp prints the command to sign in later. Doesn't change the current ChatGPT profile. |
| `ccp chatgpt rm <name>` | Delete a ChatGPT profile. The default profile, the current one, and the one `launchctl` still points apps at can't be deleted, and neither can a profile still in use: if the ChatGPT app, a `codex` session or any other process runs with that profile's `CODEX_HOME`, it lists them and stops before asking. Otherwise it asks for confirmation, stops that profile's ChatGPT background service (`codex app-server`) if it's running, runs `codex logout` in the profile, and deletes it only once `auth.json` is gone. Only the profile's own files are deleted; the shared sessions, skills and so on in `~/.codex` stay. |
| `ccp init [--yes]` | Set up zsh: with your consent, add the line to the end of `~/.zshrc`; `--yes` skips the question. Does nothing if it's already there. |
| `ccp uninstall` | Remove the line `ccp init` added from `~/.zshrc`, leaving everything else as it was. |

Profile names, for both tools, may contain only letters, digits, `.`, `_` and `-`, and must start with a letter or digit. `default` and `active` are reserved.

## Known limitations

- **What switching doesn't reach**: switching works through the `claude` wrapper function in zsh, so Claude Code started any other way isn't affected and always uses the default profile. That includes:
  - IDE plugins (for example Claude Code in VS Code or JetBrains);
  - Claude Desktop;
  - shells other than zsh (bash, fish, …).
- **ChatGPT apps follow launchd, which forgets on restart.** After you restart your Mac or log in again, apps opened before CC Pilot runs use the default ChatGPT profile, until CC Pilot launches (or you run `ccp chatgpt use`) and sets `CODEX_HOME` again; turning on "Launch at Login" keeps that gap short. Programs that were already running when you switched (an editor, a shell other than zsh, …) keep the `CODEX_HOME` they started with; only `codex` in zsh goes through the wrapper, which always uses the current profile.
- **The ChatGPT desktop app uses one account at a time.** Switching ChatGPT profiles restarts it, interrupting tasks in progress.
- **Shared ChatGPT sessions have limits.** Only local sessions are shared: ChatGPT's regular chats are stored online with each account. The desktop app's sidebar groups sessions into projects per profile, so a session started in another profile shows up under recent sessions rather than under its project. Upstream Codex may make `codex resume` list only the current account's sessions; cc-pilot won't work around that.
- **MCP servers and project trust settings are copied once, at creation.** `ccp add` copies only `mcpServers` (user-level MCP servers) and `projects` (project trust settings) from the default profile's `~/.claude.json` as the new profile's starting point. After that each profile changes on its own; they are not kept in sync. An MCP server added to the default profile later won't appear in profiles that already exist, and vice versa. Connectors configured in your claude.ai account follow the account and aren't part of the copy.
- **Settings are copied once, at creation.** `ccp add` copies the default profile's `~/.claude/settings.json` as the new profile's starting settings (`ccp chatgpt add` does the same with `~/.codex/config.toml`). After that each profile changes on its own: a theme, status line or hook changed in one profile doesn't reach the others. This lets profiles on different subscription tiers use different models and advisors. Plugins are shared, but whether a plugin is enabled is part of each profile's settings: a plugin installed and enabled in one profile has to be enabled again with `/plugin` in the others.
- **Profiles can't be renamed.** The keychain item holding a profile's credentials is named after the profile directory's path, so renaming would lose the sign-in. To change a name: `ccp add` a profile with the new name and sign in, then `ccp rm` the old one (which walks you through signing out first).
- **It depends on Claude Code internals.** How keychain items are named, the structure of account info in `.claude.json`, and the usage API's address and fields are undocumented; cc-pilot follows the actual behavior of Claude Code 2.1.309. If a Claude Code update breaks compatibility, the app says "Incompatible with the current Claude Code version" or "The usage API may have changed. Please update cc-pilot." instead of showing a guessed number.
- **It depends on Codex internals too.** The structure of `auth.json`, the ChatGPT usage API and the session transcript format are undocumented; cc-pilot follows the ChatGPT desktop app 26.1027 and the Codex CLI 0.153.4. If an update breaks compatibility, the app says "Incompatible with the current ChatGPT version" or that the usage API may have changed.
- A ChatGPT desktop app session that runs entirely while CC Pilot isn't running may not be attributable to a profile (the desktop app doesn't keep `history.jsonl`); its token usage is then not counted.
- Usage isn't available when signed in with an API key (Claude Code or ChatGPT) or a long-lived token from `setup-token`.

## Uninstall

1. (Optional) If you no longer need the other profiles, switch back with `ccp use default`, then delete each one with `ccp rm <name>` (the current profile can't be deleted). Each profile is signed out first, so no valid credentials are left in the keychain.
2. If you've used ChatGPT profiles, run `ccp chatgpt use default`: it also removes `CODEX_HOME` from launchd's environment, so apps opened afterwards use `~/.codex` again. (Optional) Then delete the other ChatGPT profiles with `ccp chatgpt rm <name>`; each is signed out with `codex logout` first.
3. Run `ccp uninstall` (or use the gear menu at the bottom right of the panel › "Remove zsh Integration…") to remove the line from `~/.zshrc`.
4. Quit CC Pilot and delete it from **Applications**.

The default profiles (`~/.claude`, `~/.claude.json` and `~/.codex`, and their sign-ins) are never affected. After uninstalling, `claude` and `codex` in a new terminal behave exactly as they did before cc-pilot was installed.

To remove every trace, you can also delete by hand:

- `~/.cc-pilot/`: `ccp` and the wrapper functions (`ccp uninstall` keeps it);
- `~/.claude-profiles/`: the other profiles and the current-profile record. If you delete it without running `ccp rm` first, those profiles' credentials stay in the keychain (items named `Claude Code-credentials-` followed by 8 hex digits); you can delete them in Keychain Access;
- `~/.codex-profiles/`: the other ChatGPT profiles and their current-profile record. Deleting it without running `ccp chatgpt rm` first deletes those profiles' `auth.json` without signing out with codex. Sessions they started stay in `~/.codex`, which they share;
- `~/Library/Application Support/cc-pilot/`: the token usage ledger;
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
shell/          zsh wrapper functions and ccp (installed as-is to ~/.cc-pilot/, see shell/README.md)
Sources/Core/   app core for both tools: profiles, switching, credential reading, usage fetching and parsing, token usage (no UI)
Sources/App/    SwiftUI menu bar interface
Resources/      Info.plist, localized strings, entitlements, tool icons
tests/          shell black-box tests, the app core's check program, fake claude / codex / security / launchctl / osascript / open / ps
docs/           design decisions (docs/adr/) and the release process (docs/release.md)
```

Terminology is in [GLOSSARY.md](GLOSSARY.md), design decisions in [docs/adr/](docs/adr/), and signing, notarization and releasing in [docs/release.md](docs/release.md) (all in Chinese).

## License

[MIT](LICENSE)
