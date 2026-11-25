import 'package:equatable/equatable.dart';

class TunnelConfig extends Equatable {
  const TunnelConfig({
    required this.name,
    required this.includedApplications,
    this.endpointHost,
    this.endpointPort,
    this.username,
  });

  factory TunnelConfig.fromMap(Map<dynamic, dynamic> map) {
    return TunnelConfig(
      name: map['name'] as String,
      includedApplications: List<String>.from(
        map['includedApplications'] as List? ?? const [],
      ),
      endpointHost: map['endpointHost'] as String?,
      endpointPort: (map['endpointPort'] as num?)?.toInt(),
      username: map['username'] as String?,
    );
  }

  final String name;
  final List<String> includedApplications;
  final String? endpointHost;
  final int? endpointPort;

  /// Only set by a preview.
  final String? username;

  @override
  List<Object?> get props => [name, includedApplications, endpointHost, endpointPort, username];
}
