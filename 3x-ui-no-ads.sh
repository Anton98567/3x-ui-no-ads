#!/usr/bin/env bash
# =============================================================================
#  3x-ui-no-ads.sh  —  remove the built-in 3X-UI sponsor/ad cards from the panel
# =============================================================================
#
#  WHAT IT DOES
#    3X-UI renders paid "sponsor" cards (реклама) on the login page, on the main
#    dashboard page and on a dedicated "Sponsors" page. They are React components
#    (SponsorSlot / SponsorCard) fed by the backend endpoint  GET <base>/sponsors,
#    which in turn pulls a remote sponsor feed. When the sponsor list is empty the
#    component returns null and renders nothing at all.
#
#    This script intercepts  <base>/sponsors  at the nginx reverse proxy in front
#    of the panel and returns an empty sponsor list. The panel UI then renders no
#    ad on ANY page (login + dashboard + sponsors). It does NOT touch the x-ui
#    binary, the x-ui database, inbounds, clients or xray -> VPN/proxy clients are
#    completely unaffected.  100% reversible with  --remove.
#
#  REQUIREMENTS
#    - 3X-UI panel behind an nginx reverse proxy (the normal setup). If your panel
#      is exposed directly (no nginx), this patch cannot intercept the API; see
#      the README for the alternative.
#
#  USAGE
#    sudo ./3x-ui-no-ads.sh apply  --url https://host/my-3x-panel/
#    sudo ./3x-ui-no-ads.sh verify --url https://host/my-3x-panel/
#    sudo ./3x-ui-no-ads.sh remove
#    sudo ./3x-ui-no-ads.sh status
#
#    Commands : apply | verify | remove | status      (default: apply)
#    Options  :
#      --url <panel-url>   Public URL of the panel incl. base path (recommended).
#                          Used to derive the base path and to verify.
#      --base-path <path>  Panel base path (e.g. /my-3x-panel). Overrides --url.
#      --conf <file>       nginx config file holding the panel server block.
#                          Auto-detected when omitted.
#      --dry-run           Show what would change, write nothing.
#      -y, --yes           Do not ask for confirmation.
#      -h, --help          This help.
#
#  HOW TO GET / SET THE PANEL URL
#    It is the address you use to open the panel in a browser, e.g.
#        https://panel.example.com/my-3x-panel/
#    The base path is the part after the host (  /my-3x-panel  ).
#
# =============================================================================
set -euo pipefail

MARK_BEGIN="# >>> 3x-ui-no-ads >>>"
MARK_END="# <<< 3x-ui-no-ads <<<"

NGX_TEST="nginx -t"
NGX_RELOAD="systemctl reload nginx"

# ---- colours (disabled when not a tty) --------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLU=$'\033[34m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_RST=""
fi
info() { printf '%s[INFO]%s %s\n'  "$C_BLU"  "$C_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n'  "$C_GRN"  "$C_RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n'  "$C_YLW"  "$C_RST" "$*"; }
err()  { printf '%s[ERR ]%s %s\n'  "$C_RED"  "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---- defaults ---------------------------------------------------------------
CMD="apply"
PANEL_URL=""
BASE_PATH=""
NGX_CONF=""
DRY_RUN=0
ASSUME_YES=0

# ---- arg parse --------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    apply|verify|remove|status) CMD="$1"; shift ;;
    --url)       PANEL_URL="${2:-}"; shift 2 ;;
    --base-path) BASE_PATH="${2:-}"; shift 2 ;;
    --conf)      NGX_CONF="${2:-}";  shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -y|--yes)    ASSUME_YES=1; shift ;;
    -h|--help)   sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1  (use --help)" ;;
  esac
done

# ---- derive base path from --url if needed ----------------------------------
if [ -z "$BASE_PATH" ] && [ -n "$PANEL_URL" ]; then
  # strip scheme://host, keep the path
  BASE_PATH=$(printf '%s' "$PANEL_URL" | sed -E 's#^[a-zA-Z]+://[^/]+##')
fi

# normalise base path: leading slash, no trailing slash ("" means root)
if [ -n "$BASE_PATH" ]; then
  case "$BASE_PATH" in
    /*) ;;
    *) BASE_PATH="/$BASE_PATH" ;;
  esac
  BASE_PATH="${BASE_PATH%/}"
fi

# the API endpoint we intercept: <base>/sponsors  (root -> /sponsors)
if [ -n "$BASE_PATH" ]; then
  ENDPOINT="${BASE_PATH}/sponsors"
else
  ENDPOINT="/sponsors"
fi

# ---- helpers ----------------------------------------------------------------

# Find the nginx config file that contains the panel server block.
detect_conf() {
  if [ -n "$NGX_CONF" ]; then
    [ -f "$NGX_CONF" ] || die "nginx config not found: $NGX_CONF"
    printf '%s\n' "$NGX_CONF"; return
  fi
  local dirs=(/etc/nginx/conf.d /etc/nginx/sites-enabled /etc/nginx/sites-available /etc/nginx)
  local f hit=""
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    # a file that both proxies somewhere and mentions the base path is our block
    # (skip our own *.bak* backups so re-runs stay deterministic)
    while IFS= read -r f; do
      case "$f" in *.bak*) continue ;; esac
      if grep -q "proxy_pass" "$f" 2>/dev/null; then
        if [ -z "$BASE_PATH" ] || grep -qF "$BASE_PATH" "$f" 2>/dev/null; then
          hit="$f"; break 2
        fi
      fi
    done < <(find "$d" -maxdepth 2 -type f -name '*.conf' 2>/dev/null)
  done
  # fallback: any conf with a proxy_pass (again skipping backups)
  if [ -z "$hit" ]; then
    hit=$(grep -rls --include='*.conf' "proxy_pass" "${dirs[@]}" 2>/dev/null | grep -v '\.bak' | head -1 || true)
  fi
  [ -n "$hit" ] || die "Could not locate the nginx config with the panel proxy. Use --conf <file>."
  printf '%s\n' "$hit"
}

# Line number of the panel location directive to insert before.
# We prefer the location block that actually proxies to the panel (has proxy_pass);
# our exact-match location goes right before it (same server block). Order inside a
# server block does not matter for nginx exact-match vs prefix matching.
panel_location_line() {
  local conf="$1"
  # For every "location" line mentioning BASE_PATH, look ahead until the block's
  # closing brace; return the first one whose block contains proxy_pass.
  awk -v base="$BASE_PATH" '
    /location[[:space:]]/ {
      if (base == "" || index($0, base) > 0) { cand = NR; depth = 0; hasproxy = 0; infence = 1 }
    }
    infence {
      n = gsub(/\{/, "{"); m = gsub(/\}/, "}");
      depth += n - m
      if ($0 ~ /proxy_pass/) hasproxy = 1
      if (depth <= 0 && NR > cand) {
        if (hasproxy) { print cand; exit }
        infence = 0
      }
    }
  ' "$conf"
}

already_applied() {
  local conf="$1"
  grep -qF "$MARK_BEGIN" "$conf" 2>/dev/null
}

build_block() {
  cat <<EOF
    $MARK_BEGIN
    # Neutralize 3X-UI sponsor/ad cards by returning an empty sponsor list.
    # Inserted by 3x-ui-no-ads.sh. Reversible with: 3x-ui-no-ads.sh remove
    location = $ENDPOINT {
        default_type application/json;
        add_header Cache-Control "no-store" always;
        return 200 '{"success":true,"msg":"","obj":{"contact":"","sponsors":[]}}';
    }
    $MARK_END
EOF
}

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  printf '%s[y/N]%s %s ' "$C_YLW" "$C_RST" "$1"
  read -r ans || ans=""
  case "$ans" in y|Y|yes|YES|да|Да|ДА) return 0 ;; *) return 1 ;; esac
}

backup_conf() {
  local conf="$1"
  local bak="${conf}.bak-3xui-no-ads-$(date +%Y%m%d-%H%M%S)"
  cp -a "$conf" "$bak"
  ok "Backup: $bak"
}

reload_nginx() {
  info "Testing nginx configuration..."
  if ! $NGX_TEST >/dev/null 2>&1; then
    $NGX_TEST || true
    die "nginx config test FAILED. No reload performed."
  fi
  $NGX_RELOAD
  # graceful reload: give the master a moment to swap workers, otherwise an
  # immediate request can still be served by an old worker with the old config.
  sleep 1
  ok "nginx reloaded."
}

# ============================================================================
#  COMMAND: apply
# ============================================================================
cmd_apply() {
  local conf
  conf=$(detect_conf)
  info "nginx config : $conf"
  info "Base path    : ${BASE_PATH:-<root>}"
  info "Endpoint     : $ENDPOINT"

  if already_applied "$conf"; then
    warn "Patch already present in $conf (idempotent). Nothing to do."
    return 0
  fi

  local ln
  ln=$(panel_location_line "$conf")
  [ -n "$ln" ] || die "Could not find the panel location block in $conf. Use --base-path / --conf."

  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] Would insert the following before line $ln of $conf:"
    build_block
    return 0
  fi

  backup_conf "$conf"
  local tmp
  tmp=$(mktemp)
  awk -v ln="$ln" -v block="$(build_block)" 'NR==ln{print block} {print}' "$conf" > "$tmp"
  # preserve ownership/permissions
  chown --reference="$conf" "$tmp" 2>/dev/null || true
  chmod --reference="$conf" "$tmp" 2>/dev/null || true
  mv "$tmp" "$conf"

  if reload_nginx; then
    ok "Ad removal applied. Reload the panel page (Ctrl+F5) to drop any cached card."
  fi
}

# ============================================================================
#  COMMAND: verify
# ============================================================================
cmd_verify() {
  local conf
  conf=$(detect_conf)
  local failed=0

  # 1) patch marker present
  if already_applied "$conf"; then
    ok "Patch marker present in $conf"
  else
    warn "Patch marker NOT present in $conf"
    failed=1
  fi

  # 2) endpoint returns empty sponsor list (retry to ride out nginx worker swap)
  if [ -n "$PANEL_URL" ]; then
    # build from origin + ENDPOINT (ENDPOINT already contains the base path)
    local origin url body="" tries=0
    origin=$(printf '%s' "$PANEL_URL" | sed -E 's#^(https?://[^/]+).*#\1#')
    url="${origin}${ENDPOINT}"
    info "Checking $url"
    while [ $tries -lt 5 ]; do
      body=$(curl -sk -m 15 "$url" 2>/dev/null || echo "")
      printf '%s' "$body" | grep -q '"sponsors":\[\]' && break
      tries=$((tries+1)); sleep 1
    done
    if printf '%s' "$body" | grep -q '"sponsors":\[\]'; then
      ok "Endpoint returns an empty sponsor list -> no ads render."
    elif printf '%s' "$body" | grep -qi '"sponsors":\[{' ; then
      err "Endpoint still returns sponsors (patch not effective)."
      failed=1
    else
      warn "Unexpected response from $url: ${body:0:120}"
      failed=1
    fi
  else
    warn "No --url given; skipped live endpoint check."
  fi

  # 3) client safety: xray + nginx still active
  if command -v systemctl >/dev/null 2>&1; then
    local svc
    for svc in x-ui xray nginx; do
      if systemctl list-unit-files "$svc.service" 2>/dev/null | grep -q "$svc.service"; then
        if systemctl is-active --quiet "$svc"; then
          ok "Service $svc is active"
        else
          warn "Service $svc is NOT active (check it if unexpected)."
        fi
      fi
    done
  fi

  if [ "$failed" = 0 ]; then
    ok "VERIFY PASSED"
  else
    die "VERIFY FAILED"
  fi
}

# ============================================================================
#  COMMAND: remove
# ============================================================================
cmd_remove() {
  local conf
  conf=$(detect_conf)
  if ! already_applied "$conf"; then
    warn "No patch found in $conf. Nothing to remove."
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] Would remove the marked block from $conf and reload nginx."
    return 0
  fi
  backup_conf "$conf"
  local tmp
  tmp=$(mktemp)
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    index($0,b){skip=1; next}
    index($0,e){skip=0; next}
    !skip{print}
  ' "$conf" > "$tmp"
  chown --reference="$conf" "$tmp" 2>/dev/null || true
  chmod --reference="$conf" "$tmp" 2>/dev/null || true
  mv "$tmp" "$conf"
  reload_nginx
  ok "Patch removed. The panel will show sponsor cards again after a page reload."
}

# ============================================================================
#  COMMAND: status
# ============================================================================
cmd_status() {
  local conf
  conf=$(detect_conf 2>/dev/null || echo "")
  echo "Command     : $CMD"
  echo "Panel URL   : ${PANEL_URL:-<none>}"
  echo "Base path   : ${BASE_PATH:-<root>}"
  echo "Endpoint    : $ENDPOINT"
  echo "nginx conf  : ${conf:-<not found>}"
  if [ -n "$conf" ] && already_applied "$conf"; then
    echo "Patch state : ${C_GRN}APPLIED${C_RST}"
  else
    echo "Patch state : ${C_YLW}NOT APPLIED${C_RST}"
  fi
}

# ---- dispatch ---------------------------------------------------------------
case "$CMD" in
  apply)  cmd_apply ;;
  verify) cmd_verify ;;
  remove) cmd_remove ;;
  status) cmd_status ;;
  *) die "Unknown command: $CMD" ;;
esac
