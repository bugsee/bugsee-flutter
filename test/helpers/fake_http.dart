// A client whose response data is a stream the test controls, behind the real classes' interfaces:
// what the capture does to pause, resume, cancel, errors and timing is observable without a socket.
// Only what the capture reads is implemented; anything else is a test error.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bugsee_flutter/src/network/http_capture.dart';

/// Real headers (the interface is large); the values are set by the test.
Future<HttpHeaders> realHeaders() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/'),
    );
    return request.headers;
  } finally {
    client.close(force: true);
    await server.close(force: true);
  }
}

class FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  FakeResponse(
    this.headers, {
    this.status = 200,
    this.redirectInfos = const [],
  });

  @override
  final HttpHeaders headers;
  final int status;
  final List<RedirectInfo> redirectInfos;

  /// The data the app will read: `add`, `addError`, `close` from the test.
  late final StreamController<List<int>> data = StreamController<List<int>>(
    sync: true,
    onListen: () => listens++,
    onCancel: () => cancels++,
    onPause: () => pauses++,
    onResume: () => resumes++,
  );

  int listens = 0;
  int cancels = 0;
  int pauses = 0;
  int resumes = 0;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => data.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  /// What `redirect()` answers (a response of the redirected request), if set.
  FakeResponse? redirectTo;

  @override
  Future<HttpClientResponse> redirect([
    String? method,
    Uri? url,
    bool? followLoops,
  ]) async => redirectTo!;

  @override
  int get statusCode => status;
  @override
  String get reasonPhrase => 'OK';
  @override
  int get contentLength => -1;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  bool get persistentConnection => true;
  @override
  bool get isRedirect => false;
  @override
  List<RedirectInfo> get redirects => redirectInfos;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakeResponse.${invocation.memberName}');
}

class FakeRedirectInfo implements RedirectInfo {
  FakeRedirectInfo(this.location);
  @override
  final Uri location;
  @override
  int get statusCode => 302;
  @override
  String get method => 'GET';
}

class FakeRequest implements HttpClientRequest {
  FakeRequest(this.headers, this.uri, this.response);

  @override
  final HttpHeaders headers;
  @override
  final Uri uri;
  final FakeResponse response;
  Object? closeFailure;
  int aborts = 0;

  @override
  String get method => 'GET';
  @override
  int contentLength = -1;
  @override
  Encoding encoding = utf8;

  @override
  Future<HttpClientResponse> close() async {
    final failure = closeFailure;
    if (failure != null) throw failure;
    return response;
  }

  @override
  Future<HttpClientResponse> get done => close();

  @override
  void abort([Object? exception, StackTrace? stackTrace]) => aborts++;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakeRequest.${invocation.memberName}');
}

class FakeClient implements HttpClient {
  FakeClient(this.request);

  final FakeRequest request;

  /// When set, opening waits for it (a connection that is still being made).
  Completer<void>? openGate;

  /// When set, opening fails with it.
  Object? failOpen;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    await openGate?.future;
    final failure = failOpen;
    if (failure != null) throw failure;
    return request;
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakeClient.${invocation.memberName}');
}

/// A captured client over a fake one, and the pieces to drive it.
class FakeRig {
  FakeRig._(this.controller, this.fake, this.response, this.client);

  final HttpCaptureController controller;
  final FakeClient fake;
  final FakeResponse response;
  final HttpClient client;

  static Future<FakeRig> create(
    HttpCaptureController controller, {
    Uri? url,
    int status = 200,
    String? contentType = 'text/plain',
  }) async {
    final headers = await realHeaders();
    if (contentType != null) headers.set('content-type', contentType);
    final response = FakeResponse(headers, status: status);
    final request = FakeRequest(
      headers,
      url ?? Uri.parse('http://example.test/x'),
      response,
    );
    final fake = FakeClient(request);
    final overrides = _FakeOverrides(fake);
    final client = HttpOverrides.runWithHttpOverrides(
      () => HttpClient(),
      BugseeHttpOverrides(controller, overrides),
    );
    return FakeRig._(controller, fake, response, client);
  }
}

class _FakeOverrides extends HttpOverrides {
  _FakeOverrides(this.client);
  final HttpClient client;
  @override
  HttpClient createHttpClient(SecurityContext? context) => client;
}
