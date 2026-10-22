// Privacy of the managed view hierarchy. The SDK stores the payload byte for byte and cannot look
// inside it, so what must not leave the device is withheld HERE. Every channel through which an app
// puts a user-looking string into the widget tree is fed one, and none may reach the payload.
import 'dart:convert';

import 'package:bugsee_flutter/src/secure/bugsee_secure_view.dart';
import 'package:bugsee_flutter/src/view_hierarchy/hierarchy_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Strings no payload may contain, one per channel. Each is distinctive, so a match is a leak.
const Map<String, String> secrets = {
  'Text': 'TEXT-alice@example.com',
  'Text.rich': 'RICH-4242-4242-4242-4242',
  'SelectableText': 'SELECTABLE-passport-X123',
  'TextField controller': 'CONTROLLER-hunter2',
  'TextField hint': 'HINT-your-pin',
  'TextField label': 'LABEL-card-number',
  'obscured field': 'OBSCURED-correct-horse',
  'Semantics label': 'SEMLABEL-john-doe',
  'Semantics hint': 'SEMHINT-secret-hint',
  'Semantics value': 'SEMVALUE-balance-9000',
  'Semantics identifier': 'SEMID-user-777',
  'Tooltip': 'TOOLTIP-medical-record',
  'Image semanticLabel': 'IMGLABEL-face-of-bob',
  'Hero tag': 'HERO-order-4711',
  'ValueKey': 'VALUEKEY-ssn-123-45-6789',
  'ObjectKey': 'OBJECTKEY-token-abc',
  'GlobalObjectKey': 'GLOBALKEY-session-xyz',
  'PageStorageKey': 'PAGEKEY-draft-letter',
  'UniqueKey label': 'FOCUSDEBUG-label',
  'route name': 'ROUTE-/profile/jane',
  'AppBar title': 'TITLE-inbox-of-jane',
  'ListTile': 'TILE-subject-line',
  'Chip': 'CHIP-diagnosis',
  'DropdownMenuItem': 'DROPDOWN-salary-band',
  'Form initialValue': 'INITIAL-home-address',
  'toString': 'TOSTRING-overridden',
  'SnackBar': 'SNACK-payment-failed',
  'Restoration id': 'RESTORE-user-state',
  'Icon semanticLabel': 'ICONLABEL-lock',
  'Semantics tooltip': 'SEMTOOL-tip',
  'TextSpan semanticsLabel': 'SPANLABEL-spoken',
};

/// A clock that never advances: the 12 ms walk budget cannot truncate the tree on a slow runner.
Duration frozenClock() => Duration.zero;

const String tinyPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

class _Overriding extends StatelessWidget {
  const _Overriding();
  @override
  Widget build(BuildContext context) => const SizedBox(width: 3, height: 3);
  @override
  String toString({DiagnosticLevel minLevel = DiagnosticLevel.info}) =>
      secrets['toString']!;
  @override
  String toStringShort() => secrets['toString']!;
  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(StringProperty('secret', secrets['toString']));
  }
}

class _Page extends StatelessWidget {
  const _Page();
  @override
  Widget build(BuildContext context) {
    final controller = TextEditingController(
      text: secrets['TextField controller'],
    );
    return Scaffold(
      appBar: AppBar(title: Text(secrets['AppBar title']!)),
      body: SingleChildScrollView(
        key: PageStorageKey<String>(secrets['PageStorageKey']!),
        child: Column(
          children: [
            Text(secrets['Text']!),
            Text.rich(
              TextSpan(
                text: secrets['Text.rich'],
                semanticsLabel: secrets['TextSpan semanticsLabel'],
                children: const [TextSpan(text: 'more')],
              ),
            ),
            SelectableText(secrets['SelectableText']!),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                hintText: secrets['TextField hint'],
                labelText: secrets['TextField label'],
              ),
            ),
            TextField(
              obscureText: true,
              controller: TextEditingController(
                text: secrets['obscured field'],
              ),
            ),
            Semantics(
              label: secrets['Semantics label'],
              hint: secrets['Semantics hint'],
              value: secrets['Semantics value'],
              identifier: secrets['Semantics identifier'],
              tooltip: secrets['Semantics tooltip'],
              child: const SizedBox(width: 10, height: 10),
            ),
            Tooltip(
              message: secrets['Tooltip']!,
              child: const SizedBox(width: 10, height: 10),
            ),
            Image.memory(
              base64Decode(tinyPng),
              width: 4,
              height: 4,
              semanticLabel: secrets['Image semanticLabel'],
            ),
            Hero(
              tag: secrets['Hero tag']!,
              child: const SizedBox(width: 5, height: 5),
            ),
            SizedBox(
              key: ValueKey<String>(secrets['ValueKey']!),
              width: 5,
              height: 5,
            ),
            SizedBox(key: ObjectKey(secrets['ObjectKey']), width: 5, height: 5),
            SizedBox(
              key: GlobalObjectKey(secrets['GlobalObjectKey']!),
              width: 5,
              height: 5,
            ),
            Focus(
              debugLabel: secrets['UniqueKey label'],
              child: const SizedBox(width: 5, height: 5),
            ),
            ListTile(
              title: Text(secrets['ListTile']!),
              subtitle: Text(secrets['ListTile']!),
            ),
            Chip(label: Text(secrets['Chip']!)),
            DropdownButton<String>(
              value: secrets['DropdownMenuItem'],
              onChanged: (_) {},
              items: [
                DropdownMenuItem(
                  value: secrets['DropdownMenuItem'],
                  child: Text(secrets['DropdownMenuItem']!),
                ),
              ],
            ),
            Form(
              child: TextFormField(initialValue: secrets['Form initialValue']),
            ),
            const _Overriding(),
            RestorationScope(
              restorationId: secrets['Restoration id'],
              child: const SizedBox(width: 2, height: 2),
            ),
            Icon(Icons.lock, semanticLabel: secrets['Icon semanticLabel']),
          ],
        ),
      ),
    );
  }
}

Widget app() => const MaterialApp(home: _Page());

String payloadOf(HierarchySnapshot s) => s.render();

/// Every string of the snapshot the way it would leave the device: the template, as native
/// fills it in, and the raw message parts.
String everything(HierarchySnapshot s) =>
    '${s.render()}\n${s.segments.join()}\n${s.bounds}';

void expectNoSecret(String text) {
  for (final entry in secrets.entries) {
    expect(
      text.contains(entry.value),
      isFalse,
      reason: 'the ${entry.key} string leaked into the view hierarchy',
    );
  }
  // Also the distinctive halves, in case a leak is a fragment.
  for (final entry in secrets.entries) {
    final head = entry.value.split('-').first;
    if (head.length >= 5) {
      expect(
        text.contains(head),
        isFalse,
        reason: 'a fragment of the ${entry.key} string leaked',
      );
    }
  }
}

void main() {
  group('no user-visible string reaches the payload', () {
    testWidgets('through any widget channel', (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      // The test is only meaningful if the strings are really on screen.
      expect(find.text(secrets['Text']!), findsOneWidget);
      expect(find.text(secrets['ListTile']!), findsNWidgets(2));
      final s = buildViewHierarchy(clock: frozenClock)!;
      expect(s.nodeCount, greaterThan(50), reason: 'a real tree was walked');
      expectNoSecret(everything(s));
    });

    testWidgets('with the semantics tree switched on', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(app());
      await tester.pump();
      // The labels are now built into the semantics tree; the payload still has none of them.
      expect(
        tester.getSemantics(find.text(secrets['Text']!)).label,
        contains(secrets['Text']!),
      );
      expectNoSecret(everything(buildViewHierarchy(clock: frozenClock)!));
      handle.dispose();
    });

    testWidgets(
      'from inside a secure view, where nothing is described at all',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BugseeSecureView(
                child: Column(
                  children: [
                    Text(secrets['Text']!),
                    TextField(key: ValueKey<String>(secrets['ValueKey']!)),
                    Semantics(
                      label: secrets['Semantics label'],
                      child: const _Overriding(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        final s = buildViewHierarchy(clock: frozenClock)!;
        expectNoSecret(everything(s));
        final root = jsonDecode(s.render()) as Map<String, Object?>;
        Iterable<Map<String, Object?>> walk(Map<String, Object?> n) sync* {
          yield n;
          for (final c in (n['subitems'] as List<Object?>?) ?? const []) {
            yield* walk(c! as Map<String, Object?>);
          }
        }

        final names = [for (final n in walk(root)) n['class_name']];
        // The type names of what is inside are not in the payload either.
        expect(names, isNot(contains('TextField')));
        expect(names, isNot(contains('_Overriding')));
      },
    );

    testWidgets('after the user typed into a field', (tester) async {
      await tester.pumpWidget(app());
      await tester.enterText(
        find.byType(TextField).first,
        'TYPED-user-input-12345',
      );
      await tester.pump();
      expect(find.text('TYPED-user-input-12345'), findsOneWidget);
      final text = everything(buildViewHierarchy(clock: frozenClock)!);
      expect(text.contains('TYPED'), isFalse);
      expect(text.contains('12345'), isFalse);
    });

    testWidgets('through a SnackBar, a dialog and a pushed route', (
      tester,
    ) async {
      final messenger = GlobalKey<ScaffoldMessengerState>();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          scaffoldMessengerKey: messenger,
          navigatorKey: navigator,
          home: const Scaffold(body: Text('base')),
        ),
      );
      messenger.currentState!.showSnackBar(
        SnackBar(content: Text(secrets['SnackBar']!)),
      );
      showDialog<void>(
        context: navigator.currentContext!,
        routeSettings: RouteSettings(name: secrets['route name']),
        builder: (_) => AlertDialog(
          title: Text(secrets['AppBar title']!),
          content: Text(secrets['Text']!),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(secrets['SnackBar']!), findsOneWidget);
      final s = buildViewHierarchy(clock: frozenClock)!;
      expectNoSecret(everything(s));
      expect(s.render().contains('AlertDialog'), isTrue);
    });
  });

  group('what the payload is made of', () {
    testWidgets(
      'every string is a type name, an id, a fixed word or a number',
      (tester) async {
        await tester.pumpWidget(app());
        await tester.pump();
        final root =
            jsonDecode(buildViewHierarchy(clock: frozenClock)!.render())
                as Map<String, Object?>;
        final identifier = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');
        const keys = {
          'id',
          'class_name',
          'base_class_name',
          'options',
          'bounds',
          'truncated',
          'subitems',
        };
        const optionKeys = {
          'age_ms',
          'device_pixel_ratio',
          'obfuscated',
          'truncated',
          'secure',
          'clickable',
          'alpha',
          'content_kind',
        };
        const contentKinds = {'image', 'surface'};
        var nodes = 0;
        void check(Map<String, Object?> n) {
          nodes++;
          expect(keys.containsAll(n.keys), isTrue, reason: 'keys ${n.keys}');
          expect(n['id'], matches(RegExp(r'^\d+$')));
          expect(n['class_name'], matches(identifier));
          if (n['base_class_name'] != null) {
            expect(n['base_class_name'], matches(identifier));
          }
          final options = n['options'] as Map<String, Object?>?;
          if (options != null) {
            expect(optionKeys.containsAll(options.keys), isTrue);
            for (final entry in options.entries) {
              final v = entry.value;
              expect(
                v is num || v is bool,
                entry.key == 'content_kind' ? isFalse : isTrue,
                reason: '${entry.key} is ${v.runtimeType}',
              );
              if (entry.key == 'content_kind') {
                expect(contentKinds, contains(v));
              }
            }
          }
          for (final b in (n['bounds']! as List<Object?>)) {
            expect(b, isA<num>());
          }
          for (final c in (n['subitems'] as List<Object?>?) ?? const []) {
            check(c! as Map<String, Object?>);
          }
        }

        check(root);
        expect(nodes, greaterThan(50));
      },
    );

    testWidgets(
      'a type name with generics or odd characters stays an identifier',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ValueListenableBuilder<Map<String, List<int>>>(
              valueListenable: ValueNotifier(const {}),
              builder: (_, _, _) => const SizedBox(),
            ),
          ),
        );
        final text = buildViewHierarchy(clock: frozenClock)!.render();
        expect(text.contains('<'), isFalse);
        expect(text.contains('ValueListenableBuilder'), isTrue);
      },
    );
  });

  group('the walk never reads text from the render objects', () {
    testWidgets('the paragraph and editable are visited without their text', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pump();
      // They are in the payload as types, so the test would notice if they were skipped.
      final text = buildViewHierarchy(clock: frozenClock)!.render();
      expect(text.contains('"base_class_name":"RenderParagraph"'), isTrue);
      expect(text.contains('"base_class_name":"RenderEditable"'), isTrue);
      expectNoSecret(text);
    });
  });
}
