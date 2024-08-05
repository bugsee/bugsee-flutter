import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'utils.dart';

class BugseeExceptionsClassifier {
  static final Object _dummyObject = Object();

  static List<Exception>? _exceptionInstances;
  static List<Error>? _errorInstances;

  static void _ensureInitialized() {
    if (_errorInstances == null) {
      try {
        _errorInstances = List.of([
          ArgumentError(),
          AssertionError(),
          ConcurrentModificationError(),
          IndexError.withLength(1, 1),
          NoSuchMethodError.withInvocation(
              null, Invocation.method(Symbol.empty, [])),
          OutOfMemoryError(),
          RangeError(""),
          StackOverflowError(),
          StateError(""),
          TypeError(),
          UnimplementedError(),
          UnsupportedError(""),
          AsyncError(_dummyObject, null),
          FlutterError(""),
        ]);
      } catch (e) {
        // ignore
      }
    }

    if (_exceptionInstances == null) {
      try {
        _exceptionInstances = List.of([
          FormatException(),
          TimeoutException(""),
          DeferredLoadException(""),
          FileSystemException(),
          HttpException(""),
          SocketException(""),
          HandshakeException(),
          CertificateException(),
          TlsException(),
          PlatformException(code: ""),
          MissingPluginException(),
          NetworkImageLoadException(
              statusCode: 500, uri: Uri.parse("https://bugsee.com")),
          TickerCanceled(),
        ]);
      } catch (e) {
        // ignore
      }
    }
  }

  static String classifyType(dynamic exception) {
    _ensureInitialized();

    // dart:core
    if (exception is ArgumentError) return 'ArgumentError';
    if (exception is AssertionError) return 'AssertionError';
    if (exception is ConcurrentModificationError) {
      return 'ConcurrentModificationError';
    }
    if (exception is FormatException) return 'FormatException';
    if (exception is IndexError) return 'IndexError';
    if (exception is NoSuchMethodError) return 'NoSuchMethodError';
    if (exception is OutOfMemoryError) return 'OutOfMemoryError';
    if (exception is RangeError) return 'RangeError';
    if (exception is StackOverflowError) return 'StackOverflowError';
    if (exception is StateError) return 'StateError';
    if (exception is TypeError) return 'TypeError';
    if (exception is UnimplementedError) return 'UnimplementedError';
    if (exception is UnsupportedError) return 'UnsupportedError';

    // dart:async
    if (exception is TimeoutException) return 'TimeoutException';
    if (exception is AsyncError) return 'FutureTimeout';
    if (exception is DeferredLoadException) return 'DeferredLoadException';

    // dart:io
    if (exception is FileSystemException) return 'FileSystemException';
    if (exception is HttpException) return 'HttpException';
    if (exception is SocketException) return 'SocketException';
    if (exception is HandshakeException) return 'HandshakeException';
    if (exception is CertificateException) return 'CertificateException';
    if (exception is TlsException) return 'TlsException';

    // flutter
    if (exception is FlutterError) return 'FlutterError';
    if (exception is PlatformException) return 'PlatformException';
    if (exception is MissingPluginException) return 'MissingPluginException';
    if (exception is NetworkImageLoadException) {
      return 'NetworkImageLoadException';
    }
    if (exception is TickerCanceled) return 'TickerCanceled';

    if (exception is String) return _inferType(exception);

    return exception != null ? '${exception.runtimeType}' : "Error";
  }

  static String _inferType(String? exceptionLine) {
    _ensureInitialized();

    String? result;

    if (exceptionLine == null) {
      // Return a generic error type when no exception is provided
      return "Error";
    }

    try {
      if (_errorInstances != null) {
        for (Error error in _errorInstances!) {
          String errorLine = error.toString();
          int startEqualityLength =
              getEqualBeginningLength(exceptionLine, errorLine);
          if (startEqualityLength > 5) {
            result = classifyType(error);
            break;
          }
        }
      }

      if (result == null && _exceptionInstances != null) {
        for (Exception error in _exceptionInstances!) {
          String errorLine = error.toString();
          int startEqualityLength =
              getEqualBeginningLength(exceptionLine, errorLine);
          if (startEqualityLength > 5) {
            result = classifyType(error);
            break;
          }
        }
      }
    } catch (e) {
      // ignore
    }

    return result ?? "Error";
  }
}
