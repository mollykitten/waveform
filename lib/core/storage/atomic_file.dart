import 'dart:developer' as developer;
import 'dart:io';

/// Restricts [path] to the owner (0600). Replaceable in tests.
Future<void> chmodOwnerOnly(String path) async {
  final r = await Process.run('chmod', ['600', path]);
  if (r.exitCode != 0) {
    throw ProcessException('chmod', ['600', path], '${r.stderr}', r.exitCode);
  }
}

/// Writes [contents] to [target] atomically: a sibling temp file is created
/// empty, restricted to the owner (0600 on POSIX) *before* any secret lands in
/// it, filled, flushed and renamed over the target. A crash mid-write leaves
/// the previous file intact instead of a truncated one.
///
/// The chmod is best effort: if it fails (no `chmod` binary, odd filesystem)
/// a warning is logged and the write still happens — the file lives in the
/// app's own container, and losing the session on restart is worse.
/// A failed write or rename removes the temp file and rethrows.
Future<void> writeFileAtomic(
  File target,
  String contents, {
  Future<void> Function(String path) chmod = chmodOwnerOnly,
}) async {
  await target.parent.create(recursive: true);
  final tmp = File('${target.path}.tmp');
  try {
    await tmp.writeAsString('', flush: true);
    if (!Platform.isWindows) {
      try {
        await chmod(tmp.path);
      } catch (e) {
        developer.log(
          'storage: chmod 600 failed, writing with default mode: $e',
          name: 'waveform.storage',
          level: 900,
        );
      }
    }
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(target.path);
  } catch (_) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
    rethrow;
  }
}
