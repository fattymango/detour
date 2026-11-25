import 'package:equatable/equatable.dart';

class AdBlockedDomain extends Equatable {
  const AdBlockedDomain({required this.domain, required this.timestamp});

  factory AdBlockedDomain.fromMap(Map<dynamic, dynamic> map) {
    final millis = map['timestampMillis'] as int? ?? 0;
    return AdBlockedDomain(
      domain: map['domain'] as String? ?? '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(millis),
    );
  }

  final String domain;
  final DateTime timestamp;

  @override
  List<Object?> get props => [domain, timestamp];
}
