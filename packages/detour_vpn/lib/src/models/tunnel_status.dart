enum TunnelState { disconnected, connecting, connected, disconnecting, reconnecting, standby, error }

class TunnelStatus {
  const TunnelStatus({
    required this.state,
    this.activeConfigName,
    this.stats,
    this.errorMessage,
  });

  const TunnelStatus.initial() : this(state: TunnelState.disconnected);

  factory TunnelStatus.fromEvent(Map<dynamic, dynamic> event) {
    final rawState = event['state'] as String? ?? '';
    final state = switch (rawState) {
      'UP' => TunnelState.connected,
      'DOWN' => TunnelState.disconnected,
      'CONNECTING' => TunnelState.connecting,
      'STANDBY' => TunnelState.standby,
      'RECONNECTING' => TunnelState.reconnecting,
      _ when rawState.startsWith('ERROR') => TunnelState.error,
      _ => TunnelState.disconnected,
    };
    return TunnelStatus(
      state: state,
      activeConfigName: event['name'] as String?,
      stats: event['stats'] != null
          ? TunnelStats.fromMap(event['stats'] as Map)
          : null,
      errorMessage: rawState.startsWith('ERROR:') ? rawState.substring('ERROR:'.length) : null,
    );
  }

  final TunnelState state;
  final String? activeConfigName;
  final TunnelStats? stats;
  final String? errorMessage;

  TunnelStatus copyWith({
    TunnelState? state,
    String? activeConfigName,
    TunnelStats? stats,
    String? errorMessage,
  }) {
    return TunnelStatus(
      state: state ?? this.state,
      activeConfigName: activeConfigName ?? this.activeConfigName,
      stats: stats ?? this.stats,
      errorMessage: errorMessage,
    );
  }
}

class TunnelStats {
  const TunnelStats({
    required this.rxBytes,
    required this.txBytes,
    this.lastHandshakeSecondsAgo,
  });

  factory TunnelStats.fromMap(Map<dynamic, dynamic> map) {
    return TunnelStats(
      rxBytes: (map['rxBytes'] as num?)?.toInt() ?? 0,
      txBytes: (map['txBytes'] as num?)?.toInt() ?? 0,
      lastHandshakeSecondsAgo: (map['lastHandshakeSecondsAgo'] as num?)?.toInt(),
    );
  }

  final int rxBytes;
  final int txBytes;
  final int? lastHandshakeSecondsAgo;
}
