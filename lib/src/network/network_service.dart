// Installs the capture, keeps the policy current, owns the pipeline. Internal; the `Bugsee`
// facade is a thin layer over it (through `BugseeRuntime`).
import 'dart:async';
import 'dart:io' show HttpOverrides;

import '../errors.dart';
import '../launch.dart' show BugseeException;
import '../status.dart';
import 'http_capture.dart';
import 'network_event.dart';
import 'network_pipeline.dart';
import 'network_policy.dart';

final class NetworkCaptureService {
  NetworkCaptureService({
    required NetworkSend send,
    required Future<NetworkPolicy> Function() loadPolicy,
    required void Function() ensureAttached,
    required Stream<BugseeStatus> Function() statuses,
    required bool Function() supported,
    void Function(String message)? warn,
    NetworkPipeline Function(NetworkSend send, NetworkPolicy Function() policy)?
    pipelineFactory,
  }) : _loadPolicy = loadPolicy,
       _ensureAttached = ensureAttached,
       _statuses = statuses,
       _supported = supported,
       _warn = warn ?? ((_) {}) {
    pipeline = (pipelineFactory ?? _defaultPipeline)(send, () => _policy);
    controller = HttpCaptureController(
      policy: () => _policy,
      record: pipeline.submit,
    )..active = false;
  }

  static NetworkPipeline _defaultPipeline(
    NetworkSend send,
    NetworkPolicy Function() policy,
  ) => NetworkPipeline(send: send, policy: policy);

  final Future<NetworkPolicy> Function() _loadPolicy;
  final void Function() _ensureAttached;
  final Stream<BugseeStatus> Function() _statuses;
  final bool Function() _supported;
  final void Function(String) _warn;

  late final NetworkPipeline pipeline;
  late final HttpCaptureController controller;

  NetworkPolicy _policy = NetworkPolicy.off;
  BugseeHttpOverrides? _overrides;
  HttpOverrides? _probedCurrent;
  StreamSubscription<BugseeStatus>? _statusSubscription;
  int _generation = 0;
  bool _warnedUnsupported = false;

  /// The policy in force (for tests and diagnostics).
  NetworkPolicy get policy => _policy;

  /// Whether the capture is installed and active.
  bool get installed => controller.active && _overrides != null;

  /// Installs the capture; idempotent. Returns whether it is in effect.
  ///
  /// Chains to the overrides in effect now ([HttpOverrides.current]); a second call while this
  /// capture is still the one in effect does nothing, and one after the app replaced the overrides
  /// without chaining re-installs it in front of the app's.
  bool install() {
    if (!_supported()) {
      if (!_warnedUnsupported) {
        _warnedUnsupported = true;
        _warn(
          'Bugsee network capture runs on Android and iOS only; nothing was installed',
        );
      }
      return false;
    }
    final current = HttpOverrides.current;
    // Inside `HttpOverrides.runZoned`/`runWithHttpOverrides` the current overrides are the zone's,
    // not the global ones: chaining to them and making that chain global would leak a scope into
    // the whole isolate. Call it from the root zone (main).
    if (!identical(current, Zone.root.run(() => HttpOverrides.current))) {
      throw const BugseeException(
        'installNetworkCapture was called inside a zone that scopes its own HttpOverrides; call it from the root zone (main, before runApp)',
      );
    }
    // Probing creates a real client through the app's overrides, so it is done once per set of
    // overrides in effect: a repeated call with the same ones answers from the first probe.
    if (installed &&
        (identical(current, _probedCurrent) || isHttpCaptureInEffect())) {
      _probedCurrent = current;
      return true;
    }
    _probedCurrent = null;
    controller.active = true;
    final overrides = BugseeHttpOverrides(controller, current);
    HttpOverrides.global = overrides;
    _overrides = overrides;
    _statusSubscription ??= _statuses().listen((status) {
      // A stop takes effect at once; a launch is believed only once the options are read.
      if (status != BugseeStatus.launched) _policy = _policy.notAccepting();
      unawaited(refreshPolicy());
    }, onError: (Object _) {});
    _ensureAttached();
    unawaited(refreshPolicy());
    return true;
  }

  /// Stops capturing. Restores the overrides that were in place before, when this capture is still
  /// the one set; if the app chained over it, it stays in the chain and forwards without recording
  /// (removing a link of someone else's chain is not ours to do).
  void uninstall() {
    final overrides = _overrides;
    controller.active = false;
    _generation++;
    _probedCurrent = null;
    // Events already captured (and already through the filter) are still handed to the SDK: the
    // app asked to stop recording, not to lose what it recorded. The SDK's own gate drops them if
    // it is no longer launched.
    if (overrides != null && identical(HttpOverrides.current, overrides)) {
      HttpOverrides.global = overrides.previous;
    }
    _overrides = null;
    final sub = _statusSubscription;
    _statusSubscription = null;
    if (sub != null) unawaited(sub.cancel());
  }

  /// Reads the SDK's status and options again. A newer call supersedes an older one still in
  /// flight; a failure to read leaves nothing accepted (fail closed).
  Future<void> refreshPolicy() async {
    if (!installed) return;
    final generation = ++_generation;
    NetworkPolicy next;
    try {
      next = await _loadPolicy();
    } catch (_) {
      next = _policy.notAccepting();
    }
    if (generation == _generation && installed) _policy = next;
  }

  void setFilter(BugseeNetworkFilter? filter, Duration timeout) {
    if (timeout <= Duration.zero || timeout > const Duration(minutes: 5)) {
      throw const BugseeArgumentException(
        'timeout',
        'the filter timeout must be positive and at most 5 minutes',
      );
    }
    pipeline.setFilter(filter, timeout);
  }
}
