// Capture of everything built on `dart:io`'s `HttpClient`, through `HttpOverrides` (Phase 5b).
// Internal: the public entry points are on `Bugsee`.
//
// The contract this file keeps, and `test/http_capture_test.dart` pins:
//  * the app's own overrides are chained to, never replaced: clients are created by the previous
//    overrides, proxy resolution is theirs, and every setting (`badCertificateCallback`,
//    `findProxy`, `connectionFactory`, credentials, ...) is passed straight through to the client
//    they made;
//  * behaviour and timing are the inner client's: every call is forwarded as it is, responses are
//    forwarded chunk by chunk with the same pause/resume/cancel semantics, and a failure of the
//    capture itself is swallowed (never thrown into the app, never changes a result);
//  * memory is bounded: a body is copied only while it is text and within the SDK's size limit,
//    and counted without copying beyond that, whatever its size;
//  * Bugsee's own traffic is never captured.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'body_capture.dart';
import 'network_event.dart';
import 'network_policy.dart';

/// The shared state of the capture: what it may do right now, where events go.
final class HttpCaptureController {
  HttpCaptureController({required this.policy, required this.record});

  /// What the SDK would accept now. Read at the start of each request: a request that began while
  /// the SDK was not launched is never captured, one that began while it was is captured to the
  /// end (the pipeline drops what the SDK no longer accepts when it hands it over).
  final NetworkPolicy Function() policy;

  /// Receives every event, synchronously, and must not throw (a throw is swallowed).
  final void Function(BugseeNetworkEvent event) record;

  /// False once uninstalled: clients that already exist keep forwarding but record nothing.
  bool active = true;

  final String _prefix = Random()
      .nextInt(1 << 32)
      .toRadixString(16)
      .padLeft(8, '0');
  int _counter = 0;

  /// Unique within the process (a random per-isolate prefix, so a hot restart cannot reuse one).
  String nextId() => '$_prefix-${++_counter}';

  void emit(BugseeNetworkEvent event) {
    try {
      record(event);
    } catch (_) {
      // Capture must never throw into the app.
    }
  }
}

/// `HttpOverrides` that wraps every client in a capturing one and delegates everything else to
/// the overrides that were installed before (or to the platform's default).
final class BugseeHttpOverrides extends HttpOverrides {
  BugseeHttpOverrides(this._controller, this._previous);

  final HttpCaptureController _controller;
  final HttpOverrides? _previous;

  /// The overrides this one chains to (for a test and for uninstalling).
  HttpOverrides? get previous => _previous;

  HttpCaptureController get controller => _controller;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final previous = _previous;
    final HttpClient inner;
    try {
      inner = previous != null
          ? previous.createHttpClient(context)
          : super.createHttpClient(context);
    } catch (_) {
      // The app's own overrides refused to make a client: that is their behaviour, not ours.
      rethrow;
    }
    // A layer further down the chain already captures this client: wrapping again would record
    // every request twice.
    if (inner is CapturingHttpClient || !_controller.active) return inner;
    return CapturingHttpClient(inner, _controller);
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    final previous = _previous;
    return previous != null
        ? previous.findProxyFromEnvironment(url, environment)
        : super.findProxyFromEnvironment(url, environment);
  }
}

/// Whether a client created now would be captured: the capture's overrides are the ones in
/// effect in this zone (the app may have replaced them without chaining, or be inside a zone that
/// scopes its own).
bool isHttpCaptureInEffect() {
  HttpClient? probe;
  try {
    probe = HttpClient();
    return probe is CapturingHttpClient;
  } catch (_) {
    return false;
  } finally {
    try {
      probe?.close(force: true);
    } catch (_) {}
  }
}

String _errorShort(Object error) {
  var text = _scrub(error.toString());
  final newline = text.indexOf('\n');
  if (newline >= 0) text = text.substring(0, newline);
  if (text.length > 200) text = '${text.substring(0, 200)}...';
  return text;
}

String _errorLong(Object error) {
  final text = _scrub(error.toString());
  return text.length > 2000 ? '${text.substring(0, 2000)}...' : text;
}

final RegExp _urlQuery = RegExp(r'''(https?://[^\s?#'"]+)[?#][^\s'"]*''');

/// An error text can carry the URL of the request (`HttpException`'s `uri = ...`), query and all.
/// The SDK's sanitizer redacts a URL field, not the middle of a message, so the query goes here.
String _scrub(String text) =>
    text.replaceAllMapped(_urlQuery, (m) => '${m[1]}?<redacted>');

Map<String, String> _headersOf(HttpHeaders headers) {
  final map = <String, String>{};
  headers.forEach((name, values) => map[name] = values.join(', '));
  return map;
}

/// One HTTP exchange being captured, from `open` to the end of the response.
final class _Exchange {
  _Exchange(this.ctl, this.policy, this.method, this.url, this.startedUs)
    : id = ctl.nextId();

  final HttpCaptureController ctl;
  final NetworkPolicy policy;
  final String method;
  final Uri url;
  final int startedUs;
  final String id;

  bool _beforeSent = false;
  bool _terminal = false;
  int? _closedUs;
  int? _headersUs;
  bool _redirectsSent = false;

  bool get terminal => _terminal;

  void _emit(
    NetworkStage stage, {
    String? method,
    Uri? url,
    Map<String, String>? headers,
    BodyOutcome? body,
    int size = 0,
    int statusCode = 0,
    String? statusText,
    Object? error,
    String? redirectedFrom,
    Map<String, double>? timings,
  }) {
    ctl.emit(
      BugseeNetworkEvent(
        id: id,
        stage: stage,
        method: method ?? this.method,
        url: (url ?? this.url).toString(),
        headers: headers,
        body: body?.body,
        noBodyReason: body?.reason,
        size: size,
        statusCode: statusCode,
        statusText: statusText,
        error: error == null ? null : _errorShort(error),
        errorDescription: error == null ? null : _errorLong(error),
        redirectedFrom: redirectedFrom,
        timings: timings,
      ),
    );
  }

  double _ms(int fromUs, int toUs) => (toUs - fromUs) / 1000.0;

  /// The request left the app: once, from `close()`, an abort or a failure that came first.
  void before({
    Map<String, String>? headers,
    BodyTee? tee,
    String? contentType,
  }) {
    if (_beforeSent) return;
    _beforeSent = true;
    _closedUs = monotonicMicros();
    BodyOutcome? body;
    if (tee != null) {
      body = resolveBody(
        tee: tee,
        contentType: contentType,
        bodyWithoutType: policy.bodyWithoutType,
        encoded: false,
        isRequest: true,
      );
    }
    _emit(
      NetworkStage.before,
      headers: headers,
      body: body,
      size: tee?.size ?? 0,
    );
  }

  /// The final URL and method after the redirects `dart:io` followed.
  (Uri, String) _final(List<RedirectInfo> redirects) {
    var current = url;
    var currentMethod = method;
    for (final hop in redirects) {
      current = current.resolveUri(hop.location);
      currentMethod = hop.method;
    }
    return (current, currentMethod);
  }

  /// The response headers arrived. Records each redirect hop (once) and returns nothing: the
  /// final stage is [complete].
  void responseStarted(List<RedirectInfo> redirects) {
    _headersUs ??= monotonicMicros();
    if (_redirectsSent) return;
    _redirectsSent = true;
    var current = url;
    var hopMethod = method;
    for (final hop in redirects) {
      final next = current.resolveUri(hop.location);
      _emit(
        NetworkStage.redirect,
        method: hopMethod,
        url: current,
        statusCode: hop.statusCode,
        headers: {'location': next.toString()},
      );
      current = next;
      hopMethod = hop.method;
    }
  }

  void complete(HttpClientResponse response, BodyTee tee, bool encoded) {
    if (_terminal) return;
    _terminal = true;
    final nowUs = monotonicMicros();
    final (finalUrl, finalMethod) = _final(response.redirects);
    final body = resolveBody(
      tee: tee,
      contentType: response.headers.value(HttpHeaders.contentTypeHeader),
      bodyWithoutType: policy.bodyWithoutType,
      encoded: encoded,
      isRequest: false,
    );
    _emit(
      NetworkStage.complete,
      method: finalMethod,
      url: finalUrl,
      headers: _headersOf(response.headers),
      body: body,
      size: tee.size,
      statusCode: response.statusCode,
      statusText: response.reasonPhrase,
      redirectedFrom: response.redirects.isEmpty ? null : url.toString(),
      timings: _timings(nowUs),
    );
  }

  /// Complete without reading the body: a response whose socket the app took (a WebSocket upgrade)
  /// has no body for the HTTP layer to see.
  void completeWithoutBody(HttpClientResponse response) {
    complete(response, BodyTee(limit: 0, keep: false), false);
  }

  void fail(Object error) {
    if (_terminal) return;
    _terminal = true;
    if (!_beforeSent) before();
    _emit(
      NetworkStage.error,
      error: error,
      timings: {'total': _ms(startedUs, monotonicMicros())},
    );
  }

  void abort({int size = 0}) {
    if (_terminal) return;
    _terminal = true;
    if (!_beforeSent) before();
    _emit(
      NetworkStage.abort,
      size: size,
      timings: {'total': _ms(startedUs, monotonicMicros())},
    );
  }

  Map<String, double> _timings(int endUs) {
    final closed = _closedUs;
    final headers = _headersUs;
    return {
      if (closed != null && headers != null) 'ttfb': _ms(closed, headers),
      if (headers != null) 'download': _ms(headers, endUs),
      'total': _ms(startedUs, endUs),
    };
  }
}

/// A client that records every exchange and forwards everything to [_inner] unchanged.
///
/// Every member of `HttpClient` is forwarded (a test lists them, so a new one in a newer SDK
/// fails to compile here rather than silently not being forwarded).
final class CapturingHttpClient implements HttpClient {
  CapturingHttpClient(this._inner, this._ctl);

  final HttpClient _inner;
  final HttpCaptureController _ctl;

  /// The client this one wraps, for tests.
  HttpClient get inner => _inner;

  Future<HttpClientRequest> _track(
    Future<HttpClientRequest> opening,
    String method,
    Uri? knownUrl,
  ) {
    final int startedUs;
    final NetworkPolicy policy;
    try {
      if (!_ctl.active) return opening;
      policy = _ctl.policy();
      if (!policy.accepting) return opening;
      if (knownUrl != null && policy.isOwnTraffic(knownUrl)) return opening;
      startedUs = monotonicMicros();
    } catch (_) {
      return opening;
    }
    return opening.then<HttpClientRequest>(
      (request) {
        try {
          if (policy.isOwnTraffic(request.uri)) return request;
          return CapturedRequest._(
            request,
            _Exchange(_ctl, policy, request.method, request.uri, startedUs),
          );
        } catch (_) {
          return request;
        }
      },
      onError: (Object error, StackTrace stack) {
        // No connection, a refused certificate, a connection timeout: the request never existed.
        try {
          if (knownUrl != null) {
            _Exchange(_ctl, policy, method, knownUrl, startedUs).fail(error);
          }
        } catch (_) {}
        Error.throwWithStackTrace(error, stack);
      },
    );
  }

  Uri? _uriOf(String host, int port, String path) {
    try {
      return Uri(scheme: 'http', host: host, port: port, path: path);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) => _track(
    _inner.open(method, host, port, path),
    method,
    _uriOf(host, port, path),
  );

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _track(_inner.openUrl(method, url), method, url);

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _track(_inner.get(host, port, path), 'GET', _uriOf(host, port, path));

  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      _track(_inner.getUrl(url), 'GET', url);

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _track(_inner.post(host, port, path), 'POST', _uriOf(host, port, path));

  @override
  Future<HttpClientRequest> postUrl(Uri url) =>
      _track(_inner.postUrl(url), 'POST', url);

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _track(_inner.put(host, port, path), 'PUT', _uriOf(host, port, path));

  @override
  Future<HttpClientRequest> putUrl(Uri url) =>
      _track(_inner.putUrl(url), 'PUT', url);

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _track(
        _inner.delete(host, port, path),
        'DELETE',
        _uriOf(host, port, path),
      );

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) =>
      _track(_inner.deleteUrl(url), 'DELETE', url);

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _track(_inner.patch(host, port, path), 'PATCH', _uriOf(host, port, path));

  @override
  Future<HttpClientRequest> patchUrl(Uri url) =>
      _track(_inner.patchUrl(url), 'PATCH', url);

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _track(_inner.head(host, port, path), 'HEAD', _uriOf(host, port, path));

  @override
  Future<HttpClientRequest> headUrl(Uri url) =>
      _track(_inner.headUrl(url), 'HEAD', url);

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;

  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? f,
  ) => _inner.authenticate = f;

  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addCredentials(url, realm, credentials);

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )?
    f,
  ) => _inner.connectionFactory = f;

  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;

  @override
  set authenticateProxy(
    Future<bool> Function(String host, int port, String scheme, String? realm)?
    f,
  ) => _inner.authenticateProxy = f;

  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addProxyCredentials(host, port, realm, credentials);

  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? callback,
  ) => _inner.badCertificateCallback = callback;

  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

/// A request that records what is written to it and forwards everything to the real one.
final class CapturedRequest implements HttpClientRequest {
  CapturedRequest._(this._inner, this._exchange);

  final HttpClientRequest _inner;
  final _Exchange _exchange;
  BodyTee? _tee;
  Future<HttpClientResponse>? _closed;
  _CapturedResponse? _response;

  /// The request this one wraps, for tests.
  HttpClientRequest get inner => _inner;

  void _teeBytes(List<int> chunk) {
    try {
      var tee = _tee;
      if (tee == null) {
        final length = _inner.contentLength;
        final type = _inner.headers.value(HttpHeaders.contentTypeHeader);
        tee = _tee = BodyTee(
          limit: _exchange.policy.bodySizeLimit,
          declaredLength: length >= 0 ? length : null,
          keep: shouldBufferBody(
            contentType: type,
            bodyWithoutType: _exchange.policy.bodyWithoutType,
            encoded: false,
          ),
        );
      }
      tee.add(chunk);
    } catch (_) {}
  }

  void _teeText(String text) {
    try {
      // Only what the body can still keep is encoded a second time; a string already past the
      // limit is counted by its UTF-8 length without keeping it.
      _teeBytes(_inner.encoding.encode(text));
    } catch (_) {}
  }

  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;

  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool value) => _inner.followRedirects = value;

  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int value) => _inner.maxRedirects = value;

  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int value) => _inner.contentLength = value;

  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;

  @override
  String get method => _inner.method;

  @override
  Uri get uri => _inner.uri;

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;

  /// The response, wrapped the same way whichever way the app asks for it ([close] or [done]).
  HttpClientResponse _wrap(HttpClientResponse response) {
    try {
      final existing = _response;
      if (existing != null && identical(existing._inner, response)) {
        return existing;
      }
      _exchange.responseStarted(response.redirects);
      // A WebSocket upgrade (101) goes through here too: the stream is only wrapped lazily, on
      // listen, so `detachSocket` still reaches the real socket and completes the exchange.
      return _response = _CapturedResponse(response, _exchange);
    } catch (_) {
      return response;
    }
  }

  Map<String, String>? _headersForBefore() {
    try {
      return _headersOf(_inner.headers);
    } catch (_) {
      return null;
    }
  }

  void _sendBefore() {
    try {
      _exchange.before(
        headers: _headersForBefore(),
        tee: _tee,
        contentType: _inner.headers.value(HttpHeaders.contentTypeHeader),
      );
    } catch (_) {}
  }

  @override
  Future<HttpClientResponse> close() {
    final cached = _closed;
    if (cached != null) return cached;
    _sendBefore();
    final Future<HttpClientResponse> future = _inner.close();
    return _closed = future.then<HttpClientResponse>(
      _wrap,
      onError: (Object error, StackTrace stack) {
        try {
          _exchange.fail(error);
        } catch (_) {}
        Error.throwWithStackTrace(error, stack);
      },
    );
  }

  Future<HttpClientResponse>? _done;

  @override
  Future<HttpClientResponse> get done =>
      _done ??= _inner.done.then<HttpClientResponse>(
        _wrap,
        onError: (Object error, StackTrace stack) {
          try {
            _exchange.fail(error);
          } catch (_) {}
          Error.throwWithStackTrace(error, stack);
        },
      );

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    try {
      _exchange.abort(size: _tee?.size ?? 0);
    } catch (_) {}
    _inner.abort(exception, stackTrace);
  }

  @override
  void add(List<int> data) {
    _inner.add(data);
    _teeBytes(data);
  }

  @override
  void write(Object? object) {
    _inner.write(object);
    _teeText('$object');
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    // The iterable may be a one-shot generator: it is walked once, here, like `IOSink` does.
    var first = true;
    for (final object in objects) {
      if (!first && separator.isNotEmpty) write(separator);
      write(object);
      first = false;
    }
  }

  @override
  void writeln([Object? object = '']) {
    write(object);
    write('\n');
  }

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) => _inner.addStream(
    stream.map((chunk) {
      _teeBytes(chunk);
      return chunk;
    }),
  );

  @override
  Future<dynamic> flush() => _inner.flush();
}

/// A response whose body is forwarded chunk by chunk and copied (bounded) on the way.
final class _CapturedResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _CapturedResponse(this._inner, this._exchange) {
    final policy = _exchange.policy;
    final type = _inner.headers.value(HttpHeaders.contentTypeHeader);
    // Still compressed: the client did not undo the encoding, so the bytes are not text.
    _encoded =
        _inner.compressionState ==
        HttpClientResponseCompressionState.compressed;
    final length = _inner.contentLength;
    _tee = BodyTee(
      limit: policy.bodySizeLimit,
      // The declared length is the compressed one when the client decompresses, so only an
      // uncompressed body can be dismissed by it.
      declaredLength:
          length >= 0 &&
              _inner.compressionState ==
                  HttpClientResponseCompressionState.notCompressed
          ? length
          : null,
      keep: shouldBufferBody(
        contentType: type,
        bodyWithoutType: policy.bodyWithoutType,
        encoded: _encoded,
      ),
    );
  }

  final HttpClientResponse _inner;
  final _Exchange _exchange;
  late final BodyTee _tee;
  late final bool _encoded;
  Stream<List<int>>? _stream;
  bool _passedOn = false;

  void _observe(List<int> chunk) {
    try {
      _tee.add(chunk);
    } catch (_) {}
  }

  Stream<List<int>> _build() {
    late final StreamController<List<int>> controller;
    StreamSubscription<List<int>>? subscription;
    controller = StreamController<List<int>>(
      sync: true,
      onListen: () {
        subscription = _inner.listen(
          (chunk) {
            _observe(chunk);
            controller.add(chunk);
          },
          onError: (Object error, StackTrace stack) {
            try {
              _exchange.fail(error);
            } catch (_) {}
            controller.addError(error, stack);
          },
          onDone: () {
            try {
              if (!_passedOn) _exchange.complete(_inner, _tee, _encoded);
            } catch (_) {}
            controller.close();
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        try {
          // The app stopped reading before the end (and nothing failed): an abort, with what was
          // seen so far. A cancel after the end is not one.
          if (!_passedOn) _exchange.abort(size: _tee.size);
        } catch (_) {}
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    // Single subscription, like the response it wraps: a second listen fails the same way.
    return (_stream ??= _build()).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  int get statusCode => _inner.statusCode;

  @override
  String get reasonPhrase => _inner.reasonPhrase;

  @override
  int get contentLength => _inner.contentLength;

  @override
  HttpClientResponseCompressionState get compressionState =>
      _inner.compressionState;

  @override
  bool get persistentConnection => _inner.persistentConnection;

  @override
  bool get isRedirect => _inner.isRedirect;

  @override
  List<RedirectInfo> get redirects => _inner.redirects;

  @override
  Future<HttpClientResponse> redirect([
    String? method,
    Uri? url,
    bool? followLoops,
  ]) {
    // The app follows this redirect itself: `dart:io` drains this response's body on its own
    // (never through this wrapper), and the new response carries the exchange on (its `redirects`
    // list holds this hop).
    return _inner.redirect(method, url, followLoops).then<HttpClientResponse>((
      next,
    ) {
      try {
        _exchange.responseStarted(next.redirects);
        return _CapturedResponse(next, _exchange);
      } catch (_) {
        return next;
      }
    });
  }

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  Future<Socket> detachSocket() {
    // The HTTP layer will never see a body for this response (a WebSocket upgrade takes the
    // socket): the exchange is what it is now.
    try {
      if (!_passedOn) _exchange.completeWithoutBody(_inner);
      _passedOn = true;
    } catch (_) {}
    return _inner.detachSocket();
  }

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  X509Certificate? get certificate => _inner.certificate;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
}
