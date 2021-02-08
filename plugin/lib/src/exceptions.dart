import 'dart:async';
import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:stack_trace/stack_trace.dart';

import 'options.dart';

class BugseeExceptionHandler {
  final MethodChannel _channel;
  bool _isInstalled = false;
  bool _isActive = false;

  bool get isUnhandledInterceptionActive => _isActive;

  BugseeExceptionHandler(MethodChannel channel) : _channel = channel {
    _installGlobalErrorHandler();
  }

  Future<Null> logException(dynamic exception, bool handled,
      [dynamic stackTrace]) async {
    if (!handled && !_isActive) {
      // check whether we should proceed with the provided exception.
      // If it's unhandled one, and we're not in an active state,
      // ignore it altogether.
      return Future.value(null);
    }

    final Chain chain = _getStackTraceChain(stackTrace);

    final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];

    var ds = new AccumulatorSink<Digest>();
    var s = sha1.startChunkedConversion(ds);
    for (int t = 0; t < chain.traces.length; t += 1) {
      for (int f = 0; f < chain.traces[t].frames.length; f += 1) {
        dynamic frame = chain.traces[t].frames[f];
        frames.add(_constructBugseeFrame(frame));
        s.add(utf8.encode(frame.location));
      }

      if (t < chain.traces.length - 1) {
        frames.add(<String, dynamic>{
          'trace': '<asynchronous gap>',
          'module': 'dart',
          'user': false,
        });
      }
    }
    s.close();

    await _sendException(exception, handled, frames, '${ds.events.single}');
  }

  Future<Null> _sendException(dynamic exception, bool handled,
      List<Map<String, dynamic>> frames, String signature) async {
    final dynamic ex = <String, dynamic>{
      'name': '${exception.runtimeType}',
      'reason': '$exception',
      'frames': frames,
      'signature': 'signature',
    };

    await _channel.invokeMethod('logException', <String, dynamic>{
      'name': 'FlutterManagedException',
      'reason': json.encode(ex),
      'handled': handled,
      'signature': signature,
    });
  }

  Map<String, dynamic> _constructBugseeFrame(dynamic frame) {
    dynamic uri = frame.uri;
    dynamic package = frame.package;
    bool user = true;

    if (uri.scheme != 'dart' && uri.scheme != 'package') {
      uri = frame.uri.pathSegments.last;
    }

    if (uri.scheme == 'hooks' || uri.scheme == 'dart' || package == 'flutter') {
      user = false;
    }

    if (package == null) {
      package = (uri.scheme == 'dart') ? 'dart' : 'application';
    }

    return <String, dynamic>{
      'trace': '${frame.member} ($uri:${frame.line})',
      'module': '$package',
      'user': user
    };
  }

  /// Get the stack chain for the specified stack trace or
  /// retrive current stack chain if no stack trace provided
  Chain _getStackTraceChain([dynamic stackTrace]) {
    Chain chain;

    if (stackTrace == null) {
      // we instruct the runtime to give us the stack chain with two
      // first frames skipped. This is required to exclude the calls
      // to this method and the one calling it (as this method is
      // marked as internal, it will be called from one of the
      // instance methods of this class)
      chain = Chain.current(2);
    } else {
      stackTrace = FlutterError.demangleStackTrace(stackTrace);
      chain = Chain.forTrace(stackTrace);
    }

    return chain;
  }

  void _installGlobalErrorHandler([bool force = false]) {
    if (_isInstalled && !force) {
      return;
    }

    final defaultOnError = FlutterError.onError;

    FlutterError.onError = (FlutterErrorDetails errorDetails) async {
      dynamic exception = errorDetails.exception;
      dynamic stack = errorDetails.stack;

      if (_isActive) {
        await logException(exception, false, stack);
      }

      // call original handler
      if (defaultOnError != null) {
        defaultOnError(errorDetails);
      }
    };

    _isInstalled = true;
  }

  void activateUnhandledInterception() {
    _isActive = true;
  }

  void deactivateUnhandledInterception() {
    _isActive = false;
  }

  void syncWithOptions(BugseeLaunchOptions? launchOptions) {
    if (launchOptions != null) {
      _isActive = launchOptions.crashReport;
    }
  }
}
