import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:path/path.dart' as p;
import 'folder_scanner.dart';
import '../models/server_status.dart';
import '../models/device_status.dart';
import '../models/extracted_device.dart';
import '../models/quest_book.dart';

class DecryptedFileResult {
  final String token;
  final String downloadUrl;
  final String downloadFileName;
  final int sizeBytes;

  DecryptedFileResult({
    required this.token,
    required this.downloadUrl,
    required this.downloadFileName,
    required this.sizeBytes,
  });

  factory DecryptedFileResult.fromJson(Map<String, dynamic> json) {
    return DecryptedFileResult(
      token: json['token']?.toString() ?? '',
      downloadUrl: json['downloadUrl']?.toString() ?? '',
      downloadFileName: json['downloadFileName']?.toString() ?? 'decrypted.epub',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
    );
  }
}

class AegisReaderApiService {
  static const String defaultApiUrl = 'https://aegisreader.com/api';

  /// 분할 업로드 기준 파일 크기
  static const int splitThresholdBytes = 10 * 1024 * 1024;

  /// 분할 청크 단위 크기
  static const int chunkSizeBytes = 5 * 1024 * 1024;

  /// Device ID 추출용 파일 최대 허용 크기 (service1: 1MB, service2/service3 realm·data: 100MB)
  static const int maxDeviceIdService1Bytes = 1 * 1024 * 1024;
  static const int maxDeviceIdRealmDataBytes = 100 * 1024 * 1024;

  static const Set<String> _genericHttpStatusPhrases = {
    'bad request',
    'unauthorized',
    'forbidden',
    'not found',
    'method not allowed',
    'payload too large',
    'unprocessable entity',
    'too many requests',
    'internal server error',
    'bad gateway',
    'service unavailable',
    'gateway timeout',
    'error',
  };

  /// HTTP 상태 코드 표준 영문 문구(예: Unprocessable Entity)인지 판별
  static bool isGenericHttpStatusPhrase(String? text) {
    if (text == null) return true;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return true;
    return _genericHttpStatusPhrases.contains(trimmed.toLowerCase());
  }

  /// 내부 명령 실패나 스택 트레이스 등 기술적 오류 문자열을 정제합니다.
  static String sanitizeClientVisibleMessage(String msg) {
    final trimmed = msg.trim();
    if (trimmed.contains('Command failed:') ||
        trimmed.contains('Failed to open Realm') ||
        trimmed.contains('invalid mnemonic') ||
        trimmed.contains('top_ref[') ||
        trimmed.contains('SQLCipher')) {
      return '잘못된 메타데이터 파일입니다.';
    }
    return trimmed;
  }

  /// 서버 에러 응답(JSON Map 또는 문자열)에서 실제 사용자 안내 메시지를 추출합니다.
  /// Nitro 프록시(createError)가 최상위 statusMessage에 'Unprocessable Entity'를 넣고
  /// 실제 안내 문구를 data.statusMessage 또는 message에 넣는 구조를 함께 처리합니다.
  static String? extractServerErrorMessage(dynamic responseData) {
    if (responseData == null) return null;

    if (responseData is String) {
      final trimmed = responseData.trim();
      if (trimmed.isEmpty || isGenericHttpStatusPhrase(trimmed)) return null;
      if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
        try {
          final decoded = jsonDecode(trimmed);
          return extractServerErrorMessage(decoded);
        } catch (_) {}
      }
      if (trimmed.startsWith('<!DOCTYPE') || trimmed.startsWith('<html')) {
        return null;
      }
      return sanitizeClientVisibleMessage(trimmed);
    }

    if (responseData is Map) {
      final nestedData = responseData['data'];
      if (nestedData is Map) {
        for (final key in const ['statusMessage', 'error', 'message']) {
          final val = nestedData[key]?.toString().trim();
          if (val != null && val.isNotEmpty && !isGenericHttpStatusPhrase(val)) {
            return sanitizeClientVisibleMessage(val);
          }
        }
      }

      for (final key in const ['statusMessage', 'message', 'error']) {
        final val = responseData[key]?.toString().trim();
        if (val != null && val.isNotEmpty && !isGenericHttpStatusPhrase(val)) {
          return sanitizeClientVisibleMessage(val);
        }
      }
    }

    return null;
  }

  /// 디바이스 ID 추출 실패 시 표시할 사유 문구를 결정합니다.
  /// HTTP 422(Unprocessable Entity) 등 추출 실패 응답인 경우 기존 가이드 문구(defaultGuideReason)를 반환합니다.
  static String resolveDeviceIdErrorReason(
    Object error, {
    required String defaultGuideReason,
  }) {
    if (error is DioException) {
      final serverMsg = extractServerErrorMessage(error.response?.data);
      if (serverMsg != null && serverMsg.isNotEmpty && !isGenericHttpStatusPhrase(serverMsg)) {
        return serverMsg;
      }
      return defaultGuideReason;
    }

    final raw = error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '').trim();
    if (raw.isEmpty || isGenericHttpStatusPhrase(raw)) {
      return defaultGuideReason;
    }
    return raw;
  }

  /// 일반 API 요청(복호화 등) 실패 시 서버 에러 메시지를 추출합니다.
  static String extractDioErrorMessage(
    Object error, {
    String fallback = '요청 처리 중 오류가 발생했습니다.',
  }) {
    if (error is DioException) {
      final serverMsg = extractServerErrorMessage(error.response?.data);
      if (serverMsg != null && serverMsg.isNotEmpty) {
        return serverMsg;
      }
      final dioMsg = error.message?.trim();
      if (dioMsg != null &&
          dioMsg.isNotEmpty &&
          !isGenericHttpStatusPhrase(dioMsg) &&
          !dioMsg.startsWith('This exception was thrown because')) {
        return dioMsg;
      }
      return fallback;
    }
    final raw = error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '').trim();
    if (raw.isEmpty || isGenericHttpStatusPhrase(raw)) {
      return fallback;
    }
    return raw;
  }

  static String? _cachedAppVersion;

  /// pubspec.yaml에서 선언된 버전 문자열 동기/정적 탐색
  static String _resolveInitialVersion() {
    try {
      for (final candidate in ['pubspec.yaml', 'flutter_client/pubspec.yaml', '../pubspec.yaml']) {
        final f = File(candidate);
        if (f.existsSync()) {
          final content = f.readAsStringSync();
          final match = RegExp(r'^version:\s*([^\s+]+)', multiLine: true).firstMatch(content);
          if (match != null && match.group(1) != null) {
            return match.group(1)!.trim();
          }
        }
      }
    } catch (_) {}
    return '0.0.0';
  }

  /// pubspec.yaml에서 선언된 앱 버전 조회 (rootBundle 애셋 및 로컬 파일 탐색)
  static Future<String> getAppVersion() async {
    if (_cachedAppVersion != null) return _cachedAppVersion!;

    // 1. rootBundle 애셋에서 pubspec.yaml 읽기 시도
    try {
      final yamlContent = await rootBundle.loadString('pubspec.yaml');
      final match = RegExp(r'^version:\s*([^\s+]+)', multiLine: true).firstMatch(yamlContent);
      if (match != null && match.group(1) != null) {
        _cachedAppVersion = match.group(1)!.trim();
        return _cachedAppVersion!;
      }
    } catch (_) {}

    // 2. 동기 탐색 결과 반환 및 캐싱
    _cachedAppVersion = _resolveInitialVersion();
    return _cachedAppVersion!;
  }

  static final String appVersion = _resolveInitialVersion();

  late final Dio _dio;

  AegisReaderApiService() {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 180),
      sendTimeout: const Duration(seconds: 180),
      headers: {
        'User-Agent': 'AegisReader-FlutterClient/$appVersion',
      },
    ));

    // Windows OS 커널 TCP Window Scaling(16MB) 및 다중 영구 커넥션 풀(최대 32개) 최적화
    // (참고: Dart package:http2는 64KB user-space flow control 제한으로 인해 300ms 고지연 WAN에서 0.1MB/s로 속도가 병목됨)
    (_dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final client = HttpClient();
      client.maxConnectionsPerHost = 32;
      client.idleTimeout = const Duration(seconds: 45);
      client.connectionTimeout = const Duration(seconds: 15);
      return client;
    };

    // pubspec.yaml에서 읽은 최신 버전으로 User-Agent 헤더 갱신 지원
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final version = await getAppVersion();
          options.headers['User-Agent'] = 'AegisReader-FlutterClient/$version';
          handler.next(options);
        },
      ),
    );
  }

  /// aegisreader API 엔드포인트 URL 정규화
  /// 기본값: https://aegisreader.com/api
  String normalizeApiUrl([String? url]) {
    String trimmed = (url ?? defaultApiUrl).trim();
    if (trimmed.isEmpty) {
      trimmed = defaultApiUrl;
    }
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      trimmed = 'https://$trimmed';
    }
    trimmed = trimmed.replaceAll(RegExp(r'/+$'), '');
    if (!trimmed.endsWith('/api')) {
      trimmed = '$trimmed/api';
    }
    return trimmed;
  }

  /// 1. aegisreader 서버 가동 상태 확인 (GET /api/backend-status, fallback /api/status)
  Future<ServerStatus> fetchServerStatus([String? rawUrl]) async {
    final apiUrl = normalizeApiUrl(rawUrl);
    try {
      Response response;
      try {
        response = await _dio.get(
          '$apiUrl/backend-status',
          options: Options(
            sendTimeout: const Duration(seconds: 4),
            receiveTimeout: const Duration(seconds: 4),
          ),
        );
      } catch (_) {
        response = await _dio.get(
          '$apiUrl/status',
          options: Options(
            sendTimeout: const Duration(seconds: 4),
            receiveTimeout: const Duration(seconds: 4),
          ),
        );
      }

      if (response.statusCode == 200 && response.data is Map<String, dynamic>) {
        return ServerStatus.fromJson(response.data as Map<String, dynamic>);
      }
    } catch (_) {
      // offline or error
    }
    return ServerStatus.offline();
  }

  /// 2. 디바이스 ID 확인 (프리미엄 상태 및 잔여 쿼터 조회)
  /// GET /api/premium/status?service=...&deviceId=...
  Future<DeviceStatus> checkDeviceStatus({
    String? rawUrl,
    required String serviceId,
    required String deviceId,
  }) async {
    final apiUrl = normalizeApiUrl(rawUrl);
    final cleanDevId = deviceId.trim();
    if (cleanDevId.isEmpty) {
      return DeviceStatus.empty(serviceId, '');
    }

    try {
      final response = await _dio.get(
        '$apiUrl/premium/status',
        queryParameters: {
          'service': serviceId,
          'deviceId': cleanDevId,
        },
      );

      if (response.statusCode == 200 && response.data is Map<String, dynamic>) {
        return DeviceStatus.fromJson(response.data as Map<String, dynamic>);
      }
    } catch (e) {
      if (e is DioException && e.response?.data is Map<String, dynamic>) {
        return DeviceStatus.fromJson(e.response!.data as Map<String, dynamic>);
      }
    }
    return DeviceStatus.empty(serviceId, cleanDevId);
  }

  /// 2-1. 퀘스트 대상 도서 목록 조회 (GET /api/quest/config)
  Future<List<QuestBook>> fetchQuestBooks([String? rawUrl]) async {
    final apiUrl = normalizeApiUrl(rawUrl);
    final response = await _dio.get('$apiUrl/quest/config');
    if (response.statusCode == 200 && response.data is Map<String, dynamic>) {
      final rawBooks = response.data['books'] as List<dynamic>?;
      if (rawBooks != null) {
        return rawBooks
            .whereType<Map<String, dynamic>>()
            .map((e) => QuestBook.fromJson(e))
            .where((b) => b.name.isNotEmpty)
            .toList();
      }
    }
    return [];
  }

  /// 3. 설정 파일에서 디바이스 ID 추출
  /// POST /api/deviceid (multipart: service, file, file_wal, file_shm)
  Future<List<ExtractedDevice>> extractDeviceIdFromFile({
    String? rawUrl,
    required String serviceId,
    required String filePath,
    String? walFilePath,
    String? shmFilePath,
    ProgressCallback? onSendProgress,
  }) async {
    final apiUrl = normalizeApiUrl(rawUrl);
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('선택한 파일이 존재하지 않습니다: $filePath');
    }

    final int maxBytes = serviceId == 'service1'
        ? maxDeviceIdService1Bytes
        : maxDeviceIdRealmDataBytes;
    final String maxLabel = serviceId == 'service1' ? '1MB' : '100MB';

    final int fileLength;
    try {
      fileLength = await file.length();
    } on FileSystemException {
      rethrow;
    } catch (e) {
      throw FileSystemException('파일 크기를 확인할 수 없습니다: $e', file.path);
    }

    if (fileLength > maxBytes) {
      throw Exception('업로드 용량 제한($maxLabel)을 초과했습니다.');
    }

    final Uint8List fileBytes;
    try {
      fileBytes = await file.readAsBytes();
    } on FileSystemException {
      rethrow;
    } catch (e) {
      throw FileSystemException('파일을 읽을 수 없습니다: $e', file.path);
    }

    if (fileBytes.length > maxBytes) {
      throw Exception('업로드 용량 제한($maxLabel)을 초과했습니다.');
    }

    final formMap = <String, dynamic>{
      'service': serviceId,
      'file': MultipartFile.fromStream(
        () => _createChunkedBytesStream(fileBytes),
        fileBytes.length,
        filename: p.basename(file.path),
      ),
    };

    // 예스24(service2)의 경우 암호화된 Realm 파일을 열기 위한 64바이트 키(Base64) 탐색 및 첨부
    if (serviceId == 'service2') {
      try {
        final keyStr = await FolderScanner.getYes24DecryptedKey(filePath);
        if (keyStr != null && keyStr.isNotEmpty) {
          formMap['file_key'] = keyStr;
        }
      } catch (_) {}
    }

    // 알라딘(service3)의 경우 SQLite WAL(-wal, -shm) 파일이 존재하고 읽기 가능하면 함께 전송하여 커밋되지 않은 최신 Device ID 복원
    if (serviceId == 'service3') {
      final targetWalPath = walFilePath ?? '${file.path}-wal';
      final targetShmPath = shmFilePath ?? '${file.path}-shm';
      final walFile = File(targetWalPath);
      final shmFile = File(targetShmPath);
      try {
        if (await walFile.exists()) {
          final walBytes = await walFile.readAsBytes();
          if (walBytes.isNotEmpty) {
            formMap['file_wal'] = MultipartFile.fromStream(
              () => _createChunkedBytesStream(walBytes),
              walBytes.length,
              filename: '${p.basename(file.path)}-wal',
            );
          }
        }
      } catch (_) {
        // macOS App Sandbox 또는 SQLite 파일 잠금으로 -wal 접근이 불가능할 경우 본체 파일만으로 진행
      }

      try {
        if (await shmFile.exists()) {
          final shmBytes = await shmFile.readAsBytes();
          if (shmBytes.isNotEmpty) {
            formMap['file_shm'] = MultipartFile.fromStream(
              () => _createChunkedBytesStream(shmBytes),
              shmBytes.length,
              filename: '${p.basename(file.path)}-shm',
            );
          }
        }
      } catch (_) {
        // -shm 접근 불가 시 안전하게 건너뜀
      }
    }

    final formData = FormData.fromMap(formMap);

    final response = await _dio.post(
      '$apiUrl/deviceid',
      data: formData,
      onSendProgress: onSendProgress,
      options: Options(
        sendTimeout: const Duration(minutes: 5),
        receiveTimeout: const Duration(minutes: 5),
      ),
    );

    if (response.statusCode == 200 && response.data is Map<String, dynamic>) {
      final rawDevices = response.data['devices'] as List<dynamic>?;
      if (rawDevices != null && rawDevices.isNotEmpty) {
        return rawDevices
            .whereType<Map<String, dynamic>>()
            .map((e) => ExtractedDevice.fromJson(e))
            .where((d) => d.deviceId.isNotEmpty)
            .toList();
      }

      final ids = (response.data['deviceIds'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .where((id) => id.isNotEmpty)
              .toList() ??
          [];
      return ids.map((id) => ExtractedDevice(deviceId: id)).toList();
    } else {
      final msg = extractServerErrorMessage(response.data) ?? 'Device ID 추출 실패';
      throw Exception(msg);
    }
  }

  /// 바이트 배열을 64KB 청크 스트림으로 분할 방출하여 Dio의 onSendProgress가 실시간으로 호출되도록 지원
  Stream<Uint8List> _createChunkedBytesStream(
    Uint8List bytes, {
    int chunkSize = 64 * 1024,
  }) async* {
    for (int offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = min(offset + chunkSize, bytes.length);
      yield Uint8List.sublistView(bytes, offset, end);
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 원시 바이너리 스트림 생성기 (디스크 I/O 없이 256KB 버퍼 재활용으로 대용량 스트리밍 전송 지원)
  static Stream<Uint8List> _createDummyStream(
    int totalBytes, {
    int sliceSize = 256 * 1024,
  }) async* {
    final slice = Uint8List(sliceSize);
    int sent = 0;
    while (sent < totalBytes) {
      final rem = totalBytes - sent;
      final cur = min(rem, sliceSize);
      sent += cur;
      yield (cur == sliceSize) ? slice : Uint8List.sublistView(slice, 0, cur);
    }
  }

  /// 4. 도서 파일 복호화 요청
  /// POST /api/decrypt (multipart: service, deviceId, files, datFiles, metaFile, clientBookPath, bookNo, clientType, removeWatermark)
  /// 100MB 초과 도서의 경우 단일 요청 100MB 제한을 방어하기 위해 자동으로 50MB 단위 분할 업로드(Chunked Upload) 수행
  Future<List<DecryptedFileResult>> decryptBook({
    String? rawUrl,
    required String serviceId,
    required String deviceId,
    required String filePath,
    String? datFilePath,
    String? metaFilePath,
    String? clientBookPath,
    String? bookNo,
    String? userNo,
    String clientType = 'flutter_client',
    bool removeWatermark = false,
    bool parallel = true,
    ProgressCallback? onSendProgress,
    void Function(String message)? onStatusUpdate,
    CancelToken? cancelToken,
  }) async {
    final apiUrl = normalizeApiUrl(rawUrl);
    final bookFile = File(filePath);
    if (!await bookFile.exists()) {
      throw Exception('업로드할 도서 파일이 존재하지 않습니다: $filePath');
    }

    final fileLength = await bookFile.length();

    String? metaKey;
    if (serviceId == 'service2') {
      try {
        metaKey = await FolderScanner.getYes24DecryptedKey(metaFilePath);
      } catch (_) {}
    }

    // 1. 단일 요청 모드 (!parallel) 이거나 파일 크기가 분할 기준 이하인 경우:
    // 청크 분할(isSplit)을 전혀 수행하지 않고, 전체 도서 파일을 단 1개의 단일 multipart POST 요청으로 통째로 전송!
    if (!parallel || fileLength <= splitThresholdBytes) {
      onStatusUpdate?.call('단일 요청 업로드 준비 중...');
      final formMap = <String, dynamic>{
        'service': serviceId,
        'deviceId': deviceId.trim(),
        'removeWatermark': removeWatermark ? 'true' : 'false',
        'clientType': clientType,
        if (clientBookPath != null && clientBookPath.isNotEmpty) 'clientBookPath': clientBookPath,
        if (bookNo != null && bookNo.isNotEmpty) 'bookNo': bookNo,
        if (userNo != null && userNo.isNotEmpty) 'userno': userNo,
        if (metaKey != null && metaKey.isNotEmpty) 'metaKey': metaKey,
        'files': await MultipartFile.fromFile(
          bookFile.path,
          filename: p.basename(bookFile.path),
        ),
      };

      if (metaFilePath != null && metaFilePath.isNotEmpty) {
        final metaFile = File(metaFilePath);
        if (await metaFile.exists()) {
          formMap['metaFile'] = await MultipartFile.fromFile(
            metaFile.path,
            filename: p.basename(metaFile.path),
          );
        }
      }

      if (datFilePath != null && datFilePath.isNotEmpty) {
        final datFile = File(datFilePath);
        if (await datFile.exists()) {
          formMap['datFiles'] = await MultipartFile.fromFile(
            datFile.path,
            filename: p.basename(datFile.path),
          );
        }
      }

      final formData = FormData.fromMap(formMap);
      final singleSw = Stopwatch()..start();
      DateTime lastSingleUi = DateTime.now();

      final response = await _dio.post(
        '$apiUrl/decrypt',
        data: formData,
        options: Options(
          sendTimeout: const Duration(minutes: 5),
          receiveTimeout: const Duration(minutes: 10),
          headers: {
            'x-client-type': clientType,
            if (clientBookPath != null && clientBookPath.isNotEmpty)
              'x-client-book-path': Uri.encodeComponent(clientBookPath),
            if (bookNo != null && bookNo.isNotEmpty) 'x-book-no': bookNo,
            if (metaKey != null && metaKey.isNotEmpty) 'x-meta-key': metaKey,
          },
        ),
        onSendProgress: (sent, total) {
          onSendProgress?.call(sent, total);
          final now = DateTime.now();
          if (now.difference(lastSingleUi).inMilliseconds >= 100 || sent >= total) {
            lastSingleUi = now;
            final elapsedSec = max(0.1, singleSw.elapsedMilliseconds / 1000.0);
            final speedMBs = (sent / (1024 * 1024)) / elapsedSec;
            final sentMb = (sent / (1024 * 1024)).toStringAsFixed(1);
            final totalMb = (total / (1024 * 1024)).toStringAsFixed(1);
            if (total > 0 && sent >= total) {
              onStatusUpdate?.call('업로드 완료 ($totalMb MB) · 서버 수신 및 복호화 대기 중...');
            } else {
              onStatusUpdate?.call('단일 업로드 중 $sentMb / $totalMb MB (${speedMBs.toStringAsFixed(1)} MB/s)');
            }
          }
        },
        cancelToken: cancelToken,
      );

      if (response.statusCode == 200 && response.data is Map<String, dynamic>) {
        if (response.data['success'] != true) {
          final msg = extractServerErrorMessage(response.data) ?? '복호화 실패';
          throw Exception(msg);
        }
        final list = (response.data['files'] as List<dynamic>?)
                ?.map((e) => DecryptedFileResult.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [];
        return list;
      } else {
        final msg = extractServerErrorMessage(response.data) ?? '복호화 실패';
        throw Exception(msg);
      }
    }

    // 2. 병렬 분할 업로드 모드 (parallel && fileLength > splitThresholdBytes):
    // 고지연 회선 대역폭 확장을 위해 파일을 청크 단위로 분할하여 다중 TCP 연결 풀로 동시 전송
    int totalChunks = (fileLength / chunkSizeBytes).ceil();
    if (totalChunks < 2) {
      totalChunks = 2;
    }
    final uploadId = 'up_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(900000) + 100000}';
    final originalFileName = p.basename(bookFile.path);

    Uint8List? metaBytes;
    String? metaFileName;
    if (metaFilePath != null && metaFilePath.isNotEmpty) {
      final metaFile = File(metaFilePath);
      if (await metaFile.exists()) {
        metaBytes = await metaFile.readAsBytes();
        metaFileName = p.basename(metaFile.path);
      }
    }

    Uint8List? datBytes;
    String? datFileName;
    if (datFilePath != null && datFilePath.isNotEmpty) {
      final datFile = File(datFilePath);
      if (await datFile.exists()) {
        datBytes = await datFile.readAsBytes();
        datFileName = p.basename(datFile.path);
      }
    }

    // 다중 독립 TCP 소켓 기반 병렬 분할 업로드
    const int maxConcurrency = 6;
    final int workerCount = min(maxConcurrency, totalChunks);
    final List<int> chunkIndices = List.generate(totalChunks, (i) => i);
    int nextCursor = 0;
    int completedCount = 0;
    final List<int> chunkSentBytes = List.filled(totalChunks, 0);
    final List<bool> chunkFlushed = List.filled(totalChunks, false);
    List<DecryptedFileResult>? finalResults;
    DateTime lastUiUpdate = DateTime.now();
    bool assemblingStarted = false;

    void updateProgress() {
      final overallSent = assemblingStarted
          ? fileLength
          : min(fileLength, chunkSentBytes.reduce((a, b) => a + b));
      onSendProgress?.call(overallSent, fileLength);

      final now = DateTime.now();
      if (now.difference(lastUiUpdate).inMilliseconds >= 50 || overallSent >= fileLength) {
        lastUiUpdate = now;
        final overallMb = (overallSent / (1024 * 1024)).toStringAsFixed(1);
        final totalMb = (fileLength / (1024 * 1024)).toStringAsFixed(1);
        if (assemblingStarted || completedCount >= totalChunks) {
          onStatusUpdate?.call('서버에서 청크 재조립 및 복호화 진행 중... ($totalMb MB)');
        } else if (completedCount >= totalChunks - 1 && chunkFlushed.every((f) => f)) {
          onStatusUpdate?.call('청크 전송 완료. 서버 조립 및 복호화 진행 중... ($totalMb MB)');
        } else if (chunkFlushed.every((f) => f)) {
          onStatusUpdate?.call('청크 전송 완료, 서버 수신 확인 중 [$completedCount/$totalChunks 완료]');
        } else {
          onStatusUpdate?.call('분할 업로드 중 [$completedCount/$totalChunks 완료] $overallMb / $totalMb MB');
        }
      }
    }

    Future<void> runWorker() async {
      while (true) {
        if (cancelToken?.isCancelled == true) {
          throw DioException(
            requestOptions: RequestOptions(path: '$apiUrl/decrypt'),
            type: DioExceptionType.cancel,
            message: '사용자에 의해 분할 업로드가 취소되었습니다.',
          );
        }

        if (nextCursor >= chunkIndices.length) break;
        final chunkIndex = chunkIndices[nextCursor++];

        final startOffset = chunkIndex * chunkSizeBytes;
        final endOffset = min(startOffset + chunkSizeBytes, fileLength);
        final currentChunkSize = endOffset - startOffset;

        int chunkRetryCount = 0;
        const int maxChunkRetries = 2;

        while (true) {
          if (cancelToken?.isCancelled == true) {
            throw DioException(
              requestOptions: RequestOptions(path: '$apiUrl/decrypt'),
              type: DioExceptionType.cancel,
              message: '사용자에 의해 분할 업로드가 취소되었습니다.',
            );
          }

          try {
            final formMap = <String, dynamic>{
              'service': serviceId,
              'deviceId': deviceId.trim(),
              'removeWatermark': removeWatermark ? 'true' : 'false',
              'isSplit': 'true',
              'isRawChunk': 'true',
              'uploadId': uploadId,
              'chunkIndex': chunkIndex.toString(),
              'totalChunks': totalChunks.toString(),
              'originalFileName': originalFileName,
              'originalFileSize': fileLength.toString(),
              'clientType': clientType,
              if (clientBookPath != null && clientBookPath.isNotEmpty) 'clientBookPath': clientBookPath,
              if (bookNo != null && bookNo.isNotEmpty) 'bookNo': bookNo,
              if (userNo != null && userNo.isNotEmpty) 'userno': userNo,
              'files': MultipartFile.fromStream(
                () => bookFile.openRead(startOffset, endOffset),
                currentChunkSize,
                filename: '$originalFileName.part_$chunkIndex',
              ),
              if (chunkIndex == 0 && metaBytes != null && metaFileName != null)
                'metaFile': MultipartFile.fromBytes(metaBytes, filename: metaFileName),
              if (chunkIndex == 0 && datBytes != null && datFileName != null)
                'datFiles': MultipartFile.fromBytes(datBytes, filename: datFileName),
              if (chunkIndex == 0 && metaKey != null && metaKey.isNotEmpty)
                'metaKey': metaKey,
            };

            final currentFormData = FormData.fromMap(formMap);

            final response = await _dio.post(
              '$apiUrl/decrypt',
              data: currentFormData,
              options: Options(
                sendTimeout: const Duration(minutes: 5),
                receiveTimeout: const Duration(minutes: 10),
                headers: {
                  'x-client-type': clientType,
                  if (clientBookPath != null && clientBookPath.isNotEmpty)
                    'x-client-book-path': Uri.encodeComponent(clientBookPath),
                  if (bookNo != null && bookNo.isNotEmpty) 'x-book-no': bookNo,
                  if (metaKey != null && metaKey.isNotEmpty) 'x-meta-key': metaKey,
                },
              ),
              cancelToken: cancelToken,
              onSendProgress: (sent, total) {
                final double chunkFraction = (total > 0) ? (sent / total).clamp(0.0, 1.0) : 0.0;
                // 소켓 송신 단계에서는 최대 85%까지만 반영 (서버 수신 응답 완료 시 100% 확정)
                final int chunkSent = min(
                  (currentChunkSize * 0.85).round(),
                  (currentChunkSize * chunkFraction * 0.85).round(),
                );
                chunkSentBytes[chunkIndex] = chunkSent;
                if (sent >= total) {
                  chunkFlushed[chunkIndex] = true;
                }
                if (completedCount >= totalChunks - 1 && chunkFlushed.every((f) => f)) {
                  assemblingStarted = true;
                }
                updateProgress();
              },
            );

            chunkSentBytes[chunkIndex] = currentChunkSize;
            chunkFlushed[chunkIndex] = true;
            completedCount++;
            if (completedCount >= totalChunks - 1) {
              assemblingStarted = true;
            }
            updateProgress();

            if (response.statusCode == 200 && response.data is Map<String, dynamic>) {
              if (response.data['success'] != true) {
                final msg = extractServerErrorMessage(response.data) ?? '청크 [$chunkIndex] 처리 실패';
                throw Exception(msg);
              }
              final filesList = (response.data['files'] as List<dynamic>?)
                  ?.map((e) => DecryptedFileResult.fromJson(e as Map<String, dynamic>))
                  .toList();
              if (filesList != null && filesList.isNotEmpty) {
                finalResults = filesList;
              }
            } else {
              final msg = extractServerErrorMessage(response.data) ?? '청크 [$chunkIndex] 응답 오류';
              throw Exception(msg);
            }
            break; // 해당 청크 성공
          } catch (postErr) {
            if (cancelToken?.isCancelled == true) rethrow;
            if (postErr is DioException &&
                postErr.response?.statusCode != null &&
                postErr.response!.statusCode! >= 400 &&
                postErr.response!.statusCode! < 500) {
              rethrow;
            }
            if (chunkRetryCount >= maxChunkRetries) {
              rethrow;
            }
            chunkRetryCount++;
            onStatusUpdate?.call(
              '청크 [${chunkIndex + 1}/$totalChunks] 재시도 중 ($chunkRetryCount/$maxChunkRetries)...',
            );
            await Future.delayed(const Duration(milliseconds: 1000));
          }
        }
      }
    }

    await Future.wait(List.generate(workerCount, (_) => runWorker()));

    if (finalResults == null || finalResults!.isEmpty) {
      throw Exception('모든 청크가 전송되었으나 서버에서 복호화 완료 결과를 받지 못했습니다.');
    }
    return finalResults!;
  }

  /// 5. 복호화 완료 파일 다운로드
  /// GET /api/download/:token
  Future<String> downloadFile({
    String? rawUrl,
    String? downloadUrl,
    String? token,
    required String savePath,
    int? fileSize,
    bool parallel = true,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    final apiUrl = normalizeApiUrl(rawUrl);
    String fullUrl;
    if (token != null && token.isNotEmpty) {
      fullUrl = '$apiUrl/download/$token';
    } else if (downloadUrl != null && downloadUrl.isNotEmpty) {
      if (downloadUrl.startsWith('http://') || downloadUrl.startsWith('https://')) {
        fullUrl = downloadUrl;
      } else {
        final hostRoot = apiUrl.replaceAll(RegExp(r'/api$'), '');
        final cleanRel = downloadUrl.startsWith('/') ? downloadUrl : '/$downloadUrl';
        fullUrl = '$hostRoot$cleanRel';
      }
    } else {
      throw ArgumentError('downloadUrl 또는 token이 필요합니다.');
    }

    final targetFile = File(savePath);
    await targetFile.parent.create(recursive: true);

    const int parallelThreshold = 5 * 1024 * 1024; // 5MB 이상 파일은 다중 스트림 병렬 다운로드 수행
    const int dynamicChunkSize = 2560 * 1024; // 2.5MB 청크 단위 동적 작업 큐
    const int maxWorkers = 8; // 고지연 회선 대역폭 확장을 위해 동시 8개 독립 연결 풀 유지

    if (parallel && fileSize != null && fileSize >= parallelThreshold) {
      final int totalChunks = (fileSize / dynamicChunkSize).ceil();
      final List<_DownloadSlice> slices = [];
      for (int i = 0; i < totalChunks; i++) {
        final int start = i * dynamicChunkSize;
        if (start >= fileSize) break;
        final int end = min(fileSize - 1, start + dynamicChunkSize - 1);
        slices.add(_DownloadSlice(index: i, start: start, end: end));
      }

      final List<int> sliceReceivedBytes = List.filled(slices.length, 0);
      final List<File> tempPartFiles = [];
      int nextSliceIndex = 0;

      void updateProgress() {
        final totalRec = min(fileSize, sliceReceivedBytes.reduce((a, b) => a + b));
        onReceiveProgress?.call(totalRec, fileSize);
      }

      try {
        Future<void> runWorker() async {
          while (true) {
            if (cancelToken?.isCancelled == true) break;
            if (nextSliceIndex >= slices.length) break;
            final slice = slices[nextSliceIndex++];

            final tempPartFile = File('$savePath.part_${slice.index}.tmp');
            tempPartFiles.add(tempPartFile);

            final sep = fullUrl.contains('?') ? '&' : '?';
            final sliceUrl =
                '$fullUrl${sep}part=${slice.index}&start=${slice.start}&end=${slice.end}';

            int retries = 0;
            while (true) {
              try {
                await _dio.download(
                  sliceUrl,
                  tempPartFile.path,
                  cancelToken: cancelToken,
                  options: Options(
                    headers: {
                      'X-Parallel-Download': '1',
                      'Range': 'bytes=${slice.start}-${slice.end}',
                    },
                    responseType: ResponseType.bytes,
                    followRedirects: true,
                  ),
                  onReceiveProgress: (rec, _) {
                    sliceReceivedBytes[slice.index] = rec;
                    updateProgress();
                  },
                );
                break; // 해당 청크 다운로드 성공
              } catch (e) {
                retries++;
                if (retries >= 3 || cancelToken?.isCancelled == true) {
                  rethrow;
                }
                await Future.delayed(const Duration(milliseconds: 300));
              }
            }
          }
        }

        final workerCount = min(maxWorkers, slices.length);
        await Future.wait(List.generate(workerCount, (_) => runWorker()));

        if (cancelToken?.isCancelled == true) {
          throw DioException(
            requestOptions: RequestOptions(path: fullUrl),
            type: DioExceptionType.cancel,
            message: '다운로드가 취소되었습니다.',
          );
        }

        // 모든 청크 파트 파일 순서대로 병합
        final sink = targetFile.openWrite();
        for (int i = 0; i < slices.length; i++) {
          final partFile = File('$savePath.part_$i.tmp');
          if (await partFile.exists()) {
            await sink.addStream(partFile.openRead());
            await partFile.delete().catchError((_) => partFile);
          }
        }
        await sink.close();
      } catch (err) {
        // 오류 발생 시 임시 파일 정리
        for (final pf in tempPartFiles) {
          if (await pf.exists()) {
            await pf.delete().catchError((_) => pf);
          }
        }
        if (await targetFile.exists()) {
          await targetFile.delete().catchError((_) => targetFile);
        }
        rethrow;
      }
    } else {
      await _dio.download(
        fullUrl,
        targetFile.path,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
        ),
      );
    }

    // 1회용 토큰 다운로드 API(/api/download/:token) 전용 완료 알림 (완료 신호 수신 시 서버 토큰 소진)
    if (fullUrl.contains('/api/download/')) {
      try {
        final sep = fullUrl.contains('?') ? '&' : '?';
        await _dio.get('$fullUrl${sep}complete=1');
      } catch (_) {
        // ignore
      }
    }

    return targetFile.path;
  }

  /// 6. 네트워크 지연 시간 (Ping) 측정
  Future<int> measurePing([String? rawUrl]) async {
    final apiUrl = normalizeApiUrl(rawUrl);
    final sw = Stopwatch()..start();
    try {
      await _dio.head(
        '$apiUrl/speedtest',
        options: Options(
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
    } catch (_) {
      await _dio.get(
        '$apiUrl/backend-status',
        options: Options(
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
    }
    sw.stop();
    return sw.elapsedMilliseconds;
  }

  /// 7. 네트워크 속도 측정 (기본 20MB / 100MB, 단일/분할 지원, 30초 타임아웃 조기 완료, 원시 바이너리 스트리밍)
  Future<SpeedTestResult> runSpeedTest({
    String? rawUrl,
    int testBytes = 20 * 1024 * 1024,
    bool parallel = false,
    void Function(SpeedTestProgress progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final apiUrl = normalizeApiUrl(rawUrl);

    final int effectiveTestBytes = (testBytes >= 90 * 1024 * 1024)
        ? 90 * 1024 * 1024
        : max(1024 * 1024, testBytes);
    final int labelMb = (testBytes >= 90 * 1024 * 1024) ? 90 : (effectiveTestBytes / (1024 * 1024)).round();
    final String modeLabel = parallel ? '분할' : '단일';

    // 1단계: Ping 측정
    onProgress?.call(SpeedTestProgress(stage: 'ping', message: '서버 지연 시간(Ping) 측정 중...'));
    final ping = await measurePing(apiUrl);
    onProgress?.call(SpeedTestProgress(stage: 'ping', pingMs: ping, message: 'Ping: ${ping}ms'));

    // 2단계: 다운로드 속도 측정 (최대 30초 제한)
    onProgress?.call(SpeedTestProgress(
      stage: 'download',
      totalBytes: effectiveTestBytes,
      pingMs: ping,
      message: '$labelMb MB ($modeLabel) 다운로드 속도 측정 중...',
    ));

    final tempDir = Directory.systemTemp;
    final tempDownloadFile = File(
      p.join(tempDir.path, 'aegisreader_speedtest_dl_${DateTime.now().millisecondsSinceEpoch}.bin'),
    );

    final dlStageCancelToken = CancelToken();
    cancelToken?.whenCancel.then((_) {
      if (!dlStageCancelToken.isCancelled) {
        dlStageCancelToken.cancel('사용자 취소');
      }
    });

    bool dlTimedOut = false;
    final dlTimer = Timer(const Duration(seconds: 30), () {
      dlTimedOut = true;
      if (!dlStageCancelToken.isCancelled) {
        dlStageCancelToken.cancel('30초 경과로 조기 산출');
      }
    });

    final dlStopwatch = Stopwatch()..start();
    DateTime lastDlUi = DateTime.now();
    double dlSpeedMBs = 0;
    double dlSpeedMbps = 0;
    int dlRecordedBytes = 0;

    try {
      await downloadFile(
        rawUrl: apiUrl,
        downloadUrl: '$apiUrl/speedtest?size=$effectiveTestBytes',
        savePath: tempDownloadFile.path,
        fileSize: effectiveTestBytes,
        parallel: parallel,
        cancelToken: dlStageCancelToken,
        onReceiveProgress: (rec, total) {
          dlRecordedBytes = rec;
          final now = DateTime.now();
          if (now.difference(lastDlUi).inMilliseconds >= 80 || rec >= effectiveTestBytes) {
            lastDlUi = now;
            final elapsedSec = max(0.05, dlStopwatch.elapsedMilliseconds / 1000.0);
            dlSpeedMBs = (rec / (1024 * 1024)) / elapsedSec;
            dlSpeedMbps = dlSpeedMBs * 8.0;
            onProgress?.call(SpeedTestProgress(
              stage: 'download',
              currentBytes: rec,
              totalBytes: effectiveTestBytes,
              currentSpeedMBs: dlSpeedMBs,
              currentSpeedMbps: dlSpeedMbps,
              pingMs: ping,
              message: '다운로드 ($modeLabel): ${dlSpeedMBs.toStringAsFixed(1)} MB/s (${dlSpeedMbps.toStringAsFixed(1)} Mbps)',
            ));
          }
        },
      );
    } catch (e) {
      if (cancelToken?.isCancelled == true) {
        rethrow;
      }
      if (!dlTimedOut) {
        rethrow;
      }
    } finally {
      dlTimer.cancel();
      dlStopwatch.stop();
      if (await tempDownloadFile.exists()) {
        await tempDownloadFile.delete().catchError((_) => tempDownloadFile);
      }
    }

    final dlDurationMs = max(1, dlStopwatch.elapsedMilliseconds);
    final finalDlBytes = dlTimedOut ? dlRecordedBytes : effectiveTestBytes;
    final finalDlMBs = (finalDlBytes / (1024 * 1024)) / (dlDurationMs / 1000.0);
    final finalDlMbps = finalDlMBs * 8.0;

    // 3단계: 업로드 속도 측정 (최대 30초 제한, 인메모리 스트리밍 전송으로 디스크 I/O 병목 및 multipart 413 방어)
    onProgress?.call(SpeedTestProgress(
      stage: 'upload',
      totalBytes: effectiveTestBytes,
      currentSpeedMBs: finalDlMBs,
      currentSpeedMbps: finalDlMbps,
      pingMs: ping,
      message: '$labelMb MB ($modeLabel) 업로드 속도 측정 중...',
    ));

    final upStageCancelToken = CancelToken();
    cancelToken?.whenCancel.then((_) {
      if (!upStageCancelToken.isCancelled) {
        upStageCancelToken.cancel('사용자 취소');
      }
    });

    bool upTimedOut = false;
    final upTimer = Timer(const Duration(seconds: 30), () {
      upTimedOut = true;
      if (!upStageCancelToken.isCancelled) {
        upStageCancelToken.cancel('30초 경과로 조기 산출');
      }
    });

    final upStopwatch = Stopwatch()..start();
    DateTime lastUpUi = DateTime.now();
    double upSpeedMBs = 0;
    double upSpeedMbps = 0;
    int upRecordedBytes = 0;
    int windowBytes = 0;
    int windowMs = 0;
    double smoothedMBs = 0;

    try {
      if (parallel && effectiveTestBytes >= 5 * 1024 * 1024) {
        const int upChunkSize = 2560 * 1024;
        const int maxUpWorkers = 6;
        final int totalChunks = (effectiveTestBytes / upChunkSize).ceil();

        final List<int> chunkSentList = List.filled(totalChunks, 0);
        int nextChunkIdx = 0;

        void updateUpProgress() {
          final totalSent = min(effectiveTestBytes, chunkSentList.reduce((a, b) => a + b));
          upRecordedBytes = totalSent;
          final now = DateTime.now();
          if (now.difference(lastUpUi).inMilliseconds >= 80 || totalSent >= effectiveTestBytes) {
            lastUpUi = now;
            final elapsedMs = upStopwatch.elapsedMilliseconds;
            final elapsedSec = max(0.1, elapsedMs / 1000.0);

            final dTime = (elapsedMs - windowMs) / 1000.0;
            if (dTime >= 0.35) {
              final dBytes = totalSent - windowBytes;
              final instantMBs = max(0.0, (dBytes / (1024 * 1024)) / dTime);
              smoothedMBs = (smoothedMBs == 0)
                  ? instantMBs
                  : (smoothedMBs * 0.35 + instantMBs * 0.65);
              windowBytes = totalSent;
              windowMs = elapsedMs;
            }

            upSpeedMBs = (smoothedMBs > 0)
                ? smoothedMBs
                : ((totalSent / (1024 * 1024)) / elapsedSec);
            upSpeedMbps = upSpeedMBs * 8.0;

            onProgress?.call(SpeedTestProgress(
              stage: 'upload',
              currentBytes: totalSent,
              totalBytes: effectiveTestBytes,
              currentSpeedMBs: upSpeedMBs,
              currentSpeedMbps: upSpeedMbps,
              pingMs: ping,
              message: '업로드 ($modeLabel): ${upSpeedMBs.toStringAsFixed(1)} MB/s (${upSpeedMbps.toStringAsFixed(1)} Mbps)',
            ));
          }
        }

        Future<void> runUpWorker() async {
          while (true) {
            if (upStageCancelToken.isCancelled || upTimedOut) break;
            if (nextChunkIdx >= totalChunks) break;
            final chunkIdx = nextChunkIdx++;

            final start = chunkIdx * upChunkSize;
            final end = min(start + upChunkSize, effectiveTestBytes);
            final chunkSize = end - start;

            try {
              await _dio.post(
                '$apiUrl/speedtest',
                data: _createDummyStream(chunkSize),
                cancelToken: upStageCancelToken,
                options: Options(
                  headers: {
                    'Content-Type': 'application/octet-stream',
                    'Content-Length': chunkSize.toString(),
                  },
                ),
                onSendProgress: (sent, _) {
                  chunkSentList[chunkIdx] = sent;
                  updateUpProgress();
                },
              );
              chunkSentList[chunkIdx] = chunkSize;
              updateUpProgress();
            } catch (e) {
              if (upStageCancelToken.isCancelled || upTimedOut) break;
              rethrow;
            }
          }
        }

        final workerCount = min(maxUpWorkers, totalChunks);
        await Future.wait(List.generate(workerCount, (_) => runUpWorker()));
      } else {
        // 단일 업로드 모드: 전체 바이트를 단 1개의 HTTP POST 스트림으로 인메모리 스트리밍 전송
        await _dio.post(
          '$apiUrl/speedtest',
          data: _createDummyStream(effectiveTestBytes),
          cancelToken: upStageCancelToken,
          options: Options(
            headers: {
              'Content-Type': 'application/octet-stream',
              'Content-Length': effectiveTestBytes.toString(),
            },
          ),
          onSendProgress: (sent, total) {
            upRecordedBytes = sent;
            final now = DateTime.now();
            if (now.difference(lastUpUi).inMilliseconds >= 80 || sent >= effectiveTestBytes) {
              lastUpUi = now;
              final elapsedMs = upStopwatch.elapsedMilliseconds;
              final elapsedSec = max(0.1, elapsedMs / 1000.0);

              final dTime = (elapsedMs - windowMs) / 1000.0;
              if (dTime >= 0.35) {
                final dBytes = sent - windowBytes;
                final instantMBs = max(0.0, (dBytes / (1024 * 1024)) / dTime);
                smoothedMBs = (smoothedMBs == 0)
                    ? instantMBs
                    : (smoothedMBs * 0.35 + instantMBs * 0.65);
                windowBytes = sent;
                windowMs = elapsedMs;
              }

              upSpeedMBs = (smoothedMBs > 0)
                  ? smoothedMBs
                  : ((sent / (1024 * 1024)) / elapsedSec);
              upSpeedMbps = upSpeedMBs * 8.0;

              onProgress?.call(SpeedTestProgress(
                stage: 'upload',
                currentBytes: sent,
                totalBytes: effectiveTestBytes,
                currentSpeedMBs: upSpeedMBs,
                currentSpeedMbps: upSpeedMbps,
                pingMs: ping,
                message: '업로드 ($modeLabel): ${upSpeedMBs.toStringAsFixed(1)} MB/s (${upSpeedMbps.toStringAsFixed(1)} Mbps)',
              ));
            }
          },
        );
      }
    } catch (e) {
      if (cancelToken?.isCancelled == true) {
        rethrow;
      }
      if (!upTimedOut) {
        rethrow;
      }
    } finally {
      upTimer.cancel();
      upStopwatch.stop();
    }

    final upDurationMs = max(1, upStopwatch.elapsedMilliseconds);
    final finalUpBytes = upTimedOut ? upRecordedBytes : effectiveTestBytes;
    final finalUpMBs = (finalUpBytes / (1024 * 1024)) / (upDurationMs / 1000.0);
    final finalUpMbps = finalUpMBs * 8.0;

    final result = SpeedTestResult(
      pingMs: ping,
      downloadSpeedMBs: finalDlMBs,
      downloadSpeedMbps: finalDlMbps,
      downloadBytes: finalDlBytes,
      downloadDurationMs: dlDurationMs,
      downloadTimedOut: dlTimedOut,
      uploadSpeedMBs: finalUpMBs,
      uploadSpeedMbps: finalUpMbps,
      uploadBytes: finalUpBytes,
      uploadDurationMs: upDurationMs,
      uploadTimedOut: upTimedOut,
      targetBytes: effectiveTestBytes,
      isParallel: parallel,
    );

    onProgress?.call(SpeedTestProgress(
      stage: 'done',
      totalBytes: effectiveTestBytes,
      currentSpeedMBs: finalDlMBs,
      currentSpeedMbps: finalDlMbps,
      pingMs: ping,
      message: '속도 측정 완료!',
    ));

    return result;
  }
}

class SpeedTestResult {
  final int pingMs;
  final double downloadSpeedMBs;
  final double downloadSpeedMbps;
  final int downloadBytes;
  final int downloadDurationMs;
  final bool downloadTimedOut;
  final double uploadSpeedMBs;
  final double uploadSpeedMbps;
  final int uploadBytes;
  final int uploadDurationMs;
  final bool uploadTimedOut;
  final int targetBytes;
  final bool isParallel;

  SpeedTestResult({
    required this.pingMs,
    required this.downloadSpeedMBs,
    required this.downloadSpeedMbps,
    required this.downloadBytes,
    required this.downloadDurationMs,
    this.downloadTimedOut = false,
    required this.uploadSpeedMBs,
    required this.uploadSpeedMbps,
    required this.uploadBytes,
    required this.uploadDurationMs,
    this.uploadTimedOut = false,
    required this.targetBytes,
    this.isParallel = false,
  });
}

class SpeedTestProgress {
  final String stage; // 'ping', 'download', 'upload', 'done', 'error'
  final int currentBytes;
  final int totalBytes;
  final double currentSpeedMBs;
  final double currentSpeedMbps;
  final int? pingMs;
  final String message;

  SpeedTestProgress({
    required this.stage,
    this.currentBytes = 0,
    this.totalBytes = 0,
    this.currentSpeedMBs = 0.0,
    this.currentSpeedMbps = 0.0,
    this.pingMs,
    this.message = '',
  });
}

class _DownloadSlice {
  final int index;
  final int start;
  final int end;
  _DownloadSlice({required this.index, required this.start, required this.end});
}

/// 하위 호환성 타입 정의
typedef ApiService = AegisReaderApiService;
