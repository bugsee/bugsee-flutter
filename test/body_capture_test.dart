// The bounded body copy and the SDK's body rules (Android 7.4.2 NetworkEventsProducer /
// BugseeCaptureDataProviderNetwork.applyBodyFilters, iOS BGSCaptureDataEntryNetwork).
import 'dart:convert';
import 'dart:typed_data';

import 'package:bugsee_flutter/src/network/body_capture.dart';
import 'package:bugsee_flutter/src/network/network_event.dart';
import 'package:flutter_test/flutter_test.dart';

BodyTee teeOf(
  List<int> bytes, {
  int limit = 100,
  int? declared,
  bool keep = true,
  int chunk = 1 << 30,
}) {
  final tee = BodyTee(limit: limit, declaredLength: declared, keep: keep);
  for (var i = 0; i < bytes.length; i += chunk) {
    tee.add(
      bytes.sublist(i, i + chunk > bytes.length ? bytes.length : i + chunk),
    );
  }
  return tee;
}

void main() {
  group('BodyTee', () {
    test('keeps what fits and counts it', () {
      final tee = teeOf(utf8.encode('hello'), limit: 5);
      expect(tee.size, 5);
      expect(tee.exceeded, isFalse);
      expect(utf8.decode(tee.bytes!), 'hello');
    });

    test(
      'one byte over the limit: nothing is kept, everything is still counted',
      () {
        final tee = teeOf(List<int>.filled(6, 1), limit: 5);
        expect(tee.exceeded, isTrue);
        expect(tee.bytes, isNull);
        expect(tee.size, 6);
      },
    );

    test(
      'bytes after the overflow are counted and not kept, whatever the chunking',
      () {
        final tee = teeOf(List<int>.filled(10000, 1), limit: 100, chunk: 7);
        expect(tee.size, 10000);
        expect(tee.bytes, isNull);
      },
    );

    test(
      'the copy is dropped at the overflow: memory is bounded by the limit',
      () {
        // The kept bytes are released the moment the limit is passed, not at the end.
        final tee = BodyTee(limit: 10);
        tee.add(List<int>.filled(8, 1));
        expect(tee.bytes, hasLength(8));
        tee.add(List<int>.filled(8, 1));
        expect(tee.bytes, isNull);
        tee.add(List<int>.filled(8, 1));
        expect(tee.bytes, isNull);
        expect(tee.size, 24);
      },
    );

    test('a chunk the app reuses afterwards does not change the copy', () {
      final tee = BodyTee(limit: 10);
      final chunk = Uint8List.fromList([1, 2, 3]);
      tee.add(chunk);
      chunk[0] = 99;
      expect(tee.bytes, [1, 2, 3]);
    });

    test(
      'a declared length over the limit keeps nothing from the first byte',
      () {
        final tee = teeOf([1, 2, 3], limit: 5, declared: 6);
        expect(tee.exceeded, isTrue);
        expect(tee.bytes, isNull);
        expect(tee.size, 3);
      },
    );

    test('a declared length within the limit changes nothing', () {
      final tee = teeOf([1, 2, 3], limit: 5, declared: 3);
      expect(tee.exceeded, isFalse);
      expect(tee.bytes, [1, 2, 3]);
    });

    test('a limit of 0 keeps nothing and any byte exceeds it', () {
      final tee = teeOf([1], limit: 0);
      expect(tee.exceeded, isTrue);
      expect(tee.bytes, isNull);
      expect(teeOf(const [], limit: 0).exceeded, isFalse);
    });

    test('keep: false counts without ever copying', () {
      final tee = teeOf([1, 2, 3], keep: false);
      expect(tee.bytes, isNull);
      expect(tee.size, 3);
      expect(tee.exceeded, isFalse);
    });
  });

  group('MediaType', () {
    test(
      'parses type, subtype and charset, case-insensitively, with quotes',
      () {
        final m = MediaType.parse('Application/JSON; Charset="UTF-8"')!;
        expect(m.type, 'application');
        expect(m.subtype, 'json');
        expect(m.charset, 'utf-8');
        expect(MediaType.parse('text/plain')!.charset, isNull);
        expect(
          MediaType.parse('text/plain; boundary=x; charset=latin1')!.charset,
          'latin1',
        );
      },
    );

    test('garbage is null', () {
      for (final bad in [null, '', 'text', '/json', 'text/', ';charset=x']) {
        expect(MediaType.parse(bad), isNull, reason: '$bad');
      }
    });

    test('textual is the SDK\'s rule: text/*, JSON, XML, form-encoded', () {
      for (final yes in [
        'text/plain',
        'text/html; charset=utf-8',
        'application/json',
        'application/vnd.api+json',
        'application/xml',
        'image/svg+xml',
        'application/x-www-form-urlencoded',
        'application/problem+json',
      ]) {
        expect(MediaType.parse(yes)!.isTextual, isTrue, reason: yes);
      }
      for (final no in [
        'application/octet-stream',
        'image/png',
        'video/mp4',
        'application/pdf',
        'multipart/form-data; boundary=x',
      ]) {
        expect(MediaType.parse(no)!.isTextual, isFalse, reason: no);
      }
    });
  });

  group('shouldBufferBody', () {
    test(
      'text is buffered, binary and typeless are not, unless the option is on',
      () {
        bool b(String? type, {bool without = false, bool encoded = false}) =>
            shouldBufferBody(
              contentType: type,
              bodyWithoutType: without,
              encoded: encoded,
            );
        expect(b('application/json'), isTrue);
        expect(b('image/png'), isFalse);
        expect(b(null), isFalse);
        expect(b(''), isFalse);
        expect(b('garbage'), isFalse);
        expect(b(null, without: true), isTrue);
        expect(
          b('image/png', without: true),
          isTrue,
          reason: 'the SDK skips every type check then',
        );
        expect(b('application/json', encoded: true), isFalse);
        expect(b(null, without: true, encoded: true), isFalse);
      },
    );
  });

  group('resolveBody', () {
    BodyOutcome resolve(
      List<int> bytes, {
      String? type = 'text/plain',
      int limit = 100,
      bool without = false,
      bool encoded = false,
      bool request = false,
      bool keep = true,
    }) => resolveBody(
      tee: teeOf(bytes, limit: limit, keep: keep),
      contentType: type,
      bodyWithoutType: without,
      encoded: encoded,
      isRequest: request,
    );

    test('no bytes: no body and no reason (the SDK\'s None)', () {
      final o = resolve(const []);
      expect(o.body, isNull);
      expect(o.reason, isNull);
    });

    test('text decodes', () {
      expect(resolve(utf8.encode('héllo ✓')).body, 'héllo ✓');
    });

    test(
      'no type, unsupported type, too large, compressed: each its own reason',
      () {
        expect(resolve([1], type: null).reason, NoBodyReason.noContentType);
        expect(resolve([1], type: '  ').reason, NoBodyReason.noContentType);
        expect(
          resolve([1], type: 'image/png', keep: false).reason,
          NoBodyReason.unsupportedContentType,
        );
        expect(
          resolve([1], type: 'nonsense').reason,
          NoBodyReason.unsupportedContentType,
        );
        expect(
          resolve(List<int>.filled(101, 97)).reason,
          NoBodyReason.sizeTooLarge,
        );
        expect(
          resolve([97], encoded: true, keep: false).reason,
          NoBodyReason.cantReadData,
        );
      },
    );

    test(
      'the order of the checks differs for a request and a response, as in the SDK',
      () {
        final big = List<int>.filled(500, 1);
        // A request that overflowed is size_too_large first (NetworkEventsProducer.getRequestBody).
        expect(
          resolve(big, type: 'image/png', request: true, keep: false).reason,
          NoBodyReason.sizeTooLarge,
        );
        expect(
          resolve(big, type: null, request: true, keep: false).reason,
          NoBodyReason.sizeTooLarge,
        );
        // A response is judged by its type first (getResponseBody).
        expect(
          resolve(big, type: 'image/png', keep: false).reason,
          NoBodyReason.unsupportedContentType,
        );
        expect(
          resolve(big, type: null, keep: false).reason,
          NoBodyReason.noContentType,
        );
        expect(resolve(big).reason, NoBodyReason.sizeTooLarge);
      },
    );

    test(
      'with the option on no type check applies; what is not text is cant_read_data',
      () {
        expect(
          resolve(utf8.encode('plain'), type: null, without: true).body,
          'plain',
        );
        expect(
          resolve(utf8.encode('x'), type: 'image/png', without: true).body,
          'x',
        );
        expect(
          resolve([0xff, 0xfe, 0xfd], type: 'image/png', without: true).reason,
          NoBodyReason.cantReadData,
        );
      },
    );

    test(
      'charsets: utf-8, latin1 and ascii decode; others and bad bytes are cant_read_data',
      () {
        expect(
          resolve([0xe9], type: 'text/plain; charset=iso-8859-1').body,
          'é',
        );
        expect(resolve([0xe9], type: 'text/plain; charset=latin1').body, 'é');
        expect(
          resolve(
            utf8.encode('abc'),
            type: 'text/plain; charset=us-ascii',
          ).body,
          'abc',
        );
        expect(
          resolve([0xe9], type: 'text/plain; charset=us-ascii').reason,
          NoBodyReason.cantReadData,
        );
        expect(
          resolve([0x68, 0x00], type: 'text/plain; charset=utf-16').reason,
          NoBodyReason.cantReadData,
        );
        expect(
          resolve([0xff, 0xfe], type: 'text/plain').reason,
          NoBodyReason.cantReadData,
        );
      },
    );

    test('exactly at the limit is a body', () {
      expect(resolve(List<int>.filled(100, 97)).body, hasLength(100));
    });
  });
}
