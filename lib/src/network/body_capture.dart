// Bounded body capture and the SDK's body rules (doc/network.md). Internal.
import 'dart:convert';
import 'dart:typed_data';

import 'network_event.dart';

/// Copies the bytes that pass through, up to [limit], and counts all of them.
///
/// A body over the limit is dropped by the SDK, not cut, so once the count passes the limit the
/// copy is thrown away and nothing more is kept: memory is bounded by [limit] however large the
/// body is. A length declared up front (`Content-Length`) that already exceeds the limit
/// short-circuits the copy from the first byte. [keep] false counts without ever copying (a
/// body the SDK would drop for its type).
final class BodyTee {
  BodyTee({required this.limit, int? declaredLength, bool keep = true})
    : _declaredExceeds = (declaredLength ?? 0) > limit,
      _keeping = keep && limit > 0 && (declaredLength ?? 0) <= limit;

  final int limit;

  /// Every byte seen, kept or not.
  int size = 0;

  final bool _declaredExceeds;
  bool _keeping;
  final BytesBuilder _bytes = BytesBuilder(copy: true);

  void add(List<int> chunk) {
    size += chunk.length;
    if (!_keeping) return;
    if (size > limit) {
      _keeping = false;
      _bytes.clear();
      return;
    }
    _bytes.add(chunk);
  }

  /// More than the limit was seen or announced (a limit of 0 or less keeps nothing, so any byte
  /// is over it, as in the SDKs).
  bool get exceeded => size > limit || _declaredExceeds;

  /// The kept bytes, or null when they were not kept.
  Uint8List? get bytes => _keeping ? _bytes.toBytes() : null;
}

/// A parsed `Content-Type` value: lower-case type, subtype and the charset parameter if any.
final class MediaType {
  const MediaType(this.type, this.subtype, this.charset);

  final String type;
  final String subtype;
  final String? charset;

  static MediaType? parse(String? header) {
    if (header == null) return null;
    final parts = header.split(';');
    final essence = parts.first.trim().toLowerCase();
    final slash = essence.indexOf('/');
    if (slash <= 0 || slash == essence.length - 1) return null;
    String? charset;
    for (final parameter in parts.skip(1)) {
      final eq = parameter.indexOf('=');
      if (eq < 0) continue;
      if (parameter.substring(0, eq).trim().toLowerCase() == 'charset') {
        charset = parameter
            .substring(eq + 1)
            .trim()
            .replaceAll('"', '')
            .toLowerCase();
      }
    }
    return MediaType(
      essence.substring(0, slash),
      essence.substring(slash + 1),
      charset,
    );
  }

  /// What the SDKs keep (`NetworkUtils.isSupportedMediaType`, Android 7.4.2): `text/*`, and
  /// anything whose subtype mentions JSON, XML or `x-www-form-urlencoded`.
  bool get isTextual =>
      type == 'text' ||
      subtype.contains('json') ||
      subtype.contains('xml') ||
      subtype.contains('x-www-form-urlencoded');
}

/// Whether bytes of a body with this `Content-Type` are worth copying at all: the SDK would
/// otherwise drop them for their type. Decided up front so a binary body (an image) is counted
/// and never copied. With `capture.network.body-without-type` on the SDK skips every type check
/// (Android `NetworkEventsProducer`: the checks sit inside `if (!captureBodyWithoutType)`), so
/// then any body is a candidate.
bool shouldBufferBody({
  required String? contentType,
  required bool bodyWithoutType,
  required bool encoded,
}) {
  if (encoded) return false;
  if (bodyWithoutType) return true;
  final media = MediaType.parse(contentType?.trim());
  // An unparseable or missing type is not textual (`parseMediaTypeSilently` gives null).
  return media != null && media.isTextual;
}

/// The outcome of the SDK's body rules for one body.
final class BodyOutcome {
  const BodyOutcome(this.body, this.reason);

  final String? body;
  final NoBodyReason? reason;
}

/// Applies the SDK's body rules (Android `NetworkEventsProducer.getRequestBody/getResponseBody`
/// and `BugseeCaptureDataProviderNetwork.applyBodyFilters`; iOS `BGSCaptureDataEntryNetwork`), in
/// their order, to what [tee] saw.
///
/// [encoded] is a body that is still compressed (`Content-Encoding` present and not undone by the
/// client); [isRequest] only changes the order of the size and type checks as the SDK does: a
/// request that overflowed is `size_too_large` first, a response is judged by its type first.
BodyOutcome resolveBody({
  required BodyTee tee,
  required String? contentType,
  required bool bodyWithoutType,
  required bool encoded,
  required bool isRequest,
}) {
  if (tee.size == 0) return const BodyOutcome(null, null);
  if (isRequest && tee.exceeded) {
    return const BodyOutcome(null, NoBodyReason.sizeTooLarge);
  }
  final value = contentType?.trim();
  if (!bodyWithoutType) {
    if (value == null || value.isEmpty) {
      return const BodyOutcome(null, NoBodyReason.noContentType);
    }
    final media = MediaType.parse(value);
    if (media == null || !media.isTextual) {
      return const BodyOutcome(null, NoBodyReason.unsupportedContentType);
    }
  }
  if (tee.exceeded) return const BodyOutcome(null, NoBodyReason.sizeTooLarge);
  if (encoded) return const BodyOutcome(null, NoBodyReason.cantReadData);
  final bytes = tee.bytes;
  if (bytes == null) return const BodyOutcome(null, NoBodyReason.cantReadData);
  try {
    return BodyOutcome(_decode(bytes, MediaType.parse(value)?.charset), null);
  } on FormatException {
    return const BodyOutcome(null, NoBodyReason.cantReadData);
  } on UnsupportedError {
    return const BodyOutcome(null, NoBodyReason.cantReadData);
  }
}

String _decode(Uint8List bytes, String? charset) {
  switch (charset) {
    case null:
    case '':
    case 'utf-8':
    case 'utf8':
      return utf8.decode(bytes);
    case 'iso-8859-1':
    case 'latin1':
    case 'latin-1':
      return latin1.decode(bytes);
    case 'us-ascii':
    case 'ascii':
      return ascii.decode(bytes);
    default:
      throw UnsupportedError('charset $charset');
  }
}
