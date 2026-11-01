// Decision logic of scripts/check_native_pins.dart (no network).
import 'package:flutter_test/flutter_test.dart';

import '../scripts/check_native_pins.dart';

const pins = {
  'android': {'sdk': '7.4.2', 'gradlePlugin': '4.0.8'},
  'ios': {
    'sdk': '7.0.0',
    'spmUrl': 'https://github.com/bugsee/spm',
    'feedbackSpmUrl': 'https://github.com/bugsee/feedback-spm',
  },
  'feedback': {'androidArtifact': 'com.bugsee:bugsee-android-feedback'},
};

PinReport run({
  List<String> sdk = const ['7.4.1', '7.4.2'],
  List<String> ndk = const ['7.4.2'],
  List<String> plugin = const ['4.0.7', '4.0.8'],
  List<String> spm = const ['7.0.0'],
  List<String> feedback = const ['7.0.0'],
  List<String> androidFeedback = const ['7.4.2'],
}) => evaluate(
  pins,
  androidSdk: sdk,
  androidNdk: ndk,
  gradlePlugin: plugin,
  spmTags: spm,
  feedbackSpmTags: feedback,
  androidFeedback: androidFeedback,
);

void main() {
  test('parses Maven metadata versions', () {
    const xml =
        '<versions><version>7.4.1</version>\n'
        '  <version>7.0.0-beta6</version></versions>';
    expect(parseMavenVersions(xml), ['7.4.1', '7.0.0-beta6']);
  });

  test('parses ls-remote tags, folding peeled entries', () {
    const out =
        'aaa\trefs/tags/7.0.0-beta6\n'
        'bbb\trefs/tags/7.0.0-beta7\n'
        'ccc\trefs/tags/7.0.0-beta7^{}\n';
    expect(parseLsRemoteTags(out), {'7.0.0-beta6', '7.0.0-beta7'});
  });

  test('newer releases: same major, stable only, numeric order', () {
    expect(
      newerSameMajor('7.4.2', [
        '7.4.10',
        '7.4.3',
        '7.5.0-beta1',
        '8.0.0',
        '7.4.1',
        '7.4.2',
      ]),
      ['7.4.3', '7.4.10'],
    );
    expect(newerSameMajor('7.0.0-beta7', ['7.4.2']), isEmpty);
  });

  test('all pins present: ok, no notes about newer', () {
    final r = run();
    expect(r.ok, isTrue);
    expect(r.notes.where((n) => n.startsWith('NEWER')), isEmpty);
  });

  test('each missing pin fails, naming the artefact', () {
    expect(run(sdk: ['7.4.1']).errors.single, contains('bugsee-android 7.4.2'));
    expect(run(ndk: []).errors.single, contains('bugsee-android-ndk'));
    expect(run(plugin: ['4.0.7']).errors.single, contains('gradle plugin'));
    expect(run(spm: []).errors.single, contains('bugsee/spm'));
    expect(
      run(feedback: ['7.0.0-beta7']).errors.single,
      contains('feedback-spm'),
    );
    expect(
      run(androidFeedback: ['7.4.1']).errors.single,
      contains('bugsee-android-feedback 7.4.2'),
    );
  });

  test('a newer Android 7.x is reported but does not fail', () {
    final r = run(sdk: ['7.4.2', '7.5.0']);
    expect(r.ok, isTrue);
    expect(
      r.notes.any((n) => n.startsWith('NEWER') && n.contains('7.5.0')),
      isTrue,
    );
  });
}
