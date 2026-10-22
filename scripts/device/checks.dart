// Assertions about a report bundle that are the same on both platforms: what the Dart exception
// carrier looks like, what the managed view hierarchy holds, what reached the log and network capture,
// and whether the secure region is redacted in a video frame. Each takes a [Run], so every check is
// recorded with its evidence.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'core/bundle.dart';
import 'core/experiment.dart';
import 'core/image.dart';
import 'core/log_parsers.dart';
import 'core/symbols.dart';
import 'shell.dart';

/// One exception report: [label] names the build and the way it was reported.
void checkExceptionReport(
  Run run,
  String label,
  Bundle b, {
  required String carrierName,
  required bool unhandled,
}) {
  final crash = b.crash;
  if (crash == null) {
    run.expect(
      '[$label] the report has a crash entry',
      false,
      'entries: ${b.entries.map((e) => e['type']).toList()}',
    );
    return;
  }
  final ex = (crash['exception'] as Map?)?.cast<String, Object?>() ?? const {};
  run.expect(
    '[$label] the carrier name is intact (the backend routes on it)',
    ex['name'] == carrierName,
    '${ex['name']}',
  );
  final doc = parseManagedDocument('${ex['reason']}');
  run.expect(
    '[$label] the document has internalType, name, reason, signature, frames, originalStackTrace and nothing else',
    doc != null &&
        doc.keys.toSet().difference(managedDocumentKeys).isEmpty &&
        doc.keys.toSet().containsAll(managedDocumentKeys),
    doc == null ? 'unparsable: ${ex['reason']}' : '${doc.keys.toList()}',
  );
  if (doc != null) {
    final frames = (doc['frames'] as List).cast<Map>();
    run.expect(
      '[$label] the document has frames and the app frame is among them (user: true)',
      frames.isNotEmpty && frames.any((f) => f['user'] == true),
      '${frames.take(2).map((f) => f['trace']).toList()}',
    );
    run.note(
      '[$label] name=${doc['name']} signature=${doc['signature']} frames=${frames.length}; originalStackTrace: ${(doc['originalStackTrace'] as String).split('\n').take(3).join(' | ')}',
    );
  }
  final handled = crash['handled'];
  run.expect(
    '[$label] handled flag and report type',
    unhandled
        ? handled == false && b.type == 'crash'
        : handled == true && b.type == 'error',
    'handled=$handled type=${b.type}',
  );
}

/// The managed hierarchy of a report: nodes, root, and the set of class names.
class ManagedTree {
  ManagedTree(this.root, this.count, this.names);
  final Map root;
  final int count;
  final Set<String> names;
}

ManagedTree? managedTree(Bundle b) {
  final vt = b.text('viewtree');
  if (vt == null) return null;
  final events = (jsonDecode(vt) as Map)['events'] as List;
  if (events.isEmpty) return null;
  final m = (events.first as Map)['managed'];
  if (m is! String) return null;
  final root = jsonDecode(m) as Map;
  var count = 0;
  final names = <String>{};
  void walk(Map n) {
    count++;
    names.add('${n['class_name']}');
    for (final c in (n['subitems'] as List?) ?? const []) {
      walk(c as Map);
    }
  }

  walk(root);
  return ManagedTree(root, count, names);
}

void checkViewHierarchy(
  Run run,
  String label,
  Bundle b, {
  required bool obfuscated,
}) {
  final t = managedTree(b);
  run.expect(
    '[$label] view hierarchy: the managed Flutter tree is in the bundle',
    t != null && t.root['class_name'] == 'FlutterView' && t.count > 5,
    t == null
        ? 'no managed part in the viewtree entry'
        : '${t.count} nodes, root ${t.root['class_name']}, ratio ${(t.root['options'] as Map?)?['device_pixel_ratio']}',
  );
  if (t == null) return;
  if (!obfuscated) {
    run.expect(
      '[$label] widget type names are the real ones',
      t.names.contains('_VerifyApp') && t.names.contains('MaterialApp'),
      '${t.names.take(8).toList()}',
    );
  } else {
    run.note(
      '[$label] under --obfuscate the widget runtimeType names are obfuscated: ${t.names.where((n) => !n.startsWith('_')).take(6).toList()}',
    );
  }
}

void checkLogs(Run run, String label, Bundle b, String marker) {
  final log = b.text('log') ?? '';
  run.expect(
    '[$label] log capture: print and debugPrint reach the report',
    log.contains('verify-log-marker $marker') &&
        log.contains('verify-debugprint-marker $marker'),
    'print marker ${log.contains('verify-log-marker $marker')}, debugPrint marker ${log.contains('verify-debugprint-marker $marker')}',
  );
}

void checkNetwork(Run run, String label, Bundle b, String marker) {
  final net = b.text('network');
  run.expect(
    '[$label] network capture: the dart:io request is in the bundle',
    net != null && net.contains('/ping?$marker'),
    net == null
        ? 'no network entry in ${b.entries.map((e) => e['type']).toList()}'
        : 'found /ping?$marker in ${net.length} bytes',
  );
}

/// With the secure region on, its box in [on] is black and none of its colour shows; [off] is the same
/// screen with the region unsecured, which is where the box is. Returns the region box found.
Rect? checkRedaction(Run run, String label, RawImage on, RawImage off) {
  const magenta = Rgb(255, 0, 255);
  const black = Rgb(0, 0, 0);
  final region = off.boundingBoxOf(magenta);
  run.expect(
    '[$label] the unsecured region is visible in the frame',
    region != null,
    '$region in ${off.width}x${off.height}',
  );
  if (region == null) return null;
  final blackInside = on.fractionOf(region, black, tolerance: 24);
  final magentaInside = on.fractionOf(region, magenta, tolerance: 60);
  run.expect(
    '[$label] with the region secured, its box is redacted (black) and none of the region shows',
    blackInside > 0.97 && magentaInside < 0.01,
    'box $region in a ${on.width}x${on.height} frame: black ${(blackInside * 100).toStringAsFixed(1)}%, magenta ${(magentaInside * 100).toStringAsFixed(1)}%',
  );
  return region;
}

/// Decodes a still image (the report screenshot: webp on Android, jpeg on iOS) to raw RGB with ffmpeg,
/// or `null` when ffmpeg is absent or cannot read it.
Future<RawImage?> decodeStill(
  Uint8List bytes,
  String workDir,
  String ext,
) async {
  final dir = Directory('$workDir/frames')..createSync(recursive: true);
  final f = File('${dir.path}/still.$ext')..writeAsBytesSync(bytes);
  try {
    final probe = await sh([
      'ffprobe',
      '-v',
      'error',
      '-select_streams',
      'v:0',
      '-show_entries',
      'stream=width,height',
      '-of',
      'csv=p=0',
      f.path,
    ]);
    if (!probe.ok || !probe.text.contains(',')) return null;
    final wh = probe.text.split(',');
    final w = int.parse(wh[0]), h = int.parse(wh[1]);
    final raw = await sh([
      'ffmpeg',
      '-v',
      'error',
      '-i',
      f.path,
      '-frames:v',
      '1',
      '-f',
      'rawvideo',
      '-pix_fmt',
      'rgb24',
      '-',
    ], raw: true);
    if (!raw.ok || raw.bytes == null || raw.bytes!.length < w * h * 3) {
      return null;
    }
    return RawImage(w, h, Uint8List.sublistView(raw.bytes!, 0, w * h * 3));
  } finally {
    f.deleteSync();
  }
}

/// The report's screenshot decoded, with the extension its manifest entry implies.
Future<RawImage?> screenshotOf(Bundle b, String workDir) async {
  final e = b.entriesOfType('screenshot');
  if (e.isEmpty) return null;
  final name = '${e.first['filename']}';
  final ext = name.endsWith('.jpg') ? 'jpg' : 'webp';
  return decodeStill(b.content(e.first), workDir, ext);
}

/// What the report screenshots say about the secure region: flat (nothing to see either way) or real
/// content, in which case the same redaction check as for the video runs on it.
Future<void> checkScreenshotRedaction(
  Run run,
  String label,
  Bundle on,
  Bundle off,
  String workDir,
) async {
  final a = await screenshotOf(on, workDir);
  final b = await screenshotOf(off, workDir);
  if (a == null || b == null) {
    run.note(
      '[$label] report screenshot: not decoded (no screenshot entry, or ffmpeg is not available)',
    );
    return;
  }
  if (a.isUniform() && b.isUniform()) {
    run.note(
      '[$label] report screenshot: ${a.width}x${a.height}, ONE FLAT COLOUR with the region secured and unsecured alike (${a.at(0, 0)}): it cannot show the redaction either way; the video frame is the evidence',
    );
    return;
  }
  checkRedaction(run, '$label screenshot', a, b);
}

/// The last frame of a bundle's video as raw RGB (ffmpeg), or `null` when ffmpeg is absent or there is
/// no video.
Future<RawImage?> lastVideoFrame(Bundle b, String workDir, String tag) async {
  final entries = b.entriesOfType('video');
  if (entries.isEmpty) return null;
  final dir = Directory('$workDir/frames')..createSync(recursive: true);
  final mp4 = File('${dir.path}/$tag.mp4')
    ..writeAsBytesSync(b.content(entries.first));
  try {
    final probe = await sh([
      'ffprobe',
      '-v',
      'error',
      '-select_streams',
      'v:0',
      '-show_entries',
      'stream=width,height',
      '-of',
      'csv=p=0',
      mp4.path,
    ]);
    if (!probe.ok) return null;
    final wh = probe.text.split(',');
    final w = int.parse(wh[0]), h = int.parse(wh[1]);
    // The last frame: seek to the end when the video is long enough to, else (a video shorter than the
    // seek, as a short iOS recording can be) decode every frame and keep the last.
    var raw = await sh([
      'ffmpeg',
      '-v',
      'error',
      '-sseof',
      '-0.4',
      '-i',
      mp4.path,
      '-frames:v',
      '1',
      '-f',
      'rawvideo',
      '-pix_fmt',
      'rgb24',
      '-',
    ], raw: true);
    if (!raw.ok || raw.bytes == null || raw.bytes!.length < w * h * 3) {
      raw = await sh(
        [
          'ffmpeg',
          '-v',
          'error',
          '-i',
          mp4.path,
          '-f',
          'rawvideo',
          '-pix_fmt',
          'rgb24',
          '-',
        ],
        raw: true,
        timeout: const Duration(minutes: 3),
      );
      if (!raw.ok || raw.bytes == null || raw.bytes!.length < w * h * 3) {
        return null;
      }
      final all = raw.bytes!;
      final frames = all.length ~/ (w * h * 3);
      return RawImage(
        w,
        h,
        Uint8List.sublistView(
          all,
          (frames - 1) * w * h * 3,
          frames * w * h * 3,
        ),
      );
    }
    return RawImage(w, h, Uint8List.sublistView(raw.bytes!, 0, w * h * 3));
  } finally {
    if (mp4.existsSync()) mp4.deleteSync();
  }
}

/// The video's own account of how the screen was fitted into the frame (`video.aux.json`: the padding
/// and the screen size), or `null`.
({int paddingH, int paddingV, int screenW, int screenH})? videoLayout(
  Bundle b,
) {
  final e = b.entriesOfType('video.aux');
  if (e.isEmpty) return null;
  try {
    final events =
        (jsonDecode(utf8.decode(b.content(e.first))) as Map)['events'] as List;
    final m = (events.first as Map).cast<String, Object?>();
    return (
      paddingH: (m['paddingH'] as num).toInt(),
      paddingV: (m['paddingV'] as num).toInt(),
      screenW: (m['screenW'] as num).toInt(),
      screenH: (m['screenH'] as num).toInt(),
    );
  } on Object {
    return null;
  }
}

/// Where the region should be in the frame, computed from what the APP says (its logical box and its
/// device pixel ratio) and how the SDK fitted the screen into the frame, against where it IS (the
/// region's colour, found with the secure view off). This is independent of the redaction: it shows the
/// logical-to-physical step and the frame mapping are understood before the redaction is judged.
void checkRegionPlacement(
  Run run,
  String label,
  Rect measured,
  ({int paddingH, int paddingV, int screenW, int screenH}) layout,
  RawImage frame,
  Map<String, num> logical,
  double ratio,
) {
  final scale = layout.paddingH > 0
      ? (frame.width - 2 * layout.paddingH) / layout.screenW
      : (frame.height - 2 * layout.paddingV) / layout.screenH;
  final x = layout.paddingH + logical['x']!.toDouble() * ratio * scale;
  final y = layout.paddingV + logical['y']!.toDouble() * ratio * scale;
  final w = logical['w']!.toDouble() * ratio * scale;
  final h = logical['h']!.toDouble() * ratio * scale;
  final off = [
    (measured.left - x).abs(),
    (measured.top - y).abs(),
    (measured.width - w).abs(),
    (measured.height - h).abs(),
  ];
  run.expect(
    '[$label] the region is where its LOGICAL box x ratio $ratio puts it in the frame (physical pixels, scale ${scale.toStringAsFixed(4)})',
    off.every((d) => d <= 3.0),
    'expected [${x.toStringAsFixed(1)},${y.toStringAsFixed(1)} ${w.toStringAsFixed(1)}x${h.toStringAsFixed(1)}], found $measured; off by ${off.map((d) => d.toStringAsFixed(1)).toList()} px',
  );
}

/// The events the isolate that printed the LAST `main` event produced (the verification app prints it
/// first thing; a hot restart starts a new isolate in the same process).
List<VerifyEvent> afterLastMain(List<VerifyEvent> events) {
  final i = events.lastIndexWhere((e) => e.kind == 'main');
  return i < 0 ? events : events.sublist(i + 1);
}
