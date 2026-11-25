enum IdleAction {
  /// Stay connected.
  off,

  /// Turn the VPN off. Its apps then use the normal connection.
  stop,

  /// Leave the server but hold the apps' traffic, and reconnect when one of
  /// them is opened.
  standby,
}
