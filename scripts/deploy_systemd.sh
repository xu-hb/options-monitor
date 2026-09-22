#!/usr/bin/env bash
set -euo pipefail

# Staged helper around `om service render` for turning an existing
# options-monitor install into systemd units. Every stage is explicit and
# idempotent; nothing touches /etc/systemd/system without confirmation.
#
# It complements docs/DEPLOY_LINUX_MAC.md, it does not replace it: read that
# document before enabling the timer stage.

REPO="${REPO:-${HOME}/apps/options-monitor/current}"
RUNTIME="${RUNTIME:-${HOME}/apps/options-monitor/runtime}"
ENV_FILE="${ENV_FILE:-${RUNTIME}/options-monitor.env}"
BUNDLE="${BUNDLE:-/tmp/options-monitor-service}"
DEPLOY_USER="${DEPLOY_USER:-$(id -un)}"
MARKETS="${MARKETS:-}"
FEISHU_WS_CONFIG_KEY="${FEISHU_WS_CONFIG_KEY:-}"
ACCOUNTS="${ACCOUNTS:-}"
INCLUDE_AUTO_UPGRADE="${INCLUDE_AUTO_UPGRADE:-1}"
INCLUDE_SECRET_CREDENTIALS="${INCLUDE_SECRET_CREDENTIALS:-0}"
PYTHON_BIN="${PYTHON:-}"

usage() {
  cat <<'EOF'
Usage:
  deploy_systemd.sh {prepare|render|install|timers|verify|sudoers|help}

Stages:
  prepare   Rebuild runtime config JSON from the YAML authoring source.
            Backs up existing config.<market>.json first. Writes the assistant
            config to $RUNTIME/resolved/config.assistant.json.
  render    Render the service bundle into $BUNDLE and run the read-only
            preflight. Does not install or start anything.
  install   Copy units into /etc/systemd/system, daemon-reload, and enable the
            long-running services. Asks for confirmation.
  timers    Enable the tick / auto-close / projection / status timers. Requires
            OpenD to be reachable and logged in. Asks for confirmation.
  verify    Read-only: service status, drift dry-run, failed units, recent log.
  sudoers   Print suggested sudoers lines. Writes nothing.

Environment overrides:
  REPO          Install root symlink. Default: $HOME/apps/options-monitor/current.
                Must stay a symlink literal path: auto-upgrade reads the remote
                URL from this release's git config.
  RUNTIME       Runtime root. Default: $HOME/apps/options-monitor/runtime.
  ENV_FILE      Service env file. Default: $RUNTIME/options-monitor.env.
  BUNDLE        Render output directory. Default: /tmp/options-monitor-service.
  DEPLOY_USER   systemd User= identity. Default: current user.
  ACCOUNTS      Space-separated account allowlist. Empty means the union of the
                accounts declared in each market runtime config.
  MARKETS       Space-separated markets to render. Default: the markets declared
                in $RUNTIME/config.yaml, falling back to whichever
                config.<market>.json already exists. Set this for a US+HK install
                whose YAML source only declares one of them.
  FEISHU_WS_CONFIG_KEY
                Market whose runtime config backs the Feishu long connection.
                Default: the first entry of MARKETS. Required by the renderer
                whenever more than one market is selected.
  INCLUDE_AUTO_UPGRADE          1 (default) renders the daily upgrade timer.
  INCLUDE_SECRET_CREDENTIALS    1 renders per-unit encrypted credential
                                drop-ins. Requires removing OM_SECRET_BACKEND=env
                                from the env file, otherwise the credential
                                backend is bypassed. See docs/SECRET_STORAGE.md.
  PYTHON        Python interpreter used to read service.profile.json.
EOF
}

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
confirm() { read -r -p "$1 [y/N] " answer; [[ "$answer" == [yY] ]]; }

python_bin() {
  if [ -n "$PYTHON_BIN" ]; then printf '%s' "$PYTHON_BIN"
  elif [ -x "$REPO/.venv/bin/python" ]; then printf '%s' "$REPO/.venv/bin/python"
  else printf 'python3'
  fi
}

common_args() {
  ARGS=(
    --target systemd
    --repo-root "$REPO"
    --runtime-root "$RUNTIME"
    --env-file "$ENV_FILE"
    --deploy-user "$DEPLOY_USER"
    --markets $MARKETS
    --config-yaml "$RUNTIME/config.yaml"
  )
  for market in $MARKETS; do
    ARGS+=(--config-"$market" "$RUNTIME/config.$market.json")
  done
  if [ -n "$ACCOUNTS" ]; then
    ARGS+=(--accounts $ACCOUNTS)
  fi
}

STAGES="prepare render install timers verify sudoers"

case "${1:-}" in
  "" | help | -h | --help)
    usage
    exit 0
    ;;
esac

case " $STAGES " in
  *" $1 "*)
    ;;
  *)
    printf 'ERROR: unknown stage: %s\n\n' "$1" >&2
    usage >&2
    exit 1
    ;;
esac

[ -d "$REPO" ] || die "install root does not exist: $REPO"
cd "$REPO"

# Read the `markets:` block from the YAML authoring source. Prints nothing when
# the file is absent, unreadable, or declares no usable market.
yaml_markets() {
  "$(python_bin)" - "$RUNTIME/config.yaml" <<'PY' 2>/dev/null || true
import sys

try:
    import yaml
except ImportError:
    sys.exit(1)

try:
    with open(sys.argv[1]) as handle:
        raw = yaml.safe_load(handle) or {}
except OSError:
    sys.exit(1)

markets = raw.get("markets")
if isinstance(markets, dict):
    print(" ".join(market for market in ("us", "hk") if market in markets))
PY
}

# A US+HK render needs --feishu-ws-config-key, so the market list has to be
# settled before any `om service` call. Prefer an explicit MARKETS, then the
# YAML source, then whatever runtime configs the install already carries.
resolve_markets() {
  if [ -n "$MARKETS" ]; then
    printf '%s' "$MARKETS"
    return
  fi
  local detected
  detected="$(yaml_markets)"
  if [ -z "$detected" ]; then
    local found=() market
    for market in us hk; do
      if [ -f "$RUNTIME/config.$market.json" ]; then
        found+=("$market")
      fi
    done
    detected="${found[*]:-}"
  fi
  if [ -z "$detected" ]; then
    die "cannot determine markets: set MARKETS, or declare a markets: block in $RUNTIME/config.yaml"
  fi
  printf '%s' "$detected"
}

first_market() {
  set -- $MARKETS
  printf '%s' "$1"
}

MARKETS="$(resolve_markets)"
if [ -z "$FEISHU_WS_CONFIG_KEY" ]; then
  FEISHU_WS_CONFIG_KEY="$(first_market)"
fi

require_config_yaml() {
  [ -f "$RUNTIME/config.yaml" ] || die "missing YAML authoring source: $RUNTIME/config.yaml"
}

require_profile() {
  [ -f "$RUNTIME/service.profile.json" ] \
    || die "missing $RUNTIME/service.profile.json; run the install stage first"
}

case "$1" in

prepare)
  require_config_yaml
  say "rebuild runtime config from $RUNTIME/config.yaml"
  stamp="$(date +%Y%m%d%H%M%S)"
  mkdir -p "$RUNTIME/resolved"
  for market in $MARKETS; do
    target="$RUNTIME/config.$market.json"
    if [ -f "$target" ]; then
      cp -a "$target" "$target.bak.$stamp"
      echo "backed up: $target.bak.$stamp"
    fi
    ./om config build --source yaml --config-yaml "$RUNTIME/config.yaml" \
      --market "$market" --output "$target"
  done
  ./om config build-assistant --source yaml --config-yaml "$RUNTIME/config.yaml" \
    --output "$RUNTIME/resolved/config.assistant.json"

  say "products"
  ls -l "$RUNTIME/config.us.json" "$RUNTIME/config.hk.json" \
    "$RUNTIME/resolved/config.assistant.json"
  echo
  echo "config build overwrites the market JSON. Compare against the .bak files"
  echo "above if you had hand edits that the YAML source does not carry."
  ;;

render)
  require_config_yaml
  say "render service bundle into $BUNDLE"
  rm -rf "$BUNDLE"
  common_args
  render_args=(
    "${ARGS[@]}"
    --include-feishu-ws
    --feishu-ws-config-key "$FEISHU_WS_CONFIG_KEY"
    --output-dir "$BUNDLE"
  )
  if [ "$INCLUDE_AUTO_UPGRADE" = "1" ]; then
    render_args+=(--include-auto-upgrade)
  fi
  if [ "$INCLUDE_SECRET_CREDENTIALS" = "1" ]; then
    render_args+=(--include-secret-credentials)
  fi
  ./om service render "${render_args[@]}"

  say "rendered files"
  find "$BUNDLE" -type f | sort
  echo
  echo "assistant config wired into feishu-ws:"
  grep -o -- '--assistant-config [^ ]*' \
    "$BUNDLE/systemd/options-monitor-feishu-ws.service" \
    || echo "  WARNING: --assistant-config not found; inspect the unit before installing"
  if [ -d "$BUNDLE/systemd/libexec" ]; then
    echo
    echo "NOTE: $BUNDLE/systemd/libexec exists. Do not copy it with the unit glob;"
    echo "      install it to /usr/local/libexec per docs/DEPLOY_LINUX_MAC.md."
  fi

  say "preflight (read-only)"
  preflight_args=(
    --runtime-root "$RUNTIME"
    --env-file "$ENV_FILE"
    --config-us "$RUNTIME/config.us.json"
    --config-hk "$RUNTIME/config.hk.json"
  )
  if [ -n "$ACCOUNTS" ]; then
    preflight_args+=(--accounts $ACCOUNTS)
  fi
  ./om service preflight "${preflight_args[@]}" \
    || echo ">>> preflight reported problems; resolve them before the install stage"
  ;;

install)
  [ -d "$BUNDLE/systemd" ] || die "no rendered bundle at $BUNDLE; run the render stage first"
  say "install units into /etc/systemd/system"
  confirm "write units to /etc/systemd/system and enable long-running services?" \
    || die "aborted"
  sudo cp -r "$BUNDLE/systemd/." /etc/systemd/system/
  cp "$BUNDLE/service.profile.json" "$RUNTIME/service.profile.json"
  sudo systemd-analyze verify /etc/systemd/system/options-monitor-*.service
  sudo systemctl daemon-reload
  sudo systemctl enable --now options-monitor-trade-intake.service
  sudo systemctl enable --now options-monitor-feishu-ws.service
  if [ "$INCLUDE_AUTO_UPGRADE" = "1" ]; then
    sudo systemctl enable --now options-monitor-upgrade.timer
  fi
  echo
  echo "Send the Bot a Feishu message to confirm it answers, then run:"
  echo "  $0 verify"
  ;;

timers)
  missing=()
  for market in $MARKETS; do
    for unit in "options-monitor-tick-$market.timer" "options-monitor-auto-close-$market.timer"; do
      [ -f "/etc/systemd/system/$unit" ] || missing+=("$unit")
    done
  done
  if [ -n "${missing[*]:-}" ]; then
    die "not installed: ${missing[*]} (run the install stage first, or check the render output for these markets)"
  fi
  say "enable business timers"
  confirm "OpenD reachable and logged in; enable timers for: $MARKETS?" || die "aborted"
  for market in $MARKETS; do
    sudo systemctl enable --now \
      "options-monitor-tick-$market.timer" \
      "options-monitor-auto-close-$market.timer"
  done
  sudo systemctl enable --now options-monitor-projection-verify.timer options-monitor-runtime-status.timer
  systemctl list-timers 'options-monitor-*' --no-pager
  ;;

verify)
  require_profile
  say "profile status"
  ./om service status --profile-path "$RUNTIME/service.profile.json" --include-service-status

  say "drift (dry-run; expect clean)"
  ./om service drift --runtime-root "$RUNTIME"

  say "failed units"
  systemctl --failed --no-pager || true

  say "recent feishu-ws log"
  sudo journalctl -u options-monitor-feishu-ws.service -n 30 --no-pager
  ;;

sudoers)
  require_profile
  say "suggested sudoers"
  cat <<'HINT'
# 1) restart rules -- declared by service.profile.json, used when a release
#    upgrade restarts the long-running services.
HINT
  "$(python_bin)" - "$RUNTIME/service.profile.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    profile = json.load(handle)

for line in profile.get("restart", {}).get("sudoers", []):
    print(line)
PY
  cat <<'HINT'

# 2) drift reconcile rules -- used by the upgrade timer to repair missing
#    units and drop-ins on its own.
#    NOTE: `install` plus `sh -c` is effectively full root. That is the cost of
#    an unattended reconcile. Skip this block and upgrade manually instead if
#    you are not comfortable with it:
#      sudo ./om update apply --confirm
HINT
  echo "$DEPLOY_USER ALL=(root) NOPASSWD: /usr/bin/install, /bin/systemctl, /usr/bin/systemctl, /usr/bin/rm, /bin/rm, /usr/bin/systemd-creds"
  echo
  echo "Write with:  sudo visudo -f /etc/sudoers.d/options-monitor"
  echo "Validate:    sudo visudo -c"
  ;;

*)
  printf 'ERROR: unknown stage: %s\n\n' "$1" >&2
  usage >&2
  exit 1
  ;;
esac
