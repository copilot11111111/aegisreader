class ExtractedDevice {
  final String deviceId;
  final String deviceName;

  const ExtractedDevice({
    required this.deviceId,
    this.deviceName = '',
  });

  factory ExtractedDevice.fromJson(Map<String, dynamic> json) {
    return ExtractedDevice(
      deviceId: json['deviceId']?.toString() ?? '',
      deviceName: json['deviceName']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
      };

  @override
  String toString() => 'ExtractedDevice(id: $deviceId, name: $deviceName)';
}
