// The behaviour behind the `Bugsee` facade, with its collaborators injectable so a test can
// supply a fake native side. Internal.
import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kDebugMode;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;

import 'bridge/bridge.dart';
import 'status.dart';
import 'bridge/messages.g.dart';
import 'launch.dart';
import 'options/bugsee_options.g.dart';
import 'options/launch_options.dart';
import 'options/option_registry.dart';

/// The platform this runs on, as the options registry knows it; `null` for any other.
OptionPlatform? currentOptionPlatform() => switch (defaultTargetPlatform) {
  TargetPlatform.android => OptionPlatform.android,
  TargetPlatform.iOS => OptionPlatform.ios,
  _ => null,
};

final class BugseeRuntime {
  BugseeRuntime({
    BugseeBridgeHostApi? host,
    BugseeBridge? bridge,
    OptionPlatform? Function()? platform,
    void Function(String message)? warn,
  }) : host = host ?? BugseeBridgeHostApi(),
       _platform = platform ?? currentOptionPlatform,
       _warn = warn ?? _debugWarn {
    this.bridge = bridge ?? BugseeBridge(host: this.host);
  }

  final BugseeBridgeHostApi host;
  late final BugseeBridge bridge;
  final OptionPlatform? Function() _platform;
  final void Function(String) _warn;

  static void _debugWarn(String message) {
    if (kDebugMode) debugPrint('bugsee_flutter: $message');
  }

  /// Attaches to native (lifecycle channel, wrapper identity refinement, report handler
  /// phases). Idempotent while it succeeds; an error is a [BugseeException] and the next call
  /// tries again.
  Future<void> ensureStarted() async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      await bridge.start();
    } on PlatformException catch (e) {
      throw BugseeException(
        'could not attach to the native Bugsee SDK: ${e.message ?? e.code}',
        cause: e,
      );
    }
  }

  /// [ensureStarted] for a caller that cannot wait (a getter): a failure is not lost, it
  /// surfaces from the next awaited call.
  void ensureStartedInBackground() {
    unawaited(ensureStarted().catchError((Object _) {}));
  }

  Future<LaunchResult> launch(String token, BugseeOptions options) async {
    if (token.trim().isEmpty) {
      throw const BugseeLaunchException(
        LaunchFailure.invalidToken,
        'Bugsee.launch needs the application token from the Bugsee dashboard; it was empty',
      );
    }
    final platform = _platform();
    if (platform == null) {
      throw const BugseeLaunchException(
        LaunchFailure.unsupportedPlatform,
        'Bugsee runs on Android and iOS only',
      );
    }
    // Before anything native is touched: a bad option must not leave a half-started launch.
    final encoded = encodeLaunchOptions(options, platform);
    encoded.warnings.forEach(_warn);

    try {
      await ensureStarted();
    } on BugseeException catch (e) {
      throw BugseeLaunchException(
        LaunchFailure.nativeError,
        e.message,
        cause: e.cause ?? e,
      );
    }

    final LaunchOutcomeMessage outcome;
    try {
      outcome = await host.launch(
        token,
        Map<String, Object>.of(encoded.values),
      );
    } on PlatformException catch (e) {
      throw BugseeLaunchException(
        LaunchFailure.nativeError,
        'the Bugsee SDK threw while launching: ${e.message ?? e.code}',
        cause: e,
      );
    }

    switch (outcome.outcome) {
      case LaunchWire.launched:
        return LaunchResult.launched;
      case LaunchWire.alreadyRunning:
        if (encoded.values.isNotEmpty) {
          _warn(
            'Bugsee was already running when launch was called, so the options passed to it were '
            'NOT applied. On Android this is usually the SDK auto-launching from the manifest '
            '(meta-data com.bugsee.app-token); add com.bugsee.auto-init=false to make launch '
            'authoritative.',
          );
        }
        return LaunchResult.alreadyRunning;
      case LaunchWire.deferred:
        return LaunchResult.deferred;
      case LaunchWire.refused:
        throw switch (outcome.reason) {
          LaunchWire.invalidToken => const BugseeLaunchException(
            LaunchFailure.invalidToken,
            'the Bugsee SDK rejected the application token',
          ),
          LaunchWire.stopping => const BugseeLaunchException(
            LaunchFailure.stopping,
            'the Bugsee SDK is still stopping; await Bugsee.stop() before launching again',
          ),
          _ => BugseeLaunchException(
            LaunchFailure.rejected,
            'the Bugsee SDK did not launch (${outcome.reason ?? 'no reason given'}); its log '
            'says why',
          ),
        };
      default:
        throw BugseeLaunchException(
          LaunchFailure.nativeError,
          'the native side answered a launch with "${outcome.outcome}", which this version of '
          'bugsee_flutter does not know',
        );
    }
  }

  Future<void> stop() async {
    await ensureStarted();
    try {
      await host.stop();
    } on PlatformException catch (e) {
      throw BugseeException(
        'the Bugsee SDK threw while stopping: ${e.message ?? e.code}',
        cause: e,
      );
    }
  }

  Future<BugseeStatus> getStatus() async {
    final String name;
    try {
      name = await host.status();
    } on PlatformException catch (e) {
      throw BugseeException(
        'could not read the Bugsee status: ${e.message ?? e.code}',
        cause: e,
      );
    }
    // A name this version does not know is a newer SDK's state; reporting a state for it
    // would say the SDK is somewhere it is not.
    return BugseeStatus.fromName(name) ??
        (throw BugseeException('the SDK reported the unknown status "$name"'));
  }

  Future<Map<String, Object>> launchOptions({required bool hostOnly}) async {
    final Map<String, Object> raw;
    try {
      raw = await host.launchOptions(hostOnly);
    } on PlatformException catch (e) {
      throw BugseeException(
        'could not read the Bugsee launch options: ${e.message ?? e.code}',
        cause: e,
      );
    }
    // Hidden options ($$ENDPOINT, ...) are not public: never handed back, whatever native sent.
    return Map.unmodifiable({
      for (final e in raw.entries)
        if (optionSpecForKey(e.key)?.hidden != true) e.key: e.value,
    });
  }

  Stream<BugseeStatus> get statusChanges => bridge.statusChanges;

  BugseeStatus get status => bridge.status ?? BugseeStatus.stopped;
}
