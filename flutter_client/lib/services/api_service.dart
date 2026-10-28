import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import '../models/server_status.dart';
import '../models/device_status.dart';

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
  /// POST /api/deviceid (multipart: service, file)
  Future<List<String>> extractDeviceIdFromFile({
    String? rawUrl,
    required String serviceId,
    required String filePath,
  }) async {
    final apiUrl = normalizeApiUrl(rawUrl);
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('선택한 파일이 존재하지 않습니다: $filePath');
    }

    final formData = FormData.fromMap({
      'service': serviceId,
      'file': await MultipartFile.fromFile(
        file.path,
        filename: p.basename(file.path),
      ),
    });

    final response = await _dio.post(
      '$apiUrl/deviceid',
      data: formData,
    );

    if (response.statusCode == 200 && response.data is Map<String, dynamic>) {
      final ids = (response.data['deviceIds'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [];
      return ids;
    } else {
      final msg = response.data?['statusMessage'] ?? 'Device ID 추출 실패';
      throw Exception(msg);
    }
  }

  /// 4. 도서 파일 복호화 요청
  /// POST /api/decrypt (multipart: service, deviceId, files, datFiles, removeWatermark)
  Future<List<DecryptedFileResult>> decryptBook({
    String? rawUrl,
    required String serviceId,
    required String deviceId,
    required String filePath,
    String? datFilePath,
    bool removeWatermark = false,
    ProgressCallback? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    final apiUrl = normalizeApiUrl(rawUrl);
    final bookFile = File(filePath);
    if (!await bookFile.exists()) {
      throw Exception('업로드할 도서 파일이 존재하지 않습니다: $filePath');
    }

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
      onSendProgress: onSendProgress,
      cancelToken: cancelToken,
    );

    if (response.statusCode == 200 && response.data is Map<String, dynamic>) {
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
