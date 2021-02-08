import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:ui';

// This imports the Bugsee plugin
import 'package:bugsee/bugsee.dart';

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
  var data = list is Uint8List ? list : new Uint8List.fromList(list);
  attachments.add(BugseeAttachment("testAttachment", "", data));

  return Future.value(attachments);
}

Future<Null> launchBugsee(Function() appRunner) async {
  Bugsee.setLogFilter(onBugseeLogEvent);
  Bugsee.setNetworkFilter(onBugseeNetworkEvent);
  Bugsee.setLifecycleCallback(onBugseeLifecycleEvent);
  Bugsee.setAttachmentsCallback(onBugseeAttachmentsRequest);

  dynamic launchOptions;
  var bugseeToken = "";

  if (Platform.isAndroid) {
    bugseeToken = "490bacaf-dcc7-4f2c-8246-3c96a5e20219";
    launchOptions = new AndroidLaunchOptions();
  } else if (Platform.isIOS) {
    bugseeToken = "a9920d8b-cb0b-43c0-a360-af68c77b5065";
    launchOptions = new IOSLaunchOptions();
  }

  // launchOptions.setCustomOption("debug", true);

  await Bugsee.launch(bugseeToken,
      appRunCallback: appRunner, launchOptions: launchOptions);
}

Future<Null> customizeBugsee() async {
  await Bugsee.appearance.iOS
      .setReportBackgroundColor(Color.fromARGB(255, 255, 0, 0));
  await Bugsee.appearance.android
      .setReportBackgroundColor(Color.fromARGB(255, 255, 0, 0));

  Color? testColor = await Bugsee.appearance.android.reportBackgroundColor;
  print('Set report background color to $testColor');
}
