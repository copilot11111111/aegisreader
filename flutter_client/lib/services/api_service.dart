import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
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

  /// 분할 업로드 기준 파일 크기 (100MB 초과 도서 대상, HTTP 프록시 단일 요청 제한 100MB 및 헤더 마진을 감안하여 95MB 초과 시 자동 분할)
  static const int splitThresholdBytes = 95 * 1024 * 1024;

  /// 분할 청크 단위 크기 (50MB)
  static const int chunkSizeBytes = 50 * 1024 * 1024;

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
      return trimmed;
    }

    if (responseData is Map) {
      final nestedData = responseData['data'];
      if (nestedData is Map) {
        for (final key in const ['statusMessage', 'error', 'message']) {
          final val = nestedData[key]?.toString().trim();
          if (val != null && val.isNotEmpty && !isGenericHttpStatusPhrase(val)) {
            return val;
          }
        }
      }

      for (final key in const ['statusMessage', 'message', 'error']) {
        final val = responseData[key]?.toString().trim();
        if (val != null && val.isNotEmpty && !isGenericHttpStatusPhrase(val)) {
          return val;
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
      final statusCode = error.response?.statusCode;
      if (statusCode == 422) {
        return defaultGuideReason;
      }

      final serverMsg = extractServerErrorMessage(error.response?.data);
      if (serverMsg != null && serverMsg.isNotEmpty) {
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

  /// 1. aegisreader 서버 가동 상태 확인 (GET /api/backend-status)
  Future<ServerStatus> fetchServerStatus([String? rawUrl]) async {
    final apiUrl = normalizeApiUrl(rawUrl);
    try {
      Response response;
      response = await _dio.get('$apiUrl/backend-status');

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

    // 100MB 이하: 기존 단일 multipart 업로드
    if (fileLength <= splitThresholdBytes) {
      onStatusUpdate?.call('업로드 중...');
      final formMap = <String, dynamic>{
        'service': serviceId,
        'deviceId': deviceId.trim(),
        'removeWatermark': removeWatermark ? 'true' : 'false',
        'clientType': clientType,
        if (clientBookPath != null && clientBookPath.isNotEmpty) 'clientBookPath': clientBookPath,
        if (bookNo != null && bookNo.isNotEmpty) 'bookNo': bookNo,
        if (userNo != null && userNo.isNotEmpty) 'userno': userNo,
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

      final response = await _dio.post(
        '$apiUrl/decrypt',
        data: formData,
        options: Options(
          headers: {
            'x-client-type': clientType,
            if (clientBookPath != null && clientBookPath.isNotEmpty)
              'x-client-book-path': Uri.encodeComponent(clientBookPath),
            if (bookNo != null && bookNo.isNotEmpty) 'x-book-no': bookNo,
          },
        ),
        onSendProgress: (sent, total) {
          onSendProgress?.call(sent, total);
          if (total > 0 && sent >= total) {
            onStatusUpdate?.call('서버에서 복호화 진행 중...');
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

    // 100MB 초과: 분할 청크 업로드 (isSplit: true, isRawChunk: true)
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

    for (int chunkIndex = 0; chunkIndex < totalChunks; chunkIndex++) {
      if (cancelToken?.isCancelled == true) {
        throw DioException(
          requestOptions: RequestOptions(path: '$apiUrl/decrypt'),
          type: DioExceptionType.cancel,
          message: '사용자에 의해 분할 업로드가 취소되었습니다.',
        );
      }

      final startOffset = chunkIndex * chunkSizeBytes;
      final endOffset = min(startOffset + chunkSizeBytes, fileLength);
      final currentChunkSize = endOffset - startOffset;

      final isFinalChunk = (chunkIndex == totalChunks - 1);

      final startMb = (startOffset / (1024 * 1024)).toStringAsFixed(1);
      final chunkSizeMb = (currentChunkSize / (1024 * 1024)).toStringAsFixed(1);
      final totalMb = (fileLength / (1024 * 1024)).toStringAsFixed(1);

      onStatusUpdate?.call(
        '분할 업로드 중 [${chunkIndex + 1}/$totalChunks] 0.0 / $chunkSizeMb MB (전체 $startMb / $totalMb MB)',
      );

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
      };

      if (metaBytes != null && metaFileName != null) {
        formMap['metaFile'] = MultipartFile.fromBytes(
          metaBytes,
          filename: metaFileName,
        );
      }

      if (datBytes != null && datFileName != null) {
        formMap['datFiles'] = MultipartFile.fromBytes(
          datBytes,
          filename: datFileName,
        );
      }

      final formData = FormData.fromMap(formMap);

      DateTime lastUiUpdate = DateTime.now();

      final response = await _dio.post(
        '$apiUrl/decrypt',
        data: formData,
        options: Options(
          sendTimeout: const Duration(minutes: 5),
          receiveTimeout: isFinalChunk ? const Duration(minutes: 10) : const Duration(minutes: 3),
          headers: {
            'x-client-type': clientType,
            if (clientBookPath != null && clientBookPath.isNotEmpty)
              'x-client-book-path': Uri.encodeComponent(clientBookPath),
            if (bookNo != null && bookNo.isNotEmpty) 'x-book-no': bookNo,
          },
        ),
        cancelToken: cancelToken,
        onSendProgress: (sent, total) {
          final double chunkFraction = (total > 0) ? (sent / total).clamp(0.0, 1.0) : 0.0;
          final int chunkSent = min(currentChunkSize, (currentChunkSize * chunkFraction).round());
          final int overallSent = min(fileLength, startOffset + chunkSent);

          onSendProgress?.call(overallSent, fileLength);

          if (isFinalChunk && sent >= total) {
            onStatusUpdate?.call('서버에서 청크 재조립 및 복호화 진행 중...');
            return;
          }

          final now = DateTime.now();
          if (sent >= total || now.difference(lastUiUpdate).inMilliseconds >= 50) {
            lastUiUpdate = now;
            final chunkSentMb = (chunkSent / (1024 * 1024)).toStringAsFixed(1);
            final overallSentMb = (overallSent / (1024 * 1024)).toStringAsFixed(1);
            onStatusUpdate?.call(
              '분할 업로드 중 [${chunkIndex + 1}/$totalChunks] $chunkSentMb / $chunkSizeMb MB (전체 $overallSentMb / $totalMb MB)',
            );
          }
        },
      );

      if (!isFinalChunk) {
        if (response.statusCode != 200 ||
            response.data is! Map<String, dynamic> ||
            response.data['success'] != true) {
          final msg = extractServerErrorMessage(response.data) ??
              '청크 [${chunkIndex + 1}/$totalChunks] 전송 실패';
          throw Exception(msg);
        }
      } else {
        // 최종 청크 전송 완료 및 복호화 결과 수신
        if (response.statusCode == 200 && response.data is Map<String, dynamic>) {
          if (response.data['success'] != true) {
            final msg = extractServerErrorMessage(response.data) ?? '복호화 실패';
            throw Exception(msg);
          }
          final list = (response.data['files'] as List<dynamic>?)
                  ?.map((e) => DecryptedFileResult.fromJson(e as Map<String, dynamic>))
                  .toList() ??
              [];
          if (list.isEmpty) {
            throw Exception('서버에서 복호화 완료 파일을 반환하지 않았습니다.');
          }
          return list;
        } else {
          final msg = extractServerErrorMessage(response.data) ?? '복호화 실패';
          throw Exception(msg);
        }
      }
    }

    throw Exception('분할 업로드 처리가 비정상적으로 완료되었습니다.');
  }

  /// 5. 복호화 완료 파일 다운로드
  /// GET /api/download/:token
  Future<String> downloadFile({
    String? rawUrl,
    String? downloadUrl,
    String? token,
    required String savePath,
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

    // 다운로드 완료 알림 (complete=1)
    try {
      final sep = fullUrl.contains('?') ? '&' : '?';
      await _dio.get('$fullUrl${sep}complete=1');
    } catch (_) {
      // ignore
    }

    return targetFile.path;
  }
}

/// 하위 호환성 타입 정의
typedef ApiService = AegisReaderApiService;
