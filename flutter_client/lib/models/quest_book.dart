import 'device_status.dart';

class QuestBook {
  final String id;
  final String name;
  final Map<String, String?> links;
  final List<String> services;

  QuestBook({
    required this.id,
    required this.name,
    required this.links,
    required this.services,
  });

  static String _normalizeServiceKey(String raw) {
    final trimmed = raw.trim().toLowerCase();
    if (trimmed == '1' || trimmed == 'service1') return '1';
    if (trimmed == '2' || trimmed == 'service2') return '2';
    if (trimmed == '3' || trimmed == 'service3') return '3';
    return trimmed;
  }

  factory QuestBook.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    final name = json['name']?.toString().trim() ?? '';

    final parsedLinks = <String, String?>{
      '1': null,
      '2': null,
      '3': null,
    };

    final rawLink = json['link'];
    if (rawLink is String && rawLink.trim().startsWith('http')) {
      parsedLinks['1'] = rawLink.trim();
    } else if (rawLink is Map) {
      for (final key in ['1', '2', '3']) {
        final val = rawLink[key] ?? rawLink['service$key'];
        if (val is String && val.trim().startsWith('http')) {
          parsedLinks[key] = val.trim();
        }
      }
    }

    final parsedServices = <String>[];
    final rawServices = json['services'];
    if (rawServices is List) {
      for (final item in rawServices) {
        if (item == null) continue;
        final norm = _normalizeServiceKey(item.toString());
        if ((norm == '1' || norm == '2' || norm == '3') &&
            !parsedServices.contains(norm)) {
          parsedServices.add(norm);
        }
      }
    }

    if (parsedServices.isEmpty) {
      parsedServices.addAll(['1', '2', '3']);
    }

    return QuestBook(
      id: id,
      name: name,
      links: parsedLinks,
      services: parsedServices,
    );
  }

  bool supportsService(String serviceKey) {
    final norm = _normalizeServiceKey(serviceKey);
    return services.contains(norm);
  }

  String? linkForService(String serviceKey) {
    final norm = _normalizeServiceKey(serviceKey);
    return links[norm];
  }

  bool isCompletedBy(DeviceStatus? status) {
    if (status == null) return false;
    if (id.isNotEmpty && status.completedQuests.contains(id)) {
      return true;
    }
    if (name.isNotEmpty && status.completedBooks.isNotEmpty) {
      final cleanTarget =
          name.replaceAll(RegExp(r'[\s_\-–—()\[\]]'), '').toLowerCase();
      if (cleanTarget.isEmpty) return false;
      final targetVolMatch = RegExp(r'(\d+)$').firstMatch(cleanTarget);

      for (final cb in status.completedBooks) {
        final cleanCb =
            cb.replaceAll(RegExp(r'[\s_\-–—()\[\]]'), '').toLowerCase();
        if (cleanCb.isEmpty) continue;
        if (cleanCb == cleanTarget) return true;

        final cbVolMatch = RegExp(r'(\d+)$').firstMatch(cleanCb);
        if (targetVolMatch != null || cbVolMatch != null) {
          if (targetVolMatch?.group(1) == cbVolMatch?.group(1) &&
              (cleanCb.contains(cleanTarget) ||
                  cleanTarget.contains(cleanCb))) {
            return true;
          }
          continue;
        }
        if (cleanCb.contains(cleanTarget) || cleanTarget.contains(cleanCb)) {
          return true;
        }
      }
    }
    return false;
  }
}
