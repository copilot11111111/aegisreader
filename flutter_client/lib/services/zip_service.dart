import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

class AegisReaderZipService {
  /// 도서 폴더를 ZIP 파일로 압축하여 반환합니다.
  static Future<File> zipDirectory(
    Directory dir, {
    String? outputPath,
    void Function(int current, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final targetPath = outputPath ??
        p.join(
          Directory.systemTemp.path,
          'aegisreader_${p.basename(dir.path)}_${DateTime.now().millisecondsSinceEpoch}.zip',
        );

    final zipFile = File(targetPath);
    if (await zipFile.exists()) {
      await zipFile.delete();
    }
    await zipFile.parent.create(recursive: true);

    final encoder = ZipFileEncoder();
    encoder.create(zipFile.path);

    final entities = await dir.list(recursive: true, followLinks: false).toList();
    final files = entities.whereType<File>().toList();
    final total = files.length;
    int current = 0;

    for (final file in files) {
      if (isCancelled?.call() == true) {
        encoder.close();
        if (await zipFile.exists()) {
          try {
            await zipFile.delete();
          } catch (_) {}
        }
        throw Exception('사용자에 의해 작업이 중단되었습니다.');
      }
      final relativePath = p.relative(file.path, from: dir.path);
      encoder.addFile(file, relativePath);
      current++;
      onProgress?.call(current, total);
    }

    encoder.close();
    return zipFile;
  }

  /// 지정한 대상 파일(targetZipFile)로 디렉터리를 압축합니다.
  static Future<File> createZipFromDirectory(
    Directory dir,
    File targetZipFile, {
    void Function(int current, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    return zipDirectory(
      dir,
      outputPath: targetZipFile.path,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }
}

/// 하위 호환성 별칭
typedef ZipService = AegisReaderZipService;
