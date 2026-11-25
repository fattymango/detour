import 'package:equatable/equatable.dart';

class ServerUser extends Equatable {
  const ServerUser({
    required this.username,
    required this.isAdmin,
    required this.connected,
    this.invitePending = false,
    this.speedKbps = 0,
    this.quotaBytes = 0,
    this.usedBytes = 0,
  });

  factory ServerUser.fromMap(Map<dynamic, dynamic> map) => ServerUser(
        username: map['username'] as String,
        isAdmin: map['admin'] as bool,
        connected: map['connected'] as int,
        invitePending: map['invite'] as bool? ?? false,
        speedKbps: map['speedKbps'] as int,
        quotaBytes: map['quotaBytes'] as int,
        usedBytes: map['usedBytes'] as int,
      );

  final String username;
  final bool isAdmin;

  /// Whether their invite link hasn't been used yet.
  final bool invitePending;

  /// How many devices are connected as this user right now.
  final int connected;

  /// Speed limit in each direction, shared by all their devices. 0 is unlimited.
  final int speedKbps;

  /// Data allowance, upload plus download. 0 is unlimited.
  final int quotaBytes;
  final int usedBytes;

  @override
  List<Object?> get props => [username, isAdmin, invitePending, connected, speedKbps, quotaBytes, usedBytes];
}
