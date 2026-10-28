import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/book_item.dart';

class FolderScanner {
  /// macOS 환경에서 /usr/bin/sqlite3를 실행하여 누적된 -wal 로그를 메인 DB로 강제 체크포인트(TRUNCATE)하여 병합
  static Future<bool> checkpointSqliteWal(String sqlitePath) async {
    if (!Platform.isMacOS) return false;
    final file = File(sqlitePath);
    if (!await file.exists()) return false;

    // TRUNCATE 모드로 실행하여 WAL에 적재된 모든 트랜잭션을 메인 DB에 즉시 병합하고 WAL을 0바이트로 절삭
    for (final mode in ['TRUNCATE', 'RESTART', 'FULL', 'PASSIVE']) {
      try {
        final res = await Process.run('/usr/bin/sqlite3', [
          sqlitePath,
          'PRAGMA wal_checkpoint($mode);',
        ]);
        if (res.exitCode == 0) {
          final out = res.stdout.toString().trim();
          if (out.startsWith('0')) {
            return true;
          }
        }
      } catch (_) {
        break;
      }
    }
    return false;
  }

  /// 현재 플랫폼에서 해당 서비스 지원 여부 반환
  static bool isServiceSupported(String serviceId) {
    if (Platform.isMacOS && serviceId == 'service2') {
      return false;
    }
    return true;
  }

  /// 사용자 홈 디렉터리 경로 반환
  static String getHomeDirectory() {
    if (Platform.isWindows) {
      return Platform.environment['USERPROFILE'] ??
          (Platform.environment['HOMEDRIVE'] != null && Platform.environment['HOMEPATH'] != null
              ? p.join(Platform.environment['HOMEDRIVE']!, Platform.environment['HOMEPATH']!)
              : '');
    }

    final candidates = getMacOSHomeCandidates();
    return candidates.isNotEmpty ? candidates.first : (Platform.environment['HOME'] ?? '');
  }

  /// macOS 환경에서 가능한 실제 사용자 홈 디렉터리 목록 반환
  static List<String> getMacOSHomeCandidates() {
    final List<String> candidates = [];
    String rawHome = Platform.environment['HOME'] ?? '';

    // 1. 만약 macOS 샌드박스로 인해 HOME이 ~/Library/Containers/... 로 격리된 경우 실제 홈 디렉터리 추출
    const containerMarker = '/Library/Containers/';
    if (rawHome.contains(containerMarker)) {
      rawHome = rawHome.substring(0, rawHome.indexOf(containerMarker));
    }

    if (rawHome.isNotEmpty) {
      candidates.add(rawHome);
      if (!rawHome.startsWith('/Volumes/Macintosh HD')) {
        candidates.add(p.join('/Volumes/Macintosh HD', rawHome.startsWith('/') ? rawHome.substring(1) : rawHome));
      } else {
        candidates.add(rawHome.replaceFirst('/Volumes/Macintosh HD', ''));
      }
    }

    final user = Platform.environment['USER'] ??
        Platform.environment['LOGNAME'] ??
        Platform.environment['USERNAME'] ??
        '';
    if (user.isNotEmpty) {
      final userHome = '/Users/$user';
      final volUserHome = '/Volumes/Macintosh HD/Users/$user';
      if (!candidates.contains(userHome)) candidates.add(userHome);
      if (!candidates.contains(volUserHome)) candidates.add(volUserHome);
    }

    if (candidates.isEmpty) {
      candidates.add('/Users/Shared');
    }

    return candidates;
  }

  /// 환경 변수 (%appdata%, %userprofile%, ~) 치환
  static String resolveEnvironmentPath(String rawPath) {
    String resolved = rawPath.trim();
    final homeCandidates = Platform.isMacOS ? getMacOSHomeCandidates() : [getHomeDirectory()];
    final primaryHome = homeCandidates.isNotEmpty ? homeCandidates.first : '';

    // 1. ~ 및 ~/ 치환 (macOS / Linux / Windows 공통 편의 제공)
    if (resolved == '~') {
      resolved = primaryHome;
    } else if (resolved.startsWith('~/') || resolved.startsWith('~\\')) {
      final sub = resolved.substring(2);
      if (Platform.isMacOS) {
        String? existing;
        for (final h in homeCandidates) {
          final cand = p.join(h, sub);
          if (Directory(cand).existsSync() || File(cand).existsSync()) {
            existing = cand;
            break;
          }
        }
        resolved = existing ?? p.join(primaryHome, sub);
      } else {
        resolved = p.join(primaryHome, sub);
      }
    } else if (resolved.startsWith(r'$HOME/') || resolved.startsWith(r'${HOME}/')) {
      final sub = resolved.substring(resolved.indexOf('/') + 1);
      resolved = p.join(primaryHome, sub);
    }

    // 2. Windows 스타일 %VAR% 환경 변수 치환
    final env = Platform.environment;
    for (final entry in env.entries) {
      final keyPattern = RegExp('%${entry.key}%', caseSensitive: false);
      resolved = resolved.replaceAll(keyPattern, entry.value);
    }
    return resolved;
  }

  /// 서비스별 기본 도서 라이브러리 경로 추천
  static String getDefaultLibraryPath(String serviceId) {
    if (Platform.isMacOS) {
      final homeCandidates = getMacOSHomeCandidates();
      switch (serviceId) {
        case 'service1': // 리디: ~/Library/Application Support/Ridibooks/library/_<USER_NO>/
          for (final h in homeCandidates) {
            final ridiRoot = p.join(h, 'Library', 'Application Support', 'Ridibooks');
            final libraryDir = Directory(p.join(ridiRoot, 'library'));

            if (libraryDir.existsSync()) {
              try {
                final subDirs = libraryDir
                    .listSync(followLinks: false)
                    .whereType<Directory>()
                    .toList();
                if (subDirs.isNotEmpty) {
                  // _<USER_NO> 폴더 우선 정렬 (예: _1234567)
                  final userDirs = subDirs.where((d) => p.basename(d.path).startsWith('_')).toList();
                  final targetDirs = userDirs.isNotEmpty ? userDirs : subDirs;
                  targetDirs.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
                  return targetDirs.first.path;
                }
              } catch (_) {}
            }
          }
          return p.join(homeCandidates.first, 'Library', 'Application Support', 'Ridibooks', 'library');

        case 'service2': // 예스24 (macOS 미지원)
          return '';

        case 'service3': // 알라딘: ~/Library/Containers/kr.co.aladin.eBookViewer/Data/Library/data/books
          const subPath = 'Library/Containers/kr.co.aladin.eBookViewer/Data/Library/data/books';
          for (final h in homeCandidates) {
            final cand = p.join(h, subPath);
            if (Directory(cand).existsSync()) {
              return cand;
            }
          }
          return p.join(homeCandidates.first, subPath);

        default:
          return '';
      }
    }

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
  static String getDefaultDeviceIdFilePath(String serviceId, {String? currentLibraryPath}) {
    if (Platform.isMacOS) {
      final homeCandidates = getMacOSHomeCandidates();
      switch (serviceId) {
        case 'service1': // 리디: ~/Library/Application Support/Ridibooks/sentry/scope_v2.json
          final ridiCandidates = <String>[];
          for (final h in homeCandidates) {
            ridiCandidates.add(p.join(h, 'Library', 'Application Support', 'Ridibooks', 'sentry', 'scope_v2.json'));
            ridiCandidates.add(p.join(h, 'Library', 'Application Support', 'Ridibooks', 'scope_v2.json'));
          }
          for (final cand in ridiCandidates) {
            try {
              final file = File(cand);
              if (file.existsSync()) {
                final raf = file.openSync(mode: FileMode.read);
                raf.closeSync();
                return cand;
              }
            } catch (_) {}
          }
          for (final cand in ridiCandidates) {
            if (File(cand).existsSync()) return cand;
          }
          return ridiCandidates.first;

        case 'service2': // 예스24: macOS 미지원
          return '';

        case 'service3': // 알라딘: ~/Library/Containers/kr.co.aladin.eBookViewer/Data/Library/data/databases/NewCrema.sqlite
          const subPath = 'Library/Containers/kr.co.aladin.eBookViewer/Data/Library/data/databases/NewCrema.sqlite';
          final candidates = <String>[
            if (currentLibraryPath != null && currentLibraryPath.trim().isNotEmpty)
              p.join(p.dirname(resolveEnvironmentPath(currentLibraryPath)), 'databases', 'NewCrema.sqlite'),
            ...homeCandidates.map((h) => p.join(h, subPath)),
          ];

          // 1. 실제로 열기(읽기) 가능한 경로 우선 탐색
          for (final cand in candidates) {
            try {
              final file = File(cand);
              if (file.existsSync()) {
                final raf = file.openSync(mode: FileMode.read);
                raf.closeSync();
                return cand;
              }
            } catch (_) {}
          }

          // 2. 읽기 권한은 없더라도 파일이 물리적으로 존재하는 경로 반환
          for (final cand in candidates) {
            if (File(cand).existsSync()) {
              return cand;
            }
          }
          return p.join(homeCandidates.first, subPath);

        default:
          return '';
      }
    }

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
    final List<FileSystemEntity> entries;
    try {
      entries = await targetDir.list(followLinks: false).toList();
    } on FileSystemException catch (e) {
      if (Platform.isMacOS) {
        throw Exception(
          '폴더 접근 권한이 제한되었습니다 ($e).\n'
          '우측 [찾아보기] 버튼을 눌러 해당 도서 폴더를 직접 한 번 선택해주시거나, macOS 시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근 권한을 확인해주세요.',
        );
      }
      rethrow;
    }

    for (final entry in entries) {
      if (entry is Directory) {
        // 하위 폴더 분석
        List<FileSystemEntity> subEntities = [];
        try {
          subEntities = await entry.list(recursive: true, followLinks: false).toList();
        } catch (_) {}
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
