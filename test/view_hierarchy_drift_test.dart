// Drift guards for the managed view hierarchy (`vh`): what Dart, Java and Objective-C repeat, what the
// SDKs fix (extracted from their source into test/fixtures/data_requests.json by
// scripts/extract_data_requests.dart), and the structural promises the design rests on: the answer
// never waits, there is one place that converts units, and the builder reads no text.
import 'dart:convert';
import 'dart:io';

import 'package:bugsee_flutter/src/view_hierarchy/hierarchy_builder.dart';
import 'package:flutter_test/flutter_test.dart';

String code(String path) =>
    File(path)
        .readAsStringSync()
        .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
        .replaceAll(RegExp(r'//[^\n]*'), '');

Map<String, Object?> json(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

const java = 'android/src/main/java/com/bugsee/flutter';
const objc = 'ios/bugsee_flutter/Sources/bugsee_flutter_wrapper';

/// The text of the method that starts at [signature], to its closing brace.
String body(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: 'no $signature');
  final open = source.indexOf('{', start);
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) return source.substring(open, i + 1);
  }
  fail('unbalanced braces after $signature');
}

void main() {
  final fixture = json('test/fixtures/data_requests.json');
  final android = fixture['android']! as Map<String, Object?>;
  final ios = fixture['ios']! as Map<String, Object?>;
  final store = code('$java/ViewHierarchyStore.java');
  final mStore = code('$objc/BGSFlutterViewHierarchyStore.m');
  final wrapper = code('$java/FlutterWrapper.java');
  final mWrapper = code('$objc/BGSFlutterWrapper.m');
  final secure = code('$java/SecureRectangleStore.java');
  final mSecure = code('$objc/BGSFlutterSecureRectangleStore.m');
  final plugin = code('$java/BugseeFlutterPlugin.java');
  final swift = code(
    'ios/bugsee_flutter/Sources/bugsee_flutter/BugseeFlutterPlugin.swift',
  );

  group('what the SDKs fix', () {
    test('the fixture was extracted at the pinned native versions', () {
      final pins = json('native-versions.json');
      final at = fixture['pins']! as Map<String, Object?>;
      expect(at['android'], (pins['android']! as Map)['sdk']);
      expect(at['ios'], (pins['ios']! as Map)['sdk']);
    });

    test('the request type is the SDKs, on both platforms', () {
      expect(android['vhType'], 'vh');
      expect(ios['vhType'], 'vh');
      expect(
        RegExp(r'TYPE\s*=\s*"([^"]*)"').firstMatch(store)!.group(1),
        android['vhType'],
      );
      expect(
        RegExp(r'kDataType\s*=\s*@"([^"]*)"').firstMatch(mStore)!.group(1),
        ios['vhType'],
      );
    });

    test(
      'the SDKs budget is 500 ms on both, timed from when the call returns',
      () {
        // Nothing of the wrapper's depends on the number (it answers at once), but a SDK that
        // changed it would change what a slow answer costs: this makes that visible.
        expect(android['vhBudgetMs'], 500);
        expect(ios['vhBudgetMs'], 500);
        // iOS cuts to 50 ms after 3 timeouts in a row; an answer, even null, is not a timeout.
        expect(ios['silentBudgetMs'], 50);
        expect(ios['silentAfterTimeouts'], 3);
      },
    );

    test('Android 7.4.2 waits for a late reply only off the main thread', () {
      // This is why the cache exists: the SDK asks on the main thread, where it does not wait.
      expect(android['waitsForReplyOffMainThreadOnly'], isTrue);
    });
  });

  group('the answer', () {
    test(
      'Android: vh from the store, everything else null, once, never throws',
      () {
        final b = body(wrapper, 'public void requestData');
        expect(b, contains('ViewHierarchyStore.TYPE.equals(dataType)'));
        expect(b, contains('views.answer()'));
        expect(RegExp(r'callback\.onResult\(').allMatches(b), hasLength(1));
        expect(b, contains('catch (Throwable'));
      },
    );

    test('iOS: vh from the store, everything else nil, once, never throws', () {
      final b = body(mWrapper, 'requestDataWithType');
      expect(b, contains('[BGSFlutterViewHierarchyStore dataType]'));
      expect(b, contains('[_views answer]'));
      expect(RegExp(r'\[callback onResult:').allMatches(b), hasLength(1));
      expect(b, contains('@catch'));
    });

    test('nothing in the answer path blocks', () {
      // The SDK asks on the main thread; Dart needs the platform thread: any wait is a deadlock.
      const banned = [
        'CountDownLatch',
        '.await(',
        'Thread.sleep',
        '.join(',
        '.wait(',
        'FutureTask',
        'dispatch_semaphore',
        'dispatch_sync',
        'dispatch_group_wait',
        'performSelectorOnMainThread',
        'waitUntilDone',
      ];
      for (final b in banned) {
        expect(store, isNot(contains(b)), reason: 'ViewHierarchyStore: $b');
        expect(
          mStore,
          isNot(contains(b)),
          reason: 'BGSFlutterViewHierarchyStore: $b',
        );
      }
      // Reads take no lock on Android (an immutable map behind a volatile); the writers do.
      expect(body(store, 'String answer()'), isNot(contains('synchronized')));
      expect(
        body(store, 'private String render('),
        isNot(contains('synchronized')),
      );
      // iOS takes the write lock only to copy two pointers.
      final b = body(mStore, '- (NSString *)answer');
      expect(RegExp(r'@synchronized').allMatches(b), hasLength(1));
      expect(b, isNot(contains('dispatch_')));
    });

    test('nothing is cached rendered: every answer is converted afresh', () {
      // The view can move with no Dart frame; a cached string would be served in the old place.
      expect(store, isNot(contains('lastAnswer')));
      expect(store, isNot(contains('cachedAnswer')));
      expect(body(store, 'private String render('), contains('mapperFor('));
      expect(
        body(mStore, '- (NSString *)renderOwner'),
        contains('mapperForOwner:'),
      );
    });
  });

  group('units and placement have one home', () {
    test('both stores convert through the secure rectangles Mapper', () {
      expect(store, contains('placement.mapperFor('));
      expect(mStore, contains('[_placement mapperForOwner:'));
      expect(secure, contains('Mapper.create('));
      expect(mSecure, contains('mapperForPlacement:'));
      // ... and the secure rectangles use it too, not a second copy of the arithmetic.
      expect(body(secure, 'private int[] serve('), contains('Mapper.create('));
      expect(
        body(mSecure, 'static NSData *BGSServe'),
        contains('mapperForPlacement:'),
      );
    });

    test('the view hierarchy store knows nothing about density or scale', () {
      for (final word in ['density', 'DisplayMetrics', 'getResources']) {
        expect(
          store,
          isNot(contains(word)),
          reason: 'ViewHierarchyStore: $word',
        );
      }
      for (final word in ['UIScreen', 'scale', 'nativeRatio']) {
        expect(mStore, isNot(contains(word)), reason: 'iOS store: $word');
      }
    });

    test('the unit factor is not applied outside the Mapper', () {
      // Java: the only multiplication of a logical value by a factor is Mapper.px/py.
      expect(RegExp(r'\*\s*factor').allMatches(secure).length, 2);
      expect(
        RegExp(r'_factor').allMatches(mSecure).length,
        greaterThanOrEqualTo(3),
      );
    });
  });

  group('the shape of a snapshot is the same everywhere', () {
    test('two more segments than boxes, in Dart, Java and Objective-C', () {
      expect(store, contains('bounds.length / 4 + 2'));
      expect(mStore, contains('doubles / 4 + 2'));
      final dart = File('lib/src/view_hierarchy/hierarchy_builder.dart')
          .readAsStringSync();
      expect(dart, contains('bounds.length / 4 + 2'));
    });

    test('the template cap and the retired-epoch memory agree', () {
      final j = int.parse(
        RegExp(r'MAX_TEMPLATE_CHARS\s*=\s*1 << (\d+)')
            .firstMatch(store)!
            .group(1)!,
      );
      final o = int.parse(
        RegExp(r'kMaxTemplateCharacters\s*=\s*1u << (\d+)')
            .firstMatch(mStore)!
            .group(1)!,
      );
      expect(j, o);
      expect(
        int.parse(
          RegExp(r'RETIRED_EPOCHS\s*=\s*(\d+)').firstMatch(store)!.group(1)!,
        ),
        int.parse(
          RegExp(r'kRetiredEpochs\s*=\s*(\d+)').firstMatch(mStore)!.group(1)!,
        ),
      );
      expect(
        int.parse(
          RegExp(r'RETIRED_EPOCHS\s*=\s*(\d+)').firstMatch(secure)!.group(1)!,
        ),
        int.parse(
          RegExp(r'RETIRED_EPOCHS\s*=\s*(\d+)').firstMatch(store)!.group(1)!,
        ),
        reason: 'the same ordering memory as the secure rectangles',
      );
    });

    test('Dart never sends more than native accepts', () {
      const limits = HierarchyLimits();
      final j =
          1 <<
          int.parse(
            RegExp(r'MAX_TEMPLATE_CHARS\s*=\s*1 << (\d+)')
                .firstMatch(store)!
                .group(1)!,
          );
      // The template plus its numbers, with a large margin for the numbers.
      expect(limits.maxBytes + limits.maxNodes * 32, lessThan(j));
    });

    test('the magnitude limit is the secure rectangles on both platforms', () {
      expect(RegExp(r'LIMIT\s*=\s*1 << 28;').hasMatch(store), isTrue);
      expect(RegExp(r'kLimit\s*=\s*268435456\.0;').hasMatch(mStore), isTrue);
    });
  });

  group('who owns it', () {
    test('an engine detach drops its snapshot on both platforms', () {
      expect(plugin, contains('ViewHierarchyStore.shared().dropOwner(owner)'));
      expect(
        swift,
        contains('BGSFlutterViewHierarchyStore.shared().dropOwner(owner)'),
      );
    });

    test('the bridge method is implemented on both platforms', () {
      expect(plugin, contains('public Boolean setViewHierarchy('));
      expect(
        swift,
        contains('func setViewHierarchy(snapshot: ViewHierarchyMessage)'),
      );
    });

    test('the store lives outside the replaceable wrapper', () {
      // The wrapper holds a reference to the process-wide store and nothing it must keep.
      expect(wrapper, contains('ViewHierarchyStore.shared()'));
      expect(mWrapper, contains('[BGSFlutterViewHierarchyStore shared]'));
      expect(wrapper, isNot(contains('new ViewHierarchyStore')));
    });

    test('the SDK asks on the main thread, so the placement refresh is synchronous there', () {
      expect(plugin, contains('refreshForViewHierarchy'));
      expect(
        body(plugin, 'private static void refreshForViewHierarchy'),
        contains('Looper.myLooper() == Looper.getMainLooper()'),
      );
    });
  });

  group('the builder reads no text', () {
    final src = code('lib/src/view_hierarchy/hierarchy_builder.dart');

    test('the only members read off a render object are structural', () {
      final reads = RegExp(r'\bro\.(\w+)')
          .allMatches(src)
          .map((m) => m.group(1)!)
          .toSet();
      const structural = {
        'attached',
        'hasSize',
        'size',
        'paintBounds',
        'parent',
        'getTransformTo',
        'flutterView',
        'enabled',
        'onTap',
        'onLongPress',
        'properties',
        'opacity',
        'visitChildren',
        'describeApproximatePaintClip',
      };
      expect(
        reads.difference(structural),
        isEmpty,
        reason:
            'a new member read off a render object must be reviewed for text',
      );
      // `properties` is a Semantics annotation's: only whether a callback exists is read from it.
      final props = RegExp(r'\bp\.(\w+)')
          .allMatches(src)
          .map((m) => m.group(1)!)
          .toSet();
      expect(props, {'onTap', 'onLongPress'});
    });

    test('no text, label, key, tag or semantics is read anywhere', () {
      for (final pattern in [
        r'\.text\b',
        r'\.label\b',
        r'\.hint\b',
        r'(?<!opacity)\.value\b',
        r'\.tooltip\b',
        r'\.controller\b',
        r'\.tag\b',
        r'\.key\b',
        r'\bKey\b',
        r'ValueKey',
        r'GlobalKey',
        r'semanticsLabel',
        r'toPlainText',
        r'toStringDeep',
        r'toStringShort',
        r'debugLabel',
        r'debugDescribeChildren',
        r'describeSemanticsConfiguration',
        r'SemanticsNode',
        r'SemanticsConfiguration',
        r'\bsemanticsOwner\b',
        r'RenderParagraph',
        r'RenderEditable',
        r'EditableText',
        r'TextEditingController',
      ]) {
        expect(
          RegExp(pattern).hasMatch(src),
          isFalse,
          reason: 'hierarchy_builder.dart mentions $pattern',
        );
      }
    });

    test('the only string taken from the tree is a runtime type name', () {
      final calls = RegExp(r'(\w+(?:\(\))?)\.toString\(').allMatches(src);
      final buffers = {
        '_text',
        'out',
      }; // StringBuffers the template is written to
      var types = 0;
      for (final m in calls) {
        if (buffers.contains(m.group(1))) continue;
        expect(
          m.group(0),
          matches(RegExp(r'runtimeType\.toString\(')),
          reason: 'toString on ${m.group(1)}',
        );
        types++;
      }
      expect(types, 2, reason: 'the name and the obfuscation probe');
      // The widget is only ever asked for its type.
      expect(
        RegExp(r'\.widget\b').allMatches(src).map((m) {
          return src.substring(m.start - 11, m.end + 8);
        }),
        everyElement(contains('_typeName(e.widget,')),
      );
    });

    test('the secure node takes nothing from the widget it stands for', () {
      final b = body(src, 'void _visitRender(');
      final from = b.indexOf('if (ro is RenderSecureRegion');
      final branch = b.substring(
        from,
        b.indexOf('if (ro is RenderSemantics', from),
      );
      expect(branch, contains('_Node(secureNodeClassName)'));
      expect(branch, isNot(contains('e.widget')));
      expect(
        branch,
        isNot(contains('_pushChildren(')),
        reason: 'nothing below it',
      );
    });
  });

  group('the walk is sliced strictly, and only the publisher slices', () {
    final src = code('lib/src/view_hierarchy/hierarchy_builder.dart');
    final pub = code('lib/src/view_hierarchy/publisher.dart');
    final doc = File('doc/view-hierarchy.md').readAsStringSync();

    test('the walker is synchronous and holds no timer, frame or future', () {
      // Where a walk stops is a time slice handed to `step`; when the next one runs is the
      // publisher's (a frame abandons the walk). The walker must not learn either.
      for (final pattern in [
        r'SchedulerBinding',
        r'\bTimer\b',
        r'addPostFrameCallback',
        r'\bFuture\b',
        r'\basync\b',
        r'\bawait\b',
        r'Isolate',
      ]) {
        expect(
          RegExp(pattern).hasMatch(src),
          isFalse,
          reason: 'hierarchy_builder.dart mentions $pattern',
        );
      }
    });

    test('there is no recursion into the tree: children are listed, then visited from one loop', () {
      final visitors = RegExp(r'debugVisitOnstageChildren\((\w+)\)')
          .allMatches(src)
          .map((m) => m.group(1))
          .toList();
      // The list of children of a level, the containment scan and the search for the view (both read,
      // neither builds a node).
      expect(visitors.toSet(), {'_collect', 'visit'});
      expect(visitors.where((v) => v == '_collect'), hasLength(1));
      expect(
        RegExp(r'\b_visit\(').allMatches(src),
        hasLength(2),
        reason: 'its definition and the one call, in the loop',
      );
      expect(body(src, 'void _walkSome()'), contains('_visit(child'));
    });

    test('the caps and the clock are the walk\'s, not a slice\'s', () {
      expect(body(src, 'bool _capped('), contains('_elapsed()'));
      expect(
        src,
        matches(
          RegExp(
            r'Duration _elapsed\(\)\s*=>\s*_spent \+ \(now\(\) - _sliceStart\)',
            dotAll: true,
          ),
        ),
      );
      expect(body(src, 'bool step('), contains('_spent +='));
    });

    test('a walk that resumes into a changed tree fails closed', () {
      expect(body(src, 'bool step('), contains('_stillMounted()'));
      expect(body(src, 'void _walkSome()'), contains('mounted'));
    });

    test(
      'a frame abandons the walk; a due frame ends it at its next slice',
      () {
        expect(
          body(pub, 'void _onFrame('),
          allOf(contains('_abandonWalk()'), contains('_consider()')),
        );
        expect(
          body(pub, 'void _onFrame(').indexOf('_abandonWalk()'),
          lessThan(body(pub, 'void _onFrame(').indexOf('_consider()')),
        );
        expect(body(pub, 'void _runSlice()'), contains('_framePending()'));
      },
    );

    test('only a walk after a real quiet stretch is sliced, and never a forced one', () {
      final b = body(pub, 'bool _sliceable(');
      expect(b, contains('maxAbandons'));
      expect(
        b,
        contains('_lastSent == null'),
        reason: 'nothing held: one piece',
      );
      expect(b, contains('busyGap'));
      expect(b, contains('_framePending()'));
      // An explicit capture, and a retry after a failed send, take a walk in one piece.
      expect(
        body(pub, 'Future<void> flush()'),
        contains('_buildAndSend(explicit: true)'),
      );
      expect(
        body(pub, 'Future<void> flush()'),
        isNot(contains('_startSlicedWalk')),
      );
      expect(
        RegExp(r'\b_startSlicedWalk\(').allMatches(pub),
        hasLength(2),
        reason: 'its definition and the one call, in _consider',
      );
    });

    test('a slice runs from its own timer, never inside a frame', () {
      expect(RegExp(r'Timer\(').allMatches(pub).length, greaterThan(0));
      expect(
        RegExp(r'addPostFrameCallback').allMatches(pub),
        hasLength(1),
        reason: 'the one that notices frames: no slice is run from a callback',
      );
      expect(body(pub, 'void _runSlice()'), contains('_sliceScheduler('));
    });

    test('the defaults are the ones the document states', () {
      expect(pub, contains('this.sliceShare = 0.12'));
      expect(pub, contains('this.minSlice = const Duration(milliseconds: 1)'));
      expect(pub, contains('this.maxSlice = const Duration(milliseconds: 4)'));
      expect(
        pub,
        contains('this.slicedBudget = const Duration(milliseconds: 100)'),
      );
      expect(pub, contains('this.maxAbandons = 3'));
      expect(doc, contains('`sliceShare` = 0.12'));
      expect(doc, contains('`slicedBudget` = 100 ms'));
      expect(doc, contains('`maxAbandons` = 3'));
      expect(doc, contains('between 1 and 4 ms'));
    });
  });
}
