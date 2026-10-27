import 'dart:io';

/// Writes [contents] to [target] atomically: a sibling temp file is created
/// empty, restricted to the owner (0600 on POSIX) *before* any secret lands in
/// it, filled, flushed and renamed over the target. A crash mid-write leaves
/// the previous file intact instead of a truncated one.
Future<void> writeFileAtomic(File target, String contents) async {
  await target.parent.create(recursive: true);
  final tmp = File('${target.path}.tmp');
  await tmp.writeAsString('', flush: true);
  if (!Platform.isWindows) {
    final r = await Process.run('chmod', ['600', tmp.path]);
    if (r.exitCode != 0) {
      await tmp.delete();
      throw FileSystemException('chmod 600 failed', tmp.path);
    }
  }
  await tmp.writeAsString(contents, flush: true);
  await tmp.rename(target.path);
}
