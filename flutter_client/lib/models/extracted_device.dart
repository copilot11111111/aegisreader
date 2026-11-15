class ExtractedDevice {
  final String deviceId;
  final String deviceName;
  final String deviceType;
  final int isAuth;

  const ExtractedDevice({
    required this.deviceId,
    this.deviceName = '',
    this.deviceType = 'PC_Aladin',
    this.isAuth = 1,
  });

  factory ExtractedDevice.fromJson(Map<String, dynamic> json) {
    return ExtractedDevice(
      deviceId: json['deviceId']?.toString() ?? '',
      deviceName: json['deviceName']?.toString() ?? '',
      deviceType: json['deviceType']?.toString() ?? 'PC_Aladin',
      isAuth: (json['isAuth'] as num?)?.toInt() ?? 1,
    );
  }

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'deviceType': deviceType,
        'isAuth': isAuth,
      };

  @override
  String toString() => 'ExtractedDevice(id: $deviceId, name: $deviceName, type: $deviceType, isAuth: $isAuth)';
}

class AladinMetaBook {
  final String itemId;
  final String title;
  final String filePath;
  final String downloadKeyId;
  final String downloadKeyEnc;
  final int drmType;

  const AladinMetaBook({
    required this.itemId,
    this.title = '',
    this.filePath = '',
    this.downloadKeyId = '',
    this.downloadKeyEnc = '',
    this.drmType = 0,
  });

  factory AladinMetaBook.fromJson(Map<String, dynamic> json) {
    return AladinMetaBook(
      itemId: json['itemId']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      filePath: json['filePath']?.toString() ?? '',
      downloadKeyId: json['downloadKeyId']?.toString() ?? '',
      downloadKeyEnc: json['downloadKeyEnc']?.toString() ?? '',
      drmType: (json['drmType'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'itemId': itemId,
        'title': title,
        'filePath': filePath,
        'downloadKeyId': downloadKeyId,
        'downloadKeyEnc': downloadKeyEnc,
        'drmType': drmType,
      };

  @override
  String toString() =>
      'AladinMetaBook(itemId: $itemId, title: $title, dlKeyId: $downloadKeyId, dlKeyEnc: ${downloadKeyEnc.isNotEmpty ? "yes" : "no"})';
}
