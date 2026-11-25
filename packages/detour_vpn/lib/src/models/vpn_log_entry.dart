import 'package:equatable/equatable.dart';

class VpnLogEntry extends Equatable {
  const VpnLogEntry({required this.timestamp, required this.message});

  factory VpnLogEntry.fromMap(Map<dynamic, dynamic> map) {
    return VpnLogEntry(
      timestamp: DateTime.tryParse(map['timestamp'] as String? ?? '') ?? DateTime.now(),
      message: map['message'] as String? ?? '',
    );
  }

  final DateTime timestamp;
  final String message;

  @override
  List<Object?> get props => [timestamp, message];
}
