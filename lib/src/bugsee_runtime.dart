// The behaviour behind the `Bugsee` facade, with its collaborators injectable so a test can
// supply a fake native side. Internal.
import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kDebugMode;
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;

import 'bridge/bridge.dart';
import 'bridge/messages.g.dart';
import 'errors.dart';
import 'exceptions/error_capture.dart';
import 'exceptions/exception_payload.dart';
import 'facade/breadcrumb.dart';
import 'facade/validation.dart';
import 'launch.dart';
import 'lifecycle_event.dart';
import 'network/network_event.dart';
import 'network/network_pipeline.dart';
import 'network/network_policy.dart';
import 'network/network_service.dart';
import 'options/bugsee_options.g.dart';
import 'options/launch_options.dart';
import 'options/option_registry.dart';
import 'report/report_enums.dart';
import 'report/report_handler.dart';
import 'status.dart';

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
    void Function()? ensureBinding,
  }) : _ensureBinding =
           ensureBinding ?? WidgetsFlutterBinding.ensureInitialized,
       host = host ?? BugseeBridgeHostApi(),
       _platform = platform ?? currentOptionPlatform,
       _warn = warn ?? _debugWarn {
    this.bridge = bridge ?? BugseeBridge(host: this.host);
  }

  final BugseeBridgeHostApi host;
  late final BugseeBridge bridge;
  final OptionPlatform? Function() _platform;
  final void Function(String) _warn;
  final void Function() _ensureBinding;

  static void _debugWarn(String message) {
    if (kDebugMode) debugPrint('bugsee_flutter: $message');
  }

  /// Attaches to native (lifecycle channel, wrapper identity refinement, report handler
  /// phases). Idempotent while it succeeds; an error is a [BugseeException] and the next call
  /// tries again.
  Future<void> ensureStarted() async {
    _requireBinding();
    try {
      await bridge.start();
    } on MissingPluginException catch (e) {
      throw BugseeException(
        'the native Bugsee plugin is not registered (a platform without it, or a missing '
        'rebuild after adding the dependency): ${e.message}',
        cause: e,
      );
    } on PlatformException catch (e) {
      throw BugseeException(
        'could not attach to the native Bugsee SDK: ${e.message ?? e.code}',
        cause: e,
      );
    }
  }

  void _requireBinding() {
    try {
      _ensureBinding();
    } catch (e) {
      // A background isolate has no binding and no platform channels of its own.
      throw BugseeException(
        'Bugsee can only be used from the root isolate (the one that runs main); call it there '
        'and pass results to other isolates. ($e)',
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

    // The capture's policy follows the SDK's status; the lifecycle event may arrive after this
    // returns, so ask now too.
    unawaited(network.refreshPolicy());
    switch (outcome.outcome) {
      case LaunchWire.launched:
        _detectCrash = _detectCrashOf(encoded.values);
        errorCapture.warnIfReplaced();
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
        _detectCrash = _detectCrashOf(encoded.values);
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
    } finally {
      unawaited(network.refreshPolicy());
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

  /// Completes with whether the SDK is launched, waiting for a launch that is still starting or
  /// was deferred. `false` when it fails (goes back to stopped after launching) or [timeout] passes.
  Future<bool> waitUntilLaunched(Duration timeout) async {
    await ensureStarted();
    final done = Completer<bool>();
    var sawLaunching = false;
    // Subscribe BEFORE reading, so a transition between the read and the listen is not missed.
    final sub = statusChanges.listen((s) {
      if (s == BugseeStatus.launched) {
        if (!done.isCompleted) done.complete(true);
      } else if (s == BugseeStatus.launching) {
        sawLaunching = true;
      } else if (s == BugseeStatus.stopped && sawLaunching) {
        if (!done.isCompleted) done.complete(false);
      }
    });
    try {
      final now = await getStatus();
      if (now == BugseeStatus.launched && !done.isCompleted) {
        done.complete(true);
      }
      if (now == BugseeStatus.launching) sawLaunching = true;
      return await done.future.timeout(timeout, onTimeout: () => false);
    } finally {
      await sub.cancel();
    }
  }

  Stream<BugseeStatus> get statusChanges => bridge.statusChanges;

  BugseeStatus get status => bridge.status ?? BugseeStatus.stopped;

  // ---- The rest of the facade (Phase 4b) --------------------------------------------------------

  bool _warnedUnsupported = false;

  /// Runs one native call for the facade.
  ///
  /// On a platform with no SDK (anything but Android and iOS) the call is a no-op returning
  /// [neutral], with one debug warning: code that logs and traces must not break a desktop run, and
  /// nothing can have been launched there ([launch] is the call that throws). A failure to reach
  /// native, or one native reports, is a [BugseeException]; [argument] names the parameter an
  /// `invalid-argument` refusal is about.
  Future<T> _call<T>(
    String what,
    T neutral,
    Future<T> Function() send, {
    String argument = 'argument',
  }) async {
    if (_platform() == null) {
      if (!_warnedUnsupported) {
        _warnedUnsupported = true;
        _warn(
          'Bugsee runs on Android and iOS only; calls to it do nothing here',
        );
      }
      return neutral;
    }
    // Attaches to native on the first call (lifecycle channel, wrapper identity, report phases), so
    // events the SDK raised earlier are replayed whichever method comes first; a failure to attach
    // is the BugseeException ensureStarted documents.
    await ensureStarted();
    try {
      return await send();
    } on MissingPluginException catch (e) {
      throw BugseeException(
        '$what: the native Bugsee plugin is not registered (a missing rebuild after adding the '
        'dependency, or an engine without it): ${e.message}',
        cause: e,
      );
    } on PlatformException catch (e) {
      throw mapFacadeError(what, e, argument: argument);
    }
  }

  /// A native refusal as the exception the facade documents.
  static BugseeException mapFacadeError(
    String what,
    PlatformException e, {
    String argument = 'argument',
  }) {
    final message = e.message ?? e.code;
    return switch (e.code) {
      FacadeWire.invalidArgument => BugseeArgumentException(
        argument,
        '$what: $message',
        cause: e,
      ),
      FacadeWire.attributeRejected => BugseeAttributeException(
        AttributeFailure.rejected,
        'value',
        '$what: $message',
        cause: e,
      ),
      _ => BugseeException('$what: $message', cause: e),
    };
  }

  /// A value the SDK holds, as the public API returns it: a String, bool, int, double or a list of
  /// strings; `null` for anything else (native already filters, this is the second line).
  static Object? readableAttribute(Object? raw) {
    if (raw is String || raw is bool || raw is int || raw is double) return raw;
    if (raw is List && raw.every((e) => e is String)) {
      return List<String>.unmodifiable(raw.cast<String>());
    }
    return null;
  }

  Future<void> setAttribute(String name, Object? value) async {
    checkAttributeName(name);
    final checked = checkAttributeValue(value);
    try {
      await _call<void>(
        'setAttribute',
        null,
        () => host.setAttribute(name, checked),
        argument: 'value',
      );
    } on BugseeArgumentException catch (e) {
      // Native defends again; the attribute calls speak BugseeAttributeException throughout.
      throw BugseeAttributeException(
        AttributeFailure.invalidValue,
        e.argument,
        e.message,
        cause: e.cause,
      );
    }
  }

  Future<Object?> getAttribute(String name) async {
    checkAttributeName(name);
    final raw = await _call<Object?>(
      'getAttribute',
      null,
      () => host.getAttribute(name),
    );
    return readableAttribute(raw);
  }

  Future<Map<String, Object>> getAllAttributes() async {
    final raw = await _call<Map<String, Object>>(
      'getAllAttributes',
      const {},
      () => host.getAllAttributes(),
    );
    return Map.unmodifiable({
      for (final e in raw.entries)
        if (readableAttribute(e.value) case final Object v) e.key: v,
    });
  }

  Future<void> clearAttribute(String name) async {
    checkAttributeName(name);
    await _call<void>('clearAttribute', null, () => host.clearAttribute(name));
  }

  Future<void> clearAllAttributes() =>
      _call<void>('clearAllAttributes', null, () => host.clearAllAttributes());

  Future<void> setUserIdentifier(String? identifier) => _call<void>(
    'setUserIdentifier',
    null,
    // An empty identifier is a clear on both platforms (Android alone would store it).
    () => host.setUserIdentifier(
      identifier == null || identifier.isEmpty ? null : identifier,
    ),
  );

  Future<String?> getUserIdentifier() =>
      _call<String?>('getUserIdentifier', null, () => host.getUserIdentifier());

  Future<void> trace(String name, Object? value) async {
    checkDataName('trace', name);
    final checked = checkTraceValue(value);
    await _call<void>(
      'trace',
      null,
      () => host.trace(name, checked),
      argument: 'value',
    );
  }

  Future<void> event(String name, Map<String, Object?>? params) async {
    checkDataName('event', name);
    final copy = params == null ? null : copyEventParams(params);
    await _call<void>(
      'event',
      null,
      () => host.event(name, copy),
      argument: 'params',
    );
  }

  Future<void> log(String message, LogLevel level) => _call<void>(
    'log',
    null,
    () => host.log(message, level.value),
    argument: 'level',
  );

  Future<bool> addBreadcrumb(BugseeBreadcrumb crumb) async {
    final data = crumb.data == null
        ? null
        : copyEventParams(crumb.data!, path: 'data');
    return _call<bool>(
      'addBreadcrumb',
      false,
      () => host.addBreadcrumb(
        BreadcrumbMessage(
          category: crumb.category,
          level: crumb.level.name,
          message: crumb.message,
          type: crumb.type,
          data: data,
        ),
      ),
      argument: 'breadcrumb',
    );
  }

  Future<void> notify(
    String title, {
    String? body,
    ReportSeverity? severity,
    Map<String, String>? fields,
    bool urgent = false,
  }) async {
    if (title.trim().isEmpty) {
      // Both SDKs drop it and only log.
      throw const BugseeArgumentException(
        'title',
        'a notification needs a non-empty title',
      );
    }
    // Pairs, in the map's order: a map would lose it crossing the bridge.
    final flat = fields == null
        ? null
        : [
            for (final e in fields.entries) ...[e.key, e.value],
          ];
    await _call<void>(
      'notify',
      null,
      () => host.relayNotification(title, body, severity?.value, flat, urgent),
      argument: 'severity',
    );
  }

  Future<void> startBlackout() =>
      _call<void>('startBlackout', null, () => host.startBlackout());

  Future<void> endBlackout() =>
      _call<void>('endBlackout', null, () => host.endBlackout());

  Future<bool> isBlackout() =>
      _call<bool>('isBlackout', false, () => host.isBlackout());

  Future<void> showReportDialog({
    String? summary,
    String? description,
    ReportSeverity? severity,
    List<String>? labels,
  }) async {
    final checked = labels == null ? null : checkLabels(labels);
    await _call<void>(
      'showReportDialog',
      null,
      () =>
          host.showReportDialog(summary, description, severity?.value, checked),
      argument: 'severity',
    );
  }

  Future<void> upload(
    String summary,
    String description, {
    ReportSeverity? severity,
    List<String>? labels,
  }) async {
    final checked = labels == null ? null : checkLabels(labels);
    await _call<void>(
      'upload',
      null,
      () => host.upload(summary, description, severity?.value, checked),
      argument: 'severity',
    );
  }

  // ---- Network capture (Phase 5b) ---------------------------------------------------------------

  /// The capture, the filter and the queue to the SDK; see `lib/src/network`.
  late final NetworkCaptureService network = NetworkCaptureService(
    send: (batch) => host.addNetworkEvents(batch),
    loadPolicy: _loadNetworkPolicy,
    ensureAttached: ensureStartedInBackground,
    statuses: () => bridge.statusChanges,
    supported: () => _platform() != null,
    // iOS has no redirect stage: the hop entries are not even created there.
    dropRedirectStage: _platform() == OptionPlatform.ios,
    warn: _warn,
  );

  Future<NetworkPolicy> _loadNetworkPolicy() async {
    final status = await host.status();
    final options = await host.launchOptions(false);
    return NetworkPolicy.from(
      options,
      launched: status == BugseeStatus.launched.name,
    );
  }

  /// Installs the `dart:io` capture (see `Bugsee.installNetworkCapture`). A call from a
  /// background isolate is a [BugseeException]: it has no platform channels to reach the SDK
  /// with.
  bool installNetworkCapture() {
    _requireBinding();
    return network.install();
  }

  void uninstallNetworkCapture() => network.uninstall();

  bool get networkCaptureInstalled => network.installed;

  void setNetworkFilter(BugseeNetworkFilter? filter, Duration timeout) =>
      network.setFilter(filter, timeout);

  BugseeNetworkFilter? get networkFilter => network.pipeline.filter;

  NetworkCaptureStats get networkCaptureStats => network.pipeline.stats;

  // ---- Report handler and lifecycle events ------------------------------------------------------

  BugseeReportHandler? _reportHandler;

  BugseeReportHandler? get reportHandler => _reportHandler;

  /// Registers (or, with `null` or an empty handler, clears) the report handler. Completes when
  /// native knows which phases have a Dart handler.
  Future<void> setReportHandler(BugseeReportHandler? handler) async {
    final active = handler == null || handler.isEmpty ? null : handler;
    if (_platform() == null) {
      // No SDK here, so no report will ever be handed over.
      _reportHandler = active;
      return;
    }
    await ensureStarted();
    try {
      await bridge.setReportHandlers(
        onBefore: active?.onBeforeReportCreated,
        onAfter: active?.onAfterReportCreated,
      );
    } on PlatformException catch (e) {
      throw mapFacadeError('setReportHandler', e);
    }
    _reportHandler = active;
  }

  Stream<LifecycleEvent> get lifecycleEvents => bridge.lifecycleEvents;

  // ---- Dart errors (Phase 5a) -------------------------------------------------------------------

  /// `detect.crash` of the launch this app made through Dart (default true, the SDKs' default). The
  /// installed handlers report nothing while it is false, like the SDKs' own crash detection; an
  /// explicit `logException` is not affected. A launch the app made natively is not seen here.
  bool _detectCrash = true;

  static bool _detectCrashOf(Map<String, Object> values) =>
      values['com.bugsee.option.detect.crash'] != false;

  /// The installed handlers (FlutterError, PlatformDispatcher, isolate listeners, zone errors).
  late final ErrorCapture errorCapture = ErrorCapture(
    report: (payload, {required handled}) async {
      await _sendException(payload, handled: handled, domain: null);
    },
    enabled: () => _detectCrash,
    warn: _warn,
  );

  /// Reports [error] to the SDK. Completes with whether the SDK was handed it (`false` before
  /// launch and after stop: both SDKs drop it there; nothing is queued).
  Future<bool> logException(
    Object error,
    StackTrace? stack, {
    required bool handled,
    String? domain,
    bool stackCaptured = false,
  }) {
    if (domain != null &&
        (domain.isEmpty || domain.length > ExceptionWire.maxDomainLength)) {
      return Future<bool>.error(
        const BugseeArgumentException(
          'domain',
          'the domain must be 1 to ${ExceptionWire.maxDomainLength} UTF-16 units',
        ),
      );
    }
    final payload = buildExceptionPayload(
      error,
      stack,
      stackCaptured: stackCaptured,
    );
    return _sendException(payload, handled: handled, domain: domain);
  }

  Future<bool> _sendException(
    ExceptionPayload payload, {
    required bool handled,
    required String? domain,
  }) => _call<bool>(
    'logException',
    false,
    () => host.logException(payload.json, handled, domain),
    // Dart checked the domain and built a document under the limit, so a refusal is about the
    // document: the native message says what (never the domain, which was valid).
    argument: 'error',
  );
}
