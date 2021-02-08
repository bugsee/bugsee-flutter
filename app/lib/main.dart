// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// This is a sample Flutter app that demonstrates how to catch various kinds
/// of errors in Flutter apps and report them to Bugsee.
///
/// Explanations are provided in the inline comments in the code below.
library crashy;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
// import 'dart:html';
import 'dart:math';

// This imports the Bugsee plugin
import 'package:bugsee/bugsee.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'bugsee-helper.dart' show launchBugsee, customizeBugsee;

Future<Null> main() async {
  HttpOverrides.global = Bugsee.defaultHttpOverrides;

  print('Application initializing...');

  await customizeBugsee();
  await launchBugsee(() => runApp(new CrashyApp()));

  // This creates a [Zone] that contains the Flutter application and establishes
  // an error handler that captures errors and reports them.
  //
  // Using a zone makes sure that as many errors as possible are captured,
  // including those thrown from [Timer]s, microtasks, I/O, and those forwarded
  // from the `FlutterError` handler.
  //
  // More about zones:
  //
  // - https://api.dartlang.org/stable/1.24.2/dart-async/Zone-class.html
  // - https://www.dartlang.org/articles/libraries/zones
  //
}

class CrashyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return new MaterialApp(
      title: 'Crashy',
      theme: new ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: new MyHomePage(),
    );
  }
}

class MyHomePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return new Scaffold(
      appBar: new AppBar(
        title: new Text('Crashy'),
      ),
      body: new Center(
        child: new Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            new ElevatedButton(
              child: new Text('Dart exception'),
              onPressed: () {
                throw new StateError('This is a Dart exception.');
              },
            ),
            new ElevatedButton(
              child: new Text('async Dart exception'),
              onPressed: () async {
                foo() async {
                  throw new StateError('This is an async Dart exception.');
                }

                bar() async {
                  await foo();
                }

                await bar();
              },
            ),
            new ElevatedButton(
              child: new Text('Java exception'),
              onPressed: () async {
                Bugsee.testExceptionCrash();
              },
            ),
            new ElevatedButton(
              child: new Text('Handled exception'),
              onPressed: () async {
                try {
                  throw new FormatException('Expected at least 1 section');
                } catch (ex, st) {
                  Bugsee.logException(ex, st);
                }
              },
            ),
            new ElevatedButton(
              child: new Text('Log messages'),
              onPressed: () {
                print("This is a message posted with print() call");
                Bugsee.log("This is a test console message");
                Bugsee.log("This is a test console ERROR message",
                    BugseeLogLevel.error);
                Bugsee.log("This is a test console DEBUG message",
                    BugseeLogLevel.debug);
                Bugsee.log(
                    "This is a test console INFO message", BugseeLogLevel.info);
                Bugsee.log("This is a test console WARNING message",
                    BugseeLogLevel.warning);
              },
            ),
            new ElevatedButton(
              child: new Text('Network request'),
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
            new ElevatedButton(
              child: new Text('Custom events'),
              onPressed: () async {
                dynamic params = <String, dynamic>{};
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
            new ElevatedButton(
              child: new Text('Show report dialog'),
              onPressed: () {
                Bugsee.showReportDialog('Test summary', 'Test description');
              },
            ),
            new ElevatedButton(
              child: new Text('Upload report'),
              onPressed: () {
                Bugsee.upload('Test summary', 'Test description');
              },
            ),
            new ElevatedButton(
              child: new Text('Show Feedback'),
              onPressed: () {
                Bugsee.showFeedbackUI();
              },
            ),
            new ElevatedButton(
              child: new Text('Add secure rect'),
              onPressed: () {
                Bugsee.addSecureRect(new Rectangle(20, 20, 100, 100));
              },
            ),
            new ElevatedButton(
              child: new Text('Add secure rect'),
              onPressed: () async {
                Bugsee.addSecureRect(new Rectangle(20, 20, 100, 100));
                var rectangles = await Bugsee.getAllSecureRects();
                print(rectangles);
              },
            ),
          ],
        ),
      ),
    );
  }
}
