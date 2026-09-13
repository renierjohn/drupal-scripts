#!/usr/bin/env bash
#
# setup-drupal-upgrade.sh
#
# Installs the D10->D11 upgrade toolkit (ddev commands + Claude Code skill)
# from this drupal-scripts/ directory into their expected locations in the
# parent project:
#
#   drupal-scripts/skills/d11-upgrade/SKILL.md     -> .claude/skills/d11-upgrade/SKILL.md
#   drupal-scripts/skills/d11-post-upgrade/SKILL.md -> .claude/skills/d11-post-upgrade/SKILL.md
#   drupal-scripts/pre-upgrade                     -> .ddev/commands/host/pre-upgrade
#   drupal-scripts/pre-upgrade-scan.php            -> .ddev/commands/host/pre-upgrade-scan.php
#   drupal-scripts/ckeditor5-checklist-scan.php    -> .ddev/commands/host/ckeditor5-checklist-scan.php
#   drupal-scripts/run-upgrade                     -> .ddev/commands/host/run-upgrade
#   drupal-scripts/post-upgrade                    -> .ddev/commands/host/post-upgrade
#   drupal-scripts/post-upgrade-menu-links.php      -> .ddev/commands/host/post-upgrade-menu-links.php
#   drupal-scripts/post-upgrade-admin-paths.php     -> .ddev/commands/host/post-upgrade-admin-paths.php
#   drupal-scripts/post-upgrade-watchdog.php        -> .ddev/commands/host/post-upgrade-watchdog.php
#   drupal-scripts/nodejs-scrape                    -> .ddev/commands/host/nodejs-scrape
#   drupal-scripts/nodejs-diff                      -> .ddev/commands/host/nodejs-diff
#   drupal-scripts/nodejs/scrape.js                 -> .ddev/commands/host/nodejs/scrape.js
#   drupal-scripts/nodejs/diff.js                   -> .ddev/commands/host/nodejs/diff.js
#   drupal-scripts/nodejs/package.json              -> .ddev/commands/host/nodejs/package.json
#   drupal-scripts/nodejs/yarn.lock                 -> .ddev/commands/host/nodejs/yarn.lock
#   drupal-scripts/nodejs/.gitignore                -> .ddev/commands/host/nodejs/.gitignore
#
# This script lives INSIDE drupal-scripts/ - run it from the project root as
# ./drupal-scripts/setup-drupal-upgrade.sh (or from anywhere; it resolves its
# own location). The project root is assumed to be its parent directory.
#
# Usage: ./drupal-scripts/setup-drupal-upgrade.sh
# Safe to re-run - it overwrites the destination files with the versions in
# drupal-scripts/, so re-running after updating drupal-scripts/ re-syncs them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SKILL_DIR="$PROJECT_ROOT/.claude/skills/d11-upgrade"
SKILL_DIR_POST="$PROJECT_ROOT/.claude/skills/d11-post-upgrade"
DDEV_HOST_DIR="$PROJECT_ROOT/.ddev/commands/host"

trap 'rm -f "$PROJECT_ROOT"/.solr-check-*.php 2>/dev/null' EXIT

log()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m!!\033[0m %s\n' "$1" >&2; exit 1; }

[ -d "$SOURCE_DIR" ] || fail "Source directory not found: $SOURCE_DIR"

CORE_LOCKED_VERSION="$(grep -A2 '"name": "drupal/core"' "$PROJECT_ROOT/composer.lock" 2>/dev/null | grep -m1 '"version"' | sed -E 's/.*"version": *"([^"]*)".*/\1/')"
CORE_MAJOR="${CORE_LOCKED_VERSION#v}"; CORE_MAJOR="${CORE_MAJOR%%.*}"
if [ -n "$CORE_MAJOR" ] && [ "$CORE_MAJOR" -ge 11 ] 2>/dev/null; then
  log "drupal/core is already $CORE_LOCKED_VERSION (D11+) per composer.lock - nothing to set up for a D10->D11 upgrade. Not proceeding."
  exit 0
fi

install_file() {
  local src="$1" dest="$2" mode="$3"
  [ -f "$src" ] || fail "Missing source file: $src"
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  [ "$mode" = "exec" ] && chmod +x "$dest"
  log "Installed $(basename "$src") -> ${dest#"$PROJECT_ROOT"/}"
}

confirm() {
  local reply
  read -rp "$1 [y/N] " reply || reply=""
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

NODE_OK=false
YARN_OK=false

check_node() {
  local ver major
  if command -v node >/dev/null 2>&1; then
    ver="$(node -v)"
    major="${ver#v}"; major="${major%%.*}"
    if [ "$major" -ge 22 ] 2>/dev/null; then
      log "Node.js $ver found (>= 22 required) - OK"
      NODE_OK=true
      return
    fi
    log "Node.js $ver found, but the nodejs-scrape/nodejs-diff toolkit needs >= 22."
  else
    log "Node.js not found on PATH."
  fi

  if confirm "Install Node.js 22 now?"; then
    if command -v brew >/dev/null 2>&1; then
      brew install node@22 || true
      brew link --overwrite --force node@22 || true
    elif command -v nvm >/dev/null 2>&1; then
      nvm install 22 || true
      nvm use 22 || true
    else
      warn "No supported installer found (Homebrew or nvm). Install Node.js 22+ manually: https://nodejs.org/ later if you want visual diffing."
    fi
    if command -v node >/dev/null 2>&1; then
      ver="$(node -v)"; major="${ver#v}"; major="${major%%.*}"
      if [ "$major" -ge 22 ] 2>/dev/null; then
        log "Node.js $ver installed."
        NODE_OK=true
      else
        warn "Node.js $ver is on PATH but is below the required 22 - nodejs-scrape/nodejs-diff won't work until it's upgraded."
      fi
    else
      warn "Node.js install did not put 'node' on PATH - nodejs-scrape/nodejs-diff won't work until it does."
    fi
  else
    warn "Skipping Node.js install - nodejs-scrape/nodejs-diff (visual diffing) won't be available until Node.js 22+ is installed. Continuing with the rest of the setup."
  fi
}

check_yarn() {
  if command -v yarn >/dev/null 2>&1; then
    log "yarn found ($(yarn -v)) - OK"
    YARN_OK=true
    return
  fi

  log "yarn not found on PATH."
  if confirm "Install yarn now?"; then
    if command -v brew >/dev/null 2>&1; then
      brew install yarn || true
    elif command -v npm >/dev/null 2>&1; then
      npm install -g yarn || true
    else
      warn "No supported installer found (Homebrew or npm). Install yarn manually: https://yarnpkg.com/getting-started/install later if you want visual diffing."
    fi
    if command -v yarn >/dev/null 2>&1; then
      log "yarn $(yarn -v) installed."
      YARN_OK=true
    else
      warn "yarn install did not put 'yarn' on PATH - nodejs-scrape/nodejs-diff won't work until it does."
    fi
  else
    warn "Skipping yarn install - nodejs-scrape/nodejs-diff (visual diffing) won't be available until yarn is installed. Continuing with the rest of the setup."
  fi
}

check_chrome_extension() {
  log "Claude for Chrome lets Claude Code drive a real browser tab (useful for visual QA alongside nodejs-scrape/nodejs-diff)."
  if confirm "Open the Chrome Web Store to install the Claude Chrome extension now?"; then
    local url="https://chromewebstore.google.com/search/claude%20for%20chrome"
    if command -v open >/dev/null 2>&1; then
      open "$url" >/dev/null 2>&1 || warn "Could not open a browser automatically - visit: $url"
    elif command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$url" >/dev/null 2>&1 || warn "Could not open a browser automatically - visit: $url"
    else
      warn "Could not detect a way to open a browser automatically - visit: $url"
    fi
    log "Search the Chrome Web Store for \"Claude for Chrome\" and click \"Add to Chrome\" (Chrome doesn't allow unattended/scripted installs)."
  else
    log "Skipping Chrome extension install - add it later from the Chrome Web Store if you want browser automation."
  fi
}

prompt_site_domain() {
  local env_file="$DDEV_HOST_DIR/.env"
  local default_domain="" input tmp

  if [ -f "$env_file" ]; then
    default_domain="$(grep -E '^BASE_URL=' "$env_file" | tail -1 | cut -d= -f2-)"
  fi

  local msg="Site domain (e.g. example.com or https://example.ddev.site)"
  [ -n "$default_domain" ] && msg="$msg [$default_domain]"

  read -rp "$msg: " input || input=""
  [ -z "$input" ] && input="$default_domain"
  [ -n "$input" ] || fail "A site domain is required."

  case "$input" in
    http://*|https://*) : ;;
    *) input="https://$input" ;;
  esac
  input="${input%/}"

  mkdir -p "$DDEV_HOST_DIR"
  if [ -f "$env_file" ] && grep -q '^BASE_URL=' "$env_file"; then
    tmp="$(mktemp)"
    awk -v val="BASE_URL=$input" '{ if ($0 ~ /^BASE_URL=/) print val; else print }' "$env_file" > "$tmp"
    mv "$tmp" "$env_file"
  else
    printf 'BASE_URL=%s\n' "$input" >> "$env_file"
  fi
  log "Saved BASE_URL=$input -> ${env_file#"$PROJECT_ROOT"/}"
}

# Emits one line per search_api server using a Solr backend:
#   <server_id>|<UP|DOWN>|<connector_plugin_id>|<core_name>
# via a throwaway drush php:script (requires ddev to be running/bootstrapped).
solr_check_php() {
  local tmp_php rel_php result
  tmp_php="$(mktemp "$PROJECT_ROOT/.solr-check-XXXXXX.php")"
  cat > "$tmp_php" <<'PHP'
<?php
if (!\Drupal::hasContainer() || !\Drupal::moduleHandler()->moduleExists('search_api')) {
  echo "NO_SEARCH_API" . PHP_EOL;
  return;
}
$storage = \Drupal::entityTypeManager()->getStorage('search_api_server');
$found = FALSE;
foreach ($storage->loadMultiple() as $server) {
  if (!$server->hasValidBackend()) {
    continue;
  }
  $backend = $server->getBackend();
  $plugin_id = $backend->getPluginId();
  if (stripos($plugin_id, 'solr') === FALSE) {
    continue;
  }
  $found = TRUE;
  $config = $backend->getConfiguration();
  $connector = $config['connector'] ?? '';
  $core = $config['connector_config']['core'] ?? '';
  $available = FALSE;
  try {
    $available = $server->status() && $server->isAvailable();
  }
  catch (\Throwable $e) {
  }
  echo implode('|', [$server->id(), $available ? 'UP' : 'DOWN', $connector, $core]) . PHP_EOL;
}
if (!$found) {
  echo "NO_SOLR_SERVER" . PHP_EOL;
}
PHP
  rel_php="${tmp_php#"$PROJECT_ROOT"/}"
  result="$(ddev drush php:script "$rel_php" 2>&1)" || true
  rm -f "$tmp_php"
  printf '%s\n' "$result"
}

solr_manual_setup_help() {
  cat <<'EOS'

Manual Solr setup:
  1. Confirm the DDEV Solr add-on is installed: ddev get ddev/ddev-drupal-solr
  2. (Re)start DDEV so Solr is up:              ddev restart
  3. Confirm Solr is responding:                ddev exec -s solr curl -fsS http://localhost:8983/solr/
  4. Point each search_api Solr server at DDEV's Solr service:
       ddev drush config:set search_api.server.<SERVER_ID> backend_config.connector standard -y
       ddev drush config:set search_api.server.<SERVER_ID> backend_config.connector_config.scheme http -y
       ddev drush config:set search_api.server.<SERVER_ID> backend_config.connector_config.host solr -y
       ddev drush config:set search_api.server.<SERVER_ID> backend_config.connector_config.port 8983 -y
       ddev drush config:set search_api.server.<SERVER_ID> backend_config.connector_config.core <CORE_NAME> -y
  5. Clear caches:                               ddev drush cr

EOS
}

check_solr() {
  if ! grep -q '"drupal/search_api_solr"' composer.json 2>/dev/null; then
    log "Solr: drupal/search_api_solr not in composer.json - skipping Solr setup."
    return
  fi
  log "Solr: drupal/search_api_solr found in composer.json - checking the DDEV Solr service ..."

  local solr_compose="$PROJECT_ROOT/.ddev/docker-compose.solr.yaml"
  local needs_restart=false

  if [ ! -f "$solr_compose" ]; then
    log "DDEV Solr add-on not installed (.ddev/docker-compose.solr.yaml missing)."
    if confirm "Install the DDEV Solr add-on (ddev get ddev/ddev-drupal-solr) now?"; then
      ddev get ddev/ddev-drupal-solr || fail "Failed to install the DDEV Solr add-on."
      needs_restart=true
    else
      warn "Skipping Solr setup - install it later with 'ddev get ddev/ddev-drupal-solr' then re-run this script."
      return
    fi
  fi

  ddev exec -s solr curl -fsS -o /dev/null http://localhost:8983/solr/ >/dev/null 2>&1 || needs_restart=true

  if $needs_restart; then
    log "(Re)starting DDEV so the Solr service is up ..."
    ddev restart || fail "ddev restart failed while bringing up Solr."
  fi

  if ddev exec -s solr curl -fsS -o /dev/null http://localhost:8983/solr/ >/dev/null 2>&1; then
    log "Solr container is up."
  else
    warn "Solr container is still not responding. Check 'ddev logs -s solr' for details - skipping connectivity check."
    return
  fi

  log "Checking whether the site's search_api Solr server(s) can connect ..."
  local solr_status server_id status connector core fixed_any=false
  solr_status="$(solr_check_php)"

  if echo "$solr_status" | grep -q "NO_SEARCH_API"; then
    warn "Could not bootstrap Drupal to check search_api - re-run this script once the site is installed to verify Solr connectivity."
    return
  fi
  if echo "$solr_status" | grep -q "NO_SOLR_SERVER"; then
    log "No search_api server is configured to use a Solr backend - nothing to connect."
    return
  fi

  local parsed_any=false
  while IFS='|' read -r server_id status connector core; do
    [ -z "$server_id" ] && continue
    case "$status" in UP|DOWN) ;; *) continue ;; esac
    parsed_any=true
    if [ "$status" = "UP" ]; then
      log "Solr server '$server_id' ($connector connector): connected."
      continue
    fi
    if [ "$connector" != "standard" ]; then
      log "Solr server '$server_id' uses the '$connector' connector (not local-friendly) - switching it to 'standard' for local dev ..."
      ddev drush config:set "search_api.server.$server_id" backend_config.connector standard -y >/dev/null 2>&1 || true
    fi
    log "Solr server '$server_id' is not connected. Pointing it at DDEV's Solr service (host=solr, port=8983) ..."
    ddev drush config:set "search_api.server.$server_id" backend_config.connector_config.scheme http -y >/dev/null 2>&1 || true
    ddev drush config:set "search_api.server.$server_id" backend_config.connector_config.host solr -y >/dev/null 2>&1 || true
    ddev drush config:set "search_api.server.$server_id" backend_config.connector_config.core dev -y >/dev/null 2>&1 || true
    ddev drush config:set "search_api.server.$server_id" backend_config.connector_config.port 8983 -y >/dev/null 2>&1 || true
    ddev drush cr
    fixed_any=true

    if [ -n "$core" ]; then
      local current_core
      current_core="$(ddev exec -s solr printenv SOLR_CORENAME 2>/dev/null | tr -d '\r')" || true
      if [ "$current_core" != "$core" ]; then
        log "Aligning DDEV's Solr core name with the server's configured core ('$core') ..."
        ddev config --web-environment-add="SOLR_CORENAME=$core" >/dev/null 2>&1 || warn "Could not set SOLR_CORENAME via 'ddev config' - set it manually in .ddev/config.yaml (web_environment) if the core name still doesn't match."
      fi
    fi
  done <<< "$solr_status"

  if ! $parsed_any; then
    warn "Unexpected error while checking Solr connectivity - could not parse drush's response:"
    printf '%s\n' "$solr_status" | sed 's/^/    /' >&2
    solr_manual_setup_help
    warn "Please set up/verify Solr manually using the steps above, then re-run this script."
    return
  fi

  if $fixed_any; then
    log "Applied Solr fixes - restarting DDEV to apply them ..."
    ddev restart || fail "ddev restart failed while reconfiguring Solr."
    ddev drush cr >/dev/null 2>&1 || true

    solr_status="$(solr_check_php)"
    local recheck_parsed_any=false
    while IFS='|' read -r server_id status connector core; do
      [ -z "$server_id" ] && continue
      case "$status" in UP|DOWN) ;; *) continue ;; esac
      recheck_parsed_any=true
      if [ "$status" = "UP" ]; then
        log "Solr server '$server_id': now connected."
      else
        warn "Solr server '$server_id' is still not connected. Check 'ddev logs -s solr' and its connector settings (host/port/core) manually."
      fi
    done <<< "$solr_status"

    if ! $recheck_parsed_any; then
      warn "Unexpected error while re-checking Solr connectivity - could not parse drush's response:"
      printf '%s\n' "$solr_status" | sed 's/^/    /' >&2
      solr_manual_setup_help
      warn "Please set up/verify Solr manually using the steps above."
    fi
  fi
}

log "Installing D10->D11 upgrade toolkit from drupal-scripts/ ..."

install_file "$SOURCE_DIR/skills/d11-upgrade/SKILL.md" "$SKILL_DIR/SKILL.md" "plain"
install_file "$SOURCE_DIR/skills/d11-post-upgrade/SKILL.md" "$SKILL_DIR_POST/SKILL.md" "plain"

install_file "$SOURCE_DIR/pre-upgrade" "$DDEV_HOST_DIR/pre-upgrade" "exec"
install_file "$SOURCE_DIR/pre-upgrade-scan.php" "$DDEV_HOST_DIR/pre-upgrade-scan.php" "exec"
install_file "$SOURCE_DIR/ckeditor5-checklist-scan.php" "$DDEV_HOST_DIR/ckeditor5-checklist-scan.php" "exec"
install_file "$SOURCE_DIR/run-upgrade" "$DDEV_HOST_DIR/run-upgrade" "exec"
install_file "$SOURCE_DIR/post-upgrade" "$DDEV_HOST_DIR/post-upgrade" "exec"
install_file "$SOURCE_DIR/post-upgrade-menu-links.php" "$DDEV_HOST_DIR/post-upgrade-menu-links.php" "exec"
install_file "$SOURCE_DIR/post-upgrade-admin-paths.php" "$DDEV_HOST_DIR/post-upgrade-admin-paths.php" "exec"
install_file "$SOURCE_DIR/post-upgrade-watchdog.php" "$DDEV_HOST_DIR/post-upgrade-watchdog.php" "exec"

install_file "$SOURCE_DIR/nodejs-scrape" "$DDEV_HOST_DIR/nodejs-scrape" "exec"
install_file "$SOURCE_DIR/nodejs-diff" "$DDEV_HOST_DIR/nodejs-diff" "exec"
install_file "$SOURCE_DIR/nodejs/scrape.js" "$DDEV_HOST_DIR/nodejs/scrape.js" "plain"
install_file "$SOURCE_DIR/nodejs/diff.js" "$DDEV_HOST_DIR/nodejs/diff.js" "plain"
install_file "$SOURCE_DIR/nodejs/package.json" "$DDEV_HOST_DIR/nodejs/package.json" "plain"
install_file "$SOURCE_DIR/nodejs/yarn.lock" "$DDEV_HOST_DIR/nodejs/yarn.lock" "plain"
install_file "$SOURCE_DIR/nodejs/.gitignore" "$DDEV_HOST_DIR/nodejs/.gitignore" "plain"

check_node
check_yarn
check_chrome_extension

if $NODE_OK && $YARN_OK; then
  log "Installing nodejs toolkit dependencies (yarn install in .ddev/commands/host/nodejs) ..."
  ( cd "$DDEV_HOST_DIR/nodejs" && yarn install ) || fail "yarn install failed in ${DDEV_HOST_DIR#"$PROJECT_ROOT"/}/nodejs"
  log "nodejs toolkit dependencies installed."
else
  warn "Skipping nodejs toolkit dependency install (Node.js 22+ and/or yarn not available) - 'ddev nodejs-scrape'/'ddev nodejs-diff' (and the visual-diff step in pre-upgrade/post-upgrade) will be skipped until you install them and re-run this script."
fi

prompt_site_domain

log "Starting DDEV ..."
ddev start

check_solr

log "Done"
log "Run 'ddev pre-upgrade' to generate the audit reports, 'ddev run-upgrade' to start the upgrade, then 'ddev post-upgrade' to smoke-test the site afterward."
