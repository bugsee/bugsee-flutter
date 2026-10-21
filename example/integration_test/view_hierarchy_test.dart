// Runs on a device or simulator (it needs the native SDKs):
//
//   cd example && flutter test integration_test/view_hierarchy_test.dart -d <device>
//
// The managed view hierarchy (`vh`) through the real SDKs: the SDK asks the plugin for the Flutter
// widget tree when it builds a report, the plugin answers from memory, and the SDK stores the
// answer byte for byte. The readback is the SDK's own storage:
//
//  * Android: the report bundle the SDK keeps on disk when it cannot upload (the endpoint is a
//    closed port, so the bundle stays), `*.viewtree.json`: the entry the report carries, with the
//    native tree beside it, so the managed root's box can be compared with the native FlutterView's.
//  * iOS: the SDK's capture buffer (`Library/Caches/com.bugsee.data/capture/.../bbf466fa-....bgsfile`,
//    the view-hierarchy entries). A placeholder token makes the SDK refuse its first upload and
//    stop, so no report bundle is assembled on a simulator; what is stored is what a report would
//    carry.
//
// What is asserted: the entry is in the report that was made (the Android async-reply trap), the
// payload has no text, the secure view is one node with only its box, and the boxes are in the
// unit of the native tree (physical pixels on Android, points on iOS) at the device's density.
import 'dart:convert';
import 'dart:io';

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter/src/view_hierarchy/hierarchy_builder.dart';
import 'package:bugsee_flutter/src/view_hierarchy/publisher.dart';
import 'package:bugsee_flutter_example/main.dart';
import 'package:bugsee_flutter_example/view_hierarchy_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void say(String line) => debugPrint('integration: $line');

/// The entries of a zip (stored or deflated), by name.
Map<String, Uint8List> unzip(Uint8List z) {
  final d = ByteData.sublistView(z);
  var eocd = z.length - 22;
  while (d.getUint32(eocd, Endian.little) != 0x06054b50) {
    eocd--;
  }
  final count = d.getUint16(eocd + 10, Endian.little);
  var p = d.getUint32(eocd + 16, Endian.little);
  final out = <String, Uint8List>{};
  for (var i = 0; i < count; i++) {
    final method = d.getUint16(p + 10, Endian.little);
    final csize = d.getUint32(p + 20, Endian.little);
    final nlen = d.getUint16(p + 28, Endian.little);
    final elen = d.getUint16(p + 30, Endian.little);
    final clen = d.getUint16(p + 32, Endian.little);
    final lho = d.getUint32(p + 42, Endian.little);
    final name = utf8.decode(z.sublist(p + 46, p + 46 + nlen));
    final start =
        lho +
        30 +
        d.getUint16(lho + 26, Endian.little) +
        d.getUint16(lho + 28, Endian.little);
    final raw = z.sublist(start, start + csize);
    out[name] = method == 0
        ? raw
        : Uint8List.fromList(ZLibCodec(raw: true).decode(raw));
    p += 46 + nlen + elen + clen;
  }
  return out;
}

/// Every managed hierarchy JSON object in [text] (it starts with the root node's fixed prefix).
List<String> managedObjectsIn(String text) {
  const marker = '{"id":"0","class_name":"FlutterView"';
  final found = <String>[];
  var from = 0;
  while (true) {
    final start = text.indexOf(marker, from);
    if (start < 0) return found;
    var depth = 0;
    var inString = false;
    var i = start;
    for (; i < text.length; i++) {
      final c = text[i];
      if (inString) {
        if (c == r'\') {
          i++;
        } else if (c == '"') {
          inString = false;
        }
      } else if (c == '"') {
        inString = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}' && --depth == 0) {
        break;
      }
    }
    if (depth == 0 && i < text.length) found.add(text.substring(start, i + 1));
    from = start + marker.length;
  }
}

typedef Json = Map<String, Object?>;

Iterable<Json> walk(Json n) sync* {
  yield n;
  for (final c in (n['subitems'] as List<Object?>?) ?? const <Object?>[]) {
    yield* walk(c! as Json);
  }
}

List<num> boxOf(Json n) => (n['bounds']! as List<Object?>).cast<num>();

/// The strings that are on the screen of ViewHierarchyScreen, or typed into it, or inside its
/// secure view: none may be in the payload.
const onScreenText = [
  'TYPED-secret-123',
  'Jane',
  'example.com',
  '4242',
  'Name and e-mail',
  'Card number',
  'Capture view hierarchy',
  'The Flutter widget tree',
  'View hierarchy',
  'vh-name',
  'vh-secure',
  'vh-text',
  'vh-capture',
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final android = defaultTargetPlatform == TargetPlatform.android;

  testWidgets(
    'the Flutter tree is in the report: no text, the secure view redacted, boxes in the SDKs unit',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ViewHierarchyScreen()));
      final ratio = tester.view.devicePixelRatio;
      say('device pixel ratio $ratio, physical ${tester.view.physicalSize}');

      final result = await Bugsee.launch(
        defaultToken,
        options: BugseeOptions(
          // A closed port: the upload fails and the SDK keeps the report on disk.
          endpoint: android ? 'http://10.0.2.2:8099' : 'http://localhost:8099',
        ),
      );
      say('launch -> $result');
      expect(await Bugsee.waitUntilLaunched(), isTrue);

      await tester.enterText(
        find.byKey(const Key('vh-name')),
        'TYPED-secret-123',
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The plugin publishes by itself once the SDK is launched.
      final publisher = ViewHierarchyPublisher.instance;
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (publisher.sendCount == 0 && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      say(
        'snapshots sent: ${publisher.sendCount}, active: ${publisher.active}',
      );
      expect(publisher.active, isTrue);
      expect(publisher.sendCount, greaterThan(0));

      // The cost of one walk on this device (a debug build: JIT, no optimisation, so a ceiling).
      final watch = Stopwatch()..start();
      final probe = buildViewHierarchy();
      watch.stop();
      say(
        'one walk: ${watch.elapsedMicroseconds} us for ${probe?.nodeCount} nodes',
      );
      expect(
        watch.elapsedMilliseconds,
        lessThan(const HierarchyLimits().budget.inMilliseconds * 4),
      );

      final secureRect = tester.getRect(find.byKey(const Key('vh-secure')));
      final started = DateTime.now().millisecondsSinceEpoch;
      await Bugsee.captureViewHierarchy();
      await Bugsee.upload('view hierarchy', 'the Flutter tree');
      say('upload requested at $started');

      // ---- read back what the SDK stored ----------------------------------------------------------
      Json? nativeTree; // Android only: the native document of the same entry
      int? entryTimestamp;
      final List<String> managed;
      if (android) {
        final bundles = Directory(
          '${Directory.systemTemp.parent.path}/files/bugsee_data/bundles',
        );
        final entries = <Json>[];
        final until = DateTime.now().add(const Duration(seconds: 60));
        while (DateTime.now().isBefore(until)) {
          entries.clear();
          if (bundles.existsSync()) {
            for (final f in bundles.listSync().whereType<File>().where(
              (f) => f.path.endsWith('.bundle.zip'),
            )) {
              final zip = unzip(f.readAsBytesSync());
              final tree = zip.entries
                  .where((e) => e.key.endsWith('.viewtree.json'))
                  .map((e) => e.value)
                  .firstOrNull;
              if (tree == null) continue;
              final doc = jsonDecode(utf8.decode(tree)) as Json;
              say(
                'bundle ${f.uri.pathSegments.last}: ${zip.keys.length} files, viewtree events ${(doc['events']! as List).length}',
              );
              entries.addAll((doc['events']! as List<Object?>).cast<Json>());
            }
          }
          if (entries.any((e) => e['managed'] != null)) break;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        expect(
          entries,
          isNotEmpty,
          reason: 'a report bundle with a view hierarchy',
        );
        // The entries taken FOR this report (the capture and the report's own snapshot) are newer
        // than the moment the capture was asked for; both must carry the managed half.
        final mine = entries
            .where((e) => (e['timestamp']! as int) >= started)
            .toList();
        say('entries since the capture: ${mine.length} of ${entries.length}');
        expect(mine, isNotEmpty);
        for (final e in mine) {
          expect(
            e['managed'],
            isA<String>(),
            reason:
                'the managed half is in the entry taken for this report, not the next one',
          );
        }
        final last = mine.last;
        entryTimestamp = last['timestamp']! as int;
        managed = [last['managed']! as String];
        nativeTree = jsonDecode(last['native']! as String) as Json;
      } else {
        // iOS: the capture buffer. Give the SDK a moment to flush the pass to disk.
        await Future<void>.delayed(const Duration(seconds: 3));
        final capture = Directory(
          '${Directory.systemTemp.parent.path}/Library/Caches/com.bugsee.data/capture',
        );
        final found = <String>[];
        if (capture.existsSync()) {
          final files =
              capture
                  .listSync(recursive: true)
                  .whereType<File>()
                  .where(
                    (f) =>
                        f.path.contains('bbf466fa-b9c6-42e4-a025-df6495ade43d'),
                  )
                  .toList()
                ..sort((a, b) => a.path.compareTo(b.path));
          for (final f in files) {
            found.addAll(
              managedObjectsIn(
                utf8.decode(f.readAsBytesSync(), allowMalformed: true),
              ),
            );
          }
          say(
            'view hierarchy entries on disk: ${files.length} files, ${found.length} managed documents',
          );
        }
        expect(
          found,
          isNotEmpty,
          reason: 'the SDK stored the managed hierarchy',
        );
        managed = [found.last];
      }

      final document = managed.single;
      say('managed document: ${document.length} bytes');
      final root = jsonDecode(document) as Json;
      final nodes = walk(root).toList();
      say('${nodes.length} nodes, root ${root['options']}');

      // ---- shape and age -----------------------------------------------------------------------
      expect(root['class_name'], 'FlutterView');
      final options = root['options']! as Json;
      expect(options['device_pixel_ratio'], ratio);
      expect(options['age_ms'], isA<int>());
      expect(options['age_ms'] as int, greaterThanOrEqualTo(0));
      expect(options['truncated'], isNull, reason: 'a small screen is not cut');
      say('the snapshot was ${options['age_ms']} ms old when the SDK asked');

      // ---- no text ------------------------------------------------------------------------------
      for (final text in onScreenText) {
        expect(
          document.contains(text),
          isFalse,
          reason: 'on-screen text "$text" leaked',
        );
      }
      final identifier = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');
      for (final n in nodes) {
        expect(n['class_name'], matches(identifier));
      }
      final names = [for (final n in nodes) n['class_name']];
      expect(names, containsAll(['TextField', 'FilledButton', 'ListView']));
      expect(
        names.where((n) => n == 'TextField').length,
        1,
        reason: 'the one in the secure view is not described',
      );

      // ---- the secure view -----------------------------------------------------------------------
      final secure = [
        for (final n in nodes)
          if ((n['options'] as Json?)?['secure'] == true) n,
      ];
      expect(secure, hasLength(1));
      expect(secure.single['class_name'], 'BugseeSecureView');
      expect(secure.single.containsKey('subitems'), isFalse);
      expect(secure.single.keys.toSet(), {
        'id',
        'class_name',
        'options',
        'bounds',
      });

      // ---- units: the SDK's native unit, at this device's density ---------------------------------
      final unit = android
          ? ratio
          : 1.0; // physical pixels on Android, points on iOS
      final size = tester.view.physicalSize / ratio; // logical
      final rootBox = boxOf(root);
      say('root box $rootBox (unit factor $unit, logical size $size)');
      // The origin of the view on the screen: the native FlutterView on Android; 0 on iOS here.
      var originX = 0.0, originY = 0.0;
      if (android) {
        final flutterViews = [
          for (final n in walk(nativeTree!))
            if ('${n['class_name']}'.endsWith('FlutterView')) n,
        ];
        expect(
          flutterViews,
          isNotEmpty,
          reason: 'the native tree has the FlutterView',
        );
        final nativeBox = boxOf(flutterViews.first);
        say('native FlutterView box $nativeBox');
        expect(
          rootBox,
          nativeBox,
          reason:
              'the managed root is the native FlutterView, in the same pixels',
        );
        originX = nativeBox[0].toDouble();
        originY = nativeBox[1].toDouble();
        expect(rootBox[2], tester.view.physicalSize.width.round());
      } else {
        expect(rootBox[2], closeTo(size.width, 1));
        expect(rootBox[3], closeTo(size.height, 1));
      }
      // The secure node is where the widget is, in that unit: an end-to-end check of ratio, unit,
      // origin and rounding. Its box is what the video masks, which includes what the field paints
      // outside its own box (the floating label sits on the border, a few logical pixels above it), so
      // it CONTAINS the widget's box (outward rounding: within a pixel) and exceeds it by no more
      // than that.
      final box = boxOf(secure.single);
      final widget = Rect.fromLTWH(
        secureRect.left * unit + originX,
        secureRect.top * unit + originY,
        secureRect.width * unit,
        secureRect.height * unit,
      );
      say('secure box $box, the widget is at $widget');
      final slack = 10 * unit; // 10 logical pixels
      expect(box[0], inInclusiveRange(widget.left - slack, widget.left + 1));
      expect(box[1], inInclusiveRange(widget.top - slack, widget.top + 1));
      expect(
        box[0] + box[2],
        inInclusiveRange(widget.right - 1, widget.right + slack),
      );
      expect(
        box[1] + box[3],
        inInclusiveRange(widget.bottom - 1, widget.bottom + slack),
      );

      if (entryTimestamp != null) {
        say('entry timestamp $entryTimestamp (asked at $started)');
      }
    },
  );

  // The trap on Android: the SDK records a report's view hierarchy only once the wrapper has
  // answered, and an answer that arrives after the snapshot closed lands in the NEXT report. A report
  // made with no capture call of ours must carry the managed half on its own.
  testWidgets(
    'a report made on its own carries the Flutter tree (nothing asked for it)',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ViewHierarchyScreen()));
      expect(
        await Bugsee.isLaunched(),
        isTrue,
        reason: 'launched by the test above',
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final bundles = Directory(
        '${Directory.systemTemp.parent.path}/files/bugsee_data/bundles',
      );
      final before = {
        for (final f in bundles.listSync().whereType<File>())
          if (f.path.endsWith('.bundle.zip')) f.path,
      };
      final started = DateTime.now().millisecondsSinceEpoch;
      await Bugsee.upload('own snapshot', 'no capture call');
      Json? entry;
      final until = DateTime.now().add(const Duration(seconds: 60));
      while (entry == null && DateTime.now().isBefore(until)) {
        for (final f in bundles.listSync().whereType<File>().where(
          (f) => f.path.endsWith('.bundle.zip') && !before.contains(f.path),
        )) {
          final tree = unzip(f.readAsBytesSync()).entries
              .where((e) => e.key.endsWith('.viewtree.json'))
              .map((e) => e.value)
              .firstOrNull;
          if (tree == null) continue;
          final events =
              ((jsonDecode(utf8.decode(tree)) as Json)['events']!
                      as List<Object?>)
                  .cast<Json>()
                  .where((e) => (e['timestamp']! as int) >= started);
          entry = events.firstOrNull;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      expect(
        entry,
        isNotNull,
        reason: 'the new report has a view hierarchy entry',
      );
      final managed = entry!['managed'];
      say(
        'the report\'s own entry: managed ${(managed as String?)?.length} bytes, native ${(entry['native'] as String?)?.length} bytes',
      );
      expect(
        managed,
        isA<String>(),
        reason: 'the answer is in the report it was asked for',
      );
      final root = jsonDecode(managed!) as Json;
      expect(root['class_name'], 'FlutterView');
      expect(walk(root).length, greaterThan(50));
    },
    skip: !android,
  );
}
