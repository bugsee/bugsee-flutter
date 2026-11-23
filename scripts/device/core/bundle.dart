// A report bundle the SDK wrote (a zip: manifest.json, request.json, one file per capture) and the
// questions the harness asks of it. Format: specs `sdk/reporting`.
import 'dart:convert';
import 'dart:typed_data';

import 'zip.dart';

class Bundle {
  Bundle(this.source, this.files)
    : manifest = _json(files['manifest.json'], 'manifest.json'),
      request = _json(files['request.json'], 'request.json');

  factory Bundle.fromZip(String source, Uint8List bytes) =>
      Bundle(source, zipContents(bytes));

  final String source;
  final Map<String, Uint8List> files;
  final Map<String, Object?> manifest;
  final Map<String, Object?> request;

  static Map<String, Object?> _json(Uint8List? bytes, String name) {
    if (bytes == null) throw FormatException('bundle has no $name');
    return (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
  }

  /// The manifest's file entries.
  List<Map<String, Object?>> get entries => [
    for (final f in manifest['files']! as List)
      (f as Map).cast<String, Object?>(),
  ];

  List<Map<String, Object?>> entriesOfType(String type) => [
    for (final e in entries)
      if (e['type'] == type) e,
  ];

  /// The bytes of the manifest entry [entry].
  Uint8List content(Map<String, Object?> entry) => files[entry['filename']]!;

  String get type => request['type']! as String;
  String? get summary => request['summary'] as String?;
  List<String> get labels => [
    for (final l in (request['labels'] as List?) ?? const []) '$l',
  ];

  Map<String, Object?> get environment =>
      (request['environment']! as Map).cast<String, Object?>();
  Map<String, Object?> get sdk =>
      (environment['sdk']! as Map).cast<String, Object?>();
  Map<String, Object?> get app =>
      (environment['app']! as Map).cast<String, Object?>();
  Object? get wrapper => sdk['wrapper'];

  /// `session` or `current` on a recovered report, absent on a live one (specs `sdk/report-identity`).
  String? get identitySource => environment['identity_source'] as String?;

  Map<String, Object?> get attributes =>
      ((manifest['attrs'] as Map?) ?? const {}).cast<String, Object?>();

  /// The decoded `crash.json`, or `null` for a report without a crash entry.
  Map<String, Object?>? get crash {
    final e = entriesOfType('crash');
    if (e.isEmpty) return null;
    return (jsonDecode(utf8.decode(content(e.first))) as Map)
        .cast<String, Object?>();
  }

  /// The captured JSON text of the first entry of [type], or `null`.
  String? text(String type) {
    final e = entriesOfType(type);
    return e.isEmpty
        ? null
        : utf8.decode(content(e.first), allowMalformed: true);
  }
}
