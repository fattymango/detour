import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';

import 'idle_minutes_dialog.dart';
import 'theme.dart';

/// Chooses what happens when none of the VPN's apps is in use.
class IdleScreen extends StatefulWidget {
  const IdleScreen({super.key, required this.vpn});

  final VpnRepository vpn;

  @override
  State<IdleScreen> createState() => _IdleScreenState();
}

class _IdleScreenState extends State<IdleScreen> with WidgetsBindingObserver {
  IdleAction _action = IdleAction.off;
  int _minutes = 5;

  // Chosen, but waiting for the user to grant usage access.
  IdleAction? _pending;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final pending = _pending;
    if (pending != null && await widget.vpn.hasUsageAccess()) {
      _pending = null;
      await widget.vpn.setIdleAction(pending);
    }
    final action = await widget.vpn.getIdleAction();
    final minutes = await widget.vpn.getIdleMinutes();
    if (!mounted) return;
    setState(() {
      _action = action;
      _minutes = minutes;
    });
  }

  Future<void> _choose(IdleAction action) async {
    if (action != IdleAction.off && !await widget.vpn.hasUsageAccess()) {
      if (!mounted) return;
      final open = await confirm(
        context,
        title: 'Allow usage access',
        message: 'Detour needs usage access to see whether one of your VPN apps is on screen. '
            'It stays on this phone. On the next screen, find Detour and turn it on.',
        action: 'Open settings',
      );
      if (!open) return;
      _pending = action;
      await widget.vpn.requestUsageAccess();
      return;
    }
    _pending = null;
    await widget.vpn.setIdleAction(action);
    await _load();
  }

  Future<void> _editMinutes() async {
    final minutes = await showDialog<int>(
      context: context,
      builder: (_) => IdleMinutesDialog(minutes: _minutes),
    );
    if (minutes == null) return;
    await widget.vpn.setIdleMinutes(minutes);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('When not in use')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'The VPN is in use while Detour or a selected app is on screen, or while data is steadily moving.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          for (final (action, icon, title, detail) in const [
            (IdleAction.off, Icons.all_inclusive, 'Stay connected', 'The VPN stays on until you turn it off.'),
            (
              IdleAction.stop,
              Icons.power_settings_new,
              'Turn off',
              'Selected apps then use your normal connection.',
            ),
            (
              IdleAction.standby,
              Icons.bedtime_outlined,
              'Standby',
              'Selected apps have no internet in the background, and opening one connects again.',
            ),
          ]) ...[
            Semantics(
              selected: _action == action,
              inMutuallyExclusiveGroup: true,
              child: InfoCard(
                icon: _action == action ? Icons.check_circle : icon,
                title: title,
                detail: detail,
                selected: _action == action,
                trailing: const SizedBox.shrink(),
                onTap: () => _choose(action),
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (_action != IdleAction.off) ...[
            const SizedBox(height: 16),
            InfoCard(
              icon: Icons.timer_outlined,
              title: 'After',
              detail: formatMinutes(_minutes),
              onTap: _editMinutes,
            ),
          ],
        ],
      ),
    );
  }
}
