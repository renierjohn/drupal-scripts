<?php
/**
 * Helper for the `ddev post-upgrade` command.
 * Prints '/' plus every enabled internal link in the 'main' menu, one path
 * per line, deduped. External links and empty/placeholder links (parent
 * items with no route of their own) are skipped.
 *
 * Requires a full Drupal bootstrap - run via:
 *   ddev drush php:script .ddev/commands/host/post-upgrade-menu-links.php
 */

$paths = ['/'];

$parameters = new \Drupal\Core\Menu\MenuTreeParameters();
$parameters->onlyEnabledLinks();
$tree = \Drupal::menuTree()->load('main', $parameters);
$manipulators = [
  ['callable' => 'menu.default_tree_manipulators:checkAccess'],
  ['callable' => 'menu.default_tree_manipulators:flatten'],
];
$tree = \Drupal::menuTree()->transform($tree, $manipulators);

foreach ($tree as $element) {
  $link = $element->link;
  if (!$link->isEnabled()) {
    continue;
  }
  try {
    $generated = $link->getUrlObject()->toString();
  }
  catch (\Throwable $e) {
    continue;
  }
  if ($generated === '' || str_starts_with($generated, 'http://') || str_starts_with($generated, 'https://')) {
    // Empty (placeholder parent item) or external - skip.
    continue;
  }
  $paths[] = $generated;
}

foreach (array_values(array_unique($paths)) as $path) {
  echo $path . "\n";
}
