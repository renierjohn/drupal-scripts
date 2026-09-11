---
name: d11-post-upgrade
description: Use when asked to fix issues found by the D11 post-upgrade smoke test, once .ddev/commands/host/reports/post-upgrade.md and .ddev/commands/host/nodejs/output/diff.*.json already exist.
---

# D11 Post-Upgrade Fix

## Overview

This is the fix-driven follow-up to the D11 upgrade, driven entirely by two reports `ddev post-upgrade` already produces: the dblog/HTTP-status report (`post-upgrade.md`) and the visual regression diff (`nodejs/output/diff.*.json`). It does not re-scan the site - it reads what already broke and works through it in a fixed order, with a hard-capped retry loop on each side so a stubborn issue can't turn into an unbounded fix-and-recheck spiral.

## When to Use

- The user asks to fix, triage, or work through post-upgrade issues on this project.
- `.ddev/commands/host/reports/post-upgrade.md` already exists (if not, run `ddev post-upgrade` first).
- Not for: running the smoke test itself, or the D11 upgrade execution (`d11-upgrade` handles that).

## Phase 1: dblog / error-driven fixes (source: `post-upgrade.md`)

Read `post-upgrade.md` in full - both "page-visit" sections (1. Homepage + main-menu pages, 2. Admin pages) and their "dblog findings - Emergency / Critical / Error / Warning" subsections.

### 1a-1b. Triage dblog findings

For every dblog row, decide whether it's a real problem or noise:
- **Ignore** Warning-severity entries that don't affect functionality - e.g. a recurring "block plugin was not found" from an orphaned `block_content` UUID that no longer resolves to a placed block. Judgment call, not a fixed ignore-list: if a Warning correlates with a visibly broken page or missing content, it's not noise.
- Everything else (Emergency/Critical/Error, or a Warning tied to an actual break) proceeds to triage below.

### 1c. Priority 1 - WSOD

Any of:
- A 500-status row (or non-2xx/3xx `**CHECK**` row that's actually a full page failure) in either visit table.
- An Emergency/Critical/Error dblog entry that breaks page render (PHP fatal, uncaught exception, etc).

For each: identify root cause (file + line from the error). Core or contrib module/theme -> apply/find a patch (`cweagans/composer-patches`, per `drupal-d10-to-d11-upgrade`). Custom module/theme -> fix the code directly.

### 1d. Priority 2 - alert-level errors

Remaining Error-severity dblog entries, or `**CHECK**`-flagged rows that return a non-fatal but user-facing error (page renders, but with a Drupal error/status message). Same triage as 1c: core/contrib -> patch, custom -> code fix.

### 1e. Retry cap - 2 attempts per issue

1. Apply the fix.
2. Re-run `ddev post-upgrade`.
3. Recheck the regenerated `post-upgrade.md` for that specific issue.
4. Still present after the 2nd attempt -> **stop**. Do not attempt a 3rd fix. Append to `.ddev/commands/host/reports/post-upgrade-fix.md`: the issue, both fixes tried and their outcome, and the current error text.

## Phase 2: visual regression fixes (source: `nodejs/output/diff.<suffix>.json`)

Each pre/post page pair produces `diff.<suffix>.json` (`.ddev/commands/host/nodejs/output/`), with per-region (`header`/`footer`/`main`/etc) `added`/`removed`/`changed` element lists, matched by xpath. `changed` entries carry `cssDiffs`, keyed by CSS property, each `{ pre, post }`.

### 2a. Locate the cause

For each changed/added/removed element, resolve its xpath + region back to the template rendering it: a `.twig` file in a custom theme, a contrib theme/module, or a custom module's render array. Check which one owns that markup before touching anything.

### 2b. Filter out JS-driven layout noise

If a `changed` entry's only `cssDiffs` keys are position/size-related (`position`, `top`, `left`, `right`, `bottom`, `width`, `height`, `transform`) - treat it as likely JS-driven layout (carousel, sticky nav, lazy-loaded image sizing, etc) and ignore it, **unless** a manual look at the page shows an actual visual break. Don't chase pixel-tolerance noise from dynamic JS.

### 2c. Confirm and fix real breaks

For everything else - elements added/removed, or `cssDiffs` on non-layout properties (color, font, display, visibility, background, border) - confirm the display is genuinely different (not just JS-driven), then locate the cause in the owning twig template, CSS/Sass, or module logic and fix it.

### 2d. Re-verify

After each fix: `ddev nodejs-scrape post` -> `ddev nodejs-diff` -> re-open the same `diff.<suffix>.json` and confirm the entry is gone.

### 2e. Retry cap

Still present after the re-check -> **stop**, don't keep iterating on that element. Log to `.ddev/commands/host/reports/post-upgrade-display-issue.md`: the page URL (for a quick manual look), region, xpath, and the `cssDiffs`/added/removed detail from the diff.

## Quick Reference

| Step | Source | Action |
|---|---|---|
| 1a-1b | `post-upgrade.md` dblog findings | Ignore non-impacting Warnings; everything else proceeds |
| 1c | 500/`**CHECK**` rows + fatal dblog entries | WSOD - patch (core/contrib) or fix code (custom), highest priority |
| 1d | Remaining Error rows / alert-level dblog | Same patch-vs-fix split, second priority |
| 1e | - | Max 2 fix attempts per issue, then log to `post-upgrade-fix.md` |
| 2a | `diff.<suffix>.json` `added`/`removed`/`changed` | Resolve xpath/region to owning twig/module/theme |
| 2b | `cssDiffs` keys | Ignore position/width/height-only diffs unless visually confirmed broken |
| 2c | Confirmed real diffs | Fix in twig/CSS-Sass/module |
| 2d | - | `nodejs-scrape post` -> `nodejs-diff` -> recheck |
| 2e | - | Still changed after recheck -> log to `post-upgrade-display-issue.md` with page URL, don't keep iterating |

## Common Mistakes

- Treating every dblog Warning as actionable - most orphaned-block-plugin noise is cosmetic, not a regression.
- Fixing a 500/WSOD after already chasing cosmetic diffs - always clear Phase 1 (site actually works) before Phase 2 (site looks right).
- Chasing `cssDiffs` on `width`/`height`/`position` that a carousel or sticky-nav script sets at runtime - that's expected JS behavior, not a regression.
- Skipping the re-verify step (2d) and assuming a twig/CSS fix worked - always re-scrape and re-diff before closing an issue out.
- Treating the 2-attempt caps (1e/2e) as suggestions - they exist to stop repeated speculative fixes from becoming a worse-broken site, same as the WSOD loop in `d11-upgrade`.
