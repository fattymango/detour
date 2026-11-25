import 'dart:async';
import 'dart:math' as math;

import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';
import 'package:installed_apps/installed_apps.dart';

import 'app_selector_screen.dart';
import 'idle_minutes_dialog.dart';
import 'idle_screen.dart';
import 'import_dialog.dart';
import 'power_button.dart';
import 'servers_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _vpn = VpnRepository();
  List<TunnelConfig>? _configs;
  String? _selectedName;
  TunnelStatus _status = const TunnelStatus.initial();
  StreamSubscription<TunnelStatus>? _statusSub;
  IdleAction _idleAction = IdleAction.off;
  int _idleMinutes = 5;
  bool _askBattery = false;
  bool _batteryDismissed = false;
  final _appNames = <String, String>{};

  bool get _busy => _status.state == TunnelState.connecting || _status.state == TunnelState.reconnecting;
  bool get _running => _busy || _status.state == TunnelState.connected || _status.state == TunnelState.standby;

  TunnelConfig? get _selected {
    final configs = _configs ?? const [];
    final name = _running ? _status.activeConfigName : _selectedName;
    return configs.where((c) => c.name == name).firstOrNull ?? configs.firstOrNull;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _statusSub = _vpn.watchStatus().listen(_onStatus);
    _vpn.currentStatus().then((s) {
      if (mounted) _onStatus(s);
    });
    _checkBattery();
    _loadIdle();
    _start();
  }

  Future<void> _start() async {
    final last = await _vpn.lastConfigName();
    if (!mounted) return;
    _selectedName = last;
    await _loadConfigs();
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
    _loadIdle();
  }

  void _onStatus(TunnelStatus status) => setState(() {
        _status = status;
        if (_running && status.activeConfigName != null) _selectedName = status.activeConfigName;
      });

  Future<void> _loadConfigs() async {
    final configs = await _vpn.listConfigs();
    if (!mounted) return;
    setState(() => _configs = configs);
    for (final package in configs.expand((c) => c.includedApplications.take(1))) {
      if (!_appNames.containsKey(package)) _loadAppName(package);
    }
  }

  Future<void> _loadAppName(String package) async {
    final app = await InstalledApps.getAppInfo(package, withIcon: false);
    if (mounted && app != null) setState(() => _appNames[package] = app.name);
  }

  Future<void> _loadIdle() async {
    final action = await _vpn.getIdleAction();
    final minutes = await _vpn.getIdleMinutes();
    if (!mounted) return;
    setState(() {
      _idleAction = action;
      _idleMinutes = minutes;
    });
  }

  Future<void> _checkBattery() async {
    final exempt = await _vpn.hasBatteryExemption();
    if (mounted) setState(() => _askBattery = !exempt);
  }

  Future<void> _connect(String name) async {
    if (!await _vpn.hasVpnPermission()) {
      final granted = await _vpn.requestVpnPermission();
      if (!granted) return;
    }
    await _vpn.requestNotificationPermission();
    try {
      await _vpn.connect(name);
    } on VpnRepositoryException catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  Future<void> _push(Widget screen) =>
      Navigator.push<void>(context, MaterialPageRoute(builder: (_) => screen));

  Future<void> _openServers() async {
    final picked = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => ServersScreen(
          vpn: _vpn,
          selected: _selected?.name,
          inUse: _running ? _status.activeConfigName : null,
        ),
      ),
    );
    await _loadConfigs();
    if (picked == null || !mounted) return;
    final switching = _running && picked != _status.activeConfigName;
    setState(() => _selectedName = picked);
    if (switching) await _connect(picked);
  }

  Future<void> _openApps(TunnelConfig config) async {
    await _push(AppSelectorScreen(vpn: _vpn, config: config));
    await _loadConfigs();
  }

  Future<void> _openIdle() async {
    await _push(IdleScreen(vpn: _vpn));
    await _loadIdle();
  }

  Future<void> _addFirstServer() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => ImportDialog(vpn: _vpn, existingNames: const {}, pasteFirst: true),
    );
    if (name == null || !mounted) return;
    setState(() => _selectedName = name);
    await _loadConfigs();
  }

  String _apps(TunnelConfig config) {
    final apps = config.includedApplications;
    if (apps.isEmpty) return 'All apps';
    final first = _appNames[apps.first] ?? apps.first;
    return apps.length == 1 ? first : '$first and ${apps.length - 1} more';
  }

  String get _idleText => switch (_idleAction) {
        IdleAction.off => 'Stay connected',
        IdleAction.stop => 'Turn off after ${formatMinutes(_idleMinutes)}',
        IdleAction.standby => 'Standby after ${formatMinutes(_idleMinutes)}',
      };

  ({StatusColors colors, String title, String detail, String action}) _look(TunnelConfig config) {
    final apps = _apps(config);
    return switch (_status.state) {
      TunnelState.connected => (
          colors: StatusColors.connected(context),
          title: 'Connected',
          detail: config.includedApplications.isEmpty ? 'All apps use the VPN' : 'Protecting $apps',
          action: 'Disconnect',
        ),
      TunnelState.connecting => (
          colors: StatusColors.busy(context),
          title: 'Connecting…',
          detail: 'Reaching ${config.name}',
          action: 'Cancel',
        ),
      TunnelState.reconnecting => (
          colors: StatusColors.busy(context),
          title: 'Reconnecting…',
          detail: 'Your selected apps wait until it is back',
          action: 'Cancel',
        ),
      TunnelState.standby => (
          colors: StatusColors.standby(context),
          title: 'On standby',
          detail: 'Connects when you open a selected app',
          action: 'Turn off',
        ),
      TunnelState.error => (
          colors: StatusColors.error(context),
          title: "Couldn't connect",
          detail: _status.errorMessage ?? 'Something went wrong',
          action: 'Try again',
        ),
      TunnelState.disconnected || TunnelState.disconnecting => (
          colors: StatusColors.off(context),
          title: 'Not connected',
          detail: 'Tap to connect',
          action: 'Connect',
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final configs = _configs;
    final config = _selected;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Detour'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () async {
              await _push(SettingsScreen(vpn: _vpn));
              await _checkBattery();
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: configs == null
            ? const Center(child: CircularProgressIndicator())
            : config == null
                ? EmptyState(
                    icon: Icons.vpn_key_outlined,
                    title: 'Add your first server',
                    body: 'Copy the invite link you were sent, then paste it here.',
                    action: FilledButton.icon(
                      onPressed: _addFirstServer,
                      icon: const Icon(Icons.content_paste),
                      label: const Text('Paste invite link'),
                    ),
                  )
                : _dashboard(config),
      ),
    );
  }

  Widget _dashboard(TunnelConfig config) {
    final theme = Theme.of(context);
    final look = _look(config);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 40),
              child: Column(
                children: [
                  if (_askBattery && !_batteryDismissed) _batteryCard(),
                  SizedBox(height: math.max(16, constraints.maxHeight * 0.05)),
                  PowerButton(
                    colors: look.colors,
                    label: look.action,
                    busy: _busy,
                    onTap: () => _running ? _vpn.disconnect() : _connect(config.name),
                  ),
                  const SizedBox(height: 24),
                  Semantics(
                    liveRegion: true,
                    child: Column(
                      children: [
                        Text(look.title, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
                        const SizedBox(height: 4),
                        Text(
                          look.detail,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Column(
              children: [
                InfoCard(
                  icon: Icons.dns_outlined,
                  title: config.name,
                  detail: '${config.endpointHost}',
                  onTap: _openServers,
                ),
                const SizedBox(height: 8),
                InfoCard(icon: Icons.apps, title: 'Apps using the VPN', detail: _apps(config), onTap: () => _openApps(config)),
                const SizedBox(height: 8),
                InfoCard(
                  icon: Icons.bedtime_outlined,
                  title: 'When not in use',
                  detail: _idleText,
                  onTap: _openIdle,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _batteryCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Android may stop the VPN to save battery. Let Detour run in the background?'),
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  onPressed: () => setState(() => _batteryDismissed = true),
                  child: const Text('Not now'),
                ),
                TextButton(onPressed: _vpn.requestBatteryExemption, child: const Text('Allow')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
