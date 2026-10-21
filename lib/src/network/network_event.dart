// The network event the Dart capture produces and a filter sees. Public (the filter's argument).
import 'dart:async' show FutureOr;

import 'package:meta/meta.dart';

final Stopwatch _monotonic = Stopwatch()..start();

/// Microseconds on this isolate's monotonic clock. Internal.
@internal
int monotonicMicros() => _monotonic.elapsedMicroseconds;

/// The stage of a request an event describes. The name is the SDKs' own wire name
/// (`network.json` `type`), except that iOS spells [abort] `cancel` (native maps it).
enum NetworkStage {
  /// The request left the app: URL, method, request headers, request body.
  before,

  /// The server answered with a redirect that the client followed. Android records each hop as its
  /// own entry; iOS has no such stage and carries the original URL on the final event
  /// ([BugseeNetworkEvent.redirectedFrom]), so those entries are not handed to the iOS SDK.
  redirect,

  /// The response arrived and its body ended: status, response headers, response body. Any HTTP
  /// status, including 4xx and 5xx: a server answering is not an error.
  complete,

  /// The request failed before or while the response arrived: no connection, a certificate
  /// refusal, a connection timeout, a connection closed mid-body.
  error,

  /// The app stopped before the exchange finished: it cancelled the response subscription or
  /// aborted the request.
  abort,
}

/// Why an event carries no body. The SDKs' own wire values (`custom.no_body_reason`).
enum NoBodyReason {
  noData('no_data'),

  /// Over `capture.network.body-size-limit` (the SDK drops such a body, it does not cut it).
  sizeTooLarge('size_too_large'),

  /// Not text (the SDKs keep `text/*`, JSON, XML and form-encoded bodies).
  unsupportedContentType('unsupported_content_type'),

  /// No `Content-Type` and `capture.network.body-without-type` is off (the default).
  noContentType('no_content_type'),

  /// Compressed, an unsupported charset, or bytes that are not valid text.
  cantReadData('cant_read_data');

  const NoBodyReason(this.wire);

  /// The value that crosses the bridge and appears in the bundle.
  final String wire;
}

/// One stage of one HTTP exchange captured from `dart:io`, as the SDK will record it.
///
/// This is what a [BugseeNetworkFilter] receives, **before** it reaches the SDK. [id], [stage],
/// [method] and [statusCode] describe what happened and cannot be changed; everything else is
/// the filter's to redact or rewrite, in place or on a copy it returns.
///
/// Header names are lower-case (the way `dart:io` reports them) and a header sent more than once
/// is one entry with its values joined by `, `.
final class BugseeNetworkEvent {
  BugseeNetworkEvent({
    required this.id,
    required this.stage,
    required this.method,
    required this.url,
    Map<String, String>? headers,
    this.body,
    this.noBodyReason,
    this.size = 0,
    this.statusCode = 0,
    this.statusText,
    this.error,
    this.errorDescription,
    this.redirectedFrom,
    this.timings,
  }) : headers = headers ?? <String, String>{},
       time = DateTime.now(),
       monotonicUs = monotonicMicros();

  /// Shared by every stage of one request. Never changes.
  final String id;

  /// Which stage this is. Never changes.
  final NetworkStage stage;

  /// The HTTP method of the request this stage belongs to. Never changes.
  final String method;

  /// HTTP status of the response, `0` for a stage that has none. Never changes.
  final int statusCode;

  /// The request or response size in bytes: the number of body bytes seen, whether or not they
  /// were kept; `0` when there was no body. Never changes.
  final int size;

  /// When it happened, on the device clock (informational: the SDK stamps its own clock).
  final DateTime time;

  /// The monotonic reading the SDK's timestamp is derived from. Internal.
  @internal
  final int monotonicUs;

  /// The full URL, query included. The SDK's default sanitizer redacts sensitive query
  /// parameters after this filter ran; a filter that needs different rules does it here.
  String url;

  /// Request headers for [NetworkStage.before], response headers for the stages that have a
  /// response. Mutable: remove or replace entries to redact.
  Map<String, String> headers;

  /// The body as text, or `null`. Only text within the SDK's size limit is ever present; see
  /// [noBodyReason] for why it is not.
  String? body;

  /// Why [body] is `null`, or `null` when there was no body to speak of or it is present.
  NoBodyReason? noBodyReason;

  /// The HTTP reason phrase (Android stores it, iOS does not).
  String? statusText;

  /// A short error text: `SocketException: Connection refused`. For [NetworkStage.error].
  String? error;

  /// The long form of [error] (Android stores it, iOS keeps only the short one).
  String? errorDescription;

  /// The URL the request started at, on the final stage of an exchange that was redirected.
  String? redirectedFrom;

  /// Phase durations in milliseconds (`ttfb`, `download`, `total`). Android only.
  Map<String, double>? timings;

  /// A deep copy: what a filter is handed, so that whatever it does to the headers map cannot
  /// reach anything the capture still holds.
  BugseeNetworkEvent copy() => BugseeNetworkEvent._copy(this);

  /// A copy that keeps WHEN the stage happened (both clock readings): what a filter is handed
  /// must still say when the exchange happened, not when the copy was made.
  BugseeNetworkEvent._copy(BugseeNetworkEvent o)
    : id = o.id,
      stage = o.stage,
      method = o.method,
      url = o.url,
      headers = Map<String, String>.of(o.headers),
      body = o.body,
      noBodyReason = o.noBodyReason,
      size = o.size,
      statusCode = o.statusCode,
      statusText = o.statusText,
      error = o.error,
      errorDescription = o.errorDescription,
      redirectedFrom = o.redirectedFrom,
      timings = o.timings == null ? null : Map<String, double>.of(o.timings!),
      time = o.time,
      monotonicUs = o.monotonicUs;

  @override
  String toString() =>
      'BugseeNetworkEvent(${stage.name} $method $id status $statusCode)';
}

/// A network filter: sees every event the Dart capture produced before it is handed to the SDK.
///
/// Return the event (modified in place, or a copy), or `null` to drop it. A filter that throws, or
/// a returned future that does not complete within the timeout given to `setNetworkFilter`, DROPS
/// the event: a redaction boundary fails closed. Runs on the isolate that made the request, one
/// event at a time and in order; see `Bugsee.setNetworkFilter`.
typedef BugseeNetworkFilter =
    FutureOr<BugseeNetworkEvent?> Function(BugseeNetworkEvent event);
