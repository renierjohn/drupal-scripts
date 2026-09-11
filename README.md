# Drupal 10 → 11 Upgrade Toolkit

Portable ddev + Claude Code toolkit for auditing and executing a Drupal 10 → 11 upgrade. Copy this `drupal-scripts/` directory into any ddev-based Drupal 10 project and run the setup script to install it.

## What's in here

| File | Installs to | Purpose |
|---|---|---|
| `setup-drupal-upgrade.sh` | (run from here, stays here) | Installer - copies everything else below into place |
| `d11-upgrade/SKILL.md` | `.claude/skills/d11-upgrade/SKILL.md` | Claude Code skill: the step-by-step upgrade execution plan |
| `pre-upgrade` | `.ddev/commands/host/pre-upgrade` | `ddev pre-upgrade` - audits the project and writes the reports the skill reads |
| `pre-upgrade-scan.php` | `.ddev/commands/host/pre-upgrade-scan.php` | Helper invoked by `pre-upgrade` (module classification, custom code, removed-core-module scan) |
| `ckeditor5-checklist-scan.php` | `.ddev/commands/host/ckeditor5-checklist-scan.php` | Helper invoked by `pre-upgrade` (CKEditor 4→5 detection + plugin compatibility) |
| `run-upgrade` | `.ddev/commands/host/run-upgrade` | `ddev run-upgrade` - opens an interactive Claude Code session that runs `/d11-upgrade run` |
| `post-upgrade` | `.ddev/commands/host/post-upgrade` | `ddev post-upgrade` - visits the homepage + main-menu pages and admin pages, checks dblog for new errors, saves the report |
| `post-upgrade-menu-links.php` | `.ddev/commands/host/post-upgrade-menu-links.php` | Helper invoked by `post-upgrade` (enumerates the 'main' menu's internal links via Drupal's menu API) |
| `post-upgrade-admin-paths.php` | `.ddev/commands/host/post-upgrade-admin-paths.php` | Helper invoked by `post-upgrade` (enumerates the 'admin' menu's top-level sections, their direct child links, and their tabs/local tasks via Drupal's menu and local-task APIs) |
| `post-upgrade-watchdog.php` | `.ddev/commands/host/post-upgrade-watchdog.php` | Helper invoked by `post-upgrade` (reads new dblog Emergency/Critical/Error/Warning entries since a given timestamp) |

Skills live one-per-subdirectory (`d11-upgrade/SKILL.md`, matching `.claude/skills/<name>/SKILL.md`), so additional skills can be added later as sibling directories (e.g. `another-skill/SKILL.md`) without colliding.

## Requirements

- **ddev**, with the target project already configured and able to `ddev start`.
- A **Drupal 10** codebase managed with **Composer**, using **Drush** (installed or installable via Composer).
- The project's **default database service must be named `db`**, reachable at `db:3306` from the web container, with the standard ddev local credentials (`db`/`db`/`db`). `pre-upgrade` and `ckeditor5-checklist-scan.php` connect directly via PDO using these defaults to read active config even when Drush itself can't fully bootstrap. If a project uses different DB credentials or a non-default service name, that direct read fails and both scripts fall back to reading `config/default/*.yml` instead - still works, but reflects the *exported* config rather than the *active* one, so DB/code drift (e.g. an enabled module with no matching code on disk) won't be caught.
- **Claude Code CLI** (`claude`) installed and authenticated on the host, only if you intend to use `ddev run-upgrade`. `ddev pre-upgrade` on its own has no Claude Code dependency.
- Enough disk/network for Composer to actually install `drush/drush`, `drupal/upgrade_status`, and `mglaman/drupal-check` if they aren't already present - `pre-upgrade` installs them automatically on first run.

## Usage

1. Copy `drupal-scripts/` into the root of the target Drupal project (alongside `composer.json`, `.ddev/`, etc.).
2. Install the toolkit:
   ```bash
   ./drupal-scripts/setup-drupal-upgrade.sh
   ```
   This copies the skill and ddev commands into place, `chmod +x`s the executables, and runs `ddev start` at the end. Safe to re-run any time you update `drupal-scripts/` - it overwrites the installed copies.
3. Generate the audit reports:
   ```bash
   ddev pre-upgrade
   ```
   Writes `pre-upgrade.md` and `ckeditor5-checklist.md` (plus raw scanner output) to `.ddev/commands/host/reports/`. Read `pre-upgrade.md` first - it flags any CRITICAL blocker (e.g. a module enabled in the DB with no code on disk) that will break later steps if left unresolved.
4. Execute the upgrade:
   - **Guided (recommended):** `ddev run-upgrade` - opens an interactive Claude Code session pre-loaded with `/d11-upgrade run`. You approve each tool call as it runs; nothing executes unattended.
   - **Manual:** open `.claude/skills/d11-upgrade/SKILL.md` and work through its phases yourself, using the two reports as the source of truth for what needs upgrading.
5. Re-run `ddev pre-upgrade` after major changes (composer updates, patches, module removals) to confirm the reports reflect the current state before continuing.
6. Smoke-test the upgraded site:
   ```bash
   ddev post-upgrade
   ```
   Visits the homepage plus every enabled link in the site's `main` menu (anonymously), then generates a `drush uli` login and visits the site's `admin` menu using that authenticated session: `/admin`, its top-level sections (Content, Structure, Configuration, People, Appearance, Modules, Reports, Help), each section's direct child pages (e.g. Structure's Content types/Taxonomy/Menus/Views, Config's category pages), and each section's tabs (e.g. People's Permissions/Roles, Modules' Uninstall) - all discovered dynamically via Drupal's menu and local-task APIs rather than hardcoded, so it adapts to whatever admin menu structure the target site actually has. After each phase it checks the dblog for any new Emergency/Critical/Error/Warning entries logged during that phase specifically (not the site's full log history) and writes everything to `post-upgrade.md`.

## Notes

- `pre-upgrade` performs *real* `composer require`/`composer update` calls (for Drush, `upgrade_status`, and `drupal-check` if missing) - it changes `composer.json`/`composer.lock`, not just reads them. Review `git diff` after running it.
- The `upgrade_status`/`drupal-check` deprecation scans require a working Drupal bootstrap. A PHP fatal anywhere in enabled module/theme code (most commonly a duplicate function declaration across two themes) will make every scanned item fail identically - `pre-upgrade.md` detects and calls this out explicitly rather than reporting misleading per-module results.
- The Drupal-11-removed core module/theme list checked by `pre-upgrade` is fixed (`ckeditor`, `color`, `classy`, `stable`, `aggregator`, `book`, `forum`, `hal`, `quickedit`, `rdf`, `statistics`, `tour`) - it will not detect a future core removal not on this list.
- `post-upgrade` also needs a working Drupal bootstrap (to enumerate the `main` menu via `drush php:script`) and the same default `db`/`db`/`db`@`db:3306` database access as `pre-upgrade` (to read dblog directly via PDO). A 200 HTTP status on a visited page does not mean nothing went wrong - always check the dblog table in the report too, since Drupal can log an error while still rendering a 200 response.
