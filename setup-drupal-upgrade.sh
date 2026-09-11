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

log "Done. Run 'ddev pre-upgrade' to generate the audit reports, 'ddev run-upgrade' to start the upgrade, then 'ddev post-upgrade' to smoke-test the site afterward."

ddev start
