#!/usr/bin/env bash
#
# sbx-up.sh — provision and attach a Docker Sandbox from a named profile.
#
# Copyright (c) 2026 copriso, Robert Hänsel. MIT licensed — see LICENSE.
#
#   ./sbx-up.sh work
#   ./sbx-up.sh private --repo git@github.com:me/side-project.git
#   ./sbx-up.sh work --reprovision          # re-run provisioning on an existing sandbox
#   ./sbx-up.sh work --dry-run              # print every command, change nothing
#   ./sbx-up.sh work --no-attach            # provision only
#   ./sbx-up.sh work --workspace /path/to/x # override the profile's workspace
#   ./sbx-up.sh work -- --branch=my-feature # everything after -- goes to `sbx run`
#
# A profile that leaves WORKSPACE empty uses the directory you ran from.
#
# Idempotent: if the sandbox already exists it is reused and provisioning is
# skipped (a marker file inside the VM records that it already ran). The
# workspace is fixed when the sandbox is created and cannot be changed by a
# later run — a different directory needs a different SANDBOX_NAME.
#
# Written for bash 3.2 so it works on stock macOS. No associative arrays.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="${SBX_UP_PROFILE_DIR:-$SCRIPT_DIR/profiles}"
MARKER="/var/tmp/.sbx-up-provisioned"   # inside the VM

# If your sbx build does not accept a `--` separator for exec, set this to "".
SBX_EXEC_SEP="${SBX_EXEC_SEP:---}"

DRY_RUN=0
REPROVISION=0
ATTACH=1
REPO_OVERRIDE=""
WORKSPACE_OVERRIDE=""
PROFILE=""
RUN_ARGS=()

# ---------------------------------------------------------------- helpers ----

c_red=$'\033[31m'; c_yel=$'\033[33m'; c_grn=$'\033[32m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[ -t 2 ] || { c_red=""; c_yel=""; c_grn=""; c_dim=""; c_off=""; }

log()  { printf '%s==>%s %s\n' "$c_grn" "$c_off" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "$c_yel" "$c_off" "$*" >&2; }
die()  { printf '%s[err]%s %s\n'  "$c_red" "$c_off" "$*" >&2; exit 1; }

# Print a command, then run it (or skip it under --dry-run).
run() {
  printf '%s  $ %s%s\n' "$c_dim" "$*" "$c_off" >&2
  [ "$DRY_RUN" -eq 1 ] && return 0
  "$@"
}

usage() {
  # Print the header comment block, starting after the shebang and stopping at
  # the first line that is not a comment.
  awk 'NR<3 {next} !/^#/ {exit} {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"
  printf '\nAvailable profiles:\n'
  for f in "$PROFILE_DIR"/*.env; do
    [ -e "$f" ] || { printf '  (none in %s)\n' "$PROFILE_DIR"; break; }
    printf '  %s\n' "$(basename "${f%.env}")"
  done
}

# ------------------------------------------------------------ arg parsing ----

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)     usage; exit 0 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --reprovision) REPROVISION=1; shift ;;
    --no-attach)   ATTACH=0; shift ;;
    --repo)        REPO_OVERRIDE="${2:?--repo needs a value}"; shift 2 ;;
    --workspace)   WORKSPACE_OVERRIDE="${2:?--workspace needs a value}"; shift 2 ;;
    --)            shift; RUN_ARGS=("$@"); break ;;
    -*)            die "unknown flag: $1 (see --help)" ;;
    *)
      [ -n "$PROFILE" ] && die "only one profile at a time (got '$PROFILE' and '$1')"
      PROFILE="$1"; shift ;;
  esac
done

[ -n "$PROFILE" ] || { usage; exit 1; }
command -v sbx >/dev/null || die "sbx not found in PATH"

# --------------------------------------------------------- profile loading ---

PROFILE_FILE="$PROFILE_DIR/$PROFILE.env"
[ -f "$PROFILE_FILE" ] || die "no profile '$PROFILE' at $PROFILE_FILE"

# Defaults. Every one of these can be overridden by the profile.
AGENT="claude"
SANDBOX_NAME=""
WORKSPACE=""
KIT_DIR=""
POLICY_INIT=""
ALLOW_DOMAINS=()
REQUIRED_GLOBAL_SECRETS=()
SANDBOX_SECRETS=()          # "service=shell command producing the value"
CUSTOM_SECRETS=()           # "ENV_VAR|host|shell command producing the value"
MCP_FILE=""
CLONE_REPO=""
CLONE_DEST=""               # expanded *inside* the VM, so $HOME is the VM's
CLONE_DEPTH=""
CLONE_BRANCH=""
EXTRA_CREATE_ARGS=()
WARN_ON_HOST_API_KEY=1

# shellcheck disable=SC1090
. "$PROFILE_FILE"

[ -n "$SANDBOX_NAME" ] || SANDBOX_NAME="$PROFILE"
[ -n "$REPO_OVERRIDE" ] && CLONE_REPO="$REPO_OVERRIDE"
[ -n "$WORKSPACE_OVERRIDE" ] && WORKSPACE="$WORKSPACE_OVERRIDE"

# A profile that leaves WORKSPACE empty runs against the directory you invoked
# the script from, the way `sbx create claude .` does. The path is mounted at
# the same location inside the VM, so it is resolved to an absolute one here.
WORKSPACE_FROM_CWD=0
if [ -z "$WORKSPACE" ]; then
  WORKSPACE="$PWD"
  WORKSPACE_FROM_CWD=1
  log "workspace: not set in profile — using current directory"
fi
case "$WORKSPACE" in
  /*)   : ;;
  ./*)  WORKSPACE="$PWD/${WORKSPACE#./}" ;;
  *)    WORKSPACE="$PWD/$WORKSPACE" ;;
esac
if [ -e "$WORKSPACE" ] && [ ! -d "$WORKSPACE" ]; then
  die "workspace exists but is not a directory: $WORKSPACE"
fi
# The isolation pattern in the README is an empty scratch dir plus an in-VM
# clone, so a missing workspace is created rather than treated as an error.
if [ ! -d "$WORKSPACE" ]; then
  log "workspace: $WORKSPACE does not exist — creating it"
  run mkdir -p "$WORKSPACE"
fi
# Collapse `..` and symlinks so the host and in-VM mount paths agree. Skipped
# when the directory was only pretend-created under --dry-run.
[ -d "$WORKSPACE" ] && WORKSPACE="$(cd "$WORKSPACE" && pwd)"

if [ -n "$MCP_FILE" ]; then
  case "$MCP_FILE" in
    /*) : ;;
    *)  MCP_FILE="$PROFILE_DIR/$MCP_FILE" ;;
  esac
  [ -f "$MCP_FILE" ] || die "MCP_FILE not found: $MCP_FILE"
  command -v jq >/dev/null || die "jq is required to apply MCP config (brew install jq)"
fi

if [ -n "$KIT_DIR" ]; then
  case "$KIT_DIR" in
    /*) : ;;
    *)  KIT_DIR="$SCRIPT_DIR/$KIT_DIR" ;;
  esac
  [ -d "$KIT_DIR" ] || die "KIT_DIR not found: $KIT_DIR"
fi

log "profile '$PROFILE' -> sandbox '$SANDBOX_NAME' (agent: $AGENT)"
[ "$DRY_RUN" -eq 1 ] && warn "dry run: nothing will be changed"

# -------------------------------------------------------------- sbx shims ----

# `sbx exec` inside the target sandbox.
sbx_exec() {
  if [ -n "$SBX_EXEC_SEP" ]; then
    run sbx exec "$SANDBOX_NAME" "$SBX_EXEC_SEP" "$@"
  else
    run sbx exec "$SANDBOX_NAME" "$@"
  fi
}

# Same, but quiet and without dry-run suppression — used for probing state.
sbx_probe() {
  if [ -n "$SBX_EXEC_SEP" ]; then
    sbx exec "$SANDBOX_NAME" "$SBX_EXEC_SEP" "$@" >/dev/null 2>&1
  else
    sbx exec "$SANDBOX_NAME" "$@" >/dev/null 2>&1
  fi
}

sandbox_exists() {
  if sbx ls --quiet >/dev/null 2>&1; then
    sbx ls --quiet | grep -qx "$SANDBOX_NAME"
  else
    sbx ls 2>/dev/null | awk '{print $1}' | grep -qx "$SANDBOX_NAME"
  fi
}

# ------------------------------------------------------- preflight checks ----

# An API key on the host overrides a Max/Pro subscription login, which silently
# sends you to the wrong account. Worth catching before the VM boots.
if [ "$WARN_ON_HOST_API_KEY" -eq 1 ] && [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  warn "ANTHROPIC_API_KEY is set in this shell and takes precedence over a"
  warn "subscription login. Unset it if you want to use /login."
fi

# Global secrets are injected at creation time and cannot be added later, so
# they have to exist before `sbx create`.
if [ "${#REQUIRED_GLOBAL_SECRETS[@]}" -gt 0 ]; then
  have_secrets="$(sbx secret ls 2>/dev/null || true)"
  for svc in "${REQUIRED_GLOBAL_SECRETS[@]}"; do
    printf '%s\n' "$have_secrets" | grep -q "$svc" \
      || warn "global secret '$svc' not found — set it before creating: sbx secret set -g $svc"
  done
fi

# ------------------------------------------------------------ create/reuse ---

FRESH=0
if sandbox_exists; then
  log "sandbox '$SANDBOX_NAME' already exists — reusing it"
  # The workspace is bound at creation time. When it came from the current
  # directory, a run from somewhere else looks like it rebound the mount but
  # did not — worth saying out loud. 'sbx ls' shows the real one.
  if [ "$WORKSPACE_FROM_CWD" -eq 1 ]; then
    warn "workspace was bound when it was created — this run does NOT remount"
    warn "$WORKSPACE. Check 'sbx ls'; another directory needs another SANDBOX_NAME."
  fi
else
  log "creating sandbox '$SANDBOX_NAME' with workspace $WORKSPACE"
  create_cmd=(sbx create "$AGENT" "$WORKSPACE")
  create_cmd+=(--name "$SANDBOX_NAME")
  [ -n "$KIT_DIR" ] && create_cmd+=(--kit "$KIT_DIR")
  [ "${#EXTRA_CREATE_ARGS[@]}" -gt 0 ] && create_cmd+=("${EXTRA_CREATE_ARGS[@]}")
  run "${create_cmd[@]}"
  FRESH=1
fi

# ------------------------------------------------ decide whether to set up ---

NEED_PROVISION=0
if [ "$FRESH" -eq 1 ] || [ "$REPROVISION" -eq 1 ]; then
  NEED_PROVISION=1
elif [ "$DRY_RUN" -eq 0 ] && ! sbx_probe test -f "$MARKER"; then
  log "no provisioning marker found — provisioning now"
  NEED_PROVISION=1
fi

if [ "$NEED_PROVISION" -eq 0 ]; then
  log "already provisioned (use --reprovision to force)"
else

  # --- network policy ------------------------------------------------------
  # `policy init` sets the *global* initial policy for every sandbox and is a
  # one-time operation — re-running it after initialisation fails, so this only
  # warns. `sbx policy reset` is the way to start over.
  if [ -n "$POLICY_INIT" ]; then
    log "network: initialising global policy '$POLICY_INIT' (applies to all sandboxes)"
    run sbx policy init "$POLICY_INIT" \
      || warn "policy init failed — already initialised? 'sbx policy reset' starts over"
  fi
  # One rule, comma-separated, scoped to this sandbox. Without --sandbox the
  # rule would apply globally to every sandbox and defeat per-profile isolation.
  if [ "${#ALLOW_DOMAINS[@]}" -gt 0 ]; then
    domain_list=""
    for d in "${ALLOW_DOMAINS[@]}"; do
      domain_list="${domain_list:+$domain_list,}$d"
    done
    log "network: allowing ${#ALLOW_DOMAINS[@]} host(s) for '$SANDBOX_NAME' only"
    run sbx policy allow network --sandbox "$SANDBOX_NAME" "$domain_list" \
      || warn "could not apply network rules — check 'sbx policy allow network --help'"
  fi

  # --- sandbox-scoped secrets ---------------------------------------------
  # These take effect immediately, even on a running sandbox, and override the
  # global value for this sandbox only.
  for entry in ${SANDBOX_SECRETS[@]+"${SANDBOX_SECRETS[@]}"}; do
    svc="${entry%%=*}"; cmd="${entry#*=}"
    log "secret: setting '$svc' (sandbox scope)"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '%s  $ <%s> | sbx secret set %s %s%s\n' "$c_dim" "$cmd" "$SANDBOX_NAME" "$svc" "$c_off" >&2
    else
      val="$(eval "$cmd")" || { warn "could not produce value for '$svc'"; continue; }
      [ -n "$val" ] || { warn "empty value for '$svc' — skipped"; continue; }
      printf '%s' "$val" | sbx secret set "$SANDBOX_NAME" "$svc" || warn "secret set failed for '$svc'"
      unset val
    fi
  done

  # --- custom (experimental) secrets --------------------------------------
  for entry in ${CUSTOM_SECRETS[@]+"${CUSTOM_SECRETS[@]}"}; do
    envvar="${entry%%|*}"; rest="${entry#*|}"
    host="${rest%%|*}";   cmd="${rest#*|}"
    log "secret: custom '$envvar' for $host"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '%s  $ sbx secret set-custom %s --host %s --env %s --value <%s>%s\n' \
        "$c_dim" "$SANDBOX_NAME" "$host" "$envvar" "$cmd" "$c_off" >&2
    else
      val="$(eval "$cmd")" || { warn "could not produce value for '$envvar'"; continue; }
      sbx secret set-custom "$SANDBOX_NAME" --host "$host" --env "$envvar" --value "$val" \
        || warn "set-custom failed for '$envvar' (it is an experimental command)"
      unset val
    fi
  done

  # --- clone the repo inside the VM ---------------------------------------
  if [ -n "$CLONE_REPO" ]; then
    log "repo: cloning $CLONE_REPO inside the sandbox"
    clone_script='
set -eu
if [ -z "${DEST:-}" ]; then
  name="$(basename "${REPO%.git}")"
  DEST="$HOME/repos/$name"
fi
if [ -d "$DEST/.git" ]; then
  echo "reusing existing clone at $DEST"
else
  mkdir -p "$(dirname "$DEST")"
  set -- clone
  [ -n "${DEPTH:-}" ]  && set -- "$@" --depth "$DEPTH"
  [ -n "${BRANCH:-}" ] && set -- "$@" --branch "$BRANCH"
  git "$@" "$REPO" "$DEST"
fi
git -C "$DEST" remote -v
printf "%s\n" "$DEST" > "$HOME/.sbx-up-repo"
'
    sbx_exec env \
      REPO="$CLONE_REPO" \
      DEST="$CLONE_DEST" \
      DEPTH="$CLONE_DEPTH" \
      BRANCH="$CLONE_BRANCH" \
      sh -c "$clone_script" \
      || warn "clone failed — is github.com allowed, and is the git credential available?"
  fi

  # --- MCP servers --------------------------------------------------------
  # Registered at user scope inside the VM, before the agent is ever attached.
  # Existing servers with the same name are left alone.
  if [ -n "$MCP_FILE" ]; then
    log "mcp: applying servers from $(basename "$MCP_FILE")"
    jq -r '(.mcpServers // .) | keys[]' "$MCP_FILE" | while IFS= read -r name; do
      [ -n "$name" ] || continue
      if [ "$DRY_RUN" -eq 0 ] && sbx_probe "$AGENT" mcp get "$name"; then
        log "mcp: '$name' already registered — keeping it"
        continue
      fi
      spec="$(jq -c --arg n "$name" '(.mcpServers // .)[$n]' "$MCP_FILE")"
      log "mcp: adding '$name'"
      sbx_exec "$AGENT" mcp add-json "$name" "$spec" -s user \
        || warn "could not add MCP server '$name'"
    done
  fi

  # --- profile hook -------------------------------------------------------
  if declare -F post_create >/dev/null; then
    log "running profile hook post_create()"
    post_create
  fi

  # --- mark as done -------------------------------------------------------
  sbx_exec sh -c "printf '%s\n' \"$PROFILE $(date -u +%FT%TZ)\" > $MARKER" \
    || warn "could not write provisioning marker"
fi

# ----------------------------------------------------------------- attach ----

if [ "$ATTACH" -eq 0 ]; then
  log "done (not attaching). Attach later with: sbx run $SANDBOX_NAME"
  exit 0
fi

if [ "$FRESH" -eq 1 ]; then
  warn "first boot: run /login inside Claude Code to sign in as the $PROFILE account,"
  warn "then /status to confirm which account is active."
fi

log "attaching to '$SANDBOX_NAME'"
run sbx run "$SANDBOX_NAME" ${RUN_ARGS[@]+"${RUN_ARGS[@]}"}
