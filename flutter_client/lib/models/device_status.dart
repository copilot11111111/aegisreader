class DeviceStatus {
  final bool isPremium;
  final String serviceId;
  final String deviceId;
  final int remainingDays;
  final String? expireTime;
  final List<String> completedQuests;
  final List<String> completedBooks;
  final int? quotaLimit;
  final int quotaUsed;
  final int? quotaRemaining;
  final int quotaResetInMinutes;

  DeviceStatus({
    required this.isPremium,
    required this.serviceId,
    required this.deviceId,
    this.remainingDays = 0,
    this.expireTime,
    this.completedQuests = const [],
    this.completedBooks = const [],
    this.quotaLimit,
    this.quotaUsed = 0,
    this.quotaRemaining,
    this.quotaResetInMinutes = 0,
  });

  /// 오늘 남은 무료 쿼터 수
  int get remainingQuota =>
      quotaRemaining ?? ((quotaLimit ?? 50) - quotaUsed).clamp(0, 99999);

  /// 하루 제공 쿼터 한도 (기본 50)
  int get dailyQuota => quotaLimit ?? 50;

  /// 프리미엄 만료 일시 파싱
  DateTime? get expiresAt {
    if (expireTime == null || expireTime!.isEmpty) return null;
    return DateTime.tryParse(expireTime!);
  }

  factory DeviceStatus.empty(String serviceId, String deviceId) {
    return DeviceStatus(
      isPremium: false,
      serviceId: serviceId,
      deviceId: deviceId,
      quotaLimit: 50,
      quotaUsed: 0,
      quotaRemaining: 50,
      quotaResetInMinutes: 0,
    );
  }

  factory DeviceStatus.fromJson(Map<String, dynamic> json) {
    final quota = json['quota'] as Map<String, dynamic>? ?? {};
    final quests = (json['completedQuests'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];
    final books = (json['completedBooks'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];

    final isPrem = json['isPremium'] == true;

    return DeviceStatus(
      isPremium: isPrem,
      serviceId: json['serviceId']?.toString() ?? json['service']?.toString() ?? '',
      deviceId: json['deviceId']?.toString() ?? '',
      remainingDays: (json['remainingDays'] as num?)?.toInt() ?? 0,
      expireTime: json['expireTime']?.toString() ?? json['date']?.toString(),
      completedQuests: quests,
      completedBooks: books,
      quotaLimit: (quota['limit'] as num?)?.toInt(),
      quotaUsed: (quota['used'] as num?)?.toInt() ?? 0,
      quotaRemaining: isPrem ? null : (quota['remaining'] as num?)?.toInt(),
      quotaResetInMinutes: (quota['resetInMinutes'] as num?)?.toInt() ?? 0,
    );
  }
}
