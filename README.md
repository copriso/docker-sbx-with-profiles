# sbx-up

Profile-driven provisioning for Docker Sandboxes. One profile per Claude account,
each with its own network policy, filesystem exposure, secrets, MCP servers and
repo.

```
chmod +x sbx-up.sh

./sbx-up.sh work --dry-run                 # see every command, change nothing
./sbx-up.sh work                           # create (or reuse) + provision + attach
./sbx-up.sh private --repo <url>           # ad-hoc repo for this run
./sbx-up.sh work --reprovision             # re-run setup on an existing sandbox
./sbx-up.sh work -- --branch=my-feature    # after `--` goes straight to `sbx run`
```

## What runs when

```
create   sbx create claude <workspace> --name <profile> [--kit ...]
network  sbx policy init <policy>                    (global, one-time)
         sbx policy allow network --sandbox <sandbox> <host,host,...>
secrets  sbx secret set <sandbox> <service>          (sandbox-scoped)
         sbx secret set-custom ...                   (experimental)
repo     git clone inside the VM, into $HOME/repos/<name>
mcp      claude mcp add-json <name> <json> -s user   inside the VM
         MCP_ENV_SECRETS values merged in first, passed over stdin
hook     post_create() from the profile
attach   sbx run <profile>
```

Everything up to `attach` happens between `sbx create` and the first time the
agent is running, which is the "before the machine starts" you asked about. A
kit is the other route — set `KIT_DIR` in the profile and it gets bind-mounted at
creation. Kits are read-only inside the VM, which is why MCP registration goes
through `claude mcp add-json` instead: Claude Code needs a writable config.

## Reuse

`sandbox_exists` checks `sbx ls`. If the sandbox is there, it's reused and
provisioning is skipped — a marker at `/var/tmp/.sbx-up-provisioned` inside the
VM records that setup already ran. MCP registration is individually idempotent
too: each server is only added if `claude mcp get <name>` doesn't already find
it, so hand-added servers survive a `--reprovision`.

## Accounts

Login is per-sandbox, so `work` and `private` keep separate sessions and neither
overwrites the other. On first boot the script reminds you to `/login`; `/status`
confirms which account is live. It also warns if `ANTHROPIC_API_KEY` is exported
in your shell, since that silently overrides a subscription login.

Do **not** set a global `-g anthropic` secret if you want the two profiles to
stay separate — global secrets apply to every sandbox.

## Filesystem

`WORKSPACE` is the only host directory shared into the VM, mounted at the same
path it has on the host. Point it at an empty scratch dir (`~/sbx/work`) and let
`CLONE_REPO` clone inside the VM, and nothing of yours is reachable from the
sandbox. Leave `CLONE_DEST` empty and the clone lands at `$HOME/repos/<name>` as
resolved *inside* the sandbox.

Leave `WORKSPACE` empty and the sandbox is created against the directory you ran
from, the way `sbx create claude .` behaves; `--workspace <path>` overrides it for
one run. The mount is bound **at creation time** — a later run from a different
directory reuses the existing sandbox with its original workspace and does not
remount, so per-directory sandboxes need distinct `SANDBOX_NAME`s.

Anything else your build supports goes in `EXTRA_CREATE_ARGS` — check
`sbx create --help`, since I deliberately didn't model flags I couldn't verify.

### Getting extra files in

Three ways, in order of how often you want them:

1. **Extra workspaces, at creation** — `sbx create` takes more than one path, each
   mounted at the same path it has on the host, `:ro` for read-only. This is what
   `EXTRA_CREATE_ARGS` is for:

   ```bash
   EXTRA_CREATE_ARGS=(/Volumes/dev/tool:ro /Volumes/dev/tool/node_modules:ro)
   ```

   Nothing is copied, edits on the host are visible immediately, and size is
   irrelevant. Mount the narrowest set of directories that works, not a repo root —
   whatever you mount is readable inside the sandbox.
2. **`sbx cp <src> <sandbox>:<dst>`, after creation** — a snapshot, so it drifts and
   has to be re-copied. Right for a handful of files (a global `CLAUDE.md`, a config);
   wrong for a dependency tree. Use `-L` if the source has symlinks, and put it in
   `post_create()` so `--reprovision` redoes it.
3. **Kits (`KIT_DIR`, experimental)** — declarative YAML bundling files, env vars,
   network policy and startup commands, applied at creation and mounted read-only.
   The right home for team-wide defaults; heavier than it's worth for one file.

An stdio MCP server whose `command` is a host path needs option 1 or 2, and needs its
dependencies too. A `dist/index.js` that imports bare specifiers resolves them by
walking up from its own directory, so the `node_modules` those imports land in must be
mounted at its real path as well — see `profiles/dashbrd.env` for a worked example.

## MCP servers that need a token

Keep the token out of the `.mcp.json`. List the env var and the command that
produces it in `MCP_ENV_SECRETS`, and it is merged into that server's `env` at
provisioning time:

```bash
MCP_ENV_SECRETS=(
  "kan-bn|KAN_API_TOKEN|security find-generic-password -s sbx-dashbrd-kan -w"
)
```

Same rule as every other secret here: the profile stores the command, never the
value. Store the token once with

```bash
security add-generic-password -a "$USER" -s sbx-dashbrd-kan -w <token> -U
```

A spec carrying a merged secret is handed to the VM on **stdin** rather than as an
argument, so the token never appears in a printed command or in `ps` output on either
side. If the command yields nothing, the server is skipped rather than registered
half-configured, with a warning naming the failing lookup.

## One thing to check against your sbx build

Verified against `sbx` as of 2026-07: `policy init <allow-all|balanced|deny-all>`,
`policy allow network [--sandbox S] <host,host,...>`, `secret set [-g | SANDBOX]
[SERVICE]`, `create <agent> PATH [PATH...] [--name] [--kit]`, `ls -q`, `cp`, and
`exec` — including that `sbx exec <name> -- <cmd>` and `sbx exec <name> <cmd>` behave
identically, both passing flag-like arguments such as `-s user` through untouched.
`SBX_EXEC_SEP=""` remains available if a future build stops accepting `--`.

One is still unconfirmed:

- **`sbx secret set-custom`** is documented as experimental, so its flags may
  have drifted. `CUSTOM_SECRETS` is empty by default.

Run `--dry-run` first and read the commands before letting it touch anything.

## Gotchas that will cost you time

- **Global secrets are injected at creation time** and can't be added to an
  existing sandbox. `REQUIRED_GLOBAL_SECRETS` only warns; set them yourself with
  `sbx secret set -g <service>` *before* the first run of a profile.
- **Remote MCP servers are blocked by default.** Add their hosts to
  `ALLOW_DOMAINS`. When something misbehaves, `sbx policy log <sandbox>` shows
  exactly what got denied — including Anthropic's own endpoints.
- **stdio MCP servers that read host paths** will start fine and find nothing;
  only `WORKSPACE` exists inside the VM. A server living outside it needs its
  directory added as an extra workspace, e.g.
  `EXTRA_CREATE_ARGS=(/path/to/server:ro)`.
- **`POLICY_INIT` is global and one-time.** `sbx policy init` sets the starting
  policy for *every* sandbox, not a per-profile default, and fails once
  initialised (`sbx policy reset` starts over). `ALLOW_DOMAINS` is the
  per-profile knob — it is applied with `--sandbox`, so it stays scoped.
- **`sbx rm <name>`** takes the login with it. **`sbx reset`** wipes secrets for
  every sandbox.

## License

MIT © 2026 copriso, Robert Hänsel. Commercial use, modification and
redistribution are all fine; keep the copyright notice in copies.
