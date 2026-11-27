import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../models/book_item.dart';
import '../models/extracted_device.dart';

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

  static String? _cachedYes24DecryptedKey;

  /// 예스24 Realm 복호화 키 캐시를 초기화합니다.
  static void clearYes24DecryptedKeyCache() {
    _cachedYes24DecryptedKey = null;
  }

  /// 예스24 Realm 암호화 키(.key / .key.m)를 확인하고 DPAPI 복호화하여 Base64 문자열로 반환
  static Future<String?> getYes24DecryptedKey([String? realmPath]) async {
    if (_cachedYes24DecryptedKey != null && _cachedYes24DecryptedKey!.isNotEmpty) {
      return _cachedYes24DecryptedKey;
    }

    final appData = Platform.environment['APPDATA'] ?? '';
    final rawCandidates = <String>[];
    if (realmPath != null && realmPath.trim().isNotEmpty) {
      rawCandidates.add('$realmPath.key');
      rawCandidates.add('$realmPath.key.m');
      rawCandidates.add(p.join(p.dirname(realmPath), 'Yes24eBook.realm.key'));
      rawCandidates.add(p.join(p.dirname(realmPath), 'Yes24eBook.realm.key.m'));
    }
    if (appData.isNotEmpty) {
      rawCandidates.add(p.join(appData, 'Yes24eBook', '.db', 'Yes24eBook.realm.key'));
      rawCandidates.add(p.join(appData, 'Yes24eBook', '.db', 'Yes24eBook.realm.key.m'));
      rawCandidates.add(p.join(appData, 'Yes24eBook', 'Yes24eBook.realm.key'));
      rawCandidates.add(p.join(appData, 'Yes24eBook', 'Yes24eBook.realm.key.m'));
    }

    final seen = <String>{};
    final existingPaths = <String>[];
    for (final c in rawCandidates) {
      if (c.isEmpty || !seen.add(c)) continue;
      if (File(c).existsSync()) {
        existingPaths.add(c);
      }
    }

    if (existingPaths.isEmpty) return null;

    // 1. 평문 64바이트 / 128자리 Hex / 88자리 Base64 키 우선 확인
    for (final kp in existingPaths) {
      try {
        final bytes = await File(kp).readAsBytes();
        if (bytes.length == 64) {
          final b64 = base64Encode(bytes);
          _cachedYes24DecryptedKey = b64;
          return b64;
        }
        final text = utf8.decode(bytes, allowMalformed: true).trim();
        if (RegExp(r'^[0-9a-fA-F]{128}$').hasMatch(text)) {
          final hexBytes = Uint8List(64);
          for (int i = 0; i < 64; i++) {
            hexBytes[i] = int.parse(text.substring(i * 2, i * 2 + 2), radix: 16);
          }
          final b64 = base64Encode(hexBytes);
          _cachedYes24DecryptedKey = b64;
          return b64;
        }
        final b64Match = RegExp(r'[A-Za-z0-9+/]{86}==').firstMatch(text);
        if (b64Match != null) {
          final b64 = b64Match.group(0)!;
          _cachedYes24DecryptedKey = b64;
          return b64;
        }
      } catch (_) {}
    }

    // 2. Windows DPAPI(.key: CurrentUser / .key.m: LocalMachine) 복호화 시도
    if (Platform.isWindows) {
      try {
        final quotedPaths = existingPaths
            .map((e) => "'${e.replaceAll("'", "''")}'")
            .join(', ');
        final psScript = '''
\$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Security
\$e = [System.Text.Encoding]::UTF8.GetBytes('Yes24eBook.Realm.EncryptionKey')
\$paths = @($quotedPaths)
foreach (\$kp in \$paths) {
  try {
    if (-not (Test-Path -LiteralPath \$kp)) { continue }
    \$b = [System.IO.File]::ReadAllBytes(\$kp)
    \$k = \$null
    try {
      \$k = [System.Security.Cryptography.ProtectedData]::Unprotect(\$b, \$e, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    } catch {
      try {
        \$k = [System.Security.Cryptography.ProtectedData]::Unprotect(\$b, \$e, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
      } catch {}
    }
    if (\$k -and \$k.Length -eq 64) {
      Write-Output [System.Convert]::ToBase64String(\$k)
      break
    }
  } catch {}
}
''';

        final encoded = _encodePowerShellScript(psScript);
        final procResult = await Process.run(
          'powershell',
          ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded],
          runInShell: true,
        );

        if (procResult.exitCode == 0) {
          final out = procResult.stdout.toString().trim();
          final match = RegExp(r'[A-Za-z0-9+/]{86}==').firstMatch(out);
          if (match != null) {
            _cachedYes24DecryptedKey = match.group(0);
            return _cachedYes24DecryptedKey;
          }
        }
      } catch (_) {}
    }

    return null;
  }

  static String? _cachedAladinDecryptedKey;
  static final Map<String, String> _cachedDecryptedAladinStrings = {};

  /// 알라딘 data DB 복호화 키 및 문자열 캐시를 초기화합니다.
  static void clearAladinDecryptedKeyCache() {
    _cachedAladinDecryptedKey = null;
    _cachedDecryptedAladinStrings.clear();
  }

  static String _encodePowerShellScript(String script) {
    final units = script.codeUnits;
    final bytes = Uint8List(units.length * 2);
    for (int i = 0; i < units.length; i++) {
      bytes[i * 2] = units[i] & 0xFF;
      bytes[i * 2 + 1] = (units[i] >> 8) & 0xFF;
    }
    return base64Encode(bytes);
  }

  static bool _isAladinEncrypted(String s) {
    return s.startsWith('TPM1:') ||
        s.startsWith('DP1:') ||
        s.startsWith('TPMU1:') ||
        s.startsWith('DPU1:') ||
        s.startsWith('TPM2:');
  }

  /// 알라딘 암호화 문자열 목록(TPM1:, DP1:, TPMU1:, DPU1:)을 CngKey로 일괄 복호화하여 반환
  /// TPM MachineKey의 경우 관리자 권한(UAC Elevation)이 필요하므로 일반 권한 실패 시 RunAs로 선별 승격 실행합니다.
  static Future<List<String>> decryptAladinStrings(List<String> rawStrings) async {
    if (!Platform.isWindows || rawStrings.isEmpty) {
      return rawStrings;
    }

    final Set<String> neededEncrypted = {};
    for (final s in rawStrings) {
      if (_isAladinEncrypted(s) && !_cachedDecryptedAladinStrings.containsKey(s)) {
        neededEncrypted.add(s);
      }
    }

    if (neededEncrypted.isEmpty) {
      return rawStrings.map((s) => _cachedDecryptedAladinStrings[s] ?? s).toList();
    }

    final targetEncryptedList = neededEncrypted.toList();
    final tempDir = Directory.systemTemp;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final inFile = File(p.join(tempDir.path, 'aladin_batch_in_$timestamp.txt'));
    final outFile = File(p.join(tempDir.path, 'aladin_batch_out_$timestamp.txt'));
    final psScriptFile = File(p.join(tempDir.path, 'aladin_batch_script_$timestamp.ps1'));
    final escapedIn = inFile.path.replaceAll("'", "''");
    final escapedOut = outFile.path.replaceAll("'", "''");

    try {
      await inFile.writeAsString(targetEncryptedList.join('\r\n'), encoding: utf8);

      final psScript = '''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
\$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Security
\$script:rsa = \$null
\$script:provider = \$null
\$script:key = \$null
\$script:rsaDl = \$null
\$script:provDl = \$null
\$script:keyDl = \$null

function Decrypt-One([string]\$val) {
  \$val = \$val.Trim()
  if (-not \$val) { return '' }
  if (\$val -match '^TPM1:(.+)\$') {
    try {
      \$prov = New-Object Security.Cryptography.CngProvider('Microsoft Platform Crypto Provider')
      \$key = \$null
      try {
        \$key = [Security.Cryptography.CngKey]::Open('Aladin.Ebook.Viewer.DeviceIdKey.v1', \$prov, [Security.Cryptography.CngKeyOpenOptions]::MachineKey)
      } catch {}
      if (-not \$key) {
        try {
          \$key = [Security.Cryptography.CngKey]::Open('Aladin.Ebook.Viewer.DeviceIdKey.v1', \$prov, [Security.Cryptography.CngKeyOpenOptions]::None)
        } catch {}
      }
      if (\$key) {
        \$rsa = New-Object Security.Cryptography.RSACng(\$key)
        \$b = [Convert]::FromBase64String(\$matches[1])
        \$d = \$rsa.Decrypt(\$b, [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
        \$s = [Text.Encoding]::UTF8.GetString(\$d)
        if (\$s) { return \$s }
      }
    } catch {}
  } elseif (\$val -match '^TPM2:(.+)\$') {
    try {
      \$prov = New-Object Security.Cryptography.CngProvider('Microsoft Platform Crypto Provider')
      \$key = \$null
      try {
        \$key = [Security.Cryptography.CngKey]::Open('Aladin.Ebook.Viewer.DeviceIdKey.v1', \$prov, [Security.Cryptography.CngKeyOpenOptions]::MachineKey)
      } catch {}
      if (-not \$key) {
        try {
          \$key = [Security.Cryptography.CngKey]::Open('Aladin.Ebook.Viewer.DeviceIdKey.v1', \$prov, [Security.Cryptography.CngKeyOpenOptions]::None)
        } catch {}
      }
      if (\$key) {
        \$rsa = New-Object Security.Cryptography.RSACng(\$key)
        \$raw = [Convert]::FromBase64String(\$matches[1])
        \$num = ([int]\$raw[0] -shl 8) -bor [int]\$raw[1]
        \$num2 = \$raw.Length - 2 - \$num - 16 - 32
        \$rsaEnc = New-Object byte[] \$num
        [Buffer]::BlockCopy(\$raw, 2, \$rsaEnc, 0, \$num)
        \$num3 = 2 + \$num
        \$num4 = \$num3 + 16
        \$decKey = \$rsa.Decrypt(\$rsaEnc, [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
        \$aesKey = New-Object byte[] 32
        [Buffer]::BlockCopy(\$decKey, 0, \$aesKey, 0, 32)
        \$aesIv = New-Object byte[] 16
        [Buffer]::BlockCopy(\$raw, \$num3, \$aesIv, 0, 16)
        \$aes = [Security.Cryptography.Aes]::Create()
        \$aes.Key = \$aesKey
        \$aes.IV = \$aesIv
        \$aes.Mode = [Security.Cryptography.CipherMode]::CBC
        \$aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
        \$dec = \$aes.CreateDecryptor()
        \$plainBytes = \$dec.TransformFinalBlock(\$raw, \$num4, \$num2)
        \$base64Token = [Text.Encoding]::UTF8.GetString(\$plainBytes).Trim()
        if (\$base64Token) {
          try {
            Add-Type -AssemblyName System.Management
            function Q-AladinWmi([string]\$p, [string]\$c) {
              try {
                \$mc = New-Object System.Management.ManagementClass(\$c)
                foreach (\$mo in \$mc.GetInstances()) {
                  \$v = \$mo[\$p]
                  if (\$v) { return \$v.ToString() }
                }
              } catch {}
              return ''
            }
            \$cpu = Q-AladinWmi 'UniqueId' 'Win32_Processor'
            if (-not \$cpu) { \$cpu = Q-AladinWmi 'ProcessorId' 'Win32_Processor' }
            if (-not \$cpu) { \$cpu = Q-AladinWmi 'Name' 'Win32_Processor' }
            if (-not \$cpu) { \$cpu = (Q-AladinWmi 'Manufacturer' 'Win32_Processor') + (Q-AladinWmi 'MaxClockSpeed' 'Win32_Processor') }

            \$bios = (Q-AladinWmi 'Manufacturer' 'Win32_BIOS') + (Q-AladinWmi 'IdentificationCode' 'Win32_BIOS') + (Q-AladinWmi 'SerialNumber' 'Win32_BIOS')
            \$base = (Q-AladinWmi 'Model' 'Win32_BaseBoard') + (Q-AladinWmi 'Manufacturer' 'Win32_BaseBoard') + (Q-AladinWmi 'Name' 'Win32_BaseBoard') + (Q-AladinWmi 'SerialNumber' 'Win32_BaseBoard')

            \$hwRaw = 'CPU >> ' + \$cpu + "`nBIOS >> " + \$bios + "`nBASE >> " + \$base
            \$md5 = [System.Security.Cryptography.MD5]::Create()
            \$hashBytes = \$md5.ComputeHash([System.Text.Encoding]::ASCII.GetBytes(\$hwRaw))
            \$hex = [BitConverter]::ToString(\$hashBytes).Replace('-', '').ToUpper()
            \$hwHash = \$hex.Substring(0, 4) + '-' + \$hex.Substring(4, 4) + '-' + \$hex.Substring(8, 4) + '-' + \$hex.Substring(12, 4) + '-' + \$hex.Substring(16, 4) + '-' + \$hex.Substring(20, 4) + '-' + \$hex.Substring(24, 4) + '-' + \$hex.Substring(28, 4)

            \$hwKey = [System.Text.Encoding]::UTF8.GetBytes(\$hwHash.Substring(0, 16))
            \$hwIv  = [System.Text.Encoding]::UTF8.GetBytes(\$hwHash.Substring(8, 16))

            \$cBytes = [Convert]::FromBase64String(\$base64Token)
            \$rij = [System.Security.Cryptography.RijndaelManaged]::new()
            \$rij.Mode = [System.Security.Cryptography.CipherMode]::CBC
            \$rij.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
            \$rij.KeySize = 128
            \$rij.BlockSize = 128
            \$rij.Key = \$hwKey
            \$rij.IV = \$hwIv

            \$dec2 = \$rij.CreateDecryptor()
            \$ms = [System.IO.MemoryStream]::new(\$cBytes)
            \$cs = [System.Security.Cryptography.CryptoStream]::new(\$ms, \$dec2, [System.Security.Cryptography.CryptoStreamMode]::Read)
            \$sr = [System.IO.StreamReader]::new(\$cs, [System.Text.Encoding]::UTF8)
            \$finalJwt = \$sr.ReadToEnd().Trim()
            \$sr.Close()
            \$cs.Close()
            \$ms.Close()
            \$rij.Clear()
            if (\$finalJwt) { return \$finalJwt }
          } catch {}
          return \$base64Token
        }
      }
    } catch {}
  } elseif (\$val -match '^DP1:(.+)\$') {
    try {
      \$b = [Convert]::FromBase64String(\$matches[1])
      \$ent = [Text.Encoding]::UTF8.GetBytes('Aladin.Ebook.Viewer.Entropy.v1')
      try { \$d = [Security.Cryptography.ProtectedData]::Unprotect(\$b, \$ent, [Security.Cryptography.DataProtectionScope]::CurrentUser) }
      catch { \$d = [Security.Cryptography.ProtectedData]::Unprotect(\$b, \$ent, [Security.Cryptography.DataProtectionScope]::LocalMachine) }
      \$s = [Text.Encoding]::UTF8.GetString(\$d)
      if (\$s) { return \$s }
    } catch {}
  } elseif (\$val -match '^TPMU1:(.+)\$') {
    try {
      \$provDl = New-Object Security.Cryptography.CngProvider('Microsoft Platform Crypto Provider')
      \$keyDl = \$null
      try {
        \$keyDl = [Security.Cryptography.CngKey]::Open('Aladin.Ebook.Viewer.DownloadKey.v1', \$provDl, [Security.Cryptography.CngKeyOpenOptions]::None)
      } catch {}
      if (-not \$keyDl) {
        try {
          \$keyDl = [Security.Cryptography.CngKey]::Open('Aladin.Ebook.Viewer.DownloadKey.v1', \$provDl, [Security.Cryptography.CngKeyOpenOptions]::MachineKey)
        } catch {}
      }
      if (\$keyDl) {
        \$rsaDl = New-Object Security.Cryptography.RSACng(\$keyDl)
        \$b = [Convert]::FromBase64String(\$matches[1])
        \$d = \$rsaDl.Decrypt(\$b, [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
        \$hex = [BitConverter]::ToString(\$d).Replace('-', '').ToLower()
        if (\$hex) { return \$hex }
      }
    } catch {}
  } elseif (\$val -match '^DPU1:(.+)\$') {
    try {
      \$b = [Convert]::FromBase64String(\$matches[1])
      \$ent = [Text.Encoding]::UTF8.GetBytes('Aladin.Ebook.Viewer.DownloadKey.v1')
      try { \$d = [Security.Cryptography.ProtectedData]::Unprotect(\$b, \$ent, [Security.Cryptography.DataProtectionScope]::CurrentUser) }
      catch { \$d = [Security.Cryptography.ProtectedData]::Unprotect(\$b, \$ent, [Security.Cryptography.DataProtectionScope]::LocalMachine) }
      \$hex = [BitConverter]::ToString(\$d).Replace('-', '').ToLower()
      if (\$hex) { return \$hex }
    } catch {}
  }
  return \$val
}

\$lines = @()
if (Test-Path '$escapedIn') {
  \$lines = [System.IO.File]::ReadAllLines('$escapedIn', [System.Text.Encoding]::UTF8)
}

\$results = [System.Collections.Generic.List[string]]::new()
foreach (\$line in \$lines) {
  \$dec = Decrypt-One \$line
  \$results.Add(\$dec)
}

[System.IO.File]::WriteAllLines('$escapedOut', \$results, [System.Text.Encoding]::UTF8)
''';

      await psScriptFile.writeAsString(psScript, encoding: utf8);

      // 1. 일반 권한 (또는 이미 관리자로 실행 중인 경우)으로 1차 실행 시도
      await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', psScriptFile.path],
        runInShell: true,
      );

      List<String> decrypted = [];
      if (await outFile.exists()) {
        decrypted = await outFile.readAsLines(encoding: utf8);
      }

      final anyStillEncrypted = decrypted.isEmpty ||
          decrypted.any((s) => _isAladinEncrypted(s));

      // 2. 권한 부족(MachineKey 액세스 거부)으로 복호화 실패 시, 관리자 권한(UAC RunAs)으로 승격 실행
      if (anyStillEncrypted) {
        if (await outFile.exists()) {
          await outFile.delete();
        }

        final escapedPsPath = psScriptFile.path.replaceAll("'", "''");
        final elevateCommand =
            "Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden "
            "-ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"\"$escapedPsPath\"\"'";

        await Process.run(
          'powershell',
          ['-NoProfile', '-Command', elevateCommand],
          runInShell: true,
        );

        if (await outFile.exists()) {
          final elevatedDecrypted = await outFile.readAsLines(encoding: utf8);
          if (elevatedDecrypted.isNotEmpty &&
              elevatedDecrypted.length == targetEncryptedList.length &&
              !elevatedDecrypted.any((s) => _isAladinEncrypted(s))) {
            decrypted = elevatedDecrypted;
          }
        }
      }

      if (decrypted.isNotEmpty && decrypted.length == targetEncryptedList.length) {
        for (int i = 0; i < targetEncryptedList.length; i++) {
          final decVal = decrypted[i];
          if (!_isAladinEncrypted(decVal)) {
            _cachedDecryptedAladinStrings[targetEncryptedList[i]] = decVal;
          }
        }
      }
    } catch (_) {
    } finally {
      try {
        if (await inFile.exists()) await inFile.delete();
        if (await outFile.exists()) await outFile.delete();
        if (await psScriptFile.exists()) await psScriptFile.delete();
      } catch (_) {}
    }

    return rawStrings.map((s) => _cachedDecryptedAladinStrings[s] ?? s).toList();
  }

  /// 알라딘 data DB 암호화 키를 확인하고 TPM/DPAPI 복호화하여 16바이트 문자열(또는 기본 키) 반환
  /// TPM MachineKey의 경우 관리자 권한(UAC Elevation)이 필요하므로 일반 권한 실패 시 RunAs로 선별 승격 실행합니다.
  /// ExecutionPolicy 제약(Restricted)을 우회하기 위해 .ps1 파일 대신 -EncodedCommand로 인라인 실행합니다.
  static Future<String?> getAladinDecryptedKey([String? dataPath]) async {
    const defaultKey = '00000000000000000000000000000000';
    if (!Platform.isWindows) {
      return defaultKey;
    }

    if (_cachedAladinDecryptedKey != null && _cachedAladinDecryptedKey!.isNotEmpty) {
      return _cachedAladinDecryptedKey;
    }

    try {
      // 1. 현재 사용자 레지스트리에서 DbKeyEnc 값을 사전 조회
      final regProc = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "(Get-ItemProperty -Path 'HKCU:Software/AladinEbookViewer' -ErrorAction SilentlyContinue).DbKeyEnc",
        ],
        runInShell: true,
      );
      final rawKey = regProc.stdout.toString().trim();
      if (rawKey.isNotEmpty) {
        if (!rawKey.startsWith('TPM1:') && !rawKey.startsWith('DP1:')) {
          _cachedAladinDecryptedKey = rawKey;
          return rawKey;
        }
        final decryptedList = await decryptAladinStrings([rawKey]);
        if (decryptedList.isNotEmpty && !decryptedList.first.startsWith('TPM1:') && !decryptedList.first.startsWith('DP1:')) {
          _cachedAladinDecryptedKey = decryptedList.first;
          return decryptedList.first;
        }
        return rawKey;
      }
    } catch (_) {}

    return defaultKey;
  }

  static final List<Map<String, dynamic>> _cachedAladinPurchaseList = [];
  static List<Map<String, dynamic>> get cachedAladinPurchaseList => List.unmodifiable(_cachedAladinPurchaseList);
  static Map<String, dynamic>? _cachedAladinUser;
  static Map<String, dynamic>? get cachedAladinUser => _cachedAladinUser != null ? Map.unmodifiable(_cachedAladinUser!) : null;

  /// '디바이스 ID 추출' 시 data DB에서 읽어온 사용자 정보(User) 캐싱
  static void cacheAladinUser(dynamic user) {
    if (user is Map<String, dynamic>) {
      _cachedAladinUser = Map<String, dynamic>.from(user);
    } else if (user is Map) {
      _cachedAladinUser = Map<String, dynamic>.from(user);
    }
  }

  /// '디바이스 ID 추출' 시 data DB에서 읽어온 알라딘 도서 메타데이터(PurchaseList) 캐싱
  static void cacheAladinPurchaseList(List<dynamic> list) {
    _cachedAladinPurchaseList.clear();
    for (final item in list) {
      if (item is Map<String, dynamic>) {
        _cachedAladinPurchaseList.add(item);
      } else if (item is Map) {
        _cachedAladinPurchaseList.add(Map<String, dynamic>.from(item));
      }
    }
  }

  /// 스캔된 도서 목록에 캐시된 알라딘 메타데이터(downloadKeyEnc, downloadKeyId, title 등)를 미리 매칭
  static void matchBooksWithAladinPurchaseList(List<BookItem> books) {
    if (_cachedAladinPurchaseList.isEmpty) return;
    for (final book in books) {
      final cleanBookNo = book.bookNo?.trim() ?? '';
      final fileName = p.basename(book.path).replaceAll(RegExp(r'\.(epub_comic|epub|zip|cpub)$', caseSensitive: false), '').trim();
      final bookPathNorm = book.path.replaceAll('\\', '/').toLowerCase();

      for (final pItem in _cachedAladinPurchaseList) {
        final itemId = pItem['itemId']?.toString().trim() ?? '';
        final title = pItem['title']?.toString().trim() ?? '';
        final filePath = pItem['filePath']?.toString().trim() ?? '';
        final ebookId = pItem['ebookId']?.toString().trim().toLowerCase() ?? '';
        final filePathNorm = filePath.replaceAll('\\', '/').toLowerCase();

        bool matched = false;
        if (cleanBookNo.isNotEmpty && itemId.isNotEmpty && cleanBookNo == itemId) {
          matched = true;
        } else if (fileName.isNotEmpty && itemId.isNotEmpty && fileName == itemId) {
          matched = true;
        } else if (ebookId.isNotEmpty && (fileName.toLowerCase() == ebookId || bookPathNorm.contains(ebookId))) {
          matched = true;
        } else if (filePathNorm.isNotEmpty && (bookPathNorm.endsWith(filePathNorm) || filePathNorm.endsWith(bookPathNorm))) {
          matched = true;
        }

        if (matched) {
          book.downloadKeyId = pItem['downloadKeyId']?.toString();
          book.downloadKeyEnc = pItem['downloadKeyEnc']?.toString();
          final drmTypeNum = pItem['drmType'];
          if (drmTypeNum is num) {
            book.drmType = drmTypeNum.toInt();
          }
          if (title.isNotEmpty && (book.detectedTitle == null || book.detectedTitle == book.name)) {
            book.detectedTitle = title;
          }
          break;
        }
      }
    }
  }

  /// 알라딘 도서 복호화 키(privKey) 추출
  /// 관리자 권한을 요청한 CNG 스크립트로 downloadKeyEnc를 복호화하여 privKey(32B hex)를 도출
  static Future<AladinV4Keys?> extractAladinV4Keys({
    required String itemId,
    String? downloadKeyEnc,
    String? downloadKeyId,
    String? dataDbPath,
    String? metaKey,
    String? contentKey,
    ExtractedDevice? device,
  }) async {
    if (!Platform.isWindows || itemId.isEmpty) return null;

    String? privKey;
    String? effectiveDownloadKeyId = downloadKeyId;
    String? enc = downloadKeyEnc;

    // 1. downloadKeyEnc가 전달되지 않은 경우 캐시된 purchaseList에서 탐색
    if (enc == null || enc.isEmpty) {
      final cachedItem = _cachedAladinPurchaseList.firstWhere(
        (b) => b['itemId']?.toString() == itemId,
        orElse: () => <String, dynamic>{},
      );
      enc = cachedItem['downloadKeyEnc']?.toString();
      effectiveDownloadKeyId ??= cachedItem['downloadKeyId']?.toString();
    }

    // 2. downloadKeyEnc를 순수 CNG 복호화(UAC RunAs 선별)로 32바이트 privKey 도출
    if (enc != null && enc.isNotEmpty) {
      try {
        final decrypted = await decryptAladinStrings([enc]);
        if (decrypted.isNotEmpty && !_isAladinEncrypted(decrypted.first)) {
          privKey = decrypted.first;
          // ignore: avoid_print
        } else if (decrypted.isNotEmpty) {
          // ignore: avoid_print
        }
      } catch (e) {
        // ignore: avoid_print
      }
    } else {
      // ignore: avoid_print
    }

    return AladinV4Keys(
      privKey: privKey,
      contentKey: contentKey,
      downloadKeyId: effectiveDownloadKeyId,
      metaKey: metaKey,
    );
  }

  /// 리디북스 도서 메타데이터 파일(BOOK_META/<BOOKNO>) 경로 탐색
  /// 책경로/../../datastores/user/_<USERNO>/BOOK_META/<BOOKNO>
  static String? findRidiMetaFile(String bookPath, {String? userNo, String? bookNo}) {
    final cleanBookNo = (bookNo != null && bookNo.trim().isNotEmpty)
        ? bookNo.trim()
        : p.basename(bookPath).replaceAll(RegExp(r'\.(epub|zip)$', caseSensitive: false), '');

    // 1. 책 경로 기준 상위 디렉터리 상대 경로 탐색
    final parentDir = p.dirname(bookPath);
    String? detectedUserNo = userNo;
    if (detectedUserNo == null || detectedUserNo.isEmpty) {
      final parentName = p.basename(parentDir);
      if (parentName.startsWith('_')) {
        detectedUserNo = parentName.substring(1);
      }
    }

    if (detectedUserNo != null && detectedUserNo.isNotEmpty) {
      final candRel = p.normalize(p.join(bookPath, '..', '..', 'datastores', 'user', '_$detectedUserNo', 'BOOK_META', cleanBookNo));
      if (File(candRel).existsSync()) return candRel;
    }

    // 2. 표준 Ridibooks datastores 디렉터리 탐색
    final List<String> datastoreRoots = [];
    if (Platform.isMacOS) {
      for (final h in getMacOSHomeCandidates()) {
        datastoreRoots.add(p.join(h, 'Library', 'Application Support', 'Ridibooks', 'datastores', 'user'));
      }
    } else {
      final appData = Platform.environment['APPDATA'] ?? '';
      if (appData.isNotEmpty) {
        datastoreRoots.add(p.join(appData, 'Ridibooks', 'datastores', 'user'));
      }
    }

    for (final root in datastoreRoots) {
      final rootDir = Directory(root);
      if (!rootDir.existsSync()) continue;

      if (detectedUserNo != null && detectedUserNo.isNotEmpty) {
        final cand = p.join(root, '_$detectedUserNo', 'BOOK_META', cleanBookNo);
        if (File(cand).existsSync()) return cand;
      }

      // 사용자 번호를 모르는 경우 모든 user 하위 폴더 순회
      try {
        final userDirs = rootDir.listSync(followLinks: false).whereType<Directory>();
        for (final uDir in userDirs) {
          final cand = p.join(uDir.path, 'BOOK_META', cleanBookNo);
          if (File(cand).existsSync()) return cand;
        }
      } catch (_) {}
    }

    return null;
  }

  /// OPF XML 문자열에서 도서 제목(dc:title) 파싱 (CDATA 언래핑 및 엔티티 복원)
  static String? parseDcTitle(String content) {
    final match = RegExp(
      r'<(?:dc:)?title(?:\s[^>]*)?>([\s\S]*?)<\/(?:dc:)?title>',
      caseSensitive: false,
    ).firstMatch(content);
    if (match != null && match.group(1) != null) {
      String title = match.group(1)!;

      // 1. CDATA 언래핑: <![CDATA[...]]> 내부 원본 문자열 추출
      title = title.replaceAllMapped(
        RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>', caseSensitive: false),
        (m) => m.group(1) ?? '',
      );
      // 혹시 남은 고아 CDATA 태그 정리
      title = title.replaceAll(RegExp(r'<!\[CDATA\[|\]\]>', caseSensitive: false), '');

      // 2. XML 엔티티 복원
      title = title
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll(RegExp(r'&apos;|&#39;'), "'")
          // 3. 파일명 및 타이틀에 사용할 수 없는 특수문자 제거
          .replaceAll(RegExp(r'[\\/*?:"<>|\x00-\x1f]'), '')
          .trim();

      // 4. 끝자리 마침표 제거
      while (title.endsWith('.')) {
        title = title.substring(0, title.length - 1).trim();
      }

      if (title.isNotEmpty) return title;
    }
    return null;
  }

  /// OPF XML 파일에서 도서 제목(dc:title) 추출
  static Future<String?> extractTitleFromOpf(File opfFile) async {
    try {
      if (await opfFile.length() > 5 * 1024 * 1024) return null;
      final content = await opfFile.readAsString();
      return parseDcTitle(content);
    } catch (_) {}
    return null;
  }

  /// 디렉터리 내의 도서 폴더 및 EPUB/ZIP 목록을 스캔
  static Future<List<BookItem>> scanFolder(
    String rawPath, {
    String serviceId = 'service1',
    String? defaultMetaFilePath,
  }) async {
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

    // 서비스별 기본 메타데이터 파일 탐색
    String? serviceDefaultMeta = defaultMetaFilePath;
    if (serviceDefaultMeta == null || serviceDefaultMeta.isEmpty) {
      if (serviceId == 'service2') {
        serviceDefaultMeta = getDefaultDeviceIdFilePath('service2');
      } else if (serviceId == 'service3') {
        serviceDefaultMeta = getDefaultDeviceIdFilePath('service3', currentLibraryPath: resolvedPath);
      }
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

        final folderName = p.basename(entry.path);
        final cleanBookNo = folderName.replaceAll(RegExp(r'\.(epub_comic|epub|zip|cpub)$', caseSensitive: false), '');
        String? detectedUserNo;
        final parentName = p.basename(p.dirname(entry.path));
        if (parentName.startsWith('_')) {
          detectedUserNo = parentName.substring(1);
        }

        String? metaPath;
        if (serviceId == 'service1') {
          metaPath = defaultMetaFilePath ?? findRidiMetaFile(entry.path, userNo: detectedUserNo, bookNo: cleanBookNo);
        } else {
          metaPath = serviceDefaultMeta;
        }

        results.add(BookItem(
          id: entry.path,
          name: folderName,
          path: entry.path,
          isDirectory: true,
          fileCount: subFiles.length,
          sizeBytes: totalSize,
          datFilePath: foundDatPath,
          metaFilePath: metaPath,
          clientBookPath: entry.path,
          bookNo: cleanBookNo,
          userNo: detectedUserNo,
          detectedTitle: detectedTitle,
        ));
      } else if (entry is File) {
        final lower = entry.path.toLowerCase();
        final isEpub = lower.endsWith('.epub') || lower.endsWith('.epub_comic') || lower.endsWith('.cpub');
        final isZip = lower.endsWith('.zip');

        if (isEpub || isZip) {
          final size = await entry.length();
          final fileName = p.basename(entry.path);
          final cleanBookNo = fileName.replaceAll(RegExp(r'\.(epub_comic|epub|zip|cpub)$', caseSensitive: false), '');

          // 같은 폴더 내에 동일 이름의 .dat 파일이 있는지 검사
          String? matchingDat;
          final siblingDat = File(p.join(p.dirname(entry.path), '$cleanBookNo.dat'));
          if (await siblingDat.exists()) {
            matchingDat = siblingDat.path;
          }

          String? detectedUserNo;
          final parentName = p.basename(p.dirname(entry.path));
          if (parentName.startsWith('_')) {
            detectedUserNo = parentName.substring(1);
          }

          String? metaPath;
          if (serviceId == 'service1') {
            metaPath = defaultMetaFilePath ?? findRidiMetaFile(entry.path, userNo: detectedUserNo, bookNo: cleanBookNo);
          } else {
            metaPath = serviceDefaultMeta;
          }

          results.add(BookItem(
            id: entry.path,
            name: fileName,
            path: entry.path,
            isDirectory: false,
            fileCount: 1,
            sizeBytes: size,
            datFilePath: matchingDat,
            metaFilePath: metaPath,
            clientBookPath: entry.path,
            bookNo: cleanBookNo,
            userNo: detectedUserNo,
            detectedTitle: cleanBookNo,
          ));
        }
      }
    }

    // 알라딘의 경우 캐시된 purchaseList 메타데이터(downloadKey 등)를 미리 매칭
    if (serviceId == 'service3') {
      matchBooksWithAladinPurchaseList(results);
    }

    // 이름순 정렬
    results.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    return results;
  }
}

/// service3 2026.11
class AladinV4Keys {
  final String? privKey;
  final String? contentKey;
  final String? downloadKeyId;
  final String? metaKey;

  AladinV4Keys({
    this.privKey,
    this.contentKey,
    this.downloadKeyId,
    this.metaKey,
  });
}
