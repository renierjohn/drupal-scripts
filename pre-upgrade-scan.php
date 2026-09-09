<?php
/**
 * Helper for the `ddev pre-upgrade` command.
 * Classifies drupal-module composer packages into upgrade-path buckets and
 * flags modules enabled in the active site config whose code is missing on
 * disk. Reads composer.lock + the active DB config directly - no Drupal
 * bootstrap required (the DB read is what lets this work even when a broken
 * module keeps Drush from bootstrapping).
 * Run inside the web container: `ddev exec php .ddev/commands/host/pre-upgrade-scan.php`.
 */

$root = getcwd();
$lockFile = $root . '/composer.lock';

$lock = json_decode(file_get_contents($lockFile), true);
if (!$lock) {
  fwrite(STDERR, "Could not read/parse $lockFile\n");
  exit(1);
}
$packages = array_merge($lock['packages'] ?? [], $lock['packages-dev'] ?? []);

$drupalModules = [];
foreach ($packages as $pkg) {
  $type = $pkg['type'] ?? '';
  if (!in_array($type, ['drupal-module', 'drupal-custom-module'], true)) {
    continue;
  }
  $name = $pkg['name'];
  $drupalModules[$name] = [
    'version' => $pkg['version'] ?? 'unknown',
    'core_constraint' => $pkg['require']['drupal/core'] ?? null,
  ];
}

/**
 * Modules actually enabled right now, read straight from the active DB
 * config (core.extension), bypassing Drupal bootstrap entirely. Falls back
 * to the exported config/default/core.extension.yml if the DB isn't
 * reachable with the default local DB credentials.
 */
function get_active_extensions(string $root): array {
  try {
    $pdo = new PDO('mysql:host=db;port=3306;dbname=db;charset=utf8mb4', 'db', 'db', [
      PDO::ATTR_TIMEOUT => 3,
    ]);
    $stmt = $pdo->query("SELECT data FROM config WHERE name = 'core.extension' LIMIT 1");
    $row = $stmt ? $stmt->fetch(PDO::FETCH_ASSOC) : FALSE;
    if ($row && ($data = @unserialize($row['data']))) {
      $themeStmt = $pdo->query("SELECT data FROM config WHERE name = 'system.theme' LIMIT 1");
      $themeRow = $themeStmt ? $themeStmt->fetch(PDO::FETCH_ASSOC) : FALSE;
      $themeDefaults = ($themeRow && ($t = @unserialize($themeRow['data']))) ? $t : [];
      return [
        'source' => 'active database config',
        'modules' => array_keys($data['module'] ?? []),
        'themes' => array_keys($data['theme'] ?? []),
        'default_theme' => $themeDefaults['default'] ?? null,
        'admin_theme' => $themeDefaults['admin'] ?? null,
      ];
    }
  }
  catch (\Throwable $e) {
    // Fall through to the file-based fallback below.
  }

  $parseExtensionBlock = function (string $file, string $key) {
    $names = [];
    if (!file_exists($file)) {
      return $names;
    }
    $inBlock = false;
    foreach (file($file) as $line) {
      if (preg_match('/^' . preg_quote($key, '/') . ':\s*$/', $line)) {
        $inBlock = true;
        continue;
      }
      if ($inBlock) {
        if (preg_match('/^  ([a-zA-Z0-9_]+):/', $line, $m)) {
          $names[] = $m[1];
        }
        elseif (preg_match('/^[a-zA-Z]/', $line)) {
          $inBlock = false;
        }
      }
    }
    return $names;
  };
  $configFile = $root . '/config/default/core.extension.yml';
  return [
    'source' => 'config/default/core.extension.yml (DB unreachable, fell back to sync export)',
    'modules' => $parseExtensionBlock($configFile, 'module'),
    'themes' => $parseExtensionBlock($configFile, 'theme'),
    'default_theme' => null,
    'admin_theme' => null,
  ];
}

$active = get_active_extensions($root);
$enabledResult = $active;
$enabled = array_fill_keys($active['modules'], true);
$enabledThemes = array_fill_keys($active['themes'], true);

/**
 * Machine names with code actually present on disk: every *.info.yml found
 * under core modules/profiles and contrib/custom modules/profiles. This
 * walks into nested submodule directories (e.g. a package that bundles
 * several sub-modules under one composer project).
 */
function scan_info_yml_machine_names(array $dirs): array {
  $names = [];
  foreach ($dirs as $dir) {
    if (!is_dir($dir)) {
      continue;
    }
    $iterator = new RecursiveIteratorIterator(
      new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS)
    );
    foreach ($iterator as $file) {
      if ($file->isFile() && preg_match('/^(.+)\.info\.yml$/', $file->getFilename(), $m)) {
        $names[$m[1]] = true;
      }
    }
  }
  return $names;
}

$known = scan_info_yml_machine_names([
  $root . '/web/core/modules',
  $root . '/web/core/profiles',
  $root . '/web/modules',
  $root . '/web/profiles',
]);

$orphanEnabled = [];
foreach (array_keys($enabled) as $machine) {
  if (!isset($known[$machine])) {
    $orphanEnabled[] = $machine;
  }
}
sort($orphanEnabled);

$hasPath = [];
$noPath = [];
$notInstalled = [];

foreach ($drupalModules as $name => $info) {
  $machine = preg_replace('#^drupal/#', '', $name);
  $constraint = $info['core_constraint'];
  $supportsD11 = $constraint !== null && preg_match('/(?:\^|~|>=?|<=?|\s|^)11(\.\d+)*/', $constraint);
  $row = sprintf('| `%s` | %s | %s |', $name, $info['version'], $constraint ?? '_(inherits root constraint)_');

  if (!isset($enabled[$machine])) {
    $notInstalled[] = $row;
  }
  elseif ($constraint === null || $supportsD11) {
    $hasPath[] = $row;
  }
  else {
    $noPath[] = $row;
  }
}

sort($hasPath);
sort($noPath);
sort($notInstalled);

function render_section(string $title, array $rows): void {
  echo "### {$title} (" . count($rows) . ")\n\n";
  if (!$rows) {
    echo "_None_\n\n";
    return;
  }
  echo "| Module | Locked version | drupal/core constraint |\n";
  echo "|---|---|---|\n";
  echo implode("\n", $rows) . "\n\n";
}

echo "_Enabled-module source: {$enabledResult['source']}._\n\n";

echo "### Orphan enabled modules — CRITICAL (" . count($orphanEnabled) . ")\n\n";
if (!$orphanEnabled) {
  echo "_None_\n\n";
}
else {
  echo "Enabled per the above source but no `*.info.yml` found anywhere under `web/core/modules`, `web/modules`, or `web/profiles`. ";
  echo "This blocks a full Drupal/Drush bootstrap (`ArgumentCountError`/`AssertionError` on module instantiation) and must be resolved before the upgrade — either restore the module code or uninstall it with `drush pm:uninstall` (see Phase 7.0 of the D10→D11 upgrade skill).\n\n";
  foreach ($orphanEnabled as $m) {
    echo "- `{$m}`\n";
  }
  echo "\n";
}

render_section('Has upgrade path (locked/available version already supports Drupal 11)', $hasPath);
render_section('No upgrade path yet (locked version caps below Drupal 11)', $noPath);
render_section('Not installed (composer package present, not enabled)', $notInstalled);

/**
 * Reads a handful of top-level `key: value` fields out of an *.info.yml
 * file without needing a full YAML parser (Drupal info files are flat).
 */
function read_info_yml(string $path): array {
  $info = [];
  foreach (file($path) as $line) {
    if (preg_match('/^([a-zA-Z0-9_]+):\s*(.+?)\s*$/', $line, $m)) {
      $info[$m[1]] = trim($m[2], "'\"");
    }
  }
  return $info;
}

/**
 * Lists every custom module/theme under $dir (one level of subdirectories,
 * each expected to contain a matching machine_name.info.yml).
 */
function list_custom_extensions(string $dir): array {
  $rows = [];
  if (!is_dir($dir)) {
    return $rows;
  }
  foreach (scandir($dir) as $entry) {
    if ($entry === '.' || $entry === '..' || !is_dir($dir . '/' . $entry)) {
      continue;
    }
    $infoFile = $dir . '/' . $entry . '/' . $entry . '.info.yml';
    $info = file_exists($infoFile) ? read_info_yml($infoFile) : [];
    $rows[$entry] = [
      'name' => $info['name'] ?? '(no .info.yml found)',
      'version' => $info['version'] ?? '-',
      'core_version_requirement' => $info['core_version_requirement'] ?? ($info['core'] ?? '-'),
    ];
  }
  ksort($rows);
  return $rows;
}

function render_custom_extension_table(string $title, array $rows, array $enabledSet, ?string $note = null): void {
  echo "### {$title} (" . count($rows) . ")\n\n";
  if ($note) {
    echo "{$note}\n\n";
  }
  if (!$rows) {
    echo "_None_\n\n";
    return;
  }
  echo "| Machine name | Name | Version | core_version_requirement | Enabled |\n";
  echo "|---|---|---|---|---|\n";
  foreach ($rows as $machine => $info) {
    $isEnabled = isset($enabledSet[$machine]) ? 'yes' : 'no';
    echo "| `{$machine}` | {$info['name']} | {$info['version']} | {$info['core_version_requirement']} | {$isEnabled} |\n";
  }
  echo "\n";
}

$customModules = list_custom_extensions($root . '/web/modules/custom');
$customThemes = list_custom_extensions($root . '/web/themes/custom');

echo "## Custom modules and themes\n\n";
render_custom_extension_table('Custom modules', $customModules, $enabled);

$themeNote = null;
if ($active['default_theme'] || $active['admin_theme']) {
  $themeNote = "Default theme: `{$active['default_theme']}` &nbsp;|&nbsp; Admin theme: `{$active['admin_theme']}`";
}
render_custom_extension_table('Custom themes', $customThemes, $enabledThemes, $themeNote);

/**
 * Core modules/themes removed in Drupal 11 (still present in D10 core).
 * Source: drupal-d10-to-d11-upgrade skill, Phase 2.
 */
$removedInD11 = [
  'ckeditor' => ['type' => 'module', 'replacement_package' => 'drupal/ckeditor', 'action' => 'Install drupal/ckeditor (compat shim) or migrate text formats to CKEditor 5'],
  'color' => ['type' => 'module', 'replacement_package' => 'drupal/color', 'action' => 'Install drupal/color contrib'],
  'classy' => ['type' => 'theme', 'replacement_package' => 'drupal/classy', 'action' => 'Install drupal/classy contrib (still used as a base theme)'],
  'stable' => ['type' => 'theme', 'replacement_package' => 'drupal/stable', 'action' => 'Install drupal/stable contrib (still used as a base theme)'],
  'aggregator' => ['type' => 'module', 'replacement_package' => null, 'action' => 'Remove, or replace with a contrib feed aggregator'],
  'book' => ['type' => 'module', 'replacement_package' => 'drupal/book', 'action' => 'Install drupal/book contrib'],
  'forum' => ['type' => 'module', 'replacement_package' => 'drupal/forum', 'action' => 'Remove, or install drupal/forum contrib'],
  'hal' => ['type' => 'module', 'replacement_package' => null, 'action' => 'Remove (rarely needed)'],
  'quickedit' => ['type' => 'module', 'replacement_package' => null, 'action' => 'Remove'],
  'rdf' => ['type' => 'module', 'replacement_package' => null, 'action' => 'Remove'],
  'statistics' => ['type' => 'module', 'replacement_package' => 'drupal/statistics', 'action' => 'Remove, or install drupal/statistics contrib'],
  'tour' => ['type' => 'module', 'replacement_package' => 'drupal/tour', 'action' => 'Remove, or install drupal/tour contrib'],
];

$allPackageNames = array_fill_keys(array_column($packages, 'name'), true);

$removedRows = [];
foreach ($removedInD11 as $machine => $info) {
  $isEnabled = $info['type'] === 'theme' ? isset($enabledThemes[$machine]) : isset($enabled[$machine]);
  if (!$isEnabled) {
    continue;
  }
  if ($info['replacement_package']) {
    $status = isset($allPackageNames[$info['replacement_package']])
      ? "Replacement already in composer.lock (`{$info['replacement_package']}`)"
      : "Not yet installed - `{$info['replacement_package']}` missing from composer.lock";
  }
  else {
    $status = 'No contrib replacement exists';
  }
  $removedRows[$machine] = [
    'type' => $info['type'],
    'action' => $info['action'],
    'status' => $status,
  ];
}
ksort($removedRows);

echo "## Drupal 11-removed core modules/themes still enabled (" . count($removedRows) . ")\n\n";
echo "Checked against the fixed Drupal 10 core removal list (ckeditor, color, classy, stable, aggregator, book, forum, hal, quickedit, rdf, statistics, tour). Only currently-enabled ones are listed - each must be resolved before the upgrade, since D11 core no longer ships them.\n\n";
if (!$removedRows) {
  echo "_None enabled._\n\n";
}
else {
  echo "| Machine name | Type | Recommended action | Status |\n";
  echo "|---|---|---|---|\n";
  foreach ($removedRows as $machine => $info) {
    echo "| `{$machine}` | {$info['type']} | {$info['action']} | {$info['status']} |\n";
  }
  echo "\n";
}
