// What the SDK would do with a network event, as far as the wrapper needs to know before it sends
// one (doc/network.md). Internal.
import '../options/endpoint.dart';

/// The option keys the policy reads, all registered by both SDKs (the vendored manifests; a test
/// compares the key, the type and the default).
abstract final class NetworkOptionKeys {
  static const capture = 'com.bugsee.option.capture.network';
  static const bodySizeLimit =
      'com.bugsee.option.capture.network.body-size-limit';
  static const bodyWithoutType =
      'com.bugsee.option.capture.network.body-without-type';
}

/// What the capture may do right now. Immutable; replaced as the SDK's status changes.
final class NetworkPolicy {
  const NetworkPolicy({
    this.accepting = false,
    this.bodySizeLimit = defaultBodySizeLimit,
    this.bodyWithoutType = false,
    this.ownHosts = const <String>{},
  });

  /// Nothing is captured: the SDK is not launched, or `capture.network` is off.
  static const NetworkPolicy off = NetworkPolicy();

  /// `capture.network.body-size-limit`'s default on both SDKs (20 KiB).
  static const int defaultBodySizeLimit = 20480;

  /// The most of one body this capture ever keeps, whatever `capture.network.body-size-limit`
  /// says: memory is this times the requests in flight, and the queue's byte budget (8 MiB) must
  /// hold at least a couple of events. A body over it is `size_too_large`, as if it were over the
  /// limit (the SDK would have kept it: the only place this differs from the option).
  static const int maxBodyBytes = 2 * 1024 * 1024;

  /// The SDK is `launched` and `capture.network` is on. Only then is anything captured: Android
  /// would accept events while `launching` (into a 32-entry buffer) but iOS drops them, and
  /// "do not send what the SDK would drop" is the one rule both can meet.
  final bool accepting;

  /// `capture.network.body-size-limit`, in bytes: a body longer than this is dropped (not cut) by
  /// the SDK, so the capture never buffers more than this many bytes of one body.
  final int bodySizeLimit;

  /// `capture.network.body-without-type`: keep a body that has no `Content-Type`.
  final bool bodyWithoutType;

  /// Hosts (lower-case, no port) whose traffic is the SDK's own and is never captured, besides
  /// `bugsee.com` and its subdomains.
  final Set<String> ownHosts;

  /// The same policy with nothing accepted: the SDK stopped or is stopping, so what is in flight
  /// is not handed over, while the own-host rule keeps holding.
  NetworkPolicy notAccepting() => NetworkPolicy(
    bodySizeLimit: bodySizeLimit,
    bodyWithoutType: bodyWithoutType,
    ownHosts: ownHosts,
  );

  /// Reads the options the SDK reports ([options]: what `getLaunchOptions` returned, hidden keys
  /// included) and the status.
  factory NetworkPolicy.from(
    Map<String, Object?> options, {
    required bool launched,
  }) {
    final capture = options[NetworkOptionKeys.capture];
    final limit = options[NetworkOptionKeys.bodySizeLimit];
    final withoutType = options[NetworkOptionKeys.bodyWithoutType];
    final endpoint = options[endpointOptionKey];
    final hosts = <String>{};
    if (endpoint is String) {
      final host = Uri.tryParse(endpoint)?.host.toLowerCase();
      if (host != null && host.isNotEmpty) hosts.add(host);
    }
    return NetworkPolicy(
      // The option's own default is on.
      accepting: launched && (capture is! bool || capture),
      bodySizeLimit: limit is int
          ? (limit > maxBodyBytes ? maxBodyBytes : limit)
          : defaultBodySizeLimit,
      bodyWithoutType: withoutType is bool && withoutType,
      ownHosts: Set.unmodifiable(hosts),
    );
  }

  /// Whether [url] is Bugsee's own: the configured endpoint's host, or `bugsee.com` and below.
  /// Compared by host, never by port or path, and never captured.
  bool isOwnTraffic(Uri url) {
    // `bugsee.com.` (a trailing dot) is the same host.
    var host = url.host.toLowerCase();
    while (host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }
    if (host.isEmpty) return false;
    return host == 'bugsee.com' ||
        host.endsWith('.bugsee.com') ||
        ownHosts.contains(host);
  }
}
