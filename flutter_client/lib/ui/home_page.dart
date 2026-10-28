import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../models/book_item.dart';
import '../models/server_status.dart';
import '../models/device_status.dart';
import '../services/api_service.dart';
import '../services/folder_scanner.dart';
import '../services/zip_service.dart';
import 'theme.dart';
import 'widgets/server_header.dart';
import 'widgets/device_id_card.dart';
import 'widgets/folder_list_view.dart';
import 'widgets/action_bar.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final AegisReaderApiService _apiService = AegisReaderApiService();

  // 텍스트 컨트롤러
  late final TextEditingController _serverUrlController;
  late final TextEditingController _deviceIdController;
  late final TextEditingController _folderPathController;
  late final TextEditingController _outputDirController;

  // 서비스별 디바이스 ID 및 상태 개별 저장 (요청 1)
  final Map<String, String> _serviceDeviceIds = {
    'service1': '',
    'service2': '',
    'service3': '',
  };
  final Map<String, DeviceStatus?> _serviceDeviceStatuses = {
    'service1': null,
    'service2': null,
    'service3': null,
  };

  // 상태 플래그
  String _selectedService = 'service1';
  bool _removeWatermark = false;
  ServerStatus _serverStatus = ServerStatus.offline();
  DeviceStatus? _deviceStatus;
  List<BookItem> _books = [];

  bool _isCheckingServer = false;
  bool _isExtractingDeviceId = false;
  bool _isScanningFolder = false;
  bool _isProcessingBatch = false;
  bool _cancelRequested = false;

  int _currentBatchIndex = 0;
  int _totalBatchCount = 0;

  // 상단 알림 오버레이 및 디바운스 타이머
  OverlayEntry? _topNotificationEntry;
  Timer? _topNotificationTimer;
  Timer? _deviceIdDebounceTimer;

  // 네트워크 요청 즉시 중단용 토큰
  CancelToken? _currentCancelToken;

  @override
  void initState() {
    super.initState();
    _serverUrlController = TextEditingController(text: 'https://aegisreader.com/api/');
    _deviceIdController = TextEditingController(text: _serviceDeviceIds[_selectedService]);

    // 기본 라이브러리 경로 (리디: library_<UserNo>, 알라딘: Documents 또는 OneDrive\Documents)
    final defaultLibrary = FolderScanner.getDefaultLibraryPath(_selectedService);
    _folderPathController = TextEditingController(text: defaultLibrary);

    final userProfile = Platform.environment['USERPROFILE'] ?? '';
    final defaultDownload = p.join(userProfile, 'Downloads');
    _outputDirController = TextEditingController(text: defaultDownload);

    // 초기 서버 연결 점검 및 기본 경로 자동 스캔 시도
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkServerStatus();
      if (_folderPathController.text.isNotEmpty && Directory(_folderPathController.text).existsSync()) {
        _scanFolder();
      }
    });
  }

  @override
  void dispose() {
    _dismissTopNotification();
    _deviceIdDebounceTimer?.cancel();
    _serverUrlController.dispose();
    _deviceIdController.dispose();
    _folderPathController.dispose();
    _outputDirController.dispose();
    super.dispose();
  }

  // 1. 서버 상태 점검
  Future<void> _checkServerStatus() async {
    setState(() => _isCheckingServer = true);
    final status = await _apiService.fetchServerStatus(_serverUrlController.text);
    if (!mounted) return;
    setState(() {
      _serverStatus = status;
      _isCheckingServer = false;
    });

    if (!status.online) {
      _showSnackBar('aegisreader API 서버에 연결할 수 없습니다. 네트워크 연결을 확인하세요.', isError: true);
    }
  }

  // 2. 서비스 변경 핸들러
  void _onServiceChanged(String newService) {
    if (_selectedService == newService) return;

    // 현재 서비스의 ID 및 상태 저장
    _serviceDeviceIds[_selectedService] = _deviceIdController.text;
    _serviceDeviceStatuses[_selectedService] = _deviceStatus;

    setState(() {
      _selectedService = newService;

      // 대상 서비스의 ID 및 상태 복원
      final restoredId = _serviceDeviceIds[newService] ?? '';
      _deviceIdController.text = restoredId;
      _deviceStatus = _serviceDeviceStatuses[newService];

      // 프리미엄 상태가 아니면 워터마크 제거 비활성화
      if (_deviceStatus?.isPremium != true) {
        _removeWatermark = false;
      }

      // 대상 서비스의 추천 기본 폴더 지정
      _folderPathController.text = FolderScanner.getDefaultLibraryPath(newService);
      _books.clear();
    });

    // 변경된 기본 폴더 자동 스캔 시도
    if (_folderPathController.text.isNotEmpty && Directory(_folderPathController.text).existsSync()) {
      _scanFolder();
    }
  }

  // 3. 디바이스 ID 텍스트 수정 핸들러 (수정 시 워터마크 즉시 소멸 & 700ms 후 자동 쿼터 확인)
  void _onDeviceIdChanged(String newText) {
    final trimmed = newText.trim();
    _serviceDeviceIds[_selectedService] = trimmed;
    _deviceIdDebounceTimer?.cancel();

    if (_deviceStatus != null) {
      setState(() {
        _deviceStatus = null;
        _serviceDeviceStatuses[_selectedService] = null;
        _removeWatermark = false; // 워터마크 체크박스 즉시 소멸
      });
    }

    if (trimmed.isNotEmpty) {
      _deviceIdDebounceTimer = Timer(const Duration(milliseconds: 700), () {
        if (mounted && _deviceIdController.text.trim() == trimmed) {
          _checkDeviceId(silent: true);
        }
      });
    }
  }

  // 4. 디바이스 ID 유효성 및 쿼터 확인
  Future<void> _checkDeviceId({bool silent = false}) async {
    final devId = _deviceIdController.text.trim();
    if (devId.isEmpty) {
      setState(() {
        _deviceStatus = null;
        _serviceDeviceStatuses[_selectedService] = null;
        _removeWatermark = false;
      });
      return;
    }

    try {
      final status = await _apiService.checkDeviceStatus(
        rawUrl: _serverUrlController.text,
        serviceId: _selectedService,
        deviceId: devId,
      );

      if (!mounted) return;
      setState(() {
        _deviceStatus = status;
        _serviceDeviceStatuses[_selectedService] = status;
        if (!status.isPremium) {
          _removeWatermark = false;
        }
      });

      if (!silent) {
        if (status.isPremium) {
          _showTopNotification('프리미엄 인증 성공! 변환 무제한 및 워터마크 제거 활성화');
        } else {
          _showTopNotification('디바이스 ID 확인 완료: 오늘 ${status.quotaUsed} / ${status.dailyQuota}권 변환 (잔여: ${status.remainingQuota}권)');
        }
      }
    } catch (e) {
      if (!mounted) return;
      if (!silent) {
        _showTopNotification('디바이스 ID 확인 실패: $e', isError: true);
      }
    }
  }

  // 5. '파일에서 추출' 버튼 핸들러 (대상 서비스 경로 자동 읽기 및 API 요청)
  Future<void> _extractDeviceIdFromFile() async {
    final candidatePath = FolderScanner.getDefaultDeviceIdFilePath(_selectedService);
    final file = File(candidatePath);

    if (!await file.exists()) {
      _showExtractionFailedDialog(
        candidatePath,
        reason: '지정된 기본 경로에서 설정 파일을 찾을 수 없습니다.',
      );
      return;
    }

    setState(() => _isExtractingDeviceId = true);
    try {
      final ids = await _apiService.extractDeviceIdFromFile(
        rawUrl: _serverUrlController.text,
        serviceId: _selectedService,
        filePath: file.path,
      );

      if (!mounted) return;
      setState(() => _isExtractingDeviceId = false);

      if (ids.isEmpty) {
        _showExtractionFailedDialog(
          candidatePath,
          reason: '파일 내에서 유효한 디바이스 ID를 확인할 수 없습니다.',
        );
        return;
      }

      if (ids.length == 1) {
        final extractedId = ids.first;
        _deviceIdController.text = extractedId;
        _serviceDeviceIds[_selectedService] = extractedId;
        _showTopNotification('디바이스 ID 자동 추출 성공: $extractedId');
        // 추출 즉시 서버에 유효성 및 쿼터 확인 자동 실행
        _checkDeviceId(silent: true);
      } else {
        _showSelectDeviceIdDialog(ids);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isExtractingDeviceId = false);
      _showExtractionFailedDialog(candidatePath, reason: e.toString());
    }
  }

  // 추출 실패 경고 알림창
  void _showExtractionFailedDialog(String targetPath, {String? reason}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AegisReaderTheme.warningColor, size: 22),
            SizedBox(width: 8),
            Text('추출하지 못했습니다', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (reason != null && reason.isNotEmpty) ...[
                  Text(reason, style: const TextStyle(fontSize: 13, color: AegisReaderTheme.textPrimary)),
                  const SizedBox(height: 10),
                ],
                const Text(
                  '확인한 파일 경로:',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AegisReaderTheme.textMuted),
                ),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AegisReaderTheme.surfaceBg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AegisReaderTheme.cardBorder),
                  ),
                  child: SelectableText(
                    targetPath,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: AegisReaderTheme.textMuted),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  '• 리디: %appdata%\\Ridibooks\\sentry\\scope_v2.json\n'
                  '• 예스24: %appdata%\\Yes24eBook\\.db\\Yes24eBook.realm\n'
                  '• 알라딘: %appdata%\\AladinEbookViewer\\data\n\n'
                  '해당 리더기 프로그램이 설치되어 있고 최소 1회 이상 로그인되었는지 확인해주세요.',
                  style: TextStyle(fontSize: 11, color: AegisReaderTheme.textMuted, height: 1.4),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _manualPickFileForDeviceId();
            },
            child: const Text('다른 위치 파일 직접 선택'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  // 보조: 사용자가 다른 위치 파일을 직접 선택
  Future<void> _manualPickFileForDeviceId() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: '디바이스 설정/DB 파일 선택',
        type: FileType.any,
      );

      if (result == null || result.files.single.path == null) return;
      final filePath = result.files.single.path!;

      setState(() => _isExtractingDeviceId = true);
      final ids = await _apiService.extractDeviceIdFromFile(
        rawUrl: _serverUrlController.text,
        serviceId: _selectedService,
        filePath: filePath,
      );

      if (!mounted) return;
      setState(() => _isExtractingDeviceId = false);

      if (ids.isEmpty) {
        _showExtractionFailedDialog(filePath, reason: '선택한 파일에서 디바이스 ID를 찾을 수 없습니다.');
        return;
      }

      if (ids.length == 1) {
        final extractedId = ids.first;
        _deviceIdController.text = extractedId;
        _serviceDeviceIds[_selectedService] = extractedId;
        _showTopNotification('디바이스 ID 추출 성공: $extractedId');
        _checkDeviceId(silent: true);
      } else {
        _showSelectDeviceIdDialog(ids);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isExtractingDeviceId = false);
      _showExtractionFailedDialog('', reason: e.toString());
    }
  }

  // 다중 디바이스 ID 선택 다이얼로그 (시인성 높은 V 선택 버튼 적용)
  void _showSelectDeviceIdDialog(List<String> ids) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.fingerprint, color: AegisReaderTheme.accentColor, size: 24),
            SizedBox(width: 10),
            Text('디바이스 ID 선택', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '파일에서 복수의 디바이스 ID가 감지되었습니다.\n사용할 디바이스 ID 항목의 [선택] 버튼을 눌러주세요:',
                  style: TextStyle(fontSize: 12, color: AegisReaderTheme.textMuted, height: 1.4),
                ),
                const SizedBox(height: 14),
                ...ids.map((id) {
                  final isAladinHwId = id.startsWith('al');
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: AegisReaderTheme.surfaceBg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AegisReaderTheme.cardBorder, width: 1.2),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        _deviceIdController.text = id;
                        _serviceDeviceIds[_selectedService] = id;
                        Navigator.of(ctx).pop();
                        _showTopNotification('디바이스 ID 선택 완료: $id');
                        _checkDeviceId(silent: true);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: AegisReaderTheme.primary.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(
                                Icons.vpn_key_rounded,
                                size: 20,
                                color: AegisReaderTheme.accentColor,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SelectableText(
                                    id,
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: AegisReaderTheme.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: (isAladinHwId
                                              ? AegisReaderTheme.warningColor
                                              : AegisReaderTheme.secondaryColor)
                                          .withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      isAladinHwId ? '알라딘 전용 하드웨어 ID' : '표준 디바이스 고유 UUID',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: isAladinHwId
                                            ? AegisReaderTheme.warningColor
                                            : AegisReaderTheme.secondaryColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            // 눈에 잘 띄는 V 선택 버튼
                            ElevatedButton.icon(
                              onPressed: () {
                                _deviceIdController.text = id;
                                _serviceDeviceIds[_selectedService] = id;
                                Navigator.of(ctx).pop();
                                _showTopNotification('디바이스 ID 선택 완료: $id');
                                _checkDeviceId(silent: true);
                              },
                              icon: const Icon(
                                Icons.check_circle_rounded,
                                size: 18,
                                color: Colors.white,
                              ),
                              label: const Text(
                                '선택',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: Colors.white,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AegisReaderTheme.primary,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                elevation: 2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('취소'),
          ),
        ],
      ),
    );
  }

  // 경로 유효성 검사
  String? _getValidDirectory(String rawPath) {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) return null;
    final dir = Directory(trimmed);
    if (dir.existsSync()) {
      return dir.path;
    }
    try {
      final parent = dir.parent;
      if (parent.existsSync()) {
        return parent.path;
      }
    } catch (_) {}
    return null;
  }

  // 6. 도서 보관 라이브러리 폴더 찾아보기
  Future<void> _browseLibraryFolder() async {
    try {
      final validDir = _getValidDirectory(_folderPathController.text);
      String? selectedDir;
      try {
        selectedDir = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '도서 보관 라이브러리 폴더 선택',
          initialDirectory: validDir,
        );
      } catch (_) {
        // initialDirectory 실패 시 fallback
        selectedDir = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '도서 보관 라이브러리 폴더 선택',
        );
      }

      if (selectedDir != null) {
        final chosenDir = selectedDir;
        _folderPathController.text = chosenDir;
        _scanFolder();
      }
    } catch (e) {
      _showSnackBar('폴더 선택 창을 열지 못했습니다: $e', isError: true);
    }
  }

  // 7. 복호화 결과 저장 폴더 변경
  Future<void> _browseOutputDir() async {
    try {
      final validDir = _getValidDirectory(_outputDirController.text);
      String? selected;
      try {
        selected = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '복호화 완료 파일 저장 폴더 선택',
          initialDirectory: validDir,
        );
      } catch (_) {
        selected = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '복호화 완료 파일 저장 폴더 선택',
        );
      }

      if (selected != null) {
        final chosen = selected;
        setState(() {
          _outputDirController.text = chosen;
        });
      }
    } catch (e) {
      _showSnackBar('저장 폴더 선택 창을 열지 못했습니다: $e', isError: true);
    }
  }

  // 8. 폴더 목록 불러오기
  Future<void> _scanFolder() async {
    final rawPath = _folderPathController.text.trim();
    if (rawPath.isEmpty) {
      _showSnackBar('스캔할 폴더 경로를 입력해주세요.', isError: true);
      return;
    }

    setState(() => _isScanningFolder = true);
    try {
      final scanned = await FolderScanner.scanFolder(rawPath, serviceId: _selectedService);
      if (!mounted) return;
      setState(() {
        _books = scanned;
        _isScanningFolder = false;
      });
      _showSnackBar('총 ${scanned.length}권의 도서 항목을 불러왔습니다.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _isScanningFolder = false);
      _showSnackBar('폴더 목록 불러오기 실패: $e', isError: true);
    }
  }

  void _resetDefaultLibraryPath() {
    _folderPathController.text = FolderScanner.getDefaultLibraryPath(_selectedService);
    _scanFolder();
  }

  // 9. 체크박스 선택 제어
  void _onSelectAll(bool? val) {
    final targetVal = val ?? false;
    setState(() {
      for (final book in _books) {
        book.isSelected = targetVal;
      }
    });
  }

  void _onItemToggle(BookItem item, bool selected) {
    setState(() {
      item.isSelected = selected;
    });
  }

  // 10. 디렉터리 / 파일 탐색기 열기
  void _openExplorer(BookItem item) {
    final path = item.downloadedFilePath ?? item.path;
    if (Platform.isWindows) {
      Process.run('explorer.exe', ['/select,', path]);
    } else if (Platform.isMacOS) {
      Process.run('open', ['-R', path]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [p.dirname(path)]);
    }
  }

  // 11. 업로드 실행 - 선택 항목 업로드
  void _uploadSelected() {
    final selectedBooks = _books.where((b) => b.isSelected).toList();
    if (selectedBooks.isEmpty) {
      _showSnackBar('업로드할 도서를 선택해주세요.', isError: true);
      return;
    }
    _runBatch(selectedBooks);
  }

  // 12. 업로드 실행 - 전체 항목 업로드
  void _uploadAll() {
    if (_books.isEmpty) {
      _showSnackBar('불러온 도서 목록이 없습니다.', isError: true);
      return;
    }
    _runBatch(_books);
  }

  // 일괄 업로드 파이프라인
  Future<void> _runBatch(List<BookItem> targets) async {
    final deviceId = _deviceIdController.text.trim();
    if (deviceId.isEmpty) {
      _showSnackBar('디바이스 ID를 먼저 입력하거나 우측 [파일에서 추출]을 눌러주세요.', isError: true);
      return;
    }

    final outDir = Directory(_outputDirController.text.trim());
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    setState(() {
      _isProcessingBatch = true;
      _cancelRequested = false;
      _currentBatchIndex = 0;
      _totalBatchCount = targets.length;
    });

    int successCount = 0;
    int failedCount = 0;

    for (int i = 0; i < targets.length; i++) {
      if (_cancelRequested) break;

      final book = targets[i];
      File? tempZipFile;

      try {
        _currentCancelToken = CancelToken();

        // 단계 1: 폴더인 경우 ZIP 압축
        String uploadFilePath = book.path;
        if (book.isDirectory) {
          setState(() {
            book.status = BookStatus.zipping;
            book.statusMessage = '폴더 패키징 중...';
            book.progress = 0.0;
          });

          final tempZipPath = p.join(
            Directory.systemTemp.path,
            'aegisreader_${DateTime.now().millisecondsSinceEpoch}_${p.basename(book.path)}.zip',
          );
          tempZipFile = File(tempZipPath);

          await AegisReaderZipService.createZipFromDirectory(
            Directory(book.path),
            tempZipFile,
            isCancelled: () => _cancelRequested,
            onProgress: (current, total) {
              if (mounted) {
                setState(() {
                  book.progress = total > 0 ? current / total : 0.0;
                  book.statusMessage = '압축 중 ($current / $total)';
                });
              }
            },
          );
          uploadFilePath = tempZipPath;
        }

        if (_cancelRequested) break;

        // 단계 2: 서버로 업로드 및 복호화 요청
        setState(() {
          book.status = BookStatus.uploading;
          book.statusMessage = '복호화 요청 전송 중...';
          book.progress = 0.0;
        });

        final results = await _apiService.decryptBook(
          rawUrl: _serverUrlController.text,
          serviceId: _selectedService,
          deviceId: deviceId,
          filePath: uploadFilePath,
          datFilePath: book.datFilePath,
          removeWatermark: _removeWatermark,
          cancelToken: _currentCancelToken,
          onSendProgress: (sent, total) {
            if (mounted && total > 0) {
              setState(() {
                book.progress = sent / total;
                book.statusMessage = '업로드 중 ${(sent / (1024 * 1024)).toStringAsFixed(1)}MB';
              });
            }
          },
        );

        if (_cancelRequested) break;

        // 단계 3: 복호화된 결과 파일 다운로드
        if (results.isEmpty) {
          throw Exception('서버에서 복호화 결과를 반환하지 않았습니다.');
        }

        setState(() {
          book.status = BookStatus.downloading;
          book.statusMessage = '복호화 결과 다운로드 중...';
          book.progress = 0.0;
        });

        String? finalSavedPath;
        String? savedFileName;
        for (final res in results) {
          if (_cancelRequested) break;
          final targetSavePath = p.join(outDir.path, res.downloadFileName);
          await _apiService.downloadFile(
            rawUrl: _serverUrlController.text,
            token: res.token,
            savePath: targetSavePath,
            cancelToken: _currentCancelToken,
            onReceiveProgress: (rec, total) {
              if (mounted && total > 0) {
                setState(() {
                  book.progress = rec / total;
                  book.statusMessage = '다운로드 중 ${(rec / (1024 * 1024)).toStringAsFixed(1)}MB';
                });
              }
            },
          );
          finalSavedPath = targetSavePath;
          savedFileName = res.downloadFileName;
        }

        if (_cancelRequested) break;

        // 성공 마킹 및 도서명/저장파일명 업데이트
        setState(() {
          book.status = BookStatus.success;
          book.statusMessage = '완료';
          book.progress = 1.0;
          book.downloadedFilePath = finalSavedPath;
          if (savedFileName != null) {
            book.savedFileName = savedFileName;
            book.detectedTitle = p.basenameWithoutExtension(savedFileName);
          }
        });
        successCount++;

        // 도서 1권 복호화 완료 즉시 일일 쿼터 실시간 갱신 (silent)
        if (deviceId.isNotEmpty) {
          await _checkDeviceId(silent: true);
        }
      } catch (e) {
        final isCancel = _cancelRequested ||
            (e is DioException && CancelToken.isCancel(e)) ||
            e.toString().contains('중단되었습니다');
        if (isCancel) {
          setState(() {
            book.status = BookStatus.idle;
            book.statusMessage = '중단됨';
            book.errorMessage = '사용자에 의해 작업이 중단되었습니다.';
          });
          break;
        }
        setState(() {
          book.status = BookStatus.failed;
          book.statusMessage = '실패';
          book.errorMessage = e.toString();
        });
        failedCount++;
      } finally {
        _currentCancelToken = null;
        if (tempZipFile != null && await tempZipFile.exists()) {
          try {
            await tempZipFile.delete();
          } catch (_) {}
        }
      }

      setState(() {
        _currentBatchIndex = i + 1;
      });
    }

    setState(() {
      _isProcessingBatch = false;
      _currentCancelToken = null;
    });

    if (_cancelRequested) {
      _showTopNotification('업로드 작업이 중단되었습니다.');
    } else {
      // 최종 쿼터 정보 갱신
      if (deviceId.isNotEmpty) {
        await _checkDeviceId(silent: true);
      }
      _showTopNotification('작업 완료: 성공 $successCount권, 실패 $failedCount권');
    }
  }

  void _cancelBatch() {
    setState(() {
      _cancelRequested = true;
    });
    if (_currentCancelToken != null && !_currentCancelToken!.isCancelled) {
      _currentCancelToken!.cancel('사용자에 의해 작업이 중단되었습니다.');
    }
  }

  // 상단 알림 오버레이 닫기
  void _dismissTopNotification() {
    _topNotificationTimer?.cancel();
    _topNotificationTimer = null;
    if (_topNotificationEntry != null) {
      try {
        _topNotificationEntry?.remove();
      } catch (_) {}
      _topNotificationEntry = null;
    }
  }

  // 상단 알림 배너 표시
  void _showTopNotification(String message, {bool isError = false}) {
    if (!mounted) return;

    _dismissTopNotification();

    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
        top: 20,
        left: 24,
        right: 24,
        child: Align(
          alignment: Alignment.topCenter,
          child: Material(
            color: Colors.transparent,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: 1.0),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutBack,
              builder: (ctx, animVal, childWidget) {
                return Transform.translate(
                  offset: Offset(0, -18 * (1 - animVal)),
                  child: Opacity(
                    opacity: animVal.clamp(0.0, 1.0),
                    child: childWidget,
                  ),
                );
              },
              child: Container(
                constraints: const BoxConstraints(maxWidth: 620),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: isError ? const Color(0xFF991B1B) : const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isError ? const Color(0xFFEF4444) : AegisReaderTheme.accentColor,
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.45),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isError ? Icons.error_outline_rounded : Icons.check_circle_rounded,
                      color: isError ? const Color(0xFFFCA5A5) : AegisReaderTheme.accentColor,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        message,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    InkWell(
                      onTap: _dismissTopNotification,
                      borderRadius: BorderRadius.circular(12),
                      child: const Padding(
                        padding: EdgeInsets.all(3.0),
                        child: Icon(Icons.close, size: 16, color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(entry);
    _topNotificationEntry = entry;

    _topNotificationTimer = Timer(const Duration(milliseconds: 3800), () {
      if (_topNotificationEntry == entry) {
        _dismissTopNotification();
      }
    });
  }

  void _showSnackBar(String message, {bool isError = false}) {
    _showTopNotification(message, isError: isError);
  }

  @override
  Widget build(BuildContext context) {
    final selectedBooksCount = _books.where((b) => b.isSelected).length;
    final isPrem = _deviceStatus?.isPremium ?? false;

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final targetWidth = max(constraints.maxWidth, 820.0);
            final targetHeight = max(constraints.maxHeight, 650.0);

            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: SingleChildScrollView(
                scrollDirection: Axis.vertical,
                physics: const ClampingScrollPhysics(),
                child: SizedBox(
                  width: targetWidth,
                  height: targetHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 1. 최상단: 서버 URL, 서비스 탭, 워터마크 토글 (URL, 새로고침, 온라인 배지 우측 고정)
                        ServerHeader(
                          serverUrlController: _serverUrlController,
                          serverStatus: _serverStatus,
                          isCheckingServer: _isCheckingServer,
                          selectedService: _selectedService,
                          isPremium: isPrem,
                          removeWatermark: _removeWatermark,
                          onCheckServer: _checkServerStatus,
                          onServiceChanged: _onServiceChanged,
                          onToggleWatermark: (val) => setState(() => _removeWatermark = val),
                        ),

                        const SizedBox(height: 6),

                        // 2. 디바이스 ID 입력 및 파일 추출 카드 (가로 전체 확장)
                        DeviceIdCard(
                          controller: _deviceIdController,
                          serviceId: _selectedService,
                          deviceStatus: _deviceStatus,
                          isExtracting: _isExtractingDeviceId,
                          onExtractFromFile: _extractDeviceIdFromFile,
                          onManualFilePick: _manualPickFileForDeviceId,
                          onChanged: _onDeviceIdChanged,
                          onSubmitted: (_) => _checkDeviceId(),
                        ),

                        const SizedBox(height: 6),

                        // 3. 도서 라이브러리 폴더 스캔 및 목록 뷰 (중간 전체를 채우고 창 높이에 따라 유연하게 확장)
                        Expanded(
                          child: FolderListView(
                            pathController: _folderPathController,
                            books: _books,
                            isScanning: _isScanningFolder,
                            isBusy: _isProcessingBatch,
                            onBrowseFolder: _browseLibraryFolder,
                            onScanFolder: _scanFolder,
                            onUseDefaultPath: _resetDefaultLibraryPath,
                            onSelectAll: _onSelectAll,
                            onItemToggle: _onItemToggle,
                            onOpenDirectory: _openExplorer,
                          ),
                        ),

                        const SizedBox(height: 6),

                        // 4. 하단 액션 바 (창 크기와 무관하게 항상 최하단에 완벽 고정)
                        ActionBarWidget(
                          outputDirController: _outputDirController,
                          totalCount: _books.length,
                          selectedCount: selectedBooksCount,
                          isBusy: _isProcessingBatch,
                          currentProcessingIndex: _currentBatchIndex,
                          totalProcessingCount: _totalBatchCount,
                          onBrowseOutputDir: _browseOutputDir,
                          onUploadSelected: _uploadSelected,
                          onUploadAll: _uploadAll,
                          onCancel: _cancelBatch,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
