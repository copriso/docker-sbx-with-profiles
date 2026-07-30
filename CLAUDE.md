# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single bash script (`sbx-up.sh`) plus a directory of profiles. It provisions and
attaches Docker Sandboxes (`sbx`) — one profile per Claude account, each with its own
network policy, filesystem exposure, secrets, MCP servers and repo. There is no build,
no test suite, and no dependency manifest.

## Commands

```bash
./sbx-up.sh work --dry-run                 # print every command, change nothing
./sbx-up.sh work                           # create (or reuse) + provision + attach
./sbx-up.sh private --repo <url>           # ad-hoc repo for this run
./sbx-up.sh work --reprovision             # force re-run of provisioning
./sbx-up.sh work --no-attach               # provision only
./sbx-up.sh work --workspace /path         # override the profile's WORKSPACE
./sbx-up.sh work -- --branch=my-feature    # everything after `--` goes to `sbx run`

shellcheck sbx-up.sh                       # the only linting that applies here
SBX_UP_PROFILE_DIR=/path ./sbx-up.sh work  # profiles from elsewhere
SBX_EXEC_SEP="" ./sbx-up.sh work           # sbx build that rejects `sbx exec <n> -- <cmd>`
```

`--dry-run` is the verification loop. It exercises argument parsing, profile loading,
`MCP_FILE`/`KIT_DIR` resolution and every code path up to the point of mutation, printing
the exact commands instead of running them. Use it after any change to the script.

## Architecture

The script is one linear pipeline, in this order, with section banners marking each step:

1. **arg parsing** → **profile loading**: `profiles/<name>.env` is `.`-sourced into the
   script's own scope. Profiles are plain bash — they set variables *and* may define a
   `post_create()` hook that runs with the script's functions (notably `sbx_exec`) in scope.
   Every default is declared before the source, so a profile can override anything.
2. **preflight**: warns on host `ANTHROPIC_API_KEY` (it silently overrides a subscription
   login) and on missing `REQUIRED_GLOBAL_SECRETS` (global secrets are injected at
   creation time and cannot be added to an existing sandbox — warn only, never set).
3. **create/reuse**: `sandbox_exists` greps `sbx ls`. Existing → reuse, `FRESH=0`.
4. **provisioning gate**: runs when fresh, when `--reprovision`, or when the marker at
   `/var/tmp/.sbx-up-provisioned` (inside the VM) is absent.
5. **provisioning**: network policy → sandbox-scoped secrets → custom secrets → repo clone
   → MCP servers → `post_create()` → write marker.
6. **attach**: `sbx run <sandbox> [RUN_ARGS]`.

An empty `WORKSPACE` resolves to `$PWD` (`--workspace` overrides), so a profile need not
hardcode a directory. The mount is bound at `sbx create` time only — reuse never remounts,
which is why the reuse path warns when the workspace came from the cwd.

### Verified `sbx` surface (checked 2026-07, don't re-guess)

```
sbx create <agent> PATH [PATH...] [--name N] [--kit REF] [--clone] [--template] [--profile]
sbx policy init <allow-all|balanced|deny-all>        # GLOBAL, one-time; reset to redo
sbx policy allow network [--sandbox S] "h1,h2,..."   # no --sandbox ⇒ applies to ALL sandboxes
sbx secret set [-g | SANDBOX] [SERVICE]              # value on stdin
sbx exec [flags] SANDBOX COMMAND [ARG...]            # `--` separator undocumented
sbx ls [-q|--json]
```

Extra `PATH`s on `create` accept a `:ro` suffix — that is the way to expose a directory
outside `WORKSPACE` (e.g. an stdio MCP server's install dir), via `EXTRA_CREATE_ARGS`.
`ALLOW_DOMAINS` is applied as one comma-separated `--sandbox`-scoped call, not a loop.

### Invariants to preserve

- **bash 3.2 / stock macOS.** No associative arrays, no `${x,,}`, no `mapfile`, no `readarray`.
- **`set -euo pipefail` plus empty-array expansion.** Iterate optional arrays as
  `${ARR[@]+"${ARR[@]}"}` — under bash 3.2 `set -u`, a bare `"${ARR[@]}"` on an empty array
  is an unbound-variable error.
- **Everything mutating goes through `run`/`sbx_exec`**, which print the command and become
  no-ops under `--dry-run`. `sbx_probe` is the deliberate exception: it queries state, stays
  silent, and is only called when `DRY_RUN` is 0.
- **Non-fatal by design.** Provisioning steps `|| warn` rather than `die`, so an unsupported
  `sbx` subcommand degrades instead of aborting a half-built sandbox. Only preflight and
  profile-resolution errors `die`.
- **Idempotence at every layer.** Sandbox reuse via `sbx ls`; provisioning via the marker;
  clone via a `[ -d "$DEST/.git" ]` check; MCP via `claude mcp get <name>` before add-json,
  so hand-added servers survive `--reprovision`.
- **Host vs. VM path resolution.** `WORKSPACE`, `KIT_DIR`, `MCP_FILE` are host paths
  resolved by the script. `CLONE_DEST` is expanded *inside* the VM — its `$HOME` is the
  sandbox's, which is why the clone logic is a heredoc'd `sh -c` passed values via `env`.

### Profile contract

`profiles/<name>.env` sets: `AGENT`, `SANDBOX_NAME` (defaults to the profile name),
`WORKSPACE`, `KIT_DIR`, `POLICY_INIT`, `ALLOW_DOMAINS[]`, `REQUIRED_GLOBAL_SECRETS[]`,
`SANDBOX_SECRETS[]` (`"service=command producing the value"`), `CUSTOM_SECRETS[]`
(`"ENV_VAR|host|command producing the value"`), `MCP_FILE`, `CLONE_REPO`/`CLONE_DEST`/
`CLONE_DEPTH`/`CLONE_BRANCH`, `EXTRA_CREATE_ARGS[]`, `WARN_ON_HOST_API_KEY`.

Secret values are never stored in profiles — only the command that produces them
(`gh auth token`, `security find-generic-password`, `pass show`), `eval`'d at provisioning
time and piped straight into `sbx secret set`.

`MCP_FILE` paths are relative to `PROFILE_DIR`; `KIT_DIR` is relative to `SCRIPT_DIR`.
MCP JSON accepts either a `{"mcpServers": {...}}` wrapper or a bare server map — the `jq`
expression `(.mcpServers // .)` handles both. Registration is `claude mcp add-json -s user`
*inside* the VM rather than via a kit, because kits mount read-only and Claude Code needs
a writable config.

### Adding a provisioning step

Insert it inside the `NEED_PROVISION` block, before the marker write, with a `# --- name ---`
banner, a `log` line, `run`/`sbx_exec` for the mutation, and `|| warn` on failure. Anything
that must exist at first boot but cannot be added later belongs in `EXTRA_CREATE_ARGS` or a
kit instead — the create call happens earlier and only once.

## Repo notes

- `.gitignore` ignores `profiles/*`; the two checked-in profiles were force-added as
  examples. New profiles need `git add -f` to be tracked, and they are the place real
  hostnames and repo URLs land — check before committing one.
- The README's "Two things to check against your sbx build" documents what remains
  unverified: the `sbx exec` separator (`SBX_EXEC_SEP`) and `sbx secret set-custom`'s
  flags. Treat those two call sites as provisional; the rest is confirmed above.
