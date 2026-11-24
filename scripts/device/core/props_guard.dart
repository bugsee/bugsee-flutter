// The Gradle plugin's `bugsee.properties` holds the app token for one build (scripts/device/e2e_symbolication.dart).
import 'dart:io';

/// Creates [f] if needed, narrows it to mode 600, THEN writes [content]: a secret is never in a broader file.
void writePrivate(File f, String content) {
  if (!f.existsSync()) f.createSync();
  Process.runSync('chmod', ['600', f.path]);
  f.writeAsStringSync(content);
}

/// Writes the Gradle plugin's `bugsee.properties` (the app token) for one build and puts back what was there.
/// A developer's own file is copied to [backup] first (private mode) and restored byte for byte, its mode too; a
/// file this run created is deleted. The file never goes to a broader mode than 600 while it holds the token.
/// A file that existed is NEVER deleted: if it could not be read, [restore] leaves it alone.
class PropsGuard {
  PropsGuard(this.file, this.backup, this.log);
  final File file;
  final File backup;
  final void Function(String) log;
  bool _active = false;
  bool _existed = false;
  List<int>? _original;
  String? _originalMode;

  /// The octal permission bits of [f] (`stat -f %Lp` on macOS, `stat -c %a` on Linux), or null.
  static String? _mode(File f) {
    for (final args in [
      ['-f', '%Lp', f.path],
      ['-c', '%a', f.path],
    ]) {
      final r = Process.runSync('stat', args);
      final out = '${r.stdout}'.trim();
      if (r.exitCode == 0 && RegExp(r'^[0-7]{3,4}$').hasMatch(out)) return out;
    }
    return null;
  }

  /// Registered BEFORE anything is touched (the caller assigns the guard first), so a failure at any step,
  /// including a write that truncated the file, still restores.
  void install(String content) {
    _existed = file.existsSync();
    _active = true;
    if (_existed) {
      _original = file.readAsBytesSync();
      _originalMode = _mode(file);
      writePrivate(backup, '');
      backup.writeAsBytesSync(_original!);
      Process.runSync('chmod', [
        '600',
        file.path,
      ]); // narrow BEFORE the token goes in
      log(
        'example/android/bugsee.properties exists: its content is saved to ${backup.path} and restored after the build',
      );
    }
    writePrivate(file, content);
  }

  void restore() {
    if (!_active) return;
    _active = false;
    try {
      final original = _original;
      if (!_existed) {
        if (file.existsSync()) file.deleteSync();
      } else if (original != null) {
        file.writeAsBytesSync(original);
        final mode = _originalMode;
        if (mode != null) Process.runSync('chmod', [mode, file.path]);
        if (backup.existsSync()) backup.deleteSync();
      }
      // existed but never read: nothing was changed (the read came first), nothing to put back
    } on Object {
      stderr.writeln(
        'WARNING: could not restore ${file.path}; it may still hold the run token (a saved copy of the original is ${backup.path})',
      );
    }
  }
}
