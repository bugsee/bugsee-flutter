// Drift guards for what the secure-rectangle store repeats across Android (Java)
// and iOS (Objective-C), and what the SDKs' contracts fix (workbook Part 5). The
// behaviour itself is tested by test/secure_region_test.dart, the JUnit tests and
// the XCTests.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String code(String path) => File(path)
    .readAsStringSync()
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

const java = 'android/src/main/java/com/bugsee/flutter';
const objc = 'ios/bugsee_flutter/Sources/bugsee_flutter_wrapper';

num number(String source, RegExp pattern) {
  final m = pattern.firstMatch(source);
  expect(m, isNotNull, reason: 'no match for ${pattern.pattern}');
  return num.parse(m!.group(1)!);
}

void main() {
  final store = code('$java/SecureRectangleStore.java');
  final tracker = code('$java/SecurePlacement.java');
  final throttle = code('$java/PullThrottle.java');
  final mStore = code('$objc/BGSFlutterSecureRectangleStore.m');
  final mTracker = code('$objc/BGSFlutterSecurePlacementTracker.m');

  test('the whole-display fallback size is the same on both platforms', () {
    final j = number(store, RegExp(r'FALLBACK_DISPLAY_SIZE\s*=\s*(\d+);'));
    final o = number(mStore, RegExp(r'kFallbackDisplaySize\s*=\s*(\d+);'));
    expect(j, o);
    expect(j, 16384);
  });

  test('the magnitude limit is the same on both platforms', () {
    // Java: `1 << 28`; Objective-C: 268435456.0 (2^28).
    expect(
      RegExp(r'LIMIT\s*=\s*1 << 28;').hasMatch(store),
      isTrue,
      reason: 'Java LIMIT',
    );
    expect(number(mStore, RegExp(r'kLimit\s*=\s*(\d+)\.0;')), 1 << 28);
  });

  test('"unknown version" is 0 on both, and is the SDKs value', () {
    expect(
      store,
      contains(
        'UNKNOWN_VERSION = BugseeWrapper.SECURE_RECTANGLES_VERSION_UNKNOWN',
      ),
    );
    expect(number(mStore, RegExp(r'kUnknownVersion\s*=\s*(\d+);')), 0);
  });

  test('the header is [version, count] on both', () {
    expect(number(store, RegExp(r'HEADER_INTS\s*=\s*(\d+);')), 2);
    expect(number(mStore, RegExp(r'kHeaderInts\s*=\s*(\d+);')), 2);
  });

  test('the implicit view is 0 and iOS polls display 0 only', () {
    expect(number(tracker, RegExp(r'IMPLICIT_VIEW_ID\s*=\s*(\d+);')), 0);
    expect(number(mTracker, RegExp(r'kImplicitViewId\s*=\s*(\d+);')), 0);
    expect(number(mTracker, RegExp(r'kDefaultDisplay\s*=\s*(\d+);')), 0);
  });

  test('the pull refresh interval is 100 ms on both', () {
    expect(number(throttle, RegExp(r'MIN_INTERVAL_MS\s*=\s*(\d+);')), 100);
    expect(
      number(mTracker, RegExp(r'kMinPullRefreshInterval\s*=\s*([\d.]+);')),
      0.1,
    );
  });

  test('the version never lands on 0 on either platform', () {
    expect(store, contains('next == UNKNOWN_VERSION ? next + 1 : next'));
    expect(mStore, contains('next == kUnknownVersion ? next + 1 : next'));
  });

  test('both stores order messages by epoch and sequence the same way', () {
    // Same epoch: sequence must grow. A retired epoch (a dead isolate) is
    // ignored; an unseen one is a new isolate and wins, whatever its number.
    expect(store, contains('last.retired.contains(epoch)'));
    expect(store, contains('if (sequence <= last.sequence)'));
    expect(mStore, contains('[lastRetired containsObject:@(epoch)]'));
    expect(mStore, contains('if (sequence <= lastSequence) return NO;'));
    expect(
      number(store, RegExp(r'RETIRED_EPOCHS\s*=\s*(\d+);')),
      number(mStore, RegExp(r'kRetiredEpochs\s*=\s*(\d+);')),
    );
  });

  test('the grace window and its limits are the same on both platforms', () {
    expect(number(store, RegExp(r'GRACE_MS\s*=\s*(\d+);')), 120);
    expect(number(mStore, RegExp(r'kGraceSeconds\s*=\s*([\d.]+);')), 0.12);
    expect(
      number(store, RegExp(r'MAX_RECTANGLES\s*=\s*(\d+);')),
      number(mStore, RegExp(r'kMaxRectangles\s*=\s*(\d+);')),
    );
  });

  test('the ratio a message must match the display at is the same', () {
    expect(
      number(store, RegExp(r'RATIO_TOLERANCE\s*=\s*([\d.e-]+);')),
      number(mStore, RegExp(r'kRatioTolerance\s*=\s*([\d.e-]+);')),
    );
  });

  test('units: Android takes physical pixels (1), iOS points (1 / screen '
      'scale, never multiplied in)', () {
    final env = code('$java/SecureEnvironment.java');
    expect(env, contains('getDisplayMetrics().density'));
    expect(env, contains('return 1;'));
    expect(mTracker, contains('return scale > 0 ? 1.0 / scale : NAN;'));
    // The screen's scale is read for the ratio and divided out; it is never
    // returned as the unit factor.
    expect(mTracker, isNot(contains('return scale;')));
  });
}
