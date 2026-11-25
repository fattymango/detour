import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';

import 'logs_screen.dart';
import 'theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.vpn});

  final VpnRepository vpn;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  bool? _exempt;

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
    final exempt = await widget.vpn.hasBatteryExemption();
    if (mounted) setState(() => _exempt = exempt);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          InfoCard(
            icon: Icons.battery_saver_outlined,
            title: 'Run in the background',
            detail: switch (_exempt) {
              null => 'Checking…',
              true => 'Allowed',
              false => 'Android may stop the VPN to save battery',
            },
            onTap: _exempt == false ? widget.vpn.requestBatteryExemption : null,
          ),
          const SizedBox(height: 8),
          InfoCard(
            icon: Icons.article_outlined,
            title: 'Connection log',
            detail: 'When the VPN connected, and why it stopped',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => LogsScreen(vpn: widget.vpn)),
            ),
          ),
        ],
      ),
    );
  }
}
