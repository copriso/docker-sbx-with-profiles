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

## Two things to check against your sbx build

Verified against `sbx` as of 2026-07: `policy init <allow-all|balanced|deny-all>`,
`policy allow network [--sandbox S] <host,host,...>`, `secret set [-g | SANDBOX]
[SERVICE]`, `create <agent> PATH [PATH...] [--name] [--kit]`, `ls -q`. These two
are still unconfirmed, and each is a one-line fix:

1. **The `sbx exec` separator.** Defaults to `sbx exec <name> -- <cmd>`, but
   `sbx exec --help` documents `sbx exec [flags] SANDBOX COMMAND [ARG...]` with no
   separator. The `--` matters because MCP registration passes `-s user`, which
   bare `sbx exec` may try to parse as its own flag. Check with
   `sbx exec <name> -- true; echo $?` and if it fails, run with
   `SBX_EXEC_SEP="" ./sbx-up.sh work`.
2. **`sbx secret set-custom`** is documented as experimental, so its flags may
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
