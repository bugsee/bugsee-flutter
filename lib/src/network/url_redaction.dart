// What never leaves the process in a URL-bearing field, whatever the SDK's own sanitizer does.
// Internal.
//
// The SDKs' sanitizers strip a URL FIELD's userinfo and redact its sensitive query parameters,
// but they match header NAMES only and leave error texts alone, and the Android HTTP breadcrumb
// records the URL as given. So the wrapper removes what a report has no use for itself:
//  * userinfo (`user:password@`) in every URL it produces: the event's `url`, `redirectedFrom`,
//    URL-valued headers and error texts;
//  * the query VALUES of URL-valued headers (`location`, `content-location`, `referer`,
//    `refresh`), which no SDK sanitizes.

/// Header names whose value is (or contains) a URL.
const Set<String> urlValuedHeaders = {
  'location',
  'content-location',
  'referer',
  'refresh',
};

// Up to the LAST `@` of the authority (`Uri` takes userinfo that way: `u:p@ss@h` is user `u`,
// password `p@ss`); `/`, `?` and `#` end the authority, so it cannot run into the path.
final RegExp _userInfo = RegExp(r'''(://|//)[^\s/?#'"]*@''');
final RegExp _fragment = RegExp(r'''#[^\s'"]*''');
final RegExp _query = RegExp(r'''\?([^\s#'"]*)''');

/// [text] without the `user:password@` of any URL in it (an absolute `scheme://...@host` or a
/// scheme-relative `//...@host`).
String stripUserInfo(String text) =>
    text.replaceAllMapped(_userInfo, (m) => m[1]!);

final RegExp _urlQuery = RegExp(r'''(https?://[^\s?#'"]+)[?#][^\s'"]*''');

/// An error text can carry the URL of the request (`HttpException`'s `uri = ...`): userinfo and
/// query go. The SDK's sanitizer redacts a URL field, not the middle of a message.
String scrubErrorText(String text) => stripUserInfo(
  text,
).replaceAllMapped(_urlQuery, (m) => '${m[1]}?<redacted>');

/// [text] without any `#fragment`. A fragment never goes on the wire, but a redirect's `Location`
/// can carry one (OAuth callbacks put tokens there), and no SDK looks at it.
String stripFragment(String text) => text.replaceAll(_fragment, '');

/// [text] with every query parameter's value replaced by `<redacted>` (names kept).
String redactQueryValues(String text) => text.replaceAllMapped(_query, (m) {
  final parts = m[1]!.split('&').map((p) {
    final eq = p.indexOf('=');
    return eq < 0 ? p : '${p.substring(0, eq)}=<redacted>';
  });
  return '?${parts.join('&')}';
});

/// A header value as it may be recorded: URL-valued headers lose userinfo and query values.
String redactHeaderValue(String name, String value) =>
    urlValuedHeaders.contains(name)
    ? redactQueryValues(stripFragment(stripUserInfo(value)))
    : value;
