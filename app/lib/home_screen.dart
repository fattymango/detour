import 'dart:async';

import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';

import 'app_selector_screen.dart';
import 'logs_screen.dart';

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
  bool _adBlockEnabled = true;

  @override
  void initState() {
    super.initState();
    _statusSub = _vpn.watchStatus().listen((s) => setState(() => _status = s));
    _vpn.currentStatus().then((s) => setState(() => _status = s));
    _vpn.isAdBlockEnabled().then((v) => setState(() => _adBlockEnabled = v));
    _loadConfigs();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    super.dispose();
  }

  Future<void> _loadConfigs() async {
    final configs = await _vpn.listConfigs();
    setState(() => _configs = configs);
  }

  Future<void> _connect(String name) async {
    if (!await _vpn.hasVpnPermission()) {
      final granted = await _vpn.requestVpnPermission();
      if (!granted) return;
    }
    await _vpn.connect(name);
  }

  Future<void> _importConfigDialog() async {
    final nameController = TextEditingController();
    final textController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import config'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: textController,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Config text',
                hintText: 'host: 1.2.3.4\nport: 443\nusername: alice\n'
                    'password: ...\nfingerprint: AA:BB:...\napps: ',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Import')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _vpn.importConfig(name: nameController.text.trim(), text: textController.text);
      await _loadConfigs();
    } on VpnRepositoryException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
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
          IconButton(
            icon: Icon(_adBlockEnabled ? Icons.shield : Icons.shield_outlined),
            tooltip: 'Ad blocking',
            onPressed: () async {
              await _vpn.setAdBlockEnabled(!_adBlockEnabled);
              setState(() => _adBlockEnabled = !_adBlockEnabled);
            },
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
                              case 'delete':
                                await _vpn.deleteConfig(config.name);
                                _loadConfigs();
                            }
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(value: 'apps', child: Text('Select apps')),
                            PopupMenuItem(value: 'delete', child: Text('Delete')),
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
