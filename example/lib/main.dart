import 'dart:async';

import 'package:bugsee_flutter/bugsee_flutter.dart';
import 'package:flutter/material.dart';

import 'facade_screen.dart';
import 'view_hierarchy_screen.dart';

/// The application token from the Bugsee dashboard. Pass your own with
/// `--dart-define=BUGSEE_TOKEN=...`; the default is a placeholder, so the SDK launches but its
/// reports are not delivered anywhere.
const defaultToken = String.fromEnvironment(
  'BUGSEE_TOKEN',
  defaultValue: 'EXAMPLE-APP-TOKEN',
);

/// An on-premises or test server, if any (`--dart-define=BUGSEE_ENDPOINT=https://...`).
const endpoint = String.fromEnvironment('BUGSEE_ENDPOINT');

/// One configuration for both platforms. An option that exists on one platform only (the video
/// mode is Android's, the AVPlayer capture is iOS's) is ignored on the other, with a warning in
/// the debug console, so a shared configuration can set both.
BugseeOptions exampleOptions() => BugseeOptions(
  endpoint: endpoint.isEmpty ? null : endpoint,
  captureVideo: true,
  captureNetwork: true,
  captureLogs: true,
  captureLogsLevel: LogLevel.info,
  captureBreadcrumbs:
      true, // off by default on both SDKs; Bugsee.addBreadcrumb needs it
  captureVideoFrameRate: FrameRate.medium,
  configDuration: 45,
  configWifiOnlyUpload: false,
  detectHang: true,
  reportingDefaultsCrashPriority: ReportSeverity.critical,
  captureVideoMode: VideoMode.v2, // Android only
  captureAvPlayer: true, // iOS only
);

/// What the example does with a report before and after the SDK builds it. Idempotent, as
/// `onAfterReportCreated` must be: it may run again for the same report.
const exampleReportHandler = BugseeReportHandler(
  onBeforeReportCreated: _beforeReport,
  onAfterReportCreated: _afterReport,
);

Future<void> _beforeReport(ReportProxy report) =>
    report.setAttribute('example.phase', 'before');

Future<void> _afterReport(ReportProxy report) async {
  await report.replaceLabels(['flutter-example']);
  await report.setAttribute('example.phase', 'after');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before launch, so reports the SDK recovers while launching are seen too.
  await Bugsee.setReportHandler(exampleReportHandler);
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Bugsee example',
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    home: const HomeScreen(),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _page = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: _page,
      children: const [LaunchScreen(), FacadeScreen(), ViewHierarchyScreen()],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _page,
      onDestinationSelected: (i) => setState(() => _page = i),
      destinations: const [
        NavigationDestination(
          key: Key('tab-launch'),
          icon: Icon(Icons.power_settings_new),
          label: 'Launch',
        ),
        NavigationDestination(
          key: Key('tab-facade'),
          icon: Icon(Icons.bug_report_outlined),
          label: 'Data',
        ),
        NavigationDestination(
          key: Key('tab-view-hierarchy'),
          icon: Icon(Icons.account_tree_outlined),
          label: 'Hierarchy',
        ),
      ],
    ),
  );
}

class LaunchScreen extends StatefulWidget {
  const LaunchScreen({super.key});

  @override
  State<LaunchScreen> createState() => _LaunchScreenState();
}

class _LaunchScreenState extends State<LaunchScreen> {
  final _token = TextEditingController(text: defaultToken);
  final _log = <String>[];
  late final StreamSubscription<BugseeStatus> _transitions;
  BugseeStatus _status = BugseeStatus.stopped;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _transitions = Bugsee.statusChanges.listen((status) {
      _note('status -> ${status.name}');
      setState(() => _status = status);
    });
    // The SDK's own answer, for a launch made before this screen listened.
    Bugsee.getStatus().then((status) {
      if (mounted) setState(() => _status = status);
    });
  }

  @override
  void dispose() {
    _transitions.cancel();
    _token.dispose();
    super.dispose();
  }

  void _note(String line) {
    debugPrint('example: $line');
    if (mounted) setState(() => _log.insert(0, line));
  }

  Future<void> _run(String name, Future<Object?> Function() action) async {
    setState(() => _busy = true);
    try {
      _note('$name -> ${await action()}');
    } on BugseeLaunchException catch (e) {
      _note('$name failed: ${e.reason.name} (${e.message})');
    } on BugseeException catch (e) {
      _note('$name failed: ${e.message}');
    } on ArgumentError catch (e) {
      _note('$name: bad options: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final launched = _status == BugseeStatus.launched;
    return Scaffold(
      appBar: AppBar(title: const Text('Bugsee')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _token,
                decoration: const InputDecoration(
                  labelText: 'Application token',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      key: const Key('launch'),
                      onPressed: _busy
                          ? null
                          : () => _run(
                              'launch',
                              () => Bugsee.launch(
                                _token.text,
                                options: exampleOptions(),
                              ),
                            ),
                      child: const Text('Launch'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('stop'),
                      onPressed: _busy ? null : () => _run('stop', Bugsee.stop),
                      child: const Text('Stop'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                key: const Key('options'),
                onPressed: _busy
                    ? null
                    : () => _run('launch options', () async {
                        final options = await Bugsee.getLaunchOptions();
                        final shown = {
                          for (final k in [
                            'com.bugsee.option.config.duration',
                            'com.bugsee.option.capture.logs.level',
                            'com.bugsee.option.capture.video.frame-rate',
                            'com.bugsee.option.capture.video.mode',
                            'com.bugsee.option.reporting.defaults.crash-priority',
                            'com.bugsee.option.detect.hang',
                          ])
                            k.substring('com.bugsee.option.'.length):
                                options[k],
                        };
                        return shown;
                      }),
                child: const Text('Show launch options'),
              ),
              const SizedBox(height: 16),
              Text(
                'Status: ${_status.name}${launched ? ' (capturing)' : ''}',
                key: const Key('status'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Divider(height: 24),
              Expanded(
                child: ListView.builder(
                  itemCount: _log.length,
                  itemBuilder: (_, i) => Text(
                    _log[i],
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
