import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/book_item.dart';

class FolderScanner {
  /// 환경 변수 (%appdata%, %userprofile%) 치환
  static String resolveEnvironmentPath(String rawPath) {
    String resolved = rawPath;
    final env = Platform.environment;
    for (final entry in env.entries) {
      final keyPattern = RegExp('%${entry.key}%', caseSensitive: false);
      resolved = resolved.replaceAll(keyPattern, entry.value);
    }
    return resolved;
  }

  /// 서비스별 기본 도서 라이브러리 경로 추천
  static String getDefaultLibraryPath(String serviceId) {
    final appData = Platform.environment['APPDATA'] ?? '';
    final userProfile = Platform.environment['USERPROFILE'] ?? '';

    switch (serviceId) {
      case 'service1': // 리디: library\_<UserNo> 폴더 우선 탐지
        final ridiRoot = p.join(appData, 'Ridibooks');
        final libraryDir = Directory(p.join(ridiRoot, 'library'));

        // 1. %appdata%\Ridibooks\library 내의 _<UserNo> 또는 <UserNo> 하위 폴더 확인
        if (libraryDir.existsSync()) {
          try {
            final subDirs = libraryDir
                .listSync(followLinks: false)
                .whereType<Directory>()
                .toList();
            if (subDirs.isNotEmpty) {
              subDirs.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
              return subDirs.first.path;
            }
          } catch (_) {}
        }

        // 2. %appdata%\Ridibooks 루트 내의 library_<UserNo> 확인
        final ridiRootDir = Directory(ridiRoot);
        if (ridiRootDir.existsSync()) {
          try {
            final rootLibDirs = ridiRootDir
                .listSync(followLinks: false)
                .whereType<Directory>()
                .where((d) => p.basename(d.path).toLowerCase().startsWith('library_'))
                .toList();
            if (rootLibDirs.isNotEmpty) {
              rootLibDirs.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
              return rootLibDirs.first.path;
            }
          } catch (_) {}
        }

        return p.join(appData, 'Ridibooks', 'library');

      case 'service2': // 예스24(Yes24)
        return p.join(appData, 'Yes24eBook', '.content');

      case 'service3': // 알라딘: %userprofile%\Documents\AladinEbookViewer 또는 %userprofile%\OneDrive\Documents\AladinEbookViewer
        final docPath = p.join(userProfile, 'Documents', 'AladinEbookViewer');
        if (Directory(docPath).existsSync()) {
          return docPath;
        }
        final oneDriveDoc = p.join(userProfile, 'OneDrive', '문서', 'AladinEbookViewer');
        if (Directory(oneDriveDoc).existsSync()) {
          return oneDriveDoc;
        }
        final oneDriveDocEn = p.join(userProfile, 'OneDrive', 'Documents', 'AladinEbookViewer');
        if (Directory(oneDriveDocEn).existsSync()) {
          return oneDriveDocEn;
        }
        return docPath;

      default:
        return '';
    }
  }

  /// 서비스별 Device ID 파일 경로 추천 (우선순위 순서)
  static String getDefaultDeviceIdFilePath(String serviceId) {
    final appData = Platform.environment['APPDATA'] ?? '';

    switch (serviceId) {
      case 'service1': // 리디: %appdata%\Ridibooks\sentry\scope_v2.json
        final candidates = [
          p.join(appData, 'Ridibooks', 'sentry', 'scope_v2.json'),
          p.join(appData, 'Ridibooks', 'scope_v2.json'),
        ];
        for (final c in candidates) {
          if (File(c).existsSync()) return c;
        }
        return candidates.first;

      case 'service2': // 예스24: %appdata%\Yes24eBook\.db\Yes24eBook.realm
        final candidates = [
          p.join(appData, 'Yes24eBook', '.db', 'Yes24eBook.realm'),
          p.join(appData, 'Yes24eBook', 'Yes24eBook.realm'),
        ];
        for (final c in candidates) {
          if (File(c).existsSync()) return c;
        }
        return candidates.first;

      case 'service3': // 알라딘: %appdata%\AladinEbookViewer\data
        final candidates = [
          p.join(appData, 'AladinEbookViewer', 'data'),
          p.join(appData, 'AladinEbookViewer', 'NewCrema.sqlite'),
        ];
        for (final c in candidates) {
          if (File(c).existsSync()) return c;
        }
        return candidates.first;

      default:
        return '';
    }
  }

  /// OPF XML 파일에서 도서 제목(dc:title) 추출
  static Future<String?> extractTitleFromOpf(File opfFile) async {
    try {
      if (await opfFile.length() > 5 * 1024 * 1024) return null;
      final content = await opfFile.readAsString();
      final match = RegExp(r'<dc:title(?:\s[^>]*)?>([\s\S]*?)<\/dc:title>', caseSensitive: false)
          .firstMatch(content);
      if (match != null && match.group(1) != null) {
        String title = match.group(1)!;
        title = title
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&quot;', '"')
            .replaceAll(RegExp(r'&apos;|&#39;'), "'")
            .replaceAll(RegExp(r'[\\/*?:"<>|\x00-\x1f]'), '')
            .trim();
        if (title.isNotEmpty) return title;
      }
    } catch (_) {}
    return null;
  }

  /// 디렉터리 내의 도서 폴더 및 EPUB/ZIP 목록을 스캔
  static Future<List<BookItem>> scanFolder(String rawPath, {String serviceId = 'service1'}) async {
    final resolvedPath = resolveEnvironmentPath(rawPath);
    final targetDir = Directory(resolvedPath);
    if (!await targetDir.exists()) {
      throw Exception('지정한 폴더가 존재하지 않습니다: $resolvedPath');
    }

    final List<BookItem> results = [];
    final entries = await targetDir.list(followLinks: false).toList();

    for (final entry in entries) {
      if (entry is Directory) {
        // 하위 폴더 분석
        final subEntities = await entry.list(recursive: true, followLinks: false).toList();
        final subFiles = subEntities.whereType<File>().toList();
        if (subFiles.isEmpty) continue;

        int totalSize = 0;
        String? foundDatPath;
        String? detectedTitle;

        for (final f in subFiles) {
          totalSize += await f.length();
          final lower = f.path.toLowerCase();
          if (lower.endsWith('.dat') && foundDatPath == null) {
            foundDatPath = f.path;
          }
          if (lower.endsWith('.opf') && detectedTitle == null) {
            detectedTitle = await extractTitleFromOpf(f);
          }
        }

        results.add(BookItem(
          id: entry.path,
          name: p.basename(entry.path),
          path: entry.path,
          isDirectory: true,
          fileCount: subFiles.length,
          sizeBytes: totalSize,
          datFilePath: foundDatPath,
          detectedTitle: detectedTitle,
        ));
      } else if (entry is File) {
        final lower = entry.path.toLowerCase();
        final isEpub = lower.endsWith('.epub');
        final isZip = lower.endsWith('.zip');

        if (isEpub || isZip) {
          final size = await entry.length();
          final stem = p.basenameWithoutExtension(entry.path);

          // 같은 폴더 내에 동일 이름의 .dat 파일이 있는지 검사
          String? matchingDat;
          final siblingDat = File(p.join(p.dirname(entry.path), '$stem.dat'));
          if (await siblingDat.exists()) {
            matchingDat = siblingDat.path;
          }

          results.add(BookItem(
            id: entry.path,
            name: p.basename(entry.path),
            path: entry.path,
            isDirectory: false,
            fileCount: 1,
            sizeBytes: size,
            datFilePath: matchingDat,
            detectedTitle: stem,
          ));
        }
      }
    }

    // 이름순 정렬
    results.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    return results;
  }
}
