class ServerStatus {
  final bool online;
  final String? lastSeenAt;
  final String? recommendedWindowText;
  final bool service1Active;
  final bool service2Active;
  final bool service3Active;
  final int last7DaysTotal;
  final int allTimeTotal;

  ServerStatus({
    required this.online,
    this.lastSeenAt,
    this.recommendedWindowText,
    this.service1Active = true,
    this.service2Active = true,
    this.service3Active = true,
    this.last7DaysTotal = 0,
    this.allTimeTotal = 0,
  });

  factory ServerStatus.offline() {
    return ServerStatus(
      online: false,
      recommendedWindowText: '서버와 연결할 수 없습니다',
      service1Active: false,
      service2Active: false,
      service3Active: false,
    );
  }

  factory ServerStatus.fromJson(Map<String, dynamic> json) {
    final services = json['services'] as Map<String, dynamic>? ?? {};
    final usage = json['serviceUsage'] as Map<String, dynamic>? ?? {};
    final last7 = usage['last7Days'] as Map<String, dynamic>? ?? {};
    final allTime = usage['allTime'] as Map<String, dynamic>? ?? {};

    bool parseActive(dynamic val) {
      if (val is bool) return val;
      if (val is Map && val['active'] is bool) return val['active'] as bool;
      return true;
    }

    return ServerStatus(
      online: json['online'] == true,
      lastSeenAt: json['lastSeenAt']?.toString(),
      recommendedWindowText: json['recommendedWindowText']?.toString(),
      service1Active: parseActive(services['service1']),
      service2Active: parseActive(services['service2']),
      service3Active: parseActive(services['service3']),
      last7DaysTotal: (last7['total'] as num?)?.toInt() ?? 0,
      allTimeTotal: (allTime['total'] as num?)?.toInt() ?? 0,
    );
  }

  bool isServiceActive(String serviceId) {
    switch (serviceId) {
      case 'service1':
        return service1Active;
      case 'service2':
        return service2Active;
      case 'service3':
        return service3Active;
      default:
        return true;
    }
  }
}
