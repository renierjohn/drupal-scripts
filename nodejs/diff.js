#!/usr/bin/env node
/**
 * Compares two labeled scrape.js runs (e.g. "pre" and "post") and reports
 * what changed: added/removed pages, and within each page's header/footer/
 * main regions, added/removed elements and elements whose computed CSS
 * differs. Elements are matched by their full xpath.
 *
 * Usage:
 *   node diff.js [preLabel] [postLabel]
 *
 * Defaults: preLabel="pre", postLabel="post"
 *
 * Reads output/<preLabel>.<suffix>.json / output/<postLabel>.<suffix>.json
 * pairs (suffix is "homepage", a menu slug, or empty for a plain custom-path
 * run), diffs each pair, prints a console summary, and writes a detailed
 * report per pair to output/diff.<suffix>.json (e.g. diff.homepage.json,
 * diff.solutions.json)
 *
 * Note: xpath encodes sibling position by tag name, so inserting/removing a
 * sibling of the same tag shifts every later sibling's xpath. That shows up
 * here as "removed at old xpath" + "added at new xpath" for what may
 * visually be the same element that just moved position in the DOM -- this
 * is expected given full-xpath matching, not a bug in the comparison.
 *
 * - CSS_PX_TOLERANCE: pixel tolerance (default 1) for comparing pixel-valued
 *             CSS (margins, padding, font-size, etc.) -- ignores sub-pixel/
 *             font-loading rendering noise.
 * - CSS_WIDTH_PX_TOLERANCE / CSS_HEIGHT_PX_TOLERANCE: same idea, but
 *             specifically for the "width" / "height" CSS properties,
 *             which tend to shift more (JS-driven layout, content-length
 *             differences). Each defaults to CSS_PX_TOLERANCE if unset.
 *             All three can be set in the environment, or in a ".env"
 *             file next to this script (e.g. CSS_WIDTH_PX_TOLERANCE=5) --
 *             values already set in the environment take precedence over
 *             ".env".
 */

'use strict';

const fs = require('fs');
const path = require('path');

const OUTPUT_DIR = path.join(__dirname, 'output');

/** Minimal .env loader (no dependency): KEY=VALUE per line, existing env vars win. */
function loadDotEnv(file = path.join(__dirname, '.env')) {
  if (!fs.existsSync(file)) return;
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const match = line.match(/^\s*([\w.-]+)\s*=\s*(.*)?\s*$/);
    if (!match) continue;
    const key = match[1];
    let value = (match[2] || '').trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (!(key in process.env)) process.env[key] = value;
  }
}

loadDotEnv();

const CSS_PX_TOLERANCE = Number(process.env.CSS_PX_TOLERANCE) || 1; // px; ignore sub-pixel/font-loading rendering noise
const CSS_WIDTH_PX_TOLERANCE = Number(process.env.CSS_WIDTH_PX_TOLERANCE) || CSS_PX_TOLERANCE;
const CSS_HEIGHT_PX_TOLERANCE = Number(process.env.CSS_HEIGHT_PX_TOLERANCE) || CSS_PX_TOLERANCE;

function toleranceFor(key) {
  if (key === 'width') return CSS_WIDTH_PX_TOLERANCE;
  if (key === 'height') return CSS_HEIGHT_PX_TOLERANCE;
  return CSS_PX_TOLERANCE;
}

/** Parses a CSS pixel value like "12.5px" into a number, or null if it isn't one. */
function parsePx(value) {
  if (typeof value !== 'string') return null;
  const match = value.match(/^(-?\d+(?:\.\d+)?)px$/);
  return match ? parseFloat(match[1]) : null;
}

/** Pixel-valued CSS (width, height, margins, etc.) compares within a small
 * tolerance to absorb sub-pixel rendering / font-loading noise; everything
 * else (colors, keywords, font names) still compares exactly. "width" and
 * "height" get their own tolerance (CSS_WIDTH_PX_TOLERANCE /
 * CSS_HEIGHT_PX_TOLERANCE), everything else uses CSS_PX_TOLERANCE. */
function cssValuesDiffer(key, a, b) {
  const na = parsePx(a);
  const nb = parsePx(b);
  if (na !== null && nb !== null) return Math.abs(na - nb) > toleranceFor(key);
  return a !== b;
}

function parseArgs(argv) {
  const args = argv.slice(2);
  return { preLabel: args[0] || 'pre', postLabel: args[1] || 'post' };
}

function listSuffixedFiles(label) {
  const prefix = `${label}.`;
  if (!fs.existsSync(OUTPUT_DIR)) return [];
  return fs
    .readdirSync(OUTPUT_DIR)
    .filter((f) => f.startsWith(prefix) && f.endsWith('.json') && !f.startsWith('diff.'))
    .map((f) => ({ file: f, suffix: f.slice(prefix.length, -'.json'.length) }));
}

function urlPathname(u) {
  try {
    return new URL(u).pathname;
  } catch (err) {
    return u;
  }
}

function diffElements(preElements, postElements) {
  const preMap = new Map(preElements.map((e) => [e.xpath, e]));
  const postMap = new Map(postElements.map((e) => [e.xpath, e]));

  const removed = [];
  const added = [];
  const changed = [];

  for (const [xpath, preEl] of preMap) {
    const postEl = postMap.get(xpath);
    if (!postEl) {
      removed.push({ xpath, tagName: preEl.tagName, className: preEl.className });
      continue;
    }

    const cssDiffs = {};
    for (const key of Object.keys(preEl.css)) {
      if (cssValuesDiffer(key, preEl.css[key], postEl.css[key])) {
        cssDiffs[key] = { pre: preEl.css[key], post: postEl.css[key] };
      }
    }

    if (Object.keys(cssDiffs).length) {
      changed.push({ xpath, tagName: preEl.tagName, className: preEl.className, cssDiffs });
    }
  }

  for (const [xpath, postEl] of postMap) {
    if (!preMap.has(xpath)) {
      added.push({ xpath, tagName: postEl.tagName, className: postEl.className });
    }
  }

  return { removed, added, changed };
}

function diffPage(prePage, postPage) {
  const regions = {};
  const regionNames = new Set([...Object.keys(prePage.regions || {}), ...Object.keys(postPage.regions || {})]);

  for (const region of regionNames) {
    const preRegion = prePage.regions[region];
    const postRegion = postPage.regions[region];
    if (!preRegion && !postRegion) continue;
    if (!preRegion) {
      regions[region] = { status: 'region-added' };
      continue;
    }
    if (!postRegion) {
      regions[region] = { status: 'region-removed' };
      continue;
    }

    const { removed, added, changed } = diffElements(preRegion.elements, postRegion.elements);
    regions[region] = {
      preElementCount: preRegion.elementCount,
      postElementCount: postRegion.elementCount,
      removedCount: removed.length,
      addedCount: added.length,
      changedCount: changed.length,
      removed,
      added,
      changed,
    };
  }

  return regions;
}

function diffFilePair(preData, postData) {
  const prePages = new Map(preData.pages.map((p) => [urlPathname(p.url), p]));
  const postPages = new Map(postData.pages.map((p) => [urlPathname(p.url), p]));
  const allPaths = new Set([...prePages.keys(), ...postPages.keys()]);

  const pages = [];
  for (const p of allPaths) {
    const prePage = prePages.get(p);
    const postPage = postPages.get(p);

    if (!prePage) {
      pages.push({ path: p, status: 'added' });
      continue;
    }
    if (!postPage) {
      pages.push({ path: p, status: 'removed' });
      continue;
    }
    if (prePage.error || postPage.error) {
      pages.push({ path: p, status: 'error', preError: prePage.error, postError: postPage.error });
      continue;
    }

    const regions = diffPage(prePage, postPage);
    const hasChanges = Object.values(regions).some((r) => r.status || r.removedCount || r.addedCount || r.changedCount);
    pages.push({ path: p, status: hasChanges ? 'changed' : 'unchanged', regions });
  }

  return { pages };
}

function summarize(suffix, result) {
  const changed = result.pages.filter((p) => p.status === 'changed');
  const added = result.pages.filter((p) => p.status === 'added');
  const removed = result.pages.filter((p) => p.status === 'removed');
  const errored = result.pages.filter((p) => p.status === 'error');
  const unchanged = result.pages.filter((p) => p.status === 'unchanged');

  console.log(`\n=== ${suffix || '(custom)'} ===`);
  console.log(
    `  pages: ${result.pages.length}  unchanged: ${unchanged.length}  changed: ${changed.length}  added: ${added.length}  removed: ${removed.length}  errored: ${errored.length}`
  );

  for (const p of changed) {
    console.log(`  CHANGED ${p.path}`);
    for (const [region, r] of Object.entries(p.regions)) {
      if (r.status) {
        console.log(`    - ${region}: ${r.status}`);
        continue;
      }
      if (r.removedCount || r.addedCount || r.changedCount) {
        console.log(
          `    - ${region}: +${r.addedCount} -${r.removedCount} ~${r.changedCount} (of ${r.preElementCount} -> ${r.postElementCount} elements)`
        );
      }
    }
  }
  for (const p of added) console.log(`  PAGE ADDED    ${p.path}`);
  for (const p of removed) console.log(`  PAGE REMOVED  ${p.path}`);
  for (const p of errored) console.log(`  PAGE ERROR    ${p.path} (pre: ${p.preError || 'ok'}, post: ${p.postError || 'ok'})`);
}

function main() {
  const { preLabel, postLabel } = parseArgs(process.argv);
  const preFiles = listSuffixedFiles(preLabel);
  const postFiles = listSuffixedFiles(postLabel);

  if (!preFiles.length) {
    console.error(`No "${preLabel}.*.json" files found in ${path.relative(process.cwd(), OUTPUT_DIR)}/`);
    process.exit(1);
  }

  const postBySuffix = new Map(postFiles.map((f) => [f.suffix, f]));
  const reports = [];

  for (const pre of preFiles) {
    const post = postBySuffix.get(pre.suffix);
    if (!post) {
      console.log(`\n=== ${pre.suffix || '(custom)'} ===\n  ! no matching "${postLabel}.${pre.suffix}.json" found, skipping`);
      continue;
    }

    const preData = JSON.parse(fs.readFileSync(path.join(OUTPUT_DIR, pre.file), 'utf8'));
    const postData = JSON.parse(fs.readFileSync(path.join(OUTPUT_DIR, post.file), 'utf8'));
    const result = diffFilePair(preData, postData);
    summarize(pre.suffix, result);

    const reportFile = path.join(OUTPUT_DIR, `diff.${pre.suffix || 'custom'}.json`);
    fs.writeFileSync(reportFile, JSON.stringify(result, null, 2));
    reports.push(path.relative(process.cwd(), reportFile));
  }

  if (reports.length) {
    console.log(`\nDetailed reports written:`);
    for (const r of reports) console.log(`  - ${r}`);
  }
}

main();
