<?php
/**
 * Helper for the `ddev ckeditor5-checklist` command.
 *
 * Detects whether CKEditor 4 is actually in use (any active text format's
 * editor.editor.* config has `editor: ckeditor`), and if so, finds every
 * module providing a CKEditor 4 plugin (Drupal's plugin discovery convention:
 * a class under <module>/src/Plugin/CKEditorPlugin/) and checks each for a
 * CKEditor 5 equivalent (a <module>.ckeditor5.yml plugin definition and/or a
 * class under <module>/src/Plugin/CKEditor5Plugin/).
 *
 * Reads the active DB config directly (PDO) plus the filesystem - no Drupal
 * bootstrap required. Prints a `CKEDITOR4: yes|no` marker as its first line.
 *
 * Run inside the web container:
 *   ddev exec php .ddev/commands/host/ckeditor5-checklist-scan.php
 */

$root = getcwd();

function get_pdo(): ?PDO {
  try {
    return new PDO('mysql:host=db;port=3306;dbname=db;charset=utf8mb4', 'db', 'db', [
      PDO::ATTR_TIMEOUT => 3,
    ]);
  }
  catch (\Throwable $e) {
    return null;
  }
}

$pdo = get_pdo();

// Editor assigned to each text format (format machine name => editor library id).
$editorFormats = [];
$formatSource = 'active database config';

if ($pdo) {
  $stmt = $pdo->query("SELECT name, data FROM config WHERE name LIKE 'editor.editor.%'");
  foreach ($stmt as $row) {
    $data = @unserialize($row['data']);
    if ($data && isset($data['editor'])) {
      $formatId = preg_replace('#^editor\.editor\.#', '', $row['name']);
      $editorFormats[$formatId] = $data['editor'];
    }
  }
}
else {
  $formatSource = 'config/default/editor.editor.*.yml (DB unreachable, fell back to sync export)';
  foreach (glob($root . '/config/default/editor.editor.*.yml') ?: [] as $file) {
    $formatId = preg_replace('#^.*editor\.editor\.(.+)\.yml$#', '$1', $file);
    foreach (file($file) as $line) {
      if (preg_match('/^editor:\s*(\S+)/', $line, $m)) {
        $editorFormats[$formatId] = trim($m[1], "'\"");
        break;
      }
    }
  }
}

// Enabled modules, for cross-referencing plugin-providing modules below.
$enabled = [];
if ($pdo) {
  $stmt = $pdo->query("SELECT data FROM config WHERE name = 'core.extension' LIMIT 1");
  $row = $stmt ? $stmt->fetch(PDO::FETCH_ASSOC) : FALSE;
  if ($row && ($data = @unserialize($row['data'])) && isset($data['module'])) {
    $enabled = $data['module'];
  }
}

$cke4Formats = array_keys(array_filter($editorFormats, fn($e) => $e === 'ckeditor'));
$cke4InUse = count($cke4Formats) > 0;

echo $cke4InUse ? "CKEDITOR4: yes\n" : "CKEDITOR4: no\n";

echo "_Text-format editor source: {$formatSource}._\n\n";
echo "## Text formats by editor\n\n";
if (!$editorFormats) {
  echo "_No text formats with an assigned editor found._\n\n";
}
else {
  echo "| Text format | Editor |\n|---|---|\n";
  ksort($editorFormats);
  foreach ($editorFormats as $fmt => $editor) {
    echo "| `{$fmt}` | `{$editor}` |\n";
  }
  echo "\n";
}

if (!$cke4InUse) {
  echo "No active text format uses the `ckeditor` (CKEditor 4) editor. Nothing further to check.\n";
  exit(0);
}

echo "CKEditor 4 is in use on: " . implode(', ', array_map(fn($f) => "`{$f}`", $cke4Formats)) . "\n\n";

/**
 * Finds every module providing a plugin of the given type, using Drupal's
 * plugin discovery directory convention: <module_root>/src/Plugin/<type>/*.php
 * Returns [module_root_dir => [class filenames]].
 */
function find_plugin_module_roots(string $root, string $pluginType): array {
  $results = [];
  $needle = '/src/Plugin/' . $pluginType . '/';
  foreach (['/web/core/modules', '/web/modules', '/web/profiles'] as $rel) {
    $base = $root . $rel;
    if (!is_dir($base)) {
      continue;
    }
    $iterator = new RecursiveIteratorIterator(
      new RecursiveDirectoryIterator($base, FilesystemIterator::SKIP_DOTS)
    );
    foreach ($iterator as $file) {
      if (!$file->isFile() || $file->getExtension() !== 'php') {
        continue;
      }
      $path = $file->getPathname();
      $pos = strpos($path, $needle);
      if ($pos === FALSE) {
        continue;
      }
      $moduleRoot = substr($path, 0, $pos);
      $results[$moduleRoot][] = basename($path);
    }
  }
  return $results;
}

$cke4Plugins = find_plugin_module_roots($root, 'CKEditorPlugin');
$cke5Plugins = find_plugin_module_roots($root, 'CKEditor5Plugin');

// Locked version + drupal/core constraint per package, for context.
$lockInfo = [];
$lockFile = $root . '/composer.lock';
if (file_exists($lockFile) && ($lock = json_decode(file_get_contents($lockFile), true))) {
  foreach (array_merge($lock['packages'] ?? [], $lock['packages-dev'] ?? []) as $pkg) {
    $lockInfo[$pkg['name']] = [
      'version' => $pkg['version'] ?? 'unknown',
      'core_constraint' => $pkg['require']['drupal/core'] ?? null,
    ];
  }
}

$rows = [];
foreach ($cke4Plugins as $moduleDir => $classFiles) {
  $machine = basename($moduleDir);
  $hasYml = (bool) glob($moduleDir . '/*.ckeditor5.yml');
  $hasCke5Class = isset($cke5Plugins[$moduleDir]);

  if ($hasYml) {
    $status = 'Compatible - has a CKEditor5 plugin definition (*.ckeditor5.yml)';
  }
  elseif ($hasCke5Class) {
    $status = 'Partially migrated - has a CKEditor5Plugin class but no *.ckeditor5.yml found (check manually)';
  }
  else {
    $status = 'NOT compatible - no CKEditor5 plugin found; needs migration or a replacement module';
  }

  $lock = $lockInfo["drupal/{$machine}"] ?? null;

  $rows[$machine] = [
    'classes' => $classFiles,
    'status' => $status,
    'enabled' => isset($enabled[$machine]),
    'version' => $lock['version'] ?? '-',
    'core_constraint' => $lock['core_constraint'] ?? '-',
  ];
}
ksort($rows);

echo "## CKEditor 4 plugin-providing modules (" . count($rows) . ")\n\n";
if (!$rows) {
  echo "_None found under web/core/modules, web/modules, or web/profiles (src/Plugin/CKEditorPlugin/)._\n\n";
}
else {
  echo "| Module | Enabled | Locked version | drupal/core constraint | CKEditor4 plugin class(es) | CKEditor5 status |\n";
  echo "|---|---|---|---|---|---|\n";
  foreach ($rows as $machine => $info) {
    $classes = implode(', ', array_map(fn($c) => "`{$c}`", $info['classes']));
    $enabledStr = $info['enabled'] ? 'yes' : 'no';
    echo "| `{$machine}` | {$enabledStr} | {$info['version']} | {$info['core_constraint']} | {$classes} | {$info['status']} |\n";
  }
  echo "\n";
}

$needsMigration = array_filter($rows, fn($r) => str_starts_with($r['status'], 'NOT compatible'));
echo "### Summary\n\n";
echo "- CKEditor 4 plugin-providing modules found: " . count($rows) . "\n";
echo "- Already have a CKEditor 5 plugin definition: " . count(array_filter($rows, fn($r) => str_starts_with($r['status'], 'Compatible'))) . "\n";
echo "- Needs migration or replacement: " . count($needsMigration) . "\n";
if ($needsMigration) {
  echo "\nModules needing attention: " . implode(', ', array_map(fn($m) => "`{$m}`", array_keys($needsMigration))) . "\n";
}
