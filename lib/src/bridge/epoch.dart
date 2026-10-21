// A random id for this Dart isolate, shared by every native store that orders messages by
// `(epoch, sequence)`.
import 'dart:math' as math;

/// A random id for this isolate, never a clock: a clock can go backwards before a hot restart,
/// and native would then reject the new isolate as a straggler of the old one. Never 0.
int newIsolateEpoch() {
  final random = math.Random.secure();
  final int id = (random.nextInt(1 << 30) << 22) | random.nextInt(1 << 22);
  return id == 0 ? 1 : id;
}
