// The Flutter exception carrier's document (doc/exceptions.md, worker `crash/managed`): the SDK's crash
// entry holds the JSON in the exception's `reason`, after the SDK's own envelope. Read with the
// backend worker's rules (the same ones scripts/verify_symbolization.dart applies).
import 'dart:convert';

/// The only keys the worker reads; the carrier writes these and nothing else.
const managedDocumentKeys = {
  'internalType',
  'name',
  'reason',
  'signature',
  'frames',
  'originalStackTrace',
};

Map<String, Object?>? parseManagedDocument(String reason) {
  var r = reason.replaceFirst(RegExp(r'^\s*.*FlutterManagedException:\s*'), '');
  r = r.replaceFirst(RegExp(r'^[^{"]+'), '');
  try {
    final v = jsonDecode(r);
    return v is Map ? v.cast<String, Object?>() : null;
  } on FormatException {
    return null;
  }
}
