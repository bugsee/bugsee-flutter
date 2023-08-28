/// This is a sample Flutter app  that demonstrates how to catch various kinds
/// of errors in Flutter apps and report them to Bugsee.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

// This imports the Bugsee plugin
import 'package:bugsee_flutter/bugsee.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

void onBugseeLifecycleEvent(BugseeLifecycleEventType e) {
  print(e);
}

Future<BugseeLogEvent> onBugseeLogEvent(BugseeLogEvent logEvent) {
  logEvent.text = "Filtered: " + logEvent.text;
  return Future.value(logEvent);
}

Future<BugseeNetworkEvent> onBugseeNetworkEvent(BugseeNetworkEvent e) {
  e.url = "<redacted>";
  return Future.value(e);
}

Future<List<BugseeAttachment>> onBugseeAttachmentsRequest(BugseeReport report) {
  var attachments = <BugseeAttachment>[];
  var list = utf8.encode("This is the contents of the attachment!");
  var data = list is Uint8List ? list : Uint8List.fromList(list);
  attachments.add(BugseeAttachment("testAttachment", "", data));
  return Future.value(attachments);
}

Future<void> configureBugsee() async {
  Bugsee.setLogFilter(onBugseeLogEvent);
  Bugsee.setNetworkFilter(onBugseeNetworkEvent);
  Bugsee.setLifecycleCallback(onBugseeLifecycleEvent);
  Bugsee.setAttachmentsCallback(onBugseeAttachmentsRequest);

  var bgColor = Color.fromARGB(255, 100, 150, 180);

  await Bugsee.appearance.iOS.setReportBackgroundColor(bgColor);
  await Bugsee.appearance.android.setReportBackgroundColor(bgColor);

  await Bugsee.appearance.iOS
      .setReportSummaryPlaceholder('Some summary, please');
  await Bugsee.appearance.iOS
      .setReportDescriptionPlaceholder('More, more and more details here');
  await Bugsee.appearance.iOS
      .setReportEmailPlaceholder('Identify yourself, please');
  await Bugsee.appearance.iOS
      .setReportLabelsPlaceholder('Labels.For.Devs [Comma separated]');
}

BugseeLaunchOptions? createLaunchOptions() {
  if (Platform.isAndroid) {
    var options = AndroidLaunchOptions();
    // You can set Android-specific options here
    return options;
  }

  if (Platform.isIOS) {
    var options = IOSLaunchOptions();
    // You can set iOS-specific options here

    // options.captureAVPlayer = true;

    return options;
  }

  return null;
}

String getApplicationToken() {
  return Platform.isAndroid
      ? 'e1f49c41-30f3-498b-aa7c-620779a32bdc'
      : (Platform.isIOS ? '1fcf9b8d-92f2-4ca5-b68f-4d6bc3e4b733' : '');
}

Future<void> launchBugsee(
    void Function(bool isBugseeLaunched) appRunner) async {
  var launchOptions = createLaunchOptions();

  // Set all the required launch options to the desired state

  await Bugsee.launch(getApplicationToken(),
      appRunCallback: appRunner, launchOptions: launchOptions);
}

Future<void> main() async {
  // This is required to let Bugsee intercept network requests
  HttpOverrides.global = Bugsee.defaultHttpOverrides;

  await launchBugsee((bool isBugseeLaunched) async {
    if (isBugseeLaunched) {
      await configureBugsee();
    }
    runApp(const CrashyApp());
  });
}

class CrashyApp extends StatelessWidget {
  const CrashyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Crashy',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: MyHomePage(),
    );
  }
}

class MyHomePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Crashy'),
      ),
      body: SingleChildScrollView(
          child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            ElevatedButton(
              child: Text('Dart exception'),
              onPressed: () {
                throw StateError('This is a Dart exception.');
              },
            ),
            ElevatedButton(
              child: Text('async Dart exception'),
              onPressed: () async {
                foo() async {
                  throw StateError('This is an async Dart exception.');
                }

                bar() async {
                  await foo();
                }

                await bar();
              },
            ),
            ElevatedButton(
              child: Text('Java exception'),
              onPressed: () async {
                Bugsee.testExceptionCrash();
              },
            ),
            ElevatedButton(
              child: Text('Handled exception'),
              onPressed: () async {
                try {
                  throw FormatException('Expected at least 1 section');
                } catch (ex, st) {
                  Bugsee.logException(ex, st);
                }
              },
            ),
            ElevatedButton(
              child: Text('Handled empty exception'),
              onPressed: () {
                Bugsee.logException(
                    StateError(
                        'This is a Dart exception with empty stack trace.'),
                    '');
              },
            ),
            BugseeSecureView(
                enabled: true,
                child: ElevatedButton(
                  child: Text('Log messages'),
                  onPressed: () {
                    print("This is a message posted with print() call");
                    Bugsee.log("This is a test console message");
                    Bugsee.log("This is a test console ERROR message",
                        BugseeLogLevel.error);
                    Bugsee.log("This is a test console DEBUG message",
                        BugseeLogLevel.debug);
                    Bugsee.log("This is a test console INFO message",
                        BugseeLogLevel.info);
                    Bugsee.log("This is a test console WARNING message",
                        BugseeLogLevel.warning);
                  },
                )),
            ElevatedButton(
              child: Text('Network request'),
              onPressed: () async {
                // var httpClient = HttpClient();
                // var request = await httpClient.getUrl(
                //     Uri.parse('https://jsonplaceholder.typicode.com/posts'));
                // var response = await request.close();
                // var responseBody =
                //     await response.transform(utf8.decoder).join();

                var response = await http.post(
                  Uri.parse('https://reqres.in/api/users'),
                  headers: <String, String>{
                    'Content-Type': 'application/json; charset=UTF-8',
                  },
                  body: jsonEncode(<String, String>{
                    'title': 'Some fancy title',
                  }),
                );
                var responseBody = response.body;

                print('Received network response. Length: ' +
                    responseBody.length.toString());
              },
            ),
            ElevatedButton(
              child: Text('Custom events'),
              onPressed: () async {
                Map<String, dynamic> params = <String, dynamic>{};
                params['string'] = 'test';
                params['int'] = 5;
                params['float'] = 0.55;
                params['bool'] = true;
                Bugsee.event('event', params);
                Bugsee.trace('number', 5);
                Bugsee.trace('float', 0.55);
                Bugsee.trace('string', 'test');
                Bugsee.trace('bool', true);
                Bugsee.trace('map', params);
                Bugsee.setAttribute('age', 36);
                Bugsee.setAttribute('name', 'John Doe');
                Bugsee.setAttribute('married', false);
              },
            ),
            ElevatedButton(
              child: Text('Show report dialog'),
              onPressed: () {
                Bugsee.showReportDialog('Test summary', 'Test description');
              },
            ),
            TextField(
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                )),
            ElevatedButton(
              child: Text('Upload report'),
              onPressed: () {
                Bugsee.upload('Test summary', 'Test description');
              },
            ),
            ElevatedButton(
              child: Text('Show Feedback'),
              onPressed: () {
                Bugsee.showFeedbackUI();
              },
            ),
            ElevatedButton(
              child: Text('Add secure rect'),
              onPressed: () {
                Bugsee.addSecureRect(Rectangle(20, 20, 100, 100));
              },
            ),
            ElevatedButton(
              child: Text('Get all secure rects'),
              onPressed: () async {
                dynamic rects = await Bugsee.getAllSecureRects();
                print(rects);
              },
            ),
            ElevatedButton(
              child: Text('Capture view hierarchy'),
              onPressed: () async {
                await Bugsee.captureViewHierarchy();
              },
            ),
            ElevatedButton(
              child: Text('Show video'),
              onPressed: () async {
                showDialog(
                    context: context,
                    builder: (BuildContext context) =>
                        _buildVideoPopupDialog(context));
              },
            ),
            ElevatedButton(
              child: Text('Dummy button'),
              onPressed: () async {},
            ),
            ElevatedButton(
              child: Text('Dummy button'),
              onPressed: () async {},
            ),
            ElevatedButton(
              child: Text('Dummy button'),
              onPressed: () async {},
            ),
            ElevatedButton(
              child: Text('Dummy button'),
              onPressed: () async {},
            ),
            ElevatedButton(
              child: Text('Dummy button'),
              onPressed: () async {},
            ),
            ElevatedButton(
              child: Text('Dummy button'),
              onPressed: () async {},
            ),
            ElevatedButton(
              child: Text('Dummy button'),
              onPressed: () async {},
            ),
            ElevatedButton(
              child: Text('Dummy button'),
              onPressed: () async {},
            ),
            ElevatedButton(
              child: Text('Dummy button'),
              onPressed: () async {},
            ),
          ],
        ),
      )),
    );
  }

  Widget _buildVideoPopupDialog(BuildContext context) {
    return new Dialog(
        child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(children: <Widget>[
              VideoWidget(),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                },
                child: const Text('Close'),
              ),
            ])));
  }
}

/// Stateful widget to fetch and then display video content.
class VideoWidget extends StatefulWidget {
  const VideoWidget({super.key});

  @override
  _VideoWidgetState createState() => _VideoWidgetState();
}

class _VideoWidgetState extends State<VideoWidget> {
  late VideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(
        'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4'))
      ..initialize().then((_) {
        // Ensure the first frame is shown after the video is initialized, even before the play button has been pressed.
        setState(() {});
      });

    _controller.play();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          _controller.value.isInitialized
              ? AspectRatio(
                  aspectRatio: _controller.value.aspectRatio,
                  child: VideoPlayer(_controller),
                )
              : Container(),
        ]);
  }

  @override
  void dispose() {
    super.dispose();
    _controller.dispose();
  }
}
