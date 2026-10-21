// What a Dart error becomes on its way to the native SDKs. Internal.
//
// The backend routes a Flutter exception on the literal text `FlutterManagedException` (in the
// exception's name, in its reason, or `type == 'flutter'`: worker `crash/managed/__init__.py`) and
// reads a JSON document out of the reason (worker `crash/managed/dart.py`). The document built here
// is the one the 9.x plugin sent, with the keys the worker reads and nothing it ignores; the
// contract and its sources are in doc/exceptions.md. This file is pure: no channel, no clock, no
// state, so every rule in it is unit-tested without a device.
//
// It never throws: a hostile `toString`, a stack that cannot be printed or parsed, a type whose
// name cannot be read all degrade to a smaller document, never to an exception in the app's error
// path.
import 'dart:async' show AsyncError, DeferredLoadException, TimeoutException;
import 'dart:convert' show jsonEncode;
import 'dart:io'
    show
        CertificateException,
        FileSystemException,
        HandshakeException,
        HttpException,
        SocketException,
        TlsException;

import 'package:flutter/foundation.dart' show DiagnosticLevel, FlutterError;
import 'package:flutter/painting.dart' show NetworkImageLoadException;
import 'package:flutter/scheduler.dart' show TickerCanceled;
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:stack_trace/stack_trace.dart' show Chain, Frame;

/// The wire constants of the exception contract. Repeated in `ExceptionOps.java` and
/// `BGSFlutterExceptionOps.m` (native defends too); `test/exceptions_drift_test.dart` compares the
/// three.
abstract final class ExceptionWire {
  /// The exception class name (Android: `com.bugsee.flutter.FlutterManagedException`; iOS: the
  /// `NSException` name) and the document's `internalType`: the backend finds a Flutter exception
  /// by this text. NEVER rename it: every Flutter report would stop being recognised.
  static const managedName = 'FlutterManagedException';

  /// The longest document native accepts, in UTF-16 units. The builder keeps below it (degrading
  /// the document step by step), native refuses what is over it (`invalid-argument`) rather than
  /// cutting JSON in half.
  static const maxPayloadLength = 262144;

  /// The longest `domain` (RN's limit; native refuses more).
  static const maxDomainLength = 256;

  /// The message, the type name and each frame field are cut to these (UTF-16 units).
  static const maxReasonLength = 8192;
  static const maxNameLength = 256;
  static const maxFieldLength = 1024;

  /// Frames kept (the top ones: a stack overflow has thousands of identical frames and the
  /// backend finds the recursion in the first few hundred).
  static const maxFrames = 256;

  /// The longest `originalStackTrace` kept, cut at a line boundary so its header (the build id the
  /// backend needs to symbolicate) always survives.
  static const maxRawStackLength = 65536;
}

const _ellipsis = '…';

/// A Dart error ready for the bridge.
final class ExceptionPayload {
  const ExceptionPayload({
    required this.name,
    required this.reason,
    required this.json,
    required this.frameCount,
  });

  /// The exception type the dashboard shows (`StateError`, `FormatException`, ...).
  final String name;

  /// The (capped) message.
  final String reason;

  /// The document handed to native: the reason of the `FlutterManagedException`.
  final String json;

  /// How many frames the document carries.
  final int frameCount;
}

/// Cuts [text] to [max] UTF-16 units without splitting a surrogate pair; a cut text ends in `…`
/// (which is not counted against [max], so a cut is always visible).
String capText(String text, int max) {
  if (text.length <= max) return text;
  var end = max;
  if (end > 0 && _isHighSurrogate(text.codeUnitAt(end - 1))) end--;
  return '${text.substring(0, end)}$_ellipsis';
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

/// The type name for [error], as the dashboard groups it.
///
/// Known types by `is`, never by `runtimeType.toString()`: an obfuscated build renames app and
/// package classes, and the dashboard would show `minified:Ab`. A type this table does not know
/// falls back to its `runtimeType` (obfuscated if the build is; the app can name its own errors by
/// catching and re-throwing a known type, which is the documented way).
///
/// [obfuscated] says the build renames classes (its stack is non-symbolic): a type this table does
/// not know is then named from its message when that starts the way Dart's convention does
/// (`MyError: ...`, what an `Exception`'s `toString` usually prints), since its `runtimeType` is
/// `bx` or the like.
String classifyExceptionType(Object? error, {bool obfuscated = false}) {
  if (error == null) return 'Error';
  // Specific before general: IndexError and RangeError ARE ArgumentErrors.
  if (error is IndexError) return 'IndexError';
  if (error is RangeError) return 'RangeError';
  if (error is ArgumentError) return 'ArgumentError';
  // A FlutterError IS an AssertionError: first.
  if (error is FlutterError) return 'FlutterError';
  if (error is AssertionError) return 'AssertionError';
  if (error is ConcurrentModificationError) {
    return 'ConcurrentModificationError';
  }
  if (error is FormatException) return 'FormatException';
  if (error is NoSuchMethodError) return 'NoSuchMethodError';
  if (error is OutOfMemoryError) return 'OutOfMemoryError';
  if (error is StackOverflowError) return 'StackOverflowError';
  if (error is StateError) return 'StateError';
  if (error is TypeError) return 'TypeError';
  if (error is UnimplementedError) return 'UnimplementedError';
  if (error is UnsupportedError) return 'UnsupportedError';
  if (error is TimeoutException) return 'TimeoutException';
  if (error is AsyncError) return 'AsyncError';
  if (error is DeferredLoadException) return 'DeferredLoadException';
  if (error is FileSystemException) return 'FileSystemException';
  if (error is HttpException) return 'HttpException';
  if (error is SocketException) return 'SocketException';
  if (error is HandshakeException) return 'HandshakeException';
  if (error is CertificateException) return 'CertificateException';
  if (error is TlsException) return 'TlsException';
  if (error is PlatformException) return 'PlatformException';
  if (error is MissingPluginException) return 'MissingPluginException';
  if (error is NetworkImageLoadException) return 'NetworkImageLoadException';
  if (error is TickerCanceled) return 'TickerCanceled';
  if (error is String) return 'String';
  if (error is Exception) {
    final named = _runtimeTypeName(error);
    final fromMessage = obfuscated ? _namedByMessage(error) : null;
    if (fromMessage != null) return fromMessage;
    // The VM's plain `Exception('...')` is a private class: name it for what the app wrote.
    if (named == null || named.startsWith('_')) return 'Exception';
    return named;
  }
  final named = _runtimeTypeName(error);
  return (obfuscated ? _namedByMessage(error) : null) ?? named ?? 'Error';
}

String? _namedByMessage(Object error) {
  try {
    return _namedLike.firstMatch('$error')?.group(1);
  } catch (_) {
    return null;
  }
}

String? _runtimeTypeName(Object error) {
  try {
    final name = error.runtimeType.toString();
    return name.isEmpty ? null : capText(name, ExceptionWire.maxNameLength);
  } catch (_) {
    return null;
  }
}

/// The prefixes of the VM's own `toString` for its error types: all an isolate error listener has,
/// since it receives the error as a string. (9.x compared against instantiated samples; a prefix
/// table cannot throw and costs nothing.)
const _stringPrefixes = <(String, String)>[
  ('Invalid argument', 'ArgumentError'),
  ('Bad state:', 'StateError'),
  ('Concurrent modification', 'ConcurrentModificationError'),
  ('Unsupported operation', 'UnsupportedError'),
  ('Assertion failed', 'AssertionError'),
  ('Stack Overflow', 'StackOverflowError'),
  ('Out of Memory', 'OutOfMemoryError'),
  ('Class \'', 'NoSuchMethodError'),
  ('NoSuchMethodError', 'NoSuchMethodError'),
  ('type \'', 'TypeError'),
  ('RangeError', 'RangeError'),
  ('IndexError', 'IndexError'),
  ('FormatException', 'FormatException'),
  ('TimeoutException', 'TimeoutException'),
  ('UnimplementedError', 'UnimplementedError'),
  ('DeferredLoadException', 'DeferredLoadException'),
  ('FileSystemException', 'FileSystemException'),
  ('HttpException', 'HttpException'),
  ('SocketException', 'SocketException'),
  ('HandshakeException', 'HandshakeException'),
  ('CertificateException', 'CertificateException'),
  ('TlsException', 'TlsException'),
  ('PlatformException', 'PlatformException'),
  ('MissingPluginException', 'MissingPluginException'),
  ('NetworkImageLoadException', 'NetworkImageLoadException'),
  ('Exception:', 'Exception'),
];

final _namedLike = RegExp(
  r'^([A-Za-z_][A-Za-z0-9_]{0,63}(?:Exception|Error))\b',
);

/// The type for an error that arrives as text (an isolate error listener's message): by the VM's
/// own prefixes, else by a leading `SomethingError` / `SomethingException` word, else `Error`.
String classifyErrorText(String text) {
  final trimmed = text.trimLeft();
  for (final (prefix, type) in _stringPrefixes) {
    if (trimmed.startsWith(prefix)) return type;
  }
  final named = _namedLike.firstMatch(trimmed);
  return named?.group(1) ?? 'Error';
}

/// The message to report for [error], capped.
///
/// A [FlutterError] contributes its SUMMARY only (the first line of what is wrong). Its full
/// message carries the framework's diagnostics (widget descriptions, constraints, property dumps)
/// that can hold what is on screen, and the dynamic content makes the dashboard's grouping unstable.
/// `FlutterErrorDetails.informationCollector` (the widget trees, "the relevant error-causing
/// widget") is never read at all. Anything else is `toString()`, which is whatever the app put in
/// its error: the same as the native SDKs report for a Java or Objective-C exception.
String describeError(Object? error) {
  String text;
  try {
    if (error is FlutterError) {
      text = _flutterSummary(error);
    } else {
      text = '$error';
    }
  } catch (_) {
    text = '<message unavailable: ${_runtimeTypeName(error!) ?? 'Error'}>';
  }
  return capText(text, ExceptionWire.maxReasonLength);
}

String _flutterSummary(FlutterError error) {
  try {
    for (final node in error.diagnostics) {
      if (node.level == DiagnosticLevel.summary) return '$node';
    }
  } catch (_) {
    // fall through to the first line of the full message
  }
  final lines = error.message.split('\n');
  return lines.isEmpty ? '' : lines.first;
}

final _nonSymbolic = RegExp(r'^\s*#\d+\s+abs\s+[0-9a-fA-F]+', multiLine: true);
final _frameLine = RegExp(r'^\s*#\d+\s');
const _suspension = '<asynchronous suspension>';

/// Whether [raw] is a stack in the VM's non-symbolic format (an obfuscated or `--split-debug-info`
/// build): a header (`build_id: ...`, the base addresses) and `#00 abs ... virt ...` lines. The
/// backend symbolicates it with the build's `.symbols` file; nothing here may rewrite it.
bool isNonSymbolicStack(String raw) =>
    raw.contains('build_id:') || _nonSymbolic.hasMatch(raw);

/// [raw] cut to [ExceptionWire.maxRawStackLength] at a line boundary (the header comes first, so
/// it survives), without the mark.
String _cutRawStack(String raw) {
  if (raw.length <= ExceptionWire.maxRawStackLength) return raw;
  var end = ExceptionWire.maxRawStackLength;
  final newline = raw.lastIndexOf('\n', end);
  if (newline > 0) end = newline;
  return raw.substring(0, end);
}

/// [raw] as it is sent: cut (see [_cutRawStack]) and marked with `…` when it was.
String capRawStack(String raw) {
  final cut = _cutRawStack(raw);
  return cut.length == raw.length ? raw : '$cut\n$_ellipsis';
}

/// The frames of a stack and its raw text, as the document carries them.
final class StackDocument {
  const StackDocument(this.frames, this.raw, {required this.omitted});

  /// `{trace, module, user, data}` maps, in the 9.x shape the worker reads.
  final List<Map<String, Object?>> frames;

  /// `stack.toString()`, unmodified except for the cap; `null` when there was no stack.
  final String? raw;

  /// Whether frames were left out (more than [ExceptionWire.maxFrames], or beyond the raw cap).
  final bool omitted;
}

/// Parses [stack] for the document.
///
/// [captured] is true for a stack taken here (`StackTrace.current` for a call that gave none):
/// its leading frames inside this package are dropped, so the report starts where the app called.
StackDocument describeStack(StackTrace? stack, {bool captured = false}) {
  if (stack == null) return const StackDocument([], null, omitted: false);
  String raw;
  try {
    raw = FlutterError.demangleStackTrace(stack).toString();
  } catch (_) {
    return const StackDocument([], null, omitted: false);
  }
  if (raw.trim().isEmpty) return const StackDocument([], null, omitted: false);

  List<Map<String, Object?>> frames;
  try {
    // Bounded work: a stack overflow prints tens of thousands of frames.
    final bounded = _cutRawStack(raw);
    frames = isNonSymbolicStack(raw)
        ? _framesFromNonSymbolic(bounded)
        : _framesFromChain(bounded, captured: captured);
  } catch (_) {
    frames = const [];
  }
  var omitted = raw.length > ExceptionWire.maxRawStackLength;
  if (frames.length > ExceptionWire.maxFrames) {
    omitted = true;
    frames = frames.sublist(0, ExceptionWire.maxFrames);
  }
  // A symbolic stack names files by path: on a developer's machine that is a user and a directory
  // tree (release builds print `package:` URIs). A non-symbolic stack is the VM's text, which the
  // backend symbolicates, and is never rewritten.
  final sent = isNonSymbolicStack(raw) ? raw : _withoutLocalPaths(raw);
  return StackDocument(frames, capRawStack(sent), omitted: omitted);
}

final _filePath = RegExp(r'file://[^\s()]*/([^/\s():]+)');

String _withoutLocalPaths(String raw) =>
    raw.replaceAllMapped(_filePath, (m) => 'file:///${m[1]}');

/// An obfuscated stack has no names to read: one frame per `#NN` line, text as printed (the
/// worker builds the same frames from `originalStackTrace` and replaces them once the symbols are
/// found).
List<Map<String, Object?>> _framesFromNonSymbolic(String raw) {
  final frames = <Map<String, Object?>>[];
  for (final line in raw.split('\n')) {
    final text = line.trim();
    if (text == _suspension) {
      if (frames.isNotEmpty) frames.add(_gap());
    } else if (_frameLine.hasMatch(line)) {
      final trace = capText(text, ExceptionWire.maxFieldLength);
      frames.add({
        'trace': trace,
        'module': 'dart',
        'user': true,
        'data': {'member': trace},
      });
    }
  }
  while (frames.isNotEmpty && frames.last['trace'] == '<asynchronous gap>') {
    frames.removeLast();
  }
  return frames;
}

Map<String, Object?> _gap() => {
  'trace': '<asynchronous gap>',
  'module': 'dart',
  'user': false,
};

/// Parses the printed text, never the object: `Chain.forTrace` would link a stack it does not
/// know to the zone it is called in (inside a `Chain.capture` zone, which the test runner is, the
/// frames of whatever is running here), and the VM's `<asynchronous suspension>` lines and the
/// `package:stack_trace` friendly format are both understood by `Chain.parse`.
List<Map<String, Object?>> _framesFromChain(
  String raw, {
  required bool captured,
}) {
  final chain = Chain.parse(raw);
  final frames = <Map<String, Object?>>[];
  var dropping = captured;
  for (final trace in chain.traces) {
    var added = 0;
    final batch = <Map<String, Object?>>[];
    for (final frame in trace.frames) {
      if (dropping && frame.package == 'bugsee_flutter') continue;
      dropping = false;
      batch.add(_frame(frame));
      added++;
    }
    if (added == 0) continue;
    if (frames.isNotEmpty) frames.add(_gap());
    frames.addAll(batch);
  }
  return frames;
}

Map<String, Object?> _frame(Frame frame) {
  final uri = frame.uri;
  final package = frame.package;
  var shown = uri.toString();
  var library = frame.library;
  if (uri.scheme != 'dart' && uri.scheme != 'package') {
    // A file path on the developer's machine (debug builds) names a user and a directory tree:
    // only the file's name is kept, in the trace and in the data alike.
    if (uri.pathSegments.isNotEmpty) shown = uri.pathSegments.last;
    library = shown;
  }
  final member = frame.member;
  final line = frame.line;
  final trace = capText(
    '$member ($shown${line == null ? '' : ':$line'})',
    ExceptionWire.maxFieldLength,
  );
  final user =
      !(uri.scheme == 'dart' ||
          package == 'flutter' ||
          package == 'bugsee_flutter');
  return {
    'trace': trace,
    'module': package ?? (uri.scheme == 'dart' ? 'dart' : 'application'),
    'user': user,
    'data': {
      'source': capText(
        uri.scheme == 'dart' || uri.scheme == 'package'
            ? uri.toString()
            : shown,
        ExceptionWire.maxFieldLength,
      ),
      'member': member == null
          ? null
          : capText(member, ExceptionWire.maxFieldLength),
      'line': line,
      'column': frame.column,
      'package': package,
      'library': capText(library, ExceptionWire.maxFieldLength),
      'isCore': frame.isCore,
    },
  };
}

/// Builds the document for [error] and [stack]. Never throws.
///
/// [name] and [reason] override what would be derived (an isolate error arrives as text). The
/// document is `{internalType, name, reason, frames, originalStackTrace?}`: exactly the keys the
/// worker reads (9.x also sent a `signature` it ignores).
ExceptionPayload buildExceptionPayload(
  Object? error,
  StackTrace? stack, {
  bool stackCaptured = false,
  String? name,
  String? reason,
}) {
  final message = reason == null
      ? describeError(error)
      : capText(reason, ExceptionWire.maxReasonLength);
  final document = _safe(
    () => describeStack(stack, captured: stackCaptured),
    const StackDocument([], null, omitted: false),
  );
  final obfuscated = document.raw != null && isNonSymbolicStack(document.raw!);
  final type = capText(
    name ??
        _safe(
          () => classifyExceptionType(error, obfuscated: obfuscated),
          'Error',
        ),
    ExceptionWire.maxNameLength,
  );

  final frames = [...document.frames];
  if (document.omitted) {
    frames.add({
      'trace': '... more frames omitted',
      'module': 'dart',
      'user': false,
    });
  }

  String encode(List<Map<String, Object?>> f, String? raw) => jsonEncode({
    'internalType': ExceptionWire.managedName,
    'name': type,
    'reason': message,
    'frames': f,
    'originalStackTrace': ?raw,
  });

  // Degrade to stay under what native accepts (the raw stack is capped, so the frames parsed from it
  // are bounded too: dropping their `data` is enough in practice; the last step is the floor).
  var json = encode(frames, document.raw);
  if (json.length > ExceptionWire.maxPayloadLength) {
    json = encode([
      for (final f in frames) {...f}..remove('data'),
    ], document.raw);
  }
  if (json.length > ExceptionWire.maxPayloadLength) {
    json = encode(const [], null);
  }
  return ExceptionPayload(
    name: type,
    reason: message,
    json: json,
    frameCount: frames.length,
  );
}

T _safe<T>(T Function() body, T fallback) {
  try {
    return body();
  } catch (_) {
    return fallback;
  }
}

/// What identifies "the same error" for the limiter: the reason and the first lines of the raw
/// stack. The same error reported through two routes (an isolate listener gets the text of what the
/// Dart handler got as an object) has the same one.
String exceptionFingerprint(String reason, String? raw) {
  final top = raw == null
      ? ''
      : raw
            .split('\n')
            .where((l) => _frameLine.hasMatch(l) || l.contains(' abs '))
            .take(5)
            .map((l) => l.trim())
            .join('|');
  return '${capText(reason, 512)}\u0000$top';
}
