// Attachments and screenshots of a report (workbook 7.3.3, report-contract "path-first"). Public
// types plus the validation that runs in Dart BEFORE anything crosses the bridge. The natives
// defend again (`ReportOps.java`, `BGSFlutterReportOps.m`) and the numbers are repeated there;
// `test/report_attachments_drift_test.dart` compares the copies.
import '../errors.dart';
import '../launch.dart';

/// The most bytes `addAttachmentBytes` takes: 1 MiB. Bytes cross the platform channel as one message
/// (copied at each end), which is fine for a small payload and wasteful for a large one; the
/// report-contract keeps the in-memory form "for small payloads only" and says to use the file form
/// for anything large. Repeated in Java (`ReportOps.MAX_ATTACHMENT_BYTES`) and Objective-C
/// (`BGSFlutterReportOps`).
const int maxAttachmentBytes = 1024 * 1024;

/// The soft limit of ONE attached file: 20 MiB. Neither SDK limits a file on this path, but a copy is
/// synchronous I/O in front of every other queued operation and the SDK's handler timer does not wait
/// for it (Android 7.4.2 can register an add that finished after processing was scheduled: the plugin
/// undoes it, but a copy that long is the cause). `config.max-data-size` (default 150 on both; iOS up to
/// 7.0.0-beta7: 50) bounds everything a report may hold. A bigger file is [ReportAttachmentFailure.tooLarge].
/// Repeated in Java (`ReportOps.MAX_ATTACHMENT_FILE_BYTES`) and Objective-C.
const int maxAttachmentFileBytes = 20 * 1024 * 1024;

/// The longest `name`, in UTF-16 units.
const int maxAttachmentNameLength = 255;

/// The longest `mimeType`, in UTF-16 units (RFC 6838: 127 + `/` + 127).
const int maxMimeTypeLength = 255;

/// The longest file path, in UTF-16 units (Android's `PATH_MAX`; iOS's is shorter, and the native
/// side reports a path it cannot open as [ReportAttachmentFailure.unreadable]).
const int maxAttachmentPathLength = 4096;

/// Android and iOS count display ids as 32-bit integers (a negative id names no display).
const int maxDisplayId = 0x7fffffff;

/// One attachment of a report, as the SDK lists it. Metadata only: the content stays natively.
final class ReportAttachment {
  const ReportAttachment({this.name, this.mimeType, this.fileName});

  /// The display name given at add time (the bundle manifest entry's `name`).
  final String? name;

  /// The MIME type given at add time, or `null` (unset: the backend treats it as unknown). iOS
  /// does not keep it for an attachment of a created report ([CreatedReport]).
  final String? mimeType;

  /// The source file's base name (`attrs.fileName`); for bytes, the name.
  final String? fileName;

  @override
  String toString() =>
      'ReportAttachment(name: $name, mimeType: $mimeType, fileName: $fileName)';
}

/// A screenshot a report holds.
final class ReportScreenshot {
  const ReportScreenshot({required this.displayId, required this.annotated});

  /// The display it belongs to (0 is the default display).
  final int displayId;

  /// Whether it carries a drawing (the screenshot entry's `annotated` attribute in the bundle).
  final bool annotated;

  @override
  String toString() =>
      'ReportScreenshot(displayId: $displayId, annotated: $annotated)';
}

/// Why the SDK or the plugin refused a file, bytes or an image for a report.
enum ReportAttachmentFailure {
  /// No file at the path.
  fileNotFound,

  /// The path names something that is not a regular file (a directory, a `file:` URL string,
  /// a device).
  notAFile,

  /// The file exists but this process cannot read it (permissions, scoped storage, another app's
  /// private directory).
  unreadable,

  /// The data is over [maxAttachmentBytes], a file is over [maxAttachmentFileBytes], or an iOS
  /// created-report attachment is over 3 MiB.
  tooLarge,

  /// The report holds as many attachments as it may (Android and iOS handler reports: 1000; iOS
  /// created reports: 3).
  limitReached,

  /// The SDK declined: the report no longer accepts attachments (its processing was scheduled),
  /// the SDK has no storage for it, or the copy failed (a full disk). The source file is untouched.
  rejected,

  /// The plugin's file worker has too many requests waiting; try again.
  busy,

  /// The platform's SDK cannot do this ([CreatedReport.setScreenshot] with `annotated` on iOS).
  unsupported,

  /// The file is not an image the platform can decode.
  imageUndecodable,

  /// The image has more pixels than the plugin will decode ([maxScreenshotPixels]).
  imageTooLarge,
}

/// The most pixels an image given to `setScreenshot` may have (width x height): 16 777 216, a
/// 4096 x 4096 picture, about 64 MiB decoded. A screenshot of a 4K display is half that.
const int maxScreenshotPixels = 4096 * 4096;

/// A file, bytes or an image was refused. [reason] says why; the report is unchanged and the source
/// file is untouched (a `move` that was refused did not consume it).
class ReportAttachmentException extends BugseeException {
  const ReportAttachmentException(this.reason, super.message, {super.cause});

  final ReportAttachmentFailure reason;

  @override
  String toString() => 'ReportAttachmentException(${reason.name}): $message';
}

/// The strings the bridge carries for a report-file operation (the reply of `reportAddAttachment`
/// and the others), in one place on the Dart side. Repeated in `ReportOps.java` and
/// `BGSFlutterReportOps.m`; `test/report_attachments_drift_test.dart` compares the three.
abstract final class ReportWire {
  /// The handle is no longer live (the completion ran, or the created report was released).
  static const notLive = 'not-live';

  static const fileNotFound = 'file-not-found';
  static const notAFile = 'not-a-file';
  static const unreadable = 'unreadable';
  static const tooLarge = 'too-large';
  static const limit = 'limit';
  static const rejected = 'rejected';
  static const busy = 'busy';
  static const unsupported = 'unsupported';
  static const imageUndecodable = 'image-undecodable';
  static const imageTooLarge = 'image-too-large';

  /// PlatformException codes of `createReport` and of a created report's upload.
  static const createBusy = 'create-busy';
  static const createTimeout = 'create-timeout';
  static const createRateLimited = 'create-rate-limited';
  static const uploadTimeout = 'upload-timeout';

  /// Every failure code (not [notLive]), with the Dart reason it maps to.
  static const Map<String, ReportAttachmentFailure> failures = {
    fileNotFound: ReportAttachmentFailure.fileNotFound,
    notAFile: ReportAttachmentFailure.notAFile,
    unreadable: ReportAttachmentFailure.unreadable,
    tooLarge: ReportAttachmentFailure.tooLarge,
    limit: ReportAttachmentFailure.limitReached,
    rejected: ReportAttachmentFailure.rejected,
    busy: ReportAttachmentFailure.busy,
    unsupported: ReportAttachmentFailure.unsupported,
    imageUndecodable: ReportAttachmentFailure.imageUndecodable,
    imageTooLarge: ReportAttachmentFailure.imageTooLarge,
  };
}

/// The exception for a native failure code. An unknown code (a newer native side) is
/// [ReportAttachmentFailure.rejected], never silence.
ReportAttachmentException attachmentFailure(String what, String code) {
  final reason = ReportWire.failures[code] ?? ReportAttachmentFailure.rejected;
  final text = switch (reason) {
    ReportAttachmentFailure.fileNotFound => 'there is no file at that path',
    ReportAttachmentFailure.notAFile =>
      'the path is not a regular file (a directory, or a URL instead of a file path)',
    ReportAttachmentFailure.unreadable =>
      'the file cannot be read by this app (permissions or storage rules)',
    ReportAttachmentFailure.tooLarge =>
      'the data or file is over the size limit',
    ReportAttachmentFailure.limitReached =>
      'the report already holds as many attachments as it may',
    ReportAttachmentFailure.rejected =>
      'the SDK declined it (the report no longer takes attachments, or the copy failed); '
          'the source is untouched',
    ReportAttachmentFailure.busy =>
      'too many file operations are waiting; try again',
    ReportAttachmentFailure.unsupported =>
      'this platform\'s SDK cannot do that for this report',
    ReportAttachmentFailure.imageUndecodable =>
      'the file is not an image this platform can decode',
    ReportAttachmentFailure.imageTooLarge =>
      'the image has more than $maxScreenshotPixels pixels',
  };
  return ReportAttachmentException(reason, '$what: $text');
}

// ---- Validation (Dart side, before anything crosses) ------------------------------------------

/// The code points that make a name blank: the same explicit set in Dart, Java (`ReportOps.BLANK_RANGES`)
/// and Objective-C (`BGSFlutterReportFiles.m`), not each language's own `trim` (they differ: Java's
/// strips only up to U+0020, Dart's also U+FEFF). A drift guard compares the three lists.
const _blankRanges = <List<int>>[
  [0x09, 0x0D],
  [0x20, 0x20],
  [0x85, 0x85],
  [0xA0, 0xA0],
  [0x1680, 0x1680],
  [0x2000, 0x200A],
  [0x2028, 0x2029],
  [0x202F, 0x202F],
  [0x205F, 0x205F],
  [0x3000, 0x3000],
];

bool _isBlank(String s) {
  for (final unit in s.codeUnits) {
    if (!_blankRanges.any((r) => unit >= r[0] && unit <= r[1])) return false;
  }
  return true;
}

bool _hasControl(String s) {
  for (final unit in s.codeUnits) {
    if (unit < 0x20 || unit == 0x7f) return true;
  }
  return false;
}

/// A file system path: absolute (both platforms resolve a relative one against a directory the app
/// never chose), no URL (`file:` and `content:` URIs name no file for the SDKs, which take a path),
/// no NUL or other control character, at most [maxAttachmentPathLength] units.
///
/// Symbolic links are accepted and copied by their content (never moved); see doc/attachments.md.
String checkAttachmentPath(String path, {String argument = 'path'}) {
  if (path.isEmpty) {
    throw BugseeArgumentException(argument, 'a file path must not be empty');
  }
  if (path.length > maxAttachmentPathLength) {
    throw BugseeArgumentException(
      argument,
      'a file path must be at most $maxAttachmentPathLength UTF-16 units',
    );
  }
  if (_hasControl(path)) {
    throw BugseeArgumentException(
      argument,
      'a file path must not contain control characters',
    );
  }
  if (RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:').hasMatch(path)) {
    throw BugseeArgumentException(
      argument,
      'pass a file system path (File.path), not a URL such as file: or content:',
    );
  }
  if (!path.startsWith('/')) {
    throw BugseeArgumentException(
      argument,
      'a file path must be absolute (File.absolute.path)',
    );
  }
  return path;
}

/// A display name for an attachment: 1 to [maxAttachmentNameLength] units, not only blanks, no
/// control character and no path separator (the name is also the file name of a bytes attachment,
/// and a consumer that saves a bundle's files must not be handed `../x`).
String checkAttachmentName(String name, {String argument = 'name'}) {
  if (_isBlank(name)) {
    throw BugseeArgumentException(
      argument,
      'an attachment name must not be empty',
    );
  }
  if (name.length > maxAttachmentNameLength) {
    throw BugseeArgumentException(
      argument,
      'an attachment name must be at most $maxAttachmentNameLength UTF-16 units',
    );
  }
  if (_hasControl(name)) {
    throw BugseeArgumentException(
      argument,
      'an attachment name must not contain control characters',
    );
  }
  if (name.contains('/') || name.contains(r'\')) {
    throw BugseeArgumentException(
      argument,
      'an attachment name must not contain a path separator',
    );
  }
  return name;
}

final RegExp _mimeToken = RegExp(
  r"^[A-Za-z0-9][A-Za-z0-9!#$&^_.+\-]{0,126}/[A-Za-z0-9][A-Za-z0-9!#$&^_.+\-]{0,126}$",
);

/// `null`, or a `type/subtype` (RFC 6838 restricted names), no parameters.
String? checkMimeType(String? mimeType, {String argument = 'mimeType'}) {
  if (mimeType == null) return null;
  if (mimeType.length > maxMimeTypeLength || !_mimeToken.hasMatch(mimeType)) {
    throw BugseeArgumentException(
      argument,
      'a MIME type must look like type/subtype (for example text/plain), without parameters',
    );
  }
  return mimeType;
}

/// A display id: 0 up to [maxDisplayId].
int checkDisplayId(int displayId, {String argument = 'displayId'}) {
  if (displayId < 0 || displayId > maxDisplayId) {
    throw BugseeArgumentException(
      argument,
      'a display id must be between 0 and $maxDisplayId',
    );
  }
  return displayId;
}
