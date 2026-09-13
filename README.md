# Drupal 10 → 11 Upgrade Toolkit

ddev + Claude Code toolkit for auditing and executing a Drupal 10 → 11 upgrade. Copy this `drupal-scripts/` directory into any ddev-based Drupal 10 project and run the setup script to install it.

📋 [Visual guide: file layout + run order](https://claude.ai/code/artifact/37c2fea0-12cd-402b-b365-4a5e58be642f?via=auto_preview&sk=HKQxiBIRpNAyU27w2xZUMw)

## What's in here

| File | Installs to | Purpose |
|---|---|---|
| `setup-drupal-upgrade.sh` | (run from here, stays here) | Installer - copies everything else below into place |
| `skills/d11-upgrade/SKILL.md` | `.claude/skills/d11-upgrade/SKILL.md` | Claude Code skill: the step-by-step upgrade execution plan |
| `skills/d11-post-upgrade/SKILL.md` | `.claude/skills/d11-post-upgrade/SKILL.md` | Claude Code skill: fixes issues found by the post-upgrade smoke test (dblog/WSOD errors, visual regressions), run via `post-upgrade`'s `/d11-post-upgrade run` |
| `pre-upgrade` | `.ddev/commands/host/pre-upgrade` | `ddev pre-upgrade` - audits the project and writes the reports the skill reads |
| `pre-upgrade-scan.php` | `.ddev/commands/host/pre-upgrade-scan.php` | Helper invoked by `pre-upgrade` (module classification, custom code, removed-core-module scan) |
| `ckeditor5-checklist-scan.php` | `.ddev/commands/host/ckeditor5-checklist-scan.php` | Helper invoked by `pre-upgrade` (CKEditor 4→5 detection + plugin compatibility) |
| `run-upgrade` | `.ddev/commands/host/run-upgrade` | `ddev run-upgrade` - opens an interactive Claude Code session that runs `/d11-upgrade run` |
| `post-upgrade` | `.ddev/commands/host/post-upgrade` | `ddev post-upgrade` - visits the homepage + main-menu pages and admin pages, checks dblog for new errors, captures a post-upgrade visual snapshot and diffs it against the pre-upgrade baseline, saves the report |
| `post-upgrade-menu-links.php` | `.ddev/commands/host/post-upgrade-menu-links.php` | Helper invoked by `post-upgrade` (enumerates the 'main' menu's internal links via Drupal's menu API) |
| `post-upgrade-admin-paths.php` | `.ddev/commands/host/post-upgrade-admin-paths.php` | Helper invoked by `post-upgrade` (enumerates the 'admin' menu's top-level sections, their direct child links, and their tabs/local tasks via Drupal's menu and local-task APIs) |
| `post-upgrade-watchdog.php` | `.ddev/commands/host/post-upgrade-watchdog.php` | Helper invoked by `post-upgrade` (reads new dblog Emergency/Critical/Error/Warning entries since a given timestamp) |
| `nodejs-scrape` | `.ddev/commands/host/nodejs-scrape` | `ddev nodejs-scrape [label] [path ...]` - runs `nodejs/scrape.js` via yarn to capture pre/post XPath + computed CSS snapshots for visual diffing |
| `nodejs-diff` | `.ddev/commands/host/nodejs-diff` | `ddev nodejs-diff [preLabel] [postLabel]` - runs `nodejs/diff.js` via yarn to diff two labeled `nodejs-scrape` runs |
| `nodejs/scrape.js`, `nodejs/diff.js`, `nodejs/package.json`, `nodejs/yarn.lock`, `nodejs/.gitignore` | `.ddev/commands/host/nodejs/` | Playwright-based scraper/diff toolkit invoked by `nodejs-scrape`/`nodejs-diff` |

Skills live under `skills/`, one per subdirectory (`skills/d11-upgrade/SKILL.md`, matching `.claude/skills/<name>/SKILL.md`), so additional skills can be added later as sibling directories (e.g. `skills/another-skill/SKILL.md`) without colliding.

## Requirements

- **ddev**, with the target project already configured and able to `ddev start`.
- A **Drupal 10** codebase managed with **Composer**, using **Drush** (installed or installable via Composer).
- The project's **default database service must be named `db`**, reachable at `db:3306` from the web container, with the standard ddev local credentials (`db`/`db`/`db`). `pre-upgrade` and `ckeditor5-checklist-scan.php` connect directly via PDO using these defaults to read active config even when Drush itself can't fully bootstrap. If a project uses different DB credentials or a non-default service name, that direct read fails and both scripts fall back to reading `config/default/*.yml` instead - still works, but reflects the *exported* config rather than the *active* one, so DB/code drift (e.g. an enabled module with no matching code on disk) won't be caught.
- **Claude Code CLI** (`claude`) installed and authenticated on the host, only if you intend to use `ddev run-upgrade`. `ddev pre-upgrade` on its own has no Claude Code dependency.
- **Node.js 22+** and **yarn**, for the `nodejs-scrape`/`nodejs-diff` visual-diff toolkit. `setup-drupal-upgrade.sh` checks for both and offers to install them (via Homebrew/nvm/npm) if missing.
- (Optional) **Chrome** with the **Claude for Chrome** extension, if you want Claude Code to drive a browser tab directly (e.g. for visual QA alongside `nodejs-scrape`/`nodejs-diff`). `setup-drupal-upgrade.sh` prompts to open the Chrome Web Store for it - Chrome doesn't allow scripted installs, so you still click "Add to Chrome" yourself.
- Enough disk/network for Composer to actually install `drush/drush`, `drupal/upgrade_status`, `mglaman/drupal-check`, and `drupal/stage_file_proxy` if they aren't already present - `pre-upgrade` installs them automatically on first run.

## Usage

1. clone repo into the root of the target Drupal project (alongside `composer.json`, `.ddev/`, etc.).
2. Install the toolkit:
   ```bash
   ./drupal-scripts/setup-drupal-upgrade.sh
   ```
   or
   ```bash
   bash drupal-scripts/setup-drupal-upgrade.sh
   ```
   This copies the skill and ddev commands into place, `chmod +x`s the executables, checks/installs Node.js 22+ and yarn (prompting first), `yarn install`s the `nodejs/` toolkit, prompts for the site's domain (saved as `BASE_URL` in `.ddev/commands/host/.env`), runs `ddev start`, then - if `drupal/search_api_solr` is in `composer.json` - checks whether DDEV's Solr service is installed and running and whether the site's `search_api` Solr server(s) can connect to it; if not, it installs the `ddev/ddev-drupal-solr` add-on (prompting first) and/or restarts DDEV as needed, and for any server using the local `standard` connector, points it at `host: solr, port: 8983` and aligns DDEV's `SOLR_CORENAME` with the server's configured core. Servers using a non-`standard` connector (e.g. `pantheon`) are left untouched. Safe to re-run any time you update `drupal-scripts/` - it overwrites the installed copies.
3. Generate the audit reports:
   ```bash
   ddev pre-upgrade
   ```
   Writes `pre-upgrade.md` and `ckeditor5-checklist.md` (plus raw scanner output) to `.ddev/commands/host/reports/`. Read `pre-upgrade.md` first - it flags any CRITICAL blocker (e.g. a module enabled in the DB with no code on disk) that will break later steps if left unresolved. It also installs/enables `drupal/stage_file_proxy` and points its origin at the `BASE_URL` saved in `.ddev/commands/host/.env` (see step 2 of setup) so local file requests fall back to the live site instead of 404ing, then runs `ddev nodejs-scrape pre` to capture a visual baseline (full XPath + computed CSS/layout snapshots of the header/footer/main-content regions for every page discovered via the homepage's main menu) before any code changes, writing `.ddev/commands/host/nodejs/output/pre.*.json`. After the upgrade, run `ddev nodejs-scrape post` and then `ddev nodejs-diff` to diff the two runs and flag any unintended visual/layout changes.
4. Execute the upgrade:
   ```bash
   ddev run-upgrade
   ```
   - **Guided (recommended):** `ddev run-upgrade` - opens an interactive Claude Code session pre-loaded with `/d11-upgrade run`. You approve each tool call as it runs; nothing executes unattended.
   - **Manual:** open `.claude/skills/d11-upgrade/SKILL.md` and work through its phases yourself, using the two reports as the source of truth for what needs upgrading.
5. Smoke-test the upgraded site:
   ```bash
   ddev post-upgrade
   ```
   Visits the homepage plus every enabled link in the site's `main` menu (anonymously), then generates a `drush uli` login and visits the site's `admin` menu using that authenticated session: `/admin`, its top-level sections (Content, Structure, Configuration, People, Appearance, Modules, Reports, Help), each section's direct child pages (e.g. Structure's Content types/Taxonomy/Menus/Views, Config's category pages), and each section's tabs (e.g. People's Permissions/Roles, Modules' Uninstall) - all discovered dynamically via Drupal's menu and local-task APIs rather than hardcoded, so it adapts to whatever admin menu structure the target site actually has. After each phase it checks the dblog for any new Emergency/Critical/Error/Warning entries logged during that phase specifically (not the site's full log history). Finally it runs `ddev nodejs-scrape post` to capture a post-upgrade visual snapshot and `ddev nodejs-diff` to diff it against the `ddev pre-upgrade` baseline (skipped with a warning if `nodejs-scrape`/`nodejs-diff` aren't installed), and writes everything to `post-upgrade.md`.

## Notes

- `pre-upgrade` performs *real* `composer require`/`composer update` calls (for Drush, `upgrade_status`, and `drupal-check` if missing) - it changes `composer.json`/`composer.lock`, not just reads them. Review `git diff` after running it.
- The `upgrade_status`/`drupal-check` deprecation scans require a working Drupal bootstrap. A PHP fatal anywhere in enabled module/theme code (most commonly a duplicate function declaration across two themes) will make every scanned item fail identically - `pre-upgrade.md` detects and calls this out explicitly rather than reporting misleading per-module results.
- The Drupal-11-removed core module/theme list checked by `pre-upgrade` is fixed (`ckeditor`, `color`, `classy`, `stable`, `aggregator`, `book`, `forum`, `hal`, `quickedit`, `rdf`, `statistics`, `tour`) - it will not detect a future core removal not on this list.
- `post-upgrade` also needs a working Drupal bootstrap (to enumerate the `main` menu via `drush php:script`) and the same default `db`/`db`/`db`@`db:3306` database access as `pre-upgrade` (to read dblog directly via PDO). A 200 HTTP status on a visited page does not mean nothing went wrong - always check the dblog table in the report too, since Drupal can log an error while still rendering a 200 response.
- The setup script's Solr check only auto-configures `search_api` servers using the generic `standard` Solr connector (typical for local dev) - it never touches a `pantheon`-connector (or other environment-specific) server, since those intentionally point elsewhere. It also needs a working Drupal bootstrap to enumerate servers; if the site isn't installed yet, re-run `./drupal-scripts/setup-drupal-upgrade.sh` once it is.
