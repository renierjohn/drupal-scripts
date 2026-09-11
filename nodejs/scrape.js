#!/usr/bin/env node
/**
 * Captures the full XPath + computed CSS of the header, footer, and
 * main-content regions -- and every element nested inside them (cards,
 * banners, headings, paragraphs, buttons, etc.), excluding visually-hidden
 * elements, slider/carousel elements (slick-slide, swiper-slide, etc.),
 * and elements with computed display:none -- for a set of pages, so a
 * "pre" run and a "post" (D11 upgrade) run can be diffed to confirm the
 * display didn't change.
 *
 * Usage:
 *   yarn install
 *   node scrape.js [label] [path ...]
 *
 * Examples:
 *   node scrape.js pre                  # auto-discovers menu pages (see below)
 *   node scrape.js post
 *   node scrape.js pre path=/work         # single page only -> output/pre.work.json
 *   node scrape.js pre / /about /contact  # explicit paths, discovery skipped
 *   BASE_URL=https://prometweb.ddev.site node scrape.js pre
 *
 * - label   : name for this run, used as the output filename prefix
 *             (default: "snapshot"). Use "pre" before the upgrade and
 *             "post" after, then diff matching files, e.g.:
 *               diff output/pre.homepage.json output/post.homepage.json
 *               diff output/pre.solutions.json output/post.solutions.json
 * - path=<p>: capture ONLY that single page, writing ONLY
 *             output/<label>.<slug>.json (slug derived from the path
 *             itself, e.g. path=/work -> output/pre.work.json). Skips
 *             discovery and every other menu/homepage file entirely.
 * - path(s) : site-relative paths to check. If omitted (and no path=
 *             argument is given either), only the homepage's own
 *             top-level navigation menu is used to find pages: the
 *             homepage is visited, its main menu is walked, and every
 *             top-level menu item + all of its child/submenu links
 *             become the scope -- links in the main body or footer are
 *             NOT included. One output file is written per top-level
 *             menu (output/<label>.<menu-name>.json) plus
 *             output/<label>.homepage.json for the homepage itself.
 *             Pass explicit path(s) to skip discovery entirely and
 *             check only those pages (written to output/<label>.json).
 *             A full "http(s)://" URL is also accepted in place of a path.
 * - BASE_URL: override the site base URL (default: auto-detected via
 *             `ddev describe -j`, falling back to https://prometweb.ddev.site).
 *             Can be set in the environment, or in a ".env" file next to
 *             this script (e.g. BASE_URL=https://example.com) -- values
 *             already set in the environment take precedence over ".env".
 * - RENDER_WAIT_MS: extra milliseconds to wait after each page loads,
 *             before capturing -- lets JS-driven layout (mega menu
 *             measurements, sliders, lazy images, web fonts) finish
 *             settling so width/height don't differ between runs just
 *             from render timing. Default: 2000. Same env/.env rules
 *             as BASE_URL.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { chromium } = require('playwright');

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

const REGION_SELECTORS = {
  header: ['header[role="banner"]', 'header', '#header', '.region-header', '.site-header'],
  footer: ['footer[role="contentinfo"]', 'footer', '#footer', '.region-footer', '.site-footer'],
  main: ['main[role="main"]', 'main', '#main-content', '.region-content', '[role="main"]'],
};

const CSS_PROPS = [
  'display', 'position', 'top', 'right', 'bottom', 'left', 'float', 'clear',
  'width', 'height', 'minWidth', 'minHeight', 'maxWidth', 'maxHeight',
  'marginTop', 'marginRight', 'marginBottom', 'marginLeft',
  'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft',
  'borderTopWidth', 'borderRightWidth', 'borderBottomWidth', 'borderLeftWidth',
  'borderStyle', 'borderColor', 'borderRadius',
  'boxSizing', 'overflow', 'overflowX', 'overflowY', 'visibility', 'opacity', 'zIndex',
  'flexDirection', 'flexWrap', 'justifyContent', 'alignItems', 'alignContent',
  'flexGrow', 'flexShrink', 'flexBasis', 'gap',
  'gridTemplateColumns', 'gridTemplateRows', 'gridColumn', 'gridRow',
  'fontFamily', 'fontSize', 'fontWeight', 'fontStyle', 'lineHeight', 'letterSpacing',
  'textAlign', 'textTransform', 'textDecoration',
  'color', 'backgroundColor', 'backgroundImage', 'backgroundPosition', 'backgroundSize', 'backgroundRepeat',
  'transform',
];

// Extra time to let JS-driven layout (mega menu measurements, sliders, lazy
// images, web fonts) finish settling after page load, before capturing.
// Override with RENDER_WAIT_MS (env var or .env).
const RENDER_WAIT_MS = Number(process.env.RENDER_WAIT_MS) || 2000;

function detectBaseUrl() {
  if (process.env.BASE_URL) return process.env.BASE_URL.replace(/\/+$/, '');
  try {
    const json = execSync('ddev describe -j', { cwd: path.resolve(__dirname, '..', '..', '..', '..'), stdio: ['ignore', 'pipe', 'ignore'] }).toString();
    const parsed = JSON.parse(json);
    const url = parsed && parsed.raw && parsed.raw.primary_url;
    if (url) return url.replace(/\/+$/, '');
  } catch (err) {
    // fall through to default
  }
  return 'https://prometweb.ddev.site';
}

function parseArgs(argv) {
  const args = argv.slice(2);
  let label = 'snapshot';

  const isPathArg = (a) => a.startsWith('/') || /^https?:\/\//.test(a) || /^path=/i.test(a);
  if (args.length && !isPathArg(args[0])) {
    label = args.shift();
  }

  const pathArgIndex = args.findIndex((a) => /^path=/i.test(a));
  if (pathArgIndex !== -1) {
    const singlePath = args[pathArgIndex].slice('path='.length);
    return { label, singlePath };
  }

  const explicitPaths = args.length > 0;
  const paths = explicitPaths ? args : ['/'];
  return { label, paths, discover: !explicitPaths };
}

/* Executed in the page context via page.evaluate() */
const SKIP_TAGS = ['script', 'style', 'noscript', 'template', 'link', 'meta'];

function extractRegion({ selectors, cssProps, skipTags }) {
  function getFullXPath(el) {
    const parts = [];
    let node = el;
    while (node && node.nodeType === Node.ELEMENT_NODE) {
      let index = 1;
      let sibling = node.previousElementSibling;
      while (sibling) {
        if (sibling.tagName === node.tagName) index++;
        sibling = sibling.previousElementSibling;
      }
      parts.unshift(`${node.tagName.toLowerCase()}[${index}]`);
      node = node.parentElement;
    }
    return '/' + parts.join('/');
  }

  function describeElement(el, precomputed) {
    const computed = precomputed || window.getComputedStyle(el);
    const css = {};
    for (const prop of cssProps) {
      css[prop] = computed[prop];
    }
    return {
      xpath: getFullXPath(el),
      tagName: el.tagName.toLowerCase(),
      id: el.id || null,
      className: el.className && typeof el.className === 'string' ? el.className : null,
      childElementCount: el.childElementCount,
      css,
    };
  }

  let el = null;
  let matchedSelector = null;
  for (const sel of selectors) {
    el = document.querySelector(sel);
    if (el) {
      matchedSelector = sel;
      break;
    }
  }

  if (!el) return null;

  // Slider/carousel classes (slick-slide, slick-slider, swiper-slide, etc.)
  // shuffle/clone/reorder DOM nodes and animate transforms on their own, so
  // they're excluded as noise unrelated to real markup/CSS changes.
  function isSliderRelated(node) {
    for (const cls of node.classList) {
      if (cls.toLowerCase().includes('slide')) return true;
    }
    return false;
  }

  const skip = new Set(skipTags);
  const elements = [describeElement(el)];
  for (const descendant of el.querySelectorAll('*')) {
    if (skip.has(descendant.tagName.toLowerCase())) continue;
    if (descendant.classList.contains('visually-hidden')) continue;
    if (isSliderRelated(descendant)) continue;
    const computed = window.getComputedStyle(descendant);
    if (computed.display === 'none') continue;
    elements.push(describeElement(descendant, computed));
  }

  return {
    matchedSelector,
    elementCount: elements.length,
    elements,
  };
}

const NON_PAGE_EXTENSIONS = /\.(pdf|jpe?g|png|gif|svg|webp|zip|docx?|xlsx?|pptx?|mp4|mp3|csv|txt|ics)$/i;

// Candidate selectors for the site's top-level navigation menu (the <ul>
// whose direct <li> children are the top-level menu items). First match wins.
const MENU_ROOT_SELECTORS = [
  '.tbm-nav.level-0',
  'header nav > ul.menu',
  'header ul.menu--main',
  '#main-menu > ul',
  '#main-menu',
  'header nav ul',
];

function slugify(str) {
  return (
    (str || '')
      .toLowerCase()
      .trim()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '') || 'menu'
  );
}

/* Executed in the page context via page.evaluate() */
function discoverMenuGroupsInPage(rootSelectors) {
  function findRoot(selectors) {
    for (const sel of selectors) {
      const el = document.querySelector(sel);
      if (el) return el;
    }
    return null;
  }

  const root = findRoot(rootSelectors);
  if (!root) return [];

  return Array.from(root.querySelectorAll(':scope > li')).map((li, idx) => {
    const labelEl =
      li.querySelector(':scope > .tbm-link-container > a') ||
      li.querySelector(':scope > a') ||
      li.querySelector('a[href]');
    const name = labelEl && labelEl.textContent.trim() ? labelEl.textContent.trim() : `menu-${idx + 1}`;
    const links = Array.from(li.querySelectorAll('a[href]')).map((a) => ({
      href: a.href,
      text: (a.textContent || '').trim().slice(0, 80),
    }));
    return { name, links };
  });
}

/**
 * Visits the homepage and walks its top-level navigation menu, grouping
 * every top-level item's own page + all of its nested child/submenu
 * links under that item's name. Main-body and footer links are NOT
 * included -- only the menu itself is the discovery scope.
 */
async function discoverMenus(browser, baseUrl) {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  let groups = [];
  try {
    try {
      await page.goto(baseUrl, { waitUntil: 'networkidle', timeout: 45000 });
    } catch (err) {
      await page.goto(baseUrl, { waitUntil: 'load', timeout: 45000 });
    }
    await page.waitForTimeout(RENDER_WAIT_MS);
    groups = await page.evaluate(discoverMenuGroupsInPage, MENU_ROOT_SELECTORS);
  } finally {
    await page.close();
  }

  const baseHost = new URL(baseUrl).hostname;
  const usedSlugs = new Set();
  const menus = [];

  for (const group of groups) {
    const seen = new Set();
    const paths = [];

    for (const link of group.links) {
      let u;
      try {
        u = new URL(link.href);
      } catch (err) {
        continue;
      }
      if (u.hostname !== baseHost) continue;
      if (!/^https?:$/.test(u.protocol)) continue;
      if (NON_PAGE_EXTENSIONS.test(u.pathname)) continue;
      const p = u.pathname || '/';
      if (p === '/' || seen.has(p)) continue;
      seen.add(p);
      paths.push(p);
    }

    if (!paths.length) continue; // e.g. a search toggle or CTA button with no real page

    let slug = slugify(group.name);
    let unique = slug;
    let n = 2;
    while (usedSlugs.has(unique)) unique = `${slug}-${n++}`;
    usedSlugs.add(unique);

    menus.push({ name: group.name, slug: unique, paths });
  }

  return menus;
}

async function snapshotPage(browser, baseUrl, urlPath) {
  const url = /^https?:\/\//.test(urlPath) ? urlPath : `${baseUrl}${urlPath.startsWith('/') ? '' : '/'}${urlPath}`;
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

  const regions = {};
  let error = null;
  try {
    try {
      await page.goto(url, { waitUntil: 'networkidle', timeout: 45000 });
    } catch (err) {
      // Some pages (chat widgets, trackers) never go network-idle -- fall
      // back to a plain load so one such page doesn't abort the whole run.
      console.warn(`  ! networkidle timed out for ${url}, retrying with 'load'`);
      await page.goto(url, { waitUntil: 'load', timeout: 45000 });
    }

    await page.waitForTimeout(RENDER_WAIT_MS);

    for (const [region, selectors] of Object.entries(REGION_SELECTORS)) {
      const result = await page.evaluate(extractRegion, { selectors, cssProps: CSS_PROPS, skipTags: SKIP_TAGS });
      regions[region] = result;
      if (!result) {
        console.warn(`  ! no match for "${region}" on ${url} (tried: ${selectors.join(', ')})`);
      } else {
        console.log(`  - ${region}: ${result.elementCount} elements captured`);
      }
    }
  } catch (err) {
    error = err.message;
    console.warn(`  ! failed to capture ${url}: ${err.message}`);
  } finally {
    await page.close();
  }

  return { url, regions, error };
}

function writeOutput(filename, data) {
  fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  const outFile = path.join(OUTPUT_DIR, filename);
  fs.writeFileSync(outFile, JSON.stringify(data, null, 2));
  console.log(`Saved: ${path.relative(process.cwd(), outFile)}`);

  const failed = data.pages.filter((p) => p.error);
  if (failed.length) {
    console.log(`  ${failed.length} page(s) failed to capture:`);
    for (const p of failed) console.log(`    - ${p.url}: ${p.error}`);
  }
}

async function main() {
  const parsed = parseArgs(process.argv);
  const { label, singlePath, paths: requestedPaths, discover } = parsed;
  const baseUrl = detectBaseUrl();

  console.log(`Base URL: ${baseUrl}`);
  console.log(`Label: ${label}`);

  const browser = await chromium.launch({ headless: true });

  try {
    if (singlePath) {
      const slug = slugify(singlePath);
      console.log(`Capturing single page ${singlePath} ...`);
      const snapshot = await snapshotPage(browser, baseUrl, singlePath);
      writeOutput(`${label}.${slug}.json`, {
        label,
        scope: 'path',
        path: singlePath,
        baseUrl,
        capturedAt: new Date().toISOString(),
        pages: [snapshot],
      });
    } else if (discover) {
      console.log(`Capturing homepage ...`);
      const homepageSnapshot = await snapshotPage(browser, baseUrl, '/');
      writeOutput(`${label}.homepage.json`, {
        label,
        scope: 'homepage',
        baseUrl,
        capturedAt: new Date().toISOString(),
        pages: [homepageSnapshot],
      });

      console.log(`\nDiscovering top-level menu items from the homepage nav ...`);
      const menus = await discoverMenus(browser, baseUrl);
      console.log(`Found ${menus.length} menu group(s) with page links.`);

      for (const menu of menus) {
        console.log(`\nMenu "${menu.name}" (${menu.paths.length} page(s)): ${menu.paths.join(', ')}`);
        const pages = [];
        for (const p of menu.paths) {
          console.log(`Capturing ${p} ...`);
          pages.push(await snapshotPage(browser, baseUrl, p));
        }
        writeOutput(`${label}.${menu.slug}.json`, {
          label,
          scope: 'menu',
          menuName: menu.name,
          menuSlug: menu.slug,
          baseUrl,
          capturedAt: new Date().toISOString(),
          pages,
        });
      }
    } else {
      console.log(`Paths to capture (${requestedPaths.length}): ${requestedPaths.join(', ')}`);
      const pages = [];
      for (const p of requestedPaths) {
        console.log(`Capturing ${p} ...`);
        pages.push(await snapshotPage(browser, baseUrl, p));
      }
      writeOutput(`${label}.json`, { label, scope: 'custom', baseUrl, capturedAt: new Date().toISOString(), pages });
    }
  } finally {
    await browser.close();
  }

  console.log(`\nRun again with a different label (e.g. "post") after the upgrade, then diff matching files.`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
