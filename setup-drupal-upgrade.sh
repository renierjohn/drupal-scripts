#!/usr/bin/env bash
#
# setup-drupal-upgrade.sh
#
# Installs the D10->D11 upgrade toolkit (ddev commands + Claude Code skill)
# from this drupal-scripts/ directory into their expected locations in the
# parent project:
#
#   drupal-scripts/d11-upgrade/SKILL.md            -> .claude/skills/d11-upgrade/SKILL.md
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
DDEV_HOST_DIR="$PROJECT_ROOT/.ddev/commands/host"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m!!\033[0m %s\n' "$1" >&2; exit 1; }

[ -d "$SOURCE_DIR" ] || fail "Source directory not found: $SOURCE_DIR"

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

check_node() {
  local ver major
  if command -v node >/dev/null 2>&1; then
    ver="$(node -v)"
    major="${ver#v}"; major="${major%%.*}"
    if [ "$major" -ge 22 ] 2>/dev/null; then
      log "Node.js $ver found (>= 22 required) - OK"
      return
    fi
    log "Node.js $ver found, but the nodejs-scrape/nodejs-diff toolkit needs >= 22."
  else
    log "Node.js not found on PATH."
  fi

  if confirm "Install Node.js 22 now?"; then
    if command -v brew >/dev/null 2>&1; then
      brew install node@22 || fail "Failed to install Node.js via Homebrew."
      brew link --overwrite --force node@22 || true
    elif command -v nvm >/dev/null 2>&1; then
      nvm install 22 && nvm use 22
    else
      fail "No supported installer found (Homebrew or nvm). Install Node.js 22+ manually: https://nodejs.org/ then re-run this script."
    fi
    command -v node >/dev/null 2>&1 || fail "Node.js install did not put 'node' on PATH. Open a new shell (or fix PATH) and re-run this script."
    log "Node.js $(node -v) installed."
  else
    fail "Node.js 22+ is required for the nodejs-scrape/nodejs-diff toolkit. Install it and re-run this script."
  fi
}

check_yarn() {
  if command -v yarn >/dev/null 2>&1; then
    log "yarn found ($(yarn -v)) - OK"
    return
  fi

  log "yarn not found on PATH."
  if confirm "Install yarn now?"; then
    if command -v brew >/dev/null 2>&1; then
      brew install yarn || fail "Failed to install yarn via Homebrew."
    elif command -v npm >/dev/null 2>&1; then
      npm install -g yarn || fail "Failed to install yarn via npm."
    else
      fail "No supported installer found (Homebrew or npm). Install yarn manually: https://yarnpkg.com/getting-started/install then re-run this script."
    fi
    command -v yarn >/dev/null 2>&1 || fail "yarn install did not put 'yarn' on PATH. Open a new shell (or fix PATH) and re-run this script."
    log "yarn $(yarn -v) installed."
  else
    fail "yarn is required for the nodejs-scrape/nodejs-diff toolkit. Install it and re-run this script."
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

log "Installing D10->D11 upgrade toolkit from drupal-scripts/ ..."

install_file "$SOURCE_DIR/d11-upgrade/SKILL.md" "$SKILL_DIR/SKILL.md" "plain"

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

log "Installing nodejs toolkit dependencies (yarn install in .ddev/commands/host/nodejs) ..."
( cd "$DDEV_HOST_DIR/nodejs" && yarn install ) || fail "yarn install failed in ${DDEV_HOST_DIR#"$PROJECT_ROOT"/}/nodejs"
log "nodejs toolkit dependencies installed."

prompt_site_domain

log "Done. Run 'ddev pre-upgrade' to generate the audit reports, 'ddev run-upgrade' to start the upgrade, then 'ddev post-upgrade' to smoke-test the site afterward."

ddev start
