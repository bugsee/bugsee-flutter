// Option encoding: the ONE flat map both SDKs take, and the checking the SDKs do not do.
import 'package:bugsee_flutter/src/options/bugsee_options.g.dart';
import 'package:bugsee_flutter/src/options/endpoint.dart';
import 'package:bugsee_flutter/src/options/launch_options.dart';
import 'package:bugsee_flutter/src/options/option_registry.dart';
import 'package:bugsee_flutter/src/options/option_registry.g.dart';
import 'package:bugsee_flutter/src/report/report_enums.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/option_samples.dart';

const android = OptionPlatform.android;
const ios = OptionPlatform.ios;

Map<String, Object> encode(BugseeOptions o, OptionPlatform p) =>
    encodeLaunchOptions(o, p).values;

void main() {
  group('encoding', () {
    test('nothing set sends nothing: the SDK defaults apply', () {
      for (final p in OptionPlatform.values) {
        final encoded = encodeLaunchOptions(const BugseeOptions(), p);
        expect(encoded.values, isEmpty);
        expect(encoded.warnings, isEmpty);
      }
    });

    test('shared options go to both platforms as the same key and value', () {
      const options = BugseeOptions(
        captureLogs: false,
        configDuration: 45,
        captureVideoScale: 0.5,
        captureLogsLevel: LogLevel.warning,
        reportingDefaultsBugPriority: ReportSeverity.critical,
      );
      final expected = {
        'com.bugsee.option.capture.logs': false,
        'com.bugsee.option.config.duration': 45,
        'com.bugsee.option.capture.video.scale': 0.5,
        'com.bugsee.option.capture.logs.level': 2,
        'com.bugsee.option.reporting.defaults.bug-priority': 4,
      };
      expect(encode(options, android), expected);
      expect(encode(options, ios), expected);
    });

    test('enums cross by the SDK internal value, never the ordinal', () {
      final out = encode(
        BugseeOptions(
          captureVideoMode: VideoMode.fullscreen,
          captureLogsLevel: LogLevel.error,
        ),
        android,
      );
      expect(out['com.bugsee.option.capture.video.mode'], 20);
      expect(out['com.bugsee.option.capture.logs.level'], 1);
    });

    test('the result cannot be changed by the caller', () {
      final encoded = encodeLaunchOptions(
        const BugseeOptions(captureLogs: true),
        android,
      );
      expect(() => encoded.values['x'] = 1, throwsUnsupportedError);
      expect(() => encoded.warnings.add('x'), throwsUnsupportedError);
    });

    test('a non-finite number is an error, not a value the SDK would drop', () {
      expect(
        () =>
            encode(const BugseeOptions(captureVideoScale: double.nan), android),
        throwsArgumentError,
      );
      expect(
        () => encode(
          const BugseeOptions(performanceSampleRate: double.infinity),
          ios,
        ),
        throwsArgumentError,
      );
    });
  });

  group('platform-specific options: skipped with a warning, never an error', () {
    test('an Android-only option is skipped on iOS and kept on Android', () {
      const options = BugseeOptions(
        captureVideoMode: VideoMode.v1,
        captureLogs: true,
      );
      final onIos = encodeLaunchOptions(options, ios);
      expect(onIos.values, {'com.bugsee.option.capture.logs': true});
      expect(onIos.warnings, [
        'com.bugsee.option.capture.video.mode exists on Android only: ignored on iOS',
      ]);
      final onAndroid = encodeLaunchOptions(options, android);
      expect(
        onAndroid.values.keys,
        contains('com.bugsee.option.capture.video.mode'),
      );
      expect(onAndroid.warnings, isEmpty);
    });

    test('an iOS-only option is skipped on Android and kept on iOS', () {
      const options = BugseeOptions(
        captureAvPlayer: true,
        reportingUiStyle: BugseeStyle.dusk,
      );
      final onAndroid = encodeLaunchOptions(options, android);
      expect(onAndroid.values, isEmpty);
      expect(onAndroid.warnings, hasLength(2));
      expect(
        onAndroid.warnings.first,
        contains('exists on iOS only: ignored on Android'),
      );
      expect(encode(options, ios), {
        'com.bugsee.option.capture.avplayer': true,
        'com.bugsee.option.reporting.ui.style': 1,
      });
    });

    test(
      'an enum constant one platform lacks is skipped there (FrameRate.raw)',
      () {
        const options = BugseeOptions(captureVideoFrameRate: FrameRate.raw);
        expect(encode(options, android), {
          'com.bugsee.option.capture.video.frame-rate': 4,
        });
        final onIos = encodeLaunchOptions(options, ios);
        expect(onIos.values, isEmpty);
        expect(
          onIos.warnings.single,
          contains('is not a value of BugseeFrameRate on iOS'),
        );
        // A constant both platforms have is never skipped.
        expect(
          encode(
            const BugseeOptions(captureVideoFrameRate: FrameRate.high),
            ios,
          ),
          {'com.bugsee.option.capture.video.frame-rate': 3},
        );
      },
    );

    test(
      'every typed option reaches exactly the platforms that register it',
      () {
        for (final spec in optionSpecs.where((s) => s.typed)) {
          final s = sample(spec);
          final options = withField(spec, s.value);
          for (final p in OptionPlatform.values) {
            final here = spec.on(p);
            final sent = encode(options, p);
            if (here == null) {
              expect(
                sent,
                isEmpty,
                reason: '${spec.key} must not be sent to $p',
              );
            } else {
              expect(sent, {spec.key: s.entry}, reason: '${spec.key} on $p');
            }
          }
        }
      },
    );

    test('no hidden key is ever sent, whatever is set', () {
      // Every typed option at once; the only hidden key that may appear is the endpoint.
      final everything = <String, Object>{};
      for (final spec in optionSpecs.where((s) => s.typed)) {
        everything.addAll(encode(withField(spec, sample(spec).value), ios));
        everything.addAll(encode(withField(spec, sample(spec).value), android));
      }
      expect(
        everything.keys.where((k) => optionSpecForKey(k)!.hidden),
        isEmpty,
      );
      expect(
        encode(const BugseeOptions(endpoint: 'https://x.example'), ios).keys,
        [endpointOptionKey],
      );
    });
  });

  group('custom: options this plugin has no field for', () {
    test('a registered key with a value of its type is sent', () {
      const options = BugseeOptions(
        custom: {'com.bugsee.option.detect.crash': false},
      );
      expect(encode(options, ios), {'com.bugsee.option.detect.crash': false});
    });

    test(
      'an int-valued enum takes a constant NAME and sends its number (iOS would read a string as 0)',
      () {
        expect(
          encode(
            const BugseeOptions(
              custom: {'com.bugsee.option.capture.logs.level': 'Warning'},
            ),
            ios,
          ),
          {'com.bugsee.option.capture.logs.level': 2},
        );
        expect(
          encode(
            const BugseeOptions(
              custom: {'com.bugsee.option.capture.video.frame-rate': 'High'},
            ),
            android,
          ),
          {'com.bugsee.option.capture.video.frame-rate': 3},
        );
        // Android's and iOS's names for severity value 1 both resolve.
        for (final name in ['VeryLow', 'Low']) {
          expect(
            encode(
              BugseeOptions(
                custom: {
                  'com.bugsee.option.reporting.defaults.bug-priority': name,
                },
              ),
              android,
            ),
            {'com.bugsee.option.reporting.defaults.bug-priority': 1},
          );
        }
        for (final bad in ['high', 'Huge', '']) {
          expect(
            () => encode(
              BugseeOptions(
                custom: {'com.bugsee.option.capture.logs.level': bad},
              ),
              ios,
            ),
            throwsArgumentError,
            reason: bad,
          );
        }
      },
    );

    test('a string-valued enum takes only its own names or wire strings', () {
      for (final ok in ['FAST', 'Fast', 'DEEP_EVERYWHERE']) {
        expect(
          encode(
            BugseeOptions(
              custom: {'com.bugsee.option.detect.memory_leaks.mode': ok},
            ),
            android,
          ),
          {'com.bugsee.option.detect.memory_leaks.mode': ok},
        );
      }
      expect(
        () => encode(
          const BugseeOptions(
            custom: {'com.bugsee.option.detect.memory_leaks.mode': 'Turbo'},
          ),
          android,
        ),
        throwsArgumentError,
      );
    });

    test('a float option takes an int and is sent as a double', () {
      const options = BugseeOptions(
        custom: {'com.bugsee.option.capture.video.scale': 1},
      );
      final value = encode(
        options,
        android,
      )['com.bugsee.option.capture.video.scale'];
      expect(value, 1.0);
      expect(value, isA<double>());
    });

    test('an enum option takes the SDK internal value', () {
      const options = BugseeOptions(
        custom: {'com.bugsee.option.capture.video.mode': 21},
      );
      expect(encode(options, android), {
        'com.bugsee.option.capture.video.mode': 21,
      });
    });

    test(
      'a key neither SDK registers is an error (the SDKs would drop it in silence)',
      () {
        expect(
          () => encode(
            const BugseeOptions(
              custom: {'com.bugsee.option.capture.vidoe': true},
            ),
            android,
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => '$e',
              'message',
              contains('not an option'),
            ),
          ),
        );
        expect(
          () =>
              encode(const BugseeOptions(custom: {'capture.video': true}), ios),
          throwsArgumentError,
        );
      },
    );

    test(
      'a deprecated option is still reachable through custom, with a warning',
      () {
        final encoded = encodeLaunchOptions(
          const BugseeOptions(
            custom: {
              'com.bugsee.option.capture.webview.domain-allowlist': 'x.example',
            },
          ),
          android,
        );
        expect(encoded.values, {
          'com.bugsee.option.capture.webview.domain-allowlist': 'x.example',
        });
        expect(encoded.warnings.single, contains('deprecated since SDK 7.1.2'));
      },
    );

    test('a hidden key is an error; the endpoint says where to go', () {
      expect(
        () => encode(
          const BugseeOptions(custom: {'com.bugsee.option.\$\$DEBUG': true}),
          android,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            contains('internal option'),
          ),
        ),
      );
      expect(
        () => encode(
          const BugseeOptions(custom: {endpointOptionKey: 'https://x.example'}),
          ios,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            contains('BugseeOptions.endpoint'),
          ),
        ),
      );
      expect(
        () => encode(
          const BugseeOptions(custom: {'com.bugsee.option.\$\$WRAPPER': {}}),
          android,
        ),
        throwsArgumentError,
      );
    });

    test(
      'a value of the wrong type is an error (the SDKs would keep the default)',
      () {
        for (final bad in <Map<String, Object?>>[
          {'com.bugsee.option.capture.logs': 'yes'},
          {'com.bugsee.option.config.duration': 1.5},
          {'com.bugsee.option.config.duration': '60'},
          {'com.bugsee.option.capture.video.scale': 'big'},
          {'com.bugsee.option.capture.video.scale': double.nan},
          {'com.bugsee.option.config.build-type': 3},
          {'com.bugsee.option.capture.logs.level': 2.5},
          {'com.bugsee.option.capture.logs': null},
        ]) {
          expect(
            () => encode(BugseeOptions(custom: bad), ios),
            throwsArgumentError,
            reason: '$bad',
          );
        }
      },
    );

    test(
      'an enum value neither SDK has is an error; one the other platform has is skipped',
      () {
        expect(
          () => encode(
            const BugseeOptions(
              custom: {'com.bugsee.option.capture.video.frame-rate': 9},
            ),
            android,
          ),
          throwsArgumentError,
        );
        final onIos = encodeLaunchOptions(
          const BugseeOptions(
            custom: {'com.bugsee.option.capture.video.frame-rate': 4},
          ),
          ios,
        );
        expect(onIos.values, isEmpty);
        expect(onIos.warnings, hasLength(1));
      },
    );

    test(
      'a key of the other platform is skipped with a warning, like a typed field',
      () {
        final encoded = encodeLaunchOptions(
          const BugseeOptions(
            custom: {'com.bugsee.option.capture.avplayer': true},
          ),
          android,
        );
        expect(encoded.values, isEmpty);
        expect(encoded.warnings.single, contains('iOS only'));
      },
    );

    test('the same option in a typed field and in custom is an error', () {
      expect(
        () => encode(
          const BugseeOptions(
            captureLogs: true,
            custom: {'com.bugsee.option.capture.logs': false},
          ),
          ios,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            contains('already set by its typed field'),
          ),
        ),
      );
    });

    test(
      'an option of a module the plugin does not bundle is sent with a warning',
      () {
        final encoded = encodeLaunchOptions(
          const BugseeOptions(
            custom: {'com.bugsee.option.detect.thread_leaks': true},
          ),
          android,
        );
        expect(encoded.values, {'com.bugsee.option.detect.thread_leaks': true});
        expect(encoded.warnings.single, contains('bugsee-android-leak'));
        // The leak module's string-valued enum takes the constant name.
        expect(
          encode(
            const BugseeOptions(
              custom: {
                'com.bugsee.option.detect.memory_leaks.mode': 'DEEP_DEBUG_ONLY',
              },
            ),
            android,
          ),
          {'com.bugsee.option.detect.memory_leaks.mode': 'DEEP_DEBUG_ONLY'},
        );
        // ... and is simply absent on iOS.
        expect(
          encodeLaunchOptions(
            const BugseeOptions(
              custom: {'com.bugsee.option.detect.thread_leaks': true},
            ),
            ios,
          ).values,
          isEmpty,
        );
      },
    );
  });
}
