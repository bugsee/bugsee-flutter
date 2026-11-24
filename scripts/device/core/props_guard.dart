// The Gradle plugin's `bugsee.properties` holds the app token for one build (scripts/device/e2e_symbolication.dart).
import 'dart:io';

/// Creates [f] if needed, narrows it to mode 600, THEN writes [content]: a secret is never in a broader file.
void writePrivate(File f, String content) {
  if (!f.existsSync()) f.createSync();
  _narrow(f);
  f.writeAsStringSync(content);
}

/// `chmod 600` that must succeed: a failure (a file owned by someone else) aborts BEFORE the secret is written.
void _narrow(File f) {
  final r = Process.runSync('chmod', ['600', f.path]);
  if (r.exitCode != 0) {
    throw FileSystemException(
      'could not set mode 600 (chmod exit ${r.exitCode})',
      f.path,
    );
  }
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
      [
        '-L',
        '-f',
        '%Lp',
        f.path,
      ], // -L: a symlink's TARGET, which chmod and the writes change
      ['-L', '-c', '%a', f.path],
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
      final bytes = file.readAsBytesSync();
      final mode = _mode(file);
      // Without the original mode the file could not be put back as it was: abort before anything changes
      // (restore() then has nothing to undo).
      if (mode == null) {
        throw FileSystemException(
          'could not read the mode of the existing file; not writing the token',
          file.path,
        );
      }
      _original = bytes;
      _originalMode = mode;
      writePrivate(backup, '');
      backup.writeAsBytesSync(bytes);
      _narrow(file); // narrow BEFORE the token goes in, and stop if that fails
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
        // An install that aborted before writing left the bytes as they were: nothing to put back (and a file
        // that could not be written would only produce a false warning).
        final current = file.readAsBytesSync();
        final same =
            current.length == original.length &&
            Iterable<int>.generate(current.length)
                .every((i) => current[i] == original[i]);
        if (!same) file.writeAsBytesSync(original);
        final mode = _originalMode;
        if (mode != null) {
          final r = Process.runSync('chmod', [mode, file.path]);
          if (r.exitCode != 0) {
            // keep the saved copy: the file may still be narrower than the developer's own mode
            stderr.writeln(
              'WARNING: could not restore the mode $mode of ${file.path} (chmod exit ${r.exitCode}); a saved copy is ${backup.path}',
            );
            return;
          }
        }
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
