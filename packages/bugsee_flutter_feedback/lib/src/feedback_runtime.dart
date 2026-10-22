// The behaviour behind the `BugseeFeedback` facade, with its collaborators injectable so a test can
// supply a fake native side. Internal.
import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kDebugMode;
import 'package:flutter/services.dart'
    show BinaryMessenger, MissingPluginException, PlatformException;
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
// The core's own version constant, to detect a core this package was not released with. Both
// packages live in one repository and are released together (feedback_version.dart); the file is
// pinned by the core's wrapper identity test.
// ignore: implementation_imports
import 'package:bugsee_flutter/src/wrapper_identity.dart' as core;

import 'bridge/messages.g.dart';
import 'errors.dart';
import 'feedback_version.dart';

/// The platform this runs on; `null` for one with no Bugsee SDK.
TargetPlatform? currentFeedbackPlatform() => switch (defaultTargetPlatform) {
  TargetPlatform.android => TargetPlatform.android,
  TargetPlatform.iOS => TargetPlatform.iOS,
  _ => null,
};

final class FeedbackRuntime implements FeedbackFlutterApi {
  FeedbackRuntime({
    FeedbackHostApi? host,
    BinaryMessenger? messenger,
    TargetPlatform? Function()? platform,
    void Function(String message)? warn,
    void Function()? ensureBinding,
    String? coreVersion,
    String? ownVersion,
  }) : _messenger = messenger,
       host = host ?? FeedbackHostApi(binaryMessenger: messenger),
       _platform = platform ?? currentFeedbackPlatform,
       _warn = warn ?? _debugWarn,
       _ensureBinding =
           ensureBinding ?? WidgetsFlutterBinding.ensureInitialized,
       _coreVersion = coreVersion ?? core.wrapperVersion,
       _ownVersion = ownVersion ?? feedbackVersion {
    _received = StreamController<List<String>>.broadcast(
      onListen: _listenersChanged,
      onCancel: _listenersChanged,
    );
    _sent = StreamController<String>.broadcast(
      onListen: _listenersChanged,
      onCancel: _listenersChanged,
    );
  }

  final FeedbackHostApi host;
  final BinaryMessenger? _messenger;
  final TargetPlatform? Function() _platform;
  final void Function(String) _warn;
  final void Function() _ensureBinding;
  final String _coreVersion;
  final String _ownVersion;

  late final StreamController<List<String>> _received;
  late final StreamController<String> _sent;

  static void _debugWarn(String message) {
    if (kDebugMode) debugPrint('bugsee_flutter_feedback: $message');
  }

  bool _warnedUnsupported = false;

  /// Resolves once this isolate has attached; a failure is not cached, the next call retries.
  Future<bool>? _attached;

  /// Whether the SDK listener is installed, as native knows it (what the last successful
  /// `setListenerEnabled` said).
  bool _listenerOn = false;

  /// Serialises `setListenerEnabled`, so a quick listen/cancel/listen ends in the state the last
  /// one asked for.
  Future<void> _syncChain = Future<void>.value();

  bool get _supported => _platform() != null;

  Stream<List<String>> get messagesReceived => _received.stream;
  Stream<String> get messagesSent => _sent.stream;

  /// Attaches this isolate to native: the Dart handler for native events, the core version check,
  /// and the listener reset. Idempotent while it succeeds.
  Future<bool> _attach() => _attached ??= _attachOnce();

  Future<bool> _attachOnce() async {
    try {
      return await _doAttach();
    } catch (_) {
      _attached = null;
      rethrow;
    }
  }

  Future<bool> _doAttach() async {
    try {
      _ensureBinding();
    } catch (e) {
      // A background isolate has no binding and no platform channels of its own.
      throw BugseeFeedbackException(
        BugseeFeedbackFailure.nativeError,
        'the feedback chat can only be used from the root isolate (the one that runs main). ($e)',
        cause: e,
      );
    }
    if (!isCompatibleCore(_ownVersion, _coreVersion)) {
      throw BugseeFeedbackException(
        BugseeFeedbackFailure.incompatibleCore,
        'bugsee_flutter_feedback $_ownVersion was released with bugsee_flutter $_ownVersion '
        '(the same major and minor), but this build uses bugsee_flutter $_coreVersion. Depend on '
        'matching versions of both packages.',
      );
    }
    FeedbackFlutterApi.setUp(this, binaryMessenger: _messenger);
    final registered = await _native('attach', host.attach);
    // Native forgot a listener a previous isolate left: nothing is installed now.
    _listenerOn = false;
    return registered;
  }

  /// Whether the SDK has the feedback module registered. `false` on a platform without a Bugsee
  /// SDK. Throws a [BugseeFeedbackException] for an unusable build (see [BugseeFeedbackFailure]).
  Future<bool> isAvailable() async {
    if (!_supported) return false;
    return _attach();
  }

  Future<void> show() async {
    if (!_guard('show')) return;
    await _attach();
    await _native('show', host.show);
  }

  Future<void> setGreeting(String? greeting) async {
    if (!_guard('setGreeting')) return;
    await _attach();
    await _native('setGreeting', () => host.setGreeting(greeting));
  }

  /// False (and one debug warning) on a platform with no SDK.
  bool _guard(String what) {
    if (_supported) return true;
    if (!_warnedUnsupported) {
      _warnedUnsupported = true;
      _warn(
        'Bugsee runs on Android and iOS only; calls to the feedback chat do nothing here',
      );
    }
    return false;
  }

  Future<T> _native<T>(String what, Future<T> Function() send) async {
    try {
      return await send();
    } on MissingPluginException catch (e) {
      throw BugseeFeedbackException(
        BugseeFeedbackFailure.nativeError,
        '$what: the native feedback plugin is not registered (a missing rebuild after adding the '
        'dependency, or an engine without it): ${e.message}',
        cause: e,
      );
    } on PlatformException catch (e) {
      throw _mapNative(what, e);
    }
  }

  BugseeFeedbackException _mapNative(String what, PlatformException e) {
    final message = e.message ?? e.code;
    if (e.code == FeedbackWire.notRegistered) {
      return BugseeFeedbackException(
        BugseeFeedbackFailure.notRegistered,
        '$what: $message',
        cause: e,
      );
    }
    return BugseeFeedbackException(
      BugseeFeedbackFailure.nativeError,
      '$what: $message',
      cause: e,
    );
  }

  // ---- listener -------------------------------------------------------------------------------

  void _listenersChanged() {
    if (!_supported) return;
    _syncChain = _syncChain.then((_) => _syncListener());
  }

  Future<void> _syncListener() async {
    var want = false;
    try {
      // First: attaching forgets what a previous isolate left installed, so what is compared
      // below is native's real state.
      await _attach();
      // After the await: the subscribers may have changed while it ran.
      want = _received.hasListener || _sent.hasListener;
      if (want == _listenerOn) return;
      await _native('setListenerEnabled', () => host.setListenerEnabled(want));
      _listenerOn = want;
    } on BugseeFeedbackException catch (e, s) {
      // A stream cannot throw from `listen`: the subscribers hear it as an error event, and the
      // next change of subscribers tries again.
      for (final c in [_received, _sent]) {
        if (c.hasListener) c.addError(e, s);
      }
    }
  }

  @override
  void onMessagesReceived(List<String> messages) {
    if (messages.isEmpty || !_received.hasListener) return;
    _received.add(List<String>.unmodifiable(messages));
  }

  @override
  void onMessageSent(String message) {
    if (!_sent.hasListener) return;
    _sent.add(message);
  }
}
