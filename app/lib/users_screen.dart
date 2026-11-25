import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';

import 'invite_sheet.dart';
import 'limits_dialog.dart';
import 'theme.dart';

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
        showMessage(context, e.message);
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
        scrollable: true,
        title: const Text('Invite someone'),
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
            child: const Text('Create invite'),
          ),
        ],
      ),
    );
    if (username == null || username.isEmpty) return;
    await _run(() async => _showInvite(username, await widget.vpn.addServerUser(_server, username)));
  }

  Future<void> _remove(String username) async {
    if (!await confirm(context, title: 'Remove $username?', message: 'They are disconnected right away and can no longer log in.', action: 'Remove')) {
      return;
    }
    await _run(() => widget.vpn.removeServerUser(_server, username));
  }

  Future<void> _reset(String username) async {
    if (!await confirm(context, title: 'New link for $username?', message: 'Their phone is disconnected, and they need the new link to get back in.', action: 'Create')) {
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
    if (!await confirm(context, title: 'Reset usage of $username?', message: 'Their data usage starts from zero again.', action: 'Reset')) return;
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
        title: Text('People on $_server'),
        bottom: _busy
            ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator())
            : null,
      ),
      body: _error != null
          ? EmptyState(
              icon: Icons.cloud_off,
              title: "Couldn't load people",
              body: _error!,
              action: FilledButton.tonal(onPressed: _load, child: const Text('Try again')),
            )
          : users == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    itemCount: users.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _person(users[i]),
                  ),
                ),
      bottomNavigationBar: users == null || _error != null
          ? null
          : BottomAction(
              child: FilledButton.icon(
                onPressed: _busy ? null : _add,
                icon: const Icon(Icons.person_add_alt),
                label: const Text('Invite someone'),
              ),
            ),
    );
  }

  Widget _person(ServerUser user) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = theme.textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant);
    final over = user.quotaBytes > 0 && user.usedBytes >= user.quotaBytes;
    final online = user.connected > 0;
    final status = user.invitePending
        ? 'Invite not used yet'
        : online
            ? 'Connected${user.connected > 1 ? ' on ${user.connected} devices' : ''}'
            : 'Not connected';
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: CircleAvatar(
                backgroundColor: colors.primaryContainer,
                foregroundColor: colors.onPrimaryContainer,
                child: Text(user.username.characters.take(2).toString().toUpperCase(), textScaler: TextScaler.noScaling),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(user.username, style: theme.textTheme.titleMedium),
                  Text.rich(
                    TextSpan(children: [
                      if (user.isAdmin) const TextSpan(text: 'Admin · '),
                      TextSpan(
                        text: status,
                        style: online && !user.invitePending
                            ? TextStyle(
                                color: theme.brightness == Brightness.dark
                                    ? const Color(0xFF5DCAA5)
                                    : StatusColors.connected(context).fill,
                                fontWeight: FontWeight.w500,
                              )
                            : null,
                      ),
                    ]),
                    style: muted,
                  ),
                  if (!user.invitePending)
                    Text(
                      [
                        user.quotaBytes > 0
                            ? '${formatBytes(user.usedBytes)} of ${formatBytes(user.quotaBytes)}'
                            : '${formatBytes(user.usedBytes)} used',
                        if (user.speedKbps > 0) 'max ${formatNumber(user.speedKbps / 1000)} Mbps',
                      ].join(' · '),
                      style: over ? muted?.copyWith(color: colors.error) : muted,
                    ),
                  if (user.quotaBytes > 0 && !user.invitePending)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, right: 8),
                      child: LinearProgressIndicator(
                        value: (user.usedBytes / user.quotaBytes).clamp(0, 1),
                        color: over ? colors.error : colors.primary,
                        borderRadius: BorderRadius.circular(2),
                        semanticsLabel: 'Data used',
                      ),
                    ),
                ],
              ),
            ),
            PopupMenuButton<String>(
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
          ],
        ),
      ),
    );
  }
}
