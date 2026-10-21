// What the wrapper removes from URL-bearing fields itself, because no SDK does it there.
import 'dart:convert';

import 'package:bugsee_flutter/src/network/body_capture.dart';
import 'package:bugsee_flutter/src/network/url_redaction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('stripUserInfo', () {
    test('removes user and password from an absolute URL, keeps the rest', () {
      expect(
        stripUserInfo('http://user:pw@127.0.0.1:8080/a/b?x=1#f'),
        'http://127.0.0.1:8080/a/b?x=1#f',
      );
      expect(
        stripUserInfo('https://token@example.com/'),
        'https://example.com/',
      );
    });

    test('also in a scheme-relative URL and inside a longer text', () {
      expect(stripUserInfo('//u:p@host/x'), '//host/x');
      expect(
        stripUserInfo('failed, uri = http://a:b@h/p and http://c:d@h2/q'),
        'failed, uri = http://h/p and http://h2/q',
      );
    });

    test(
      'leaves a URL without userinfo and an @ in the path or query alone',
      () {
        for (final u in [
          'http://example.com/',
          'http://example.com/a@b',
          'http://example.com/?mail=a@b.c',
          'http://example.com/#@x',
        ]) {
          expect(stripUserInfo(u), u);
        }
      },
    );
  });

  group('redactQueryValues', () {
    test('keeps names, drops values, keeps a valueless parameter', () {
      expect(
        redactQueryValues('/final?token=abc&x=1&flag'),
        '/final?token=<redacted>&x=<redacted>&flag',
      );
    });

    test('stops at the fragment and whitespace', () {
      expect(
        redactQueryValues('0; url=/n?s=1#frag'),
        '0; url=/n?s=<redacted>#frag',
      );
    });

    test('text without a query is unchanged', () {
      expect(redactQueryValues('/plain/path'), '/plain/path');
    });
  });

  group('redactHeaderValue', () {
    test('URL-valued headers lose userinfo and query values', () {
      expect(
        redactHeaderValue('location', 'http://u:p@h/x?token=abc'),
        'http://h/x?token=<redacted>',
      );
      expect(
        redactHeaderValue('content-location', '/x?a=1'),
        '/x?a=<redacted>',
      );
      expect(
        redactHeaderValue('referer', 'http://u:p@h/p?k=v'),
        'http://h/p?k=<redacted>',
      );
      expect(
        redactHeaderValue('refresh', '0; url=/n?s=1'),
        '0; url=/n?s=<redacted>',
      );
    });

    test('every other header is untouched', () {
      expect(
        redactHeaderValue('accept', 'text/html;q=0.9?x=1'),
        'text/html;q=0.9?x=1',
      );
      expect(
        redactHeaderValue('x-callback', 'http://u:p@h/x?token=abc'),
        'http://u:p@h/x?token=abc',
        reason: 'not URL-valued by name: the SDK sanitizer owns it',
      );
    });
  });

  group('the length of text without encoding it', () {
    const samples = [
      '',
      'plain ascii',
      'café ü',
      '€100 中文',
      'emoji \u{1F600}\u{1F4A9} end',
      'lone high \uD800 x',
      'lone low \uDC00 y',
      'high at end \uD83D',
      '\uD83D😀',
    ];

    test('utf8Length is what the UTF-8 encoder produces', () {
      for (final s in samples) {
        expect(utf8Length(s), utf8.encode(s).length, reason: s);
      }
    });

    test(
      'encodedLength: UTF-8, Latin-1 and ASCII without building bytes, others by encoding',
      () {
        expect(encodedLength('café', utf8), 5);
        expect(encodedLength('café', latin1), 4);
        expect(encodedLength('abc', ascii), 3);
        expect(encodedLength('abc', const _Doubling()), 6);
      },
    );

    test('a text is kept only while its bytes can still fit', () {
      final tee = BodyTee(limit: 10);
      expect(canKeepText(tee, '0123456789'), isTrue);
      expect(canKeepText(tee, '0123456789a'), isFalse);
      tee.add([1, 2, 3, 4]);
      expect(canKeepText(tee, '012345'), isTrue);
      expect(canKeepText(tee, '0123456'), isFalse);
      tee.addCount(100);
      expect(
        canKeepText(tee, ''),
        isFalse,
        reason: 'past the limit nothing is kept',
      );
      expect(tee.keptLength, 0);
      expect(tee.size, 104);
      expect(canKeepText(BodyTee(limit: 10, keep: false), 'a'), isFalse);
    });

    test('counting past the limit releases what was kept', () {
      final tee = BodyTee(limit: 10)..add([1, 2, 3]);
      expect(tee.keptLength, 3);
      tee.addCount(8);
      expect(tee.keptLength, 0);
      expect(tee.bytes, isNull);
      expect(tee.exceeded, isTrue);
    });
  });
}

/// An encoding whose bytes are twice the text (to reach the fallback path).
class _Doubling extends Encoding {
  const _Doubling();
  @override
  Converter<String, List<int>> get encoder => const _DoublingEncoder();
  @override
  Converter<List<int>, String> get decoder => utf8.decoder;
  @override
  String get name => 'doubling';
}

class _DoublingEncoder extends Converter<String, List<int>> {
  const _DoublingEncoder();
  @override
  List<int> convert(String input) => [
    for (final c in input.codeUnits) ...[c & 0xff, c & 0xff],
  ];
}
