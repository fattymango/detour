import 'dart:async';
import 'dart:io';

import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';

import 'app_selector_screen.dart';
import 'idle_minutes_dialog.dart';
import 'import_dialog.dart';
import 'logs_screen.dart';
import 'users_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _vpn = VpnRepository();
  List<TunnelConfig> _configs = [];
  TunnelStatus _status = const TunnelStatus.initial();
  StreamSubscription<TunnelStatus>? _statusSub;

  // Answered servers only, so each is asked once and unreachable ones are retried.
  final _isAdmin = <String, bool>{};

  final _latency = <String, String>{};
  bool _askBattery = false;
  bool _batteryDismissed = false;
  IdleAction _idleAction = IdleAction.off;

  // Chosen, but waiting for the user to grant usage access.
  IdleAction? _pendingIdleAction;
  int _idleMinutes = 5;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkBattery();
    _loadIdleSettings();
    _statusSub = _vpn.watchStatus().listen((s) => setState(() => _status = s));
    _vpn.currentStatus().then((s) => setState(() => _status = s));
    _loadConfigs();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _checkBattery();
    _loadIdleSettings();
  }

  Future<void> _loadIdleSettings() async {
    final pending = _pendingIdleAction;
    if (pending != null && await _vpn.hasUsageAccess()) {
      _pendingIdleAction = null;
      await _vpn.setIdleAction(pending);
    }
    final action = await _vpn.getIdleAction();
    final minutes = await _vpn.getIdleMinutes();
    if (!mounted) return;
    setState(() {
      _idleAction = action;
      _idleMinutes = minutes;
    });
  }

  Future<void> _editIdleMinutes() async {
    final minutes = await showDialog<int>(
      context: context,
      builder: (_) => IdleMinutesDialog(minutes: _idleMinutes),
    );
    if (minutes == null) return;
    await _vpn.setIdleMinutes(minutes);
    await _loadIdleSettings();
  }

  Future<void> _setIdleAction(IdleAction action) async {
    if (action != IdleAction.off && !await _vpn.hasUsageAccess()) {
      if (!mounted) return;
      final open = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('Allow usage access'),
          content: const Text(
            'Detour needs usage access to see whether one of your VPN apps is on screen. '
            'It stays on this phone. On the next screen, find Detour and turn it on.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Open settings')),
          ],
        ),
      );
      if (open != true) return;
      _pendingIdleAction = action;
      await _vpn.requestUsageAccess();
      return;
    }
    _pendingIdleAction = null;
    await _vpn.setIdleAction(action);
    await _loadIdleSettings();
  }

  Future<void> _checkBattery() async {
    final exempt = await _vpn.hasBatteryExemption();
    if (mounted) setState(() => _askBattery = !exempt);
  }

  Future<void> _checkLatency(TunnelConfig config) async {
    setState(() => _latency[config.name] = 'checking…');
    String result;
    final watch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(
        config.endpointHost!,
        config.endpointPort!,
        timeout: const Duration(seconds: 5),
      );
      result = '${watch.elapsedMilliseconds} ms';
      socket.destroy();
    } on Exception {
      result = 'unreachable';
    }
    if (mounted) setState(() => _latency[config.name] = result);
  }

  Future<void> _rename(TunnelConfig config) async {
    final controller = TextEditingController(text: config.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Rename server'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Rename')),
        ],
      ),
    );
    if (name == null || name == config.name) return;
    try {
      await _vpn.renameConfig(config.name, name);
      _isAdmin.remove(config.name);
      _latency.remove(config.name);
    } on VpnRepositoryException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
    await _loadConfigs();
  }

  Future<void> _loadConfigs() async {
    final configs = await _vpn.listConfigs();
    if (!mounted) return;
    setState(() => _configs = configs);
    for (final config in configs) {
      if (!_isAdmin.containsKey(config.name)) _checkAdmin(config.name);
    }
  }

  Future<void> _checkAdmin(String name) async {
    final admin = await _vpn.isServerAdmin(name);
    if (mounted && admin != null) setState(() => _isAdmin[name] = admin);
  }

  Future<void> _connect(String name) async {
    if (!await _vpn.hasVpnPermission()) {
      final granted = await _vpn.requestVpnPermission();
      if (!granted) return;
    }
    await _vpn.requestNotificationPermission();
    await _vpn.connect(name);
  }

  Future<void> _importConfigDialog() async {
    final imported = await showDialog<bool>(
      context: context,
      builder: (_) => ImportDialog(vpn: _vpn, existingNames: _configs.map((c) => c.name).toSet()),
    );
    if (imported == true) await _loadConfigs();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _status.state == TunnelState.connected;
    final standby = _status.state == TunnelState.standby;
    final busy = _status.state == TunnelState.connecting || _status.state == TunnelState.reconnecting;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Detour'),
        actions: [
          IconButton(
            icon: const Icon(Icons.article_outlined),
            tooltip: 'Logs',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => LogsScreen(vpn: _vpn)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          ListTile(
            title: Text(_statusLabel(_status)),
            subtitle: _status.activeConfigName != null ? Text(_status.activeConfigName!) : null,
            trailing: connected || busy || standby
                ? FilledButton.tonal(onPressed: _vpn.disconnect, child: Text(busy ? 'Cancel' : 'Disconnect'))
                : null,
          ),
          ListTile(
            title: const Text('When not in use'),
            subtitle: Text(switch (_idleAction) {
              IdleAction.off => 'Stays connected.',
              IdleAction.stop => 'Selected apps then use your normal connection.',
              IdleAction.standby =>
                'Selected apps have no internet in the background, and opening one connects again.',
            }),
            trailing: DropdownButton<IdleAction>(
              value: _idleAction,
              onChanged: (action) => _setIdleAction(action!),
              items: const [
                DropdownMenuItem(value: IdleAction.off, child: Text('Stay on')),
                DropdownMenuItem(value: IdleAction.stop, child: Text('Turn off')),
                DropdownMenuItem(value: IdleAction.standby, child: Text('Standby')),
              ],
            ),
          ),
          if (_idleAction != IdleAction.off)
            ListTile(
              title: const Text('After'),
              trailing: Text(formatMinutes(_idleMinutes)),
              onTap: _editIdleMinutes,
            ),
          const Divider(height: 1),
          if (_askBattery && !_batteryDismissed)
            MaterialBanner(
              leading: const Icon(Icons.battery_alert),
              content: const Text('Android may stop the VPN to save battery. Let Detour run in the background?'),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _batteryDismissed = true),
                  child: const Text('Not now'),
                ),
                TextButton(onPressed: _vpn.requestBatteryExemption, child: const Text('Allow')),
              ],
            ),
          Expanded(
            child: _configs.isEmpty
                ? const Center(child: Text('No saved configs yet. Tap + to import one.'))
                : ListView.builder(
                    itemCount: _configs.length,
                    itemBuilder: (context, i) {
                      final config = _configs[i];
                      final inUse = _status.activeConfigName == config.name && (connected || busy || standby);
                      final isActive = inUse && connected;
                      return ListTile(
                        leading: Icon(isActive ? Icons.lock : Icons.lock_outline),
                        title: Text(config.name),
                        subtitle: Text('${config.endpointHost}:${config.endpointPort} · '
                            '${config.includedApplications.length} app(s)'
                            '${_latency.containsKey(config.name) ? ' · ${_latency[config.name]}' : ''}'),
                        onTap: isActive ? null : () => _connect(config.name),
                        trailing: PopupMenuButton<String>(
                          onSelected: (action) async {
                            switch (action) {
                              case 'apps':
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => AppSelectorScreen(vpn: _vpn, config: config),
                                  ),
                                );
                                _loadConfigs();
                              case 'users':
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => UsersScreen(vpn: _vpn, config: config),
                                  ),
                                );
                              case 'latency':
                                await _checkLatency(config);
                              case 'rename':
                                await _rename(config);
                              case 'delete':
                                await _vpn.deleteConfig(config.name);
                                _isAdmin.remove(config.name);
                                _loadConfigs();
                            }
                          },
                          itemBuilder: (context) => [
                            const PopupMenuItem(value: 'apps', child: Text('Select apps')),
                            if (_isAdmin[config.name] ?? false)
                              const PopupMenuItem(value: 'users', child: Text('Manage users')),
                            const PopupMenuItem(value: 'latency', child: Text('Check latency')),
                            // The running VPN finds its config by name.
                            PopupMenuItem(value: 'rename', enabled: !inUse, child: const Text('Rename')),
                            PopupMenuItem(value: 'delete', enabled: !inUse, child: const Text('Delete')),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _importConfigDialog,
        child: const Icon(Icons.add),
      ),
    );
  }

  String _statusLabel(TunnelStatus status) {
    return switch (status.state) {
      TunnelState.connected => 'Connected',
      TunnelState.connecting => 'Connecting…',
      TunnelState.reconnecting => 'Reconnecting…',
      TunnelState.standby => 'Standby, connects when you open a selected app',
      TunnelState.disconnecting => 'Disconnecting…',
      TunnelState.error => 'Error: ${status.errorMessage ?? 'unknown'}',
      TunnelState.disconnected => 'Disconnected',
    };
  }
}
