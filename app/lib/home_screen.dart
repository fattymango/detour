import 'dart:async';

import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';

import 'app_selector_screen.dart';
import 'import_dialog.dart';
import 'logs_screen.dart';
import 'users_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _vpn = VpnRepository();
  List<TunnelConfig> _configs = [];
  TunnelStatus _status = const TunnelStatus.initial();
  StreamSubscription<TunnelStatus>? _statusSub;

  // Answered servers only, so each is asked once and unreachable ones are retried.
  final _isAdmin = <String, bool>{};

  @override
  void initState() {
    super.initState();
    _statusSub = _vpn.watchStatus().listen((s) => setState(() => _status = s));
    _vpn.currentStatus().then((s) => setState(() => _status = s));
    _loadConfigs();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    super.dispose();
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
            trailing: connected
                ? FilledButton.tonal(onPressed: _vpn.disconnect, child: const Text('Disconnect'))
                : null,
          ),
          const Divider(height: 1),
          Expanded(
            child: _configs.isEmpty
                ? const Center(child: Text('No saved configs yet. Tap + to import one.'))
                : ListView.builder(
                    itemCount: _configs.length,
                    itemBuilder: (context, i) {
                      final config = _configs[i];
                      final isActive = _status.activeConfigName == config.name && connected;
                      return ListTile(
                        leading: Icon(isActive ? Icons.lock : Icons.lock_outline),
                        title: Text(config.name),
                        subtitle: Text('${config.endpointHost}:${config.endpointPort} · '
                            '${config.includedApplications.length} app(s)'),
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
                            const PopupMenuItem(value: 'delete', child: Text('Delete')),
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
      TunnelState.disconnecting => 'Disconnecting…',
      TunnelState.error => 'Error: ${status.errorMessage ?? 'unknown'}',
      TunnelState.disconnected => 'Disconnected',
    };
  }
}
