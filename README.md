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
network  sbx policy init / sbx policy allow  per domain
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

`WORKSPACE` is the only host directory shared into the VM. Point it at an empty
scratch dir (`~/sbx/work`) and let `CLONE_REPO` clone inside the VM, and nothing
of yours is reachable from the sandbox. Leave `CLONE_DEST` empty and the clone
lands at `$HOME/repos/<name>` as resolved *inside* the sandbox.

Anything else your build supports goes in `EXTRA_CREATE_ARGS` — check
`sbx create --help`, since I deliberately didn't model flags I couldn't verify.

## Three things to check against your sbx build

I couldn't confirm these from the docs, and they're each a one-line fix:

1. **`sbx policy allow` argument order.** The script calls
   `sbx policy allow <sandbox> <domain>`. If your build wants the sandbox
   selected differently, adjust the loop under `network policy`. Failures only
   warn, so the run continues.
2. **The `sbx exec` separator.** Defaults to `sbx exec <name> -- <cmd>`. If your
   build doesn't take `--`, run with `SBX_EXEC_SEP="" ./sbx-up.sh work`.
3. **`sbx secret set-custom`** is documented as experimental, so its flags may
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
  only `WORKSPACE` exists inside the VM.
- **`sbx rm <name>`** takes the login with it. **`sbx reset`** wipes secrets for
  every sandbox.

## License

MIT © 2026 copriso, Robert Hänsel. Commercial use, modification and
redistribution are all fine; keep the copyright notice in copies.
