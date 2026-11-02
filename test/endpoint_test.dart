// The endpoint override, normalised in one place (workbook 8.2).
import 'package:bugsee_flutter/src/options/bugsee_options.g.dart';
import 'package:bugsee_flutter/src/options/endpoint.dart';
import 'package:bugsee_flutter/src/options/launch_options.dart';
import 'package:bugsee_flutter/src/options/option_registry.dart';
import 'package:bugsee_flutter/src/options/option_registry.g.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeEndpoint', () {
    test(
      'nothing to send for null, empty or blank (never an empty override)',
      () {
        expect(normalizeEndpoint(null), isNull);
        expect(normalizeEndpoint(''), isNull);
        expect(normalizeEndpoint('   \n'), isNull);
      },
    );

    test('a plain base URL is kept, trimmed', () {
      expect(
        normalizeEndpoint('https://api.example.com'),
        'https://api.example.com',
      );
      expect(
        normalizeEndpoint('  https://api.example.com  '),
        'https://api.example.com',
      );
      expect(normalizeEndpoint('http://10.0.2.2:8080'), 'http://10.0.2.2:8080');
    });

    test(
      'the version segment and trailing slashes are removed: the SDKs append it',
      () {
        for (final given in [
          'https://api.example.com/v2',
          'https://api.example.com/v2/',
          'https://api.example.com/',
          'https://api.example.com//',
          'https://api.example.com/v2/v2',
          'https://api.example.com/v2//v2/',
        ]) {
          expect(
            normalizeEndpoint(given),
            'https://api.example.com',
            reason: given,
          );
        }
      },
    );

    test('a path prefix is kept, the version after it is removed', () {
      expect(
        normalizeEndpoint('https://example.com/bugsee/v2'),
        'https://example.com/bugsee',
      );
      expect(
        normalizeEndpoint('https://example.com/bugsee/'),
        'https://example.com/bugsee',
      );
    });

    test('only a path segment is a version: a host called v2 is a host', () {
      expect(normalizeEndpoint('https://v2'), 'https://v2');
      expect(normalizeEndpoint('https://v2/'), 'https://v2');
      expect(
        normalizeEndpoint('https://example.com/v22'),
        'https://example.com/v22',
      );
    });

    test('something that is not an http(s) URL with a host is an error', () {
      for (final bad in [
        'api.example.com',
        '/v2',
        'ftp://api.example.com',
        'https://',
        'https:///v2',
        'https://api.example.com?x=1',
        'https://api.example.com#top',
      ]) {
        expect(() => normalizeEndpoint(bad), throwsArgumentError, reason: bad);
      }
    });
  });

  group('the endpoint reaches both SDKs under one key', () {
    test('the key is the hidden option both manifests register', () {
      final spec = optionSpecs.singleWhere((s) => s.key == endpointOptionKey);
      expect(spec.hidden, isTrue);
      expect(spec.android, isNotNull);
      expect(
        spec.ios,
        isNotNull,
        reason: 'iOS 7.0.0 registers it too (it did not in 6.x)',
      );
      expect(spec.typed, isFalse);
    });

    test('the same version-less value goes to Android and iOS', () {
      const options = BugseeOptions(endpoint: 'https://bugsee.example.com/v2/');
      for (final platform in OptionPlatform.values) {
        final encoded = encodeLaunchOptions(options, platform);
        expect(encoded.values, {
          endpointOptionKey: 'https://bugsee.example.com',
        }, reason: '$platform');
        expect(
          encoded.values.containsKey('endpoint'),
          isFalse,
          reason: 'no flat legacy key',
        );
      }
    });

    test('no endpoint, no key', () {
      for (final platform in OptionPlatform.values) {
        expect(
          encodeLaunchOptions(
            const BugseeOptions(endpoint: '  '),
            platform,
          ).values,
          isEmpty,
        );
      }
    });

    test('a bad endpoint fails before anything is sent', () {
      expect(
        () => encodeLaunchOptions(
          const BugseeOptions(endpoint: 'not a url'),
          OptionPlatform.ios,
        ),
        throwsArgumentError,
      );
    });
  });
}
