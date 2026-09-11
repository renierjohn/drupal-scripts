<?php
/**
 * Helper for the `ddev post-upgrade` command.
 * Prints '/admin' plus every enabled admin section, its direct child menu
 * links, and its tabs (local tasks) - e.g. Structure's children (Content
 * types, Taxonomy, Menus, Views, ...), Config's category pages
 * (/admin/config/system, /admin/config/media, ...), and tabs like People's
 * Permissions/Roles or Modules' Uninstall - one path per line, deduped.
 *
 * Two related but distinct APIs are involved:
 * - Menu links (Drupal\Core\Menu\MenuLinkTree): give the section pages
 *   themselves and their direct children. Top-level sections aren't
 *   reliably at menu depth 1: contrib modules like admin_toolbar_tools nest
 *   them one level deeper, under the 'system.admin' link itself, and inject
 *   extra depth-1 action links (flush caches, etc.) alongside it. So instead
 *   of trusting depth, this walks the tree by parent plugin ID: level 1 is
 *   whatever has 'system.admin' as its parent, level 2 is whatever has one
 *   of those level-1 links as its parent. This also naturally avoids the
 *   per-entity "add" explosion (e.g. one /node/add/{type} link per content
 *   type): those sit at level 3+, one level past what this script visits,
 *   and links only reachable through a toolbar action item never get
 *   traversed since that item itself isn't kept as a level-1 parent.
 * - Local tasks (Drupal\Core\Menu\LocalTaskManager): the tabs shown on a
 *   page, which for many admin pages (People, Appearance, Modules, Content)
 *   aren't menu links at all - only fetched for the top-level section pages,
 *   not recursively for every child, to keep this bounded.
 *
 * Both are gated behind permissions (e.g. "access administration pages"),
 * and drush php:script bootstraps as the anonymous user, so this temporarily
 * switches to uid 1 to run the access checks, then switches back.
 *
 * Requires a full Drupal bootstrap - run via:
 *   ddev drush php:script .ddev/commands/host/post-upgrade-admin-paths.php
 */

function post_upgrade_admin_paths_url(\Drupal\Core\Menu\MenuLinkInterface $link): ?string {
  try {
    $generated = $link->getUrlObject()->toString();
  }
  catch (\Throwable $e) {
    return NULL;
  }
  return post_upgrade_admin_paths_filter($generated);
}

function post_upgrade_admin_paths_filter(string $path): ?string {
  if ($path === '' || $path === '/' || str_contains($path, '?') || str_starts_with($path, 'http://') || str_starts_with($path, 'https://')) {
    // Empty/front-page (placeholder parent item), a token-bearing action
    // link (cache flush, cron run, logout), or external - skip.
    return NULL;
  }
  return $path;
}

$paths = ['/admin'];

$account_switcher = \Drupal::service('account_switcher');
$account_switcher->switchTo(\Drupal\user\Entity\User::load(1));

try {
  $parameters = new \Drupal\Core\Menu\MenuTreeParameters();
  $parameters->onlyEnabledLinks();
  $tree = \Drupal::menuTree()->load('admin', $parameters);
  $manipulators = [
    ['callable' => 'menu.default_tree_manipulators:checkAccess'],
    ['callable' => 'menu.default_tree_manipulators:flatten'],
  ];
  $tree = \Drupal::menuTree()->transform($tree, $manipulators);

  // Level 1: direct children of the /admin link itself (the section pages).
  $level1_ids = [];
  foreach ($tree as $element) {
    $link = $element->link;
    if (!$link->isEnabled() || $link->getParent() !== 'system.admin') {
      continue;
    }
    if ($path = post_upgrade_admin_paths_url($link)) {
      $paths[] = $path;
      $level1_ids[$link->getPluginId()] = TRUE;
    }
  }

  // Level 2: direct children of any kept level-1 section.
  foreach ($tree as $element) {
    $link = $element->link;
    if (!$link->isEnabled() || !isset($level1_ids[$link->getParent()])) {
      continue;
    }
    if ($path = post_upgrade_admin_paths_url($link)) {
      $paths[] = $path;
    }
  }

  // Tabs (local tasks) on each level-1 section page.
  $local_task_manager = \Drupal::service('plugin.manager.menu.local_task');
  $route_provider = \Drupal::service('router.route_provider');
  foreach (array_keys($level1_ids) as $route_name) {
    try {
      $route = $route_provider->getRouteByName($route_name);
    }
    catch (\Throwable $e) {
      continue;
    }
    $route_match = new \Drupal\Core\Routing\RouteMatch($route_name, $route, [], []);
    foreach (\Drupal::service('plugin.manager.menu.local_task')->getLocalTasksForRoute($route_name) as $level_tasks) {
      foreach ($level_tasks as $task) {
        try {
          $tab_route_parameters = $task->getRouteParameters($route_match);
          $generated = \Drupal\Core\Url::fromRoute($task->getRouteName(), $tab_route_parameters)->toString();
        }
        catch (\Throwable $e) {
          continue;
        }
        if ($path = post_upgrade_admin_paths_filter($generated)) {
          $paths[] = $path;
        }
      }
    }
  }
}
finally {
  $account_switcher->switchBack();
}

foreach (array_values(array_unique($paths)) as $path) {
  echo $path . "\n";
}
