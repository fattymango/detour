import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key, required this.vpn});

  final VpnRepository vpn;

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  List<VpnLogEntry> _logs = [];

  @override
  void initState() {
    super.initState();
    widget.vpn.getLogs().then((logs) => setState(() => _logs = logs));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connection log')),
      body: _logs.isEmpty
          ? const Center(child: Text('No log entries yet'))
          : ListView.builder(
              itemCount: _logs.length,
              itemBuilder: (context, i) {
                final entry = _logs[i];
                return ListTile(
                  dense: true,
                  title: Text(entry.message),
                  subtitle: Text(entry.timestamp.toString()),
                );
              },
            ),
    );
  }
}
