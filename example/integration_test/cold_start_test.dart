// The recommended cold start: `await Bugsee.launch(...)` in main() before runApp.
//
//   cd example && flutter test integration_test/cold_start_test.dart -d <device>
//
// The launch is made before any widget exists, as an app's main() would. On iOS the SDK defers a
// launch made while the app's state is still background (during didFinishLaunching), so the
// result may be `deferred` rather than `launched`; either way `Bugsee.waitUntilLaunched` settles it.
import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:bugsee_flutter_example/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final statuses = <BugseeStatus>[];
  Bugsee.statusChanges.listen(statuses.add);
  // Before runApp / any test: the cold start.
  final result = await Bugsee.launch(defaultToken, options: exampleOptions());
  debugPrint('cold start: launch -> $result');

  testWidgets('a launch from main() ends launched', (tester) async {
    final launched = await Bugsee.waitUntilLaunched();
    debugPrint(
      'cold start: waitUntilLaunched -> $launched; transitions = ${statuses.map((s) => s.name).toList()}',
    );
    expect(result, anyOf(LaunchResult.launched, LaunchResult.deferred));
    expect(launched, isTrue);
    expect(await Bugsee.getStatus(), BugseeStatus.launched);
    await Bugsee.stop();
  });
}
