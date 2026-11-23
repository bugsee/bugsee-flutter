// Decides when the managed view hierarchy is published (doc/view-hierarchy.md). Internal.
//
// All three must hold, or nothing is built and native's copy is cleared:
//  * the SDK is LAUNCHED (before a launch and after a stop the SDK asks for nothing, and a
//    snapshot sitting in memory would be stale for the next launch);
//  * the SDK's own view-hierarchy capture option is ON (`capture.view-hierarchy`, default on
//    both SDKs): with it off the SDK never asks, and building a tree is wasted work;
//  * the app is in the FOREGROUND: a snapshot taken for a screen the user is no longer looking
//    at must not be served to a report made later.
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../status.dart';
import 'publisher.dart';

/// The SDK's switch for view-hierarchy capture. The same key on both platforms; a test compares
/// it with the generated option registry.
const String viewHierarchyOptionKey =
    'com.bugsee.option.capture.view-hierarchy';

class ViewHierarchyController with WidgetsBindingObserver {
  ViewHierarchyController({
    required this.publisher,
    required this.readOption,
    bool? foreground,
    this.readRetryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
  }) : _foreground = foreground ?? _foregroundNow();

  final ViewHierarchyPublisher publisher;

  /// Reads the launch options in effect and answers whether the SDK captures the view hierarchy.
  /// An error counts as "off" (fail closed).
  final Future<bool> Function() readOption;

  /// Waits between the retries of an option read that FAILED (a channel hiccup right after
  /// `launched` must not switch publishing off for the whole launch); a read that answered
  /// "off" is final. After the last retry it counts as off.
  final List<Duration> readRetryDelays;

  bool _launched = false;
  bool _optionOn = false;
  bool _foreground;
  int _generation = 0;
  StreamSubscription<BugseeStatus>? _subscription;
  bool _observing = false;

  static bool _foregroundNow() {
    try {
      final AppLifecycleState? state = WidgetsBinding.instance.lifecycleState;
      return _isForeground(state);
    } catch (_) {
      return true;
    }
  }

  /// `inactive` is still foreground (a system dialog over a visible app); `hidden`, `paused`
  /// and `detached` are not. Unknown (before the first frame) counts as foreground.
  static bool _isForeground(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  /// Follows the SDK's status from [current] on. Safe to call again: the earlier subscription is
  /// replaced.
  void attach(BugseeStatus? current, Stream<BugseeStatus> changes) {
    if (!_observing) {
      try {
        WidgetsBinding.instance.addObserver(this);
        _observing = true;
      } catch (_) {
        // No binding: lifecycle is then taken as foreground.
      }
    }
    _subscription?.cancel();
    _subscription = changes.listen(onStatus);
    if (current != null) onStatus(current);
  }

  /// A status transition. `launched` reads the option; anything else switches publishing off.
  void onStatus(BugseeStatus status) {
    final int generation = ++_generation;
    if (status != BugseeStatus.launched) {
      _launched = false;
      _optionOn = false;
      _apply();
      return;
    }
    _launched = true;
    unawaited(() async {
      var on = false;
      for (var attempt = 0; ; attempt++) {
        try {
          on = await readOption();
          break;
        } catch (_) {
          on = false;
        }
        if (attempt >= readRetryDelays.length) break;
        await Future<void>.delayed(readRetryDelays[attempt]);
        // A newer transition during the wait wins: stop retrying for a launch that is over.
        if (generation != _generation) return;
      }
      // A newer transition (a stop while the read was in flight) wins.
      if (generation != _generation) return;
      _optionOn = on;
      _apply();
    }());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = _isForeground(state);
    _apply();
  }

  void _apply() {
    if (_launched && _optionOn && _foreground) {
      publisher.activate();
    } else {
      unawaited(publisher.deactivate());
    }
  }

  /// Whether snapshots are wanted right now.
  bool get wanted => _launched && _optionOn && _foreground;
}
