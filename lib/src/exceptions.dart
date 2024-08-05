import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:stack_trace/stack_trace.dart';

import 'options.dart';
import 'version.dart';
import 'exceptions_classifier.dart';

class BugseeExceptionHandler {
  static final BugseeExceptionHandler _defaultHandler =
      BugseeExceptionHandler();

  final MethodChannel _channel = const MethodChannel('bugsee');
  bool _isInstalled = false;
  bool _isActive = false;

  bool get isUnhandledInterceptionActive => _isActive;

  static BugseeExceptionHandler get defaultHandler => _defaultHandler;

  RawReceivePort createErrorHandlingPort() {
    return RawReceivePort(
      (dynamic error) async {
        Isolate.current.setErrorsFatal(false);
        await logIsolateError(error);
      },
    );
  }

  RawReceivePort addIsolateErrorListener(Isolate isolate) {
    final port = createErrorHandlingPort();
    isolate.addErrorListener(port.sendPort);
    return port;
  }

  /// Log an unhandled error from [Isolate]
  Future<void> logIsolateError(dynamic error, [bool handled = true]) async {
    /// Per https://api.dartlang.org/stable/2.7.0/dart-isolate/Isolate/addErrorListener.html
    /// --------------------------------------------------
    /// The errors are sent back as two elements lists. The first
    /// element is a String representation of the error, usually
    /// reated by calling toString on the error. The second element
    /// is a String representation of an accompanying stack trace,
    /// or null if no stack trace was provided. To convert this back
    /// to a StackTrace object, use StackTrace.fromString.

    if (error is List && error.length == 2) {
      await logException(error.first, handled, error.last);
    }
  }

  Future<void> logException(dynamic exception, bool handled,
      [dynamic stackTrace]) async {
    final Chain chain = _getStackTraceChain(stackTrace);

    final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];

    var ds = AccumulatorSink<Digest>();
    var s = sha1.startChunkedConversion(ds);

    // add current application version beforehand
    s.add(utf8.encode(getApplicationVersionInternal()));

    for (int t = 0; t < chain.traces.length; t += 1) {
      for (int f = 0; f < chain.traces[t].frames.length; f += 1) {
        var frame = chain.traces[t].frames[f];
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

    await _sendException(
        exception, handled, frames, '${ds.events.single}', stackTrace);
  }

  Future<void> _sendException(dynamic exception, bool handled,
      List<Map<String, dynamic>> frames, String signature,
      [dynamic originalStackTrace]) async {
    String exceptionType = BugseeExceptionsClassifier.classifyType(exception);
    final dynamic exceptionData = <String, dynamic>{
      'internalType': 'FlutterManagedException',
      'name': exceptionType,
      'reason': '$exception',
      'frames': frames,
      'signature': signature,
      'originalStackTrace': '$originalStackTrace'
    };

    await _channel.invokeMethod('logException', <String, dynamic>{
      'name': 'FlutterManagedException',
      'reason': json.encode(exceptionData),
      'handled': handled,
      'signature': signature,
    });
  }

  Map<String, dynamic> _constructBugseeFrame(Frame frame) {
    Uri frameUri = frame.uri;
    String? package = frame.package;
    bool user = true;
    String stringUri = frameUri.toString();

    if (frameUri.scheme != 'dart' && frameUri.scheme != 'package') {
      if (frameUri.pathSegments.isNotEmpty) {
        stringUri = frameUri.pathSegments.last;
      }
    }

    if (frameUri.scheme == 'hooks' ||
        frameUri.scheme == 'dart' ||
        package == 'flutter') {
      user = false;
    }

    package ??= (frameUri.scheme == 'dart') ? 'dart' : 'application';

    return <String, dynamic>{
      'trace': '${frame.member} ($stringUri:${frame.line})',
      'module': package,
      'user': user,
      'data': {
        'source': frame.uri.toString(),
        'member': frame.member,
        'line': frame.line,
        'column': frame.column,
        'package': frame.package,
        'library': frame.library,
        'isCore': frame.isCore
      }
    };
  }

  /// Get the stack chain for the specified stack trace or
  /// retrive current stack chain if no stack trace provided
  Chain _getStackTraceChain([dynamic stackTrace]) {
    Chain? chain;

    if (stackTrace != null && stackTrace.toString() != "") {
      if (stackTrace is StackTrace) {
        stackTrace = FlutterError.demangleStackTrace(stackTrace);
        chain = Chain.forTrace(stackTrace);
      } else if (stackTrace is String) {
        try {
          stackTrace = StackTrace.fromString(stackTrace);
          chain = Chain.forTrace(stackTrace);
        } catch (e) {
          // Ignore error here
        }
      }
    }

    // we instruct the runtime to give us the stack chain with our
    // own frames on top stripped. This is required to exclude the calls
    // to this method and the one calling it (as this method is
    // marked as internal, it will be called from one of the
    // instance methods of this class)
    chain ??= Chain.current(3);

    return chain;
  }

  void installGlobalErrorHandler([bool force = false]) {
    if (_isInstalled && !force) {
      return;
    }

    final defaultOnError = FlutterError.onError;

    FlutterError.onError = (FlutterErrorDetails errorDetails) async {
      Object exception = errorDetails.exception;
      StackTrace? stack = errorDetails.stack;

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
