<?php
/**
 * Helper for the `ddev post-upgrade` command.
 * Prints a markdown table of dblog (watchdog) entries with severity
 * Emergency(0), Critical(2), or Error(3) logged at or after the given unix
 * timestamp. Reads the DB directly via PDO - no Drupal bootstrap required.
 *
 * Usage: php post-upgrade-watchdog.php <start_unix_timestamp>
 */

$startTs = isset($argv[1]) ? (int) $argv[1] : 0;

try {
  $pdo = new PDO('mysql:host=db;port=3306;dbname=db;charset=utf8mb4', 'db', 'db', [
    PDO::ATTR_TIMEOUT => 5,
  ]);
}
catch (\Throwable $e) {
  echo "_Could not connect to the database to read dblog: {$e->getMessage()}_\n";
  exit(0);
}

$stmt = $pdo->prepare(
  "SELECT wid, type, severity, timestamp, message, variables, location
   FROM watchdog
   WHERE severity IN (0, 2, 3) AND timestamp >= :ts
   ORDER BY timestamp ASC"
);
$stmt->execute([':ts' => $startTs]);
$rows = $stmt->fetchAll(PDO::FETCH_ASSOC);

if (!$rows) {
  echo "_None found._\n";
  exit(0);
}

$severityLabels = [0 => 'Emergency', 2 => 'Critical', 3 => 'Error'];

echo "| Severity | Type | Timestamp | Message | Location |\n";
echo "|---|---|---|---|---|\n";
foreach ($rows as $row) {
  $message = $row['message'];
  $vars = @unserialize($row['variables']);
  if (is_array($vars)) {
    $message = strtr($message, $vars);
  }
  $message = str_replace(["\r\n", "\n", "\r", '|'], [' ', ' ', ' ', '\\|'], (string) $message);
  if (strlen($message) > 300) {
    $message = substr($message, 0, 300) . '...';
  }
  $location = str_replace('|', '\\|', (string) $row['location']);
  $sev = $severityLabels[(int) $row['severity']] ?? $row['severity'];
  $ts = date('Y-m-d H:i:s', (int) $row['timestamp']);
  echo "| {$sev} | {$row['type']} | {$ts} | {$message} | {$location} |\n";
}
