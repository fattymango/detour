import 'dart:io';

import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';

import 'import_dialog.dart';
import 'theme.dart';
import 'users_screen.dart';

Future<int?> measureLatency(TunnelConfig config) async {
  final watch = Stopwatch()..start();
  try {
    final socket = await Socket.connect(
      config.endpointHost!,
      config.endpointPort!,
      timeout: const Duration(seconds: 5),
    );
    final ms = watch.elapsedMilliseconds;
    socket.destroy();
    return ms;
  } on Exception {
    return null;
  }
}

/// Pops with the name of the chosen server.
class ServersScreen extends StatefulWidget {
  const ServersScreen({
    super.key,
    required this.vpn,
    required this.selected,
    required this.inUse,
    this.latency = measureLatency,
  });

  final VpnRepository vpn;
  final String? selected;

  /// The server the running VPN uses. It finds its config by name.
  final String? inUse;

  final Future<int?> Function(TunnelConfig) latency;

  @override
  State<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends State<ServersScreen> {
  List<TunnelConfig>? _configs;

  // Answered servers only, so each is asked once and unreachable ones are retried.
  final _isAdmin = <String, bool>{};

  // Null means unreachable; missing means still checking.
  final _latency = <String, int?>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final configs = await widget.vpn.listConfigs();
    if (!mounted) return;
    setState(() => _configs = configs);
    for (final config in configs) {
      if (_latency[config.name] == null) _checkLatency(config);
      if (!_isAdmin.containsKey(config.name)) _checkAdmin(config.name);
    }
  }

  Future<void> _refresh() async {
    setState(_latency.clear);
    await _load();
  }

  Future<void> _checkLatency(TunnelConfig config) async {
    final ms = await widget.latency(config);
    if (mounted) setState(() => _latency[config.name] = ms);
  }

  Future<void> _checkAdmin(String name) async {
    final admin = await widget.vpn.isServerAdmin(name);
    if (mounted && admin != null) setState(() => _isAdmin[name] = admin);
  }

  Future<void> _add() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => ImportDialog(
        vpn: widget.vpn,
        existingNames: {for (final c in _configs ?? const <TunnelConfig>[]) c.name},
        pasteFirst: true,
      ),
    );
    if (name != null) await _load();
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
      await widget.vpn.renameConfig(config.name, name);
      _forget(config.name);
    } on VpnRepositoryException catch (e) {
      if (mounted) showMessage(context, e.message);
    }
    await _load();
  }

  Future<void> _delete(TunnelConfig config) async {
    final sure = await confirm(
      context,
      title: 'Delete ${config.name}?',
      message: 'Its invite link has already been used, so you need a new one to add it again.',
      action: 'Delete',
    );
    if (!sure) return;
    await widget.vpn.deleteConfig(config.name);
    _forget(config.name);
    await _load();
  }

  void _forget(String name) {
    _isAdmin.remove(name);
    _latency.remove(name);
  }

  @override
  Widget build(BuildContext context) {
    final configs = _configs;
    return Scaffold(
      appBar: AppBar(title: const Text('Servers')),
      body: configs == null
          ? const Center(child: CircularProgressIndicator())
          : configs.isEmpty
              ? const EmptyState(
                  icon: Icons.dns_outlined,
                  title: 'No servers',
                  body: 'Copy an invite link, then paste it below.',
                )
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    itemCount: configs.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _server(configs[i]),
                  ),
                ),
      bottomNavigationBar: BottomAction(
        child: FilledButton.icon(
          onPressed: _add,
          icon: const Icon(Icons.content_paste),
          label: const Text('Paste invite link'),
        ),
      ),
    );
  }

  Widget _server(TunnelConfig config) {
    final admin = _isAdmin[config.name] ?? false;
    final checked = _latency.containsKey(config.name);
    final ms = _latency[config.name];
    final unreachable = checked && ms == null;
    final selected = config.name == widget.selected;
    final inUse = config.name == widget.inUse;
    final detail = [
      if (unreachable) "Can't be reached" else if (ms != null) '$ms ms' else 'Checking…',
      if (admin) 'Admin',
    ].join(' · ');
    return Semantics(
      selected: selected,
      child: InfoCard(
        icon: selected
            ? Icons.check_circle
            : unreachable
                ? Icons.cloud_off
                : Icons.dns_outlined,
        title: config.name,
        detail: detail,
        detailColor: unreachable ? Theme.of(context).colorScheme.error : null,
        selected: selected,
        onTap: () => Navigator.pop(context, config.name),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (admin)
              IconButton(
                icon: const Icon(Icons.group_outlined),
                tooltip: 'Manage people',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => UsersScreen(vpn: widget.vpn, config: config)),
                ),
              ),
            PopupMenuButton<String>(
              onSelected: (action) => action == 'rename' ? _rename(config) : _delete(config),
              itemBuilder: (context) => [
                PopupMenuItem(value: 'rename', enabled: !inUse, child: const Text('Rename')),
                PopupMenuItem(value: 'delete', enabled: !inUse, child: const Text('Delete')),
                if (inUse) const PopupMenuItem(enabled: false, child: Text('Disconnect first')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
