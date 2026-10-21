// A breadcrumb the app records itself. Public.

/// How serious a breadcrumb is.
///
/// Crosses the bridge as the NAME, not a number: the two SDKs number their levels differently
/// (Android `Breadcrumb.Level` debug 1 .. fatal 5; iOS `BugseeLogLevel` error 1 .. debug 4, with
/// no `fatal`), so no single integer means the same on both, and each native side maps the name
/// itself. iOS stores [fatal] as `error`.
enum BreadcrumbLevel {
  debug,
  info,
  warning,
  error,

  /// Android has a rung for this; iOS records it as [error].
  fatal;

  /// The level for a name, or `null`.
  static BreadcrumbLevel? fromName(String? name) {
    for (final l in values) {
      if (l.name == name) return l;
    }
    return null;
  }
}

/// A trail entry the app adds to the report ("opened the cart", "navigated to /settings").
///
/// The SDK stamps the time. [data] takes what event parameters take (strings, numbers, bools,
/// null, lists and maps of them).
final class BugseeBreadcrumb {
  const BugseeBreadcrumb({
    required this.category,
    required this.message,
    this.level = BreadcrumbLevel.info,
    this.type = 'default',
    this.data,
  });

  /// A short grouping, e.g. `navigation`, `ui`, `http`.
  final String category;

  final String message;
  final BreadcrumbLevel level;

  /// The kind of entry, e.g. `default`, `user`, `navigation`, `error`.
  final String type;

  /// Extra values for the entry.
  final Map<String, Object?>? data;
}
