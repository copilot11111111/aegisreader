import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import '../models/server_status.dart';
import '../models/device_status.dart';
import '../models/extracted_device.dart';

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

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 180),
    sendTimeout: const Duration(seconds: 180),
  ));

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

  /// 3. 설정 파일에서 디바이스 ID 추출
  /// POST /api/deviceid (multipart: service, file, file_wal, file_shm)
  Future<List<ExtractedDevice>> extractDeviceIdFromFile({
    String? rawUrl,
    required String serviceId,
    required String filePath,
    String? walFilePath,
    String? shmFilePath,
  }) async {
    final apiUrl = normalizeApiUrl(rawUrl);
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('선택한 파일이 존재하지 않습니다: $filePath');
    }

    final Uint8List fileBytes;
    try {
      fileBytes = await file.readAsBytes();
    } on FileSystemException {
      rethrow;
    } catch (e) {
      throw FileSystemException('파일을 읽을 수 없습니다: $e', file.path);
    }

    final formMap = <String, dynamic>{
      'service': serviceId,
      'file': MultipartFile.fromBytes(
        fileBytes,
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
            formMap['file_wal'] = MultipartFile.fromBytes(
              walBytes,
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
            formMap['file_shm'] = MultipartFile.fromBytes(
              shmBytes,
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
      final msg = response.data?['statusMessage'] ?? 'Device ID 추출 실패';
      throw Exception(msg);
    }
  }

  /// 4. 도서 파일 복호화 요청
  /// POST /api/decrypt (multipart: service, deviceId, files, datFiles, removeWatermark)
  /// 100MB 초과 도서의 경우 단일 요청 100MB 제한을 방어하기 위해 자동으로 50MB 단위 분할 업로드(Chunked Upload) 수행
  Future<List<DecryptedFileResult>> decryptBook({
    String? rawUrl,
    required String serviceId,
    required String deviceId,
    required String filePath,
    String? datFilePath,
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
        'files': await MultipartFile.fromFile(
          bookFile.path,
          filename: p.basename(bookFile.path),
        ),
      };

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
          final msg = response.data['statusMessage'] ?? '복호화 실패';
          throw Exception(msg);
        }
        final list = (response.data['files'] as List<dynamic>?)
                ?.map((e) => DecryptedFileResult.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [];
        return list;
      } else {
        final msg = response.data?['statusMessage'] ?? '복호화 실패';
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
        'files': MultipartFile.fromStream(
          () => bookFile.openRead(startOffset, endOffset),
          currentChunkSize,
          filename: '$originalFileName.part_$chunkIndex',
        ),
      };

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
          final msg = (response.data is Map<String, dynamic>)
              ? response.data['statusMessage']
              : '청크 [${chunkIndex + 1}/$totalChunks] 전송 실패';
          throw Exception(msg ?? '청크 전송 실패');
        }
      } else {
        // 최종 청크 전송 완료 및 복호화 결과 수신
        if (response.statusCode == 200 && response.data is Map<String, dynamic>) {
          if (response.data['success'] != true) {
            final msg = response.data['statusMessage'] ?? '복호화 실패';
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
          final msg = (response.data is Map<String, dynamic>)
              ? response.data['statusMessage']
              : '복호화 실패';
          throw Exception(msg ?? '복호화 실패');
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
