import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';

import 'invite_sheet.dart';
import 'limits_dialog.dart';

/// Admin view of one server's users.
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key, required this.vpn, required this.config});

  final VpnRepository vpn;
  final TunnelConfig config;

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  List<ServerUser>? _users;
  String? _error;
  bool _busy = false;

  String get _server => widget.config.name;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final users = await widget.vpn.listServerUsers(_server);
      if (!mounted) return;
      setState(() {
        _users = users;
        _error = null;
      });
    } on VpnRepositoryException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on VpnRepositoryException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _add() async {
    final controller = TextEditingController();
    final username = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add user'),
        content: TextField(
          controller: controller,
          autofocus: true,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Username',
            helperText: 'Letters, digits, dot, dash or underscore',
          ),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (username == null || username.isEmpty) return;
    await _run(() async => _showInvite(username, await widget.vpn.addServerUser(_server, username)));
  }

  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
          ],
        ),
      ) ??
      false;

  Future<void> _remove(String username) async {
    if (!await _confirm('Remove $username?', 'They are disconnected right away and can no longer log in.', 'Remove')) {
      return;
    }
    await _run(() => widget.vpn.removeServerUser(_server, username));
  }

  Future<void> _reset(String username) async {
    if (!await _confirm('New link for $username?', 'Their phone is disconnected, and they need the new link to get back in.', 'Create')) {
      return;
    }
    await _run(() async => _showInvite(username, await widget.vpn.resetServerUser(_server, username)));
  }

  Future<void> _limits(ServerUser user) async {
    final limits = await showDialog<({int speedKbps, int quotaBytes})>(
      context: context,
      builder: (_) => LimitsDialog(user: user),
    );
    if (limits == null) return;
    await _run(() => widget.vpn.setServerUserLimits(
          _server,
          user.username,
          speedKbps: limits.speedKbps,
          quotaBytes: limits.quotaBytes,
        ));
  }

  Future<void> _resetUsage(String username) async {
    if (!await _confirm('Reset usage of $username?', 'Their data usage starts from zero again.', 'Reset')) return;
    await _run(() => widget.vpn.resetServerUserUsage(_server, username));
  }

  Future<void> _showInvite(String username, String link) async {
    if (!mounted) return;
    await showInviteSheet(context, username: username, server: _server, link: link);
  }

  @override
  Widget build(BuildContext context) {
    final users = _users;
    return Scaffold(
      appBar: AppBar(
        title: Text('Users on $_server'),
        bottom: _busy
            ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator())
            : null,
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.tonal(onPressed: _load, child: const Text('Try again')),
                  ],
                ),
              ),
            )
          : users == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: users.length,
                    itemBuilder: (context, i) {
                      final user = users[i];
                      return ListTile(
                        leading: Icon(user.isAdmin ? Icons.admin_panel_settings : Icons.person),
                        title: Text(user.username),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text([
                              if (user.isAdmin) 'Admin',
                              if (user.invitePending)
                                'Invite not used yet'
                              else if (user.connected > 0)
                                'Connected (${user.connected})'
                              else
                                'Not connected',
                            ].join(' · ')),
                            Text([
                              user.quotaBytes > 0
                                  ? '${formatBytes(user.usedBytes)} of ${formatBytes(user.quotaBytes)}'
                                  : '${formatBytes(user.usedBytes)} used',
                              if (user.speedKbps > 0) 'max ${formatNumber(user.speedKbps / 1000)} Mbps',
                            ].join(' · ')),
                            if (user.quotaBytes > 0)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: LinearProgressIndicator(
                                  value: (user.usedBytes / user.quotaBytes).clamp(0, 1),
                                  color: user.usedBytes >= user.quotaBytes
                                      ? Theme.of(context).colorScheme.error
                                      : null,
                                ),
                              ),
                          ],
                        ),
                        trailing: PopupMenuButton<String>(
                          enabled: !_busy,
                          onSelected: (action) => switch (action) {
                            'limits' => _limits(user),
                            'usage' => _resetUsage(user.username),
                            'reset' => _reset(user.username),
                            _ => _remove(user.username),
                          },
                          itemBuilder: (context) => [
                            const PopupMenuItem(value: 'limits', child: Text('Limits')),
                            const PopupMenuItem(value: 'usage', child: Text('Reset usage')),
                            if (!user.isAdmin) ...const [
                              PopupMenuItem(value: 'reset', child: Text('New invite link')),
                              PopupMenuItem(value: 'remove', child: Text('Remove')),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                ),
      floatingActionButton: users == null || _error != null
          ? null
          : FloatingActionButton(
              onPressed: _busy ? null : _add,
              tooltip: 'Add user',
              child: const Icon(Icons.person_add),
            ),
    );
  }
}
