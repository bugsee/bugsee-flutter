// The endpoint override, normalised in ONE place (workbook 8.2). Internal.
//
// The workbook says the two SDKs spell it differently: iOS a flat `endpoint` key whose value
// includes the API version, Android `com.bugsee.option.$$ENDPOINT` without it. That was true of
// the 6.x iOS SDK. At the pinned iOS 7.0.0-beta7 (nextgen commit d33dcc987, "namespaced endpoint
// override with /v2 normalization"; `BGSURLResolver +normalizedAPIBase:`) iOS registers the same
// hidden `com.bugsee.option.$$ENDPOINT` (the options manifest lists it for both SDKs), keeps the
// flat `endpoint` only as a legacy alias, and strips every trailing API-version segment before
// appending its own. Android strips the same way (`apiUrl()`), so ONE version-less value under the
// ONE namespaced key is right for both, and that is what this sends. If a future SDK diverges
// again this is the only place that has to change (and `test/endpoint_test.dart` says what is
// expected of each platform).

/// The hidden option both SDKs read the endpoint from.
const String endpointOptionKey = 'com.bugsee.option.\$\$ENDPOINT';

/// The API version segment both SDKs append themselves.
const String _versionSegment = '/v2';

/// The value to send for [endpoint], or `null` when there is nothing to send (`null`, or only
/// whitespace: an empty override must not replace the SDK's own default with nothing).
///
/// Throws [ArgumentError] for something that is not an absolute http(s) URL with a host: the SDKs
/// would accept it and then fail every request, which looks like the server being down.
String? normalizeEndpoint(String? endpoint) {
  final trimmed = endpoint?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      !uri.hasScheme ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    throw ArgumentError.value(
      endpoint,
      'endpoint',
      'must be an absolute http or https URL, for example https://bugsee.example.com',
    );
  }
  if (uri.hasQuery || uri.hasFragment) {
    throw ArgumentError.value(
      endpoint,
      'endpoint',
      'must not carry a query or a fragment',
    );
  }
  // Trailing slashes and any number of trailing version segments (the SDKs strip a doubled one
  // too), so the version is appended exactly once, by the SDK. On the PATH only: a host that is
  // called `v2` is a host.
  var path = uri.path;
  while (true) {
    final before = path;
    path = path.replaceFirst(RegExp(r'/+$'), '');
    if (path.endsWith(_versionSegment)) {
      path = path.substring(0, path.length - _versionSegment.length);
    }
    if (path == before) break;
  }
  return uri.replace(path: path).toString();
}
