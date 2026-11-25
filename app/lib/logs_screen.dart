import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key, required this.vpn});

  final VpnRepository vpn;

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  List<VpnLogEntry>? _logs;

  @override
  void initState() {
    super.initState();
    widget.vpn.getLogs().then((logs) {
      if (mounted) setState(() => _logs = logs);
    });
  }

  String _time(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final logs = _logs;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Connection log')),
      body: logs == null
          ? const Center(child: CircularProgressIndicator())
          : logs.isEmpty
              ? const EmptyState(
                  icon: Icons.article_outlined,
                  title: 'Nothing logged yet',
                  body: 'Connections and problems show up here.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: logs.length,
                  separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
                  itemBuilder: (context, i) => ListTile(
                    title: Text(logs[i].message, style: theme.textTheme.bodyLarge),
                    subtitle: Text(_time(logs[i].timestamp)),
                  ),
                ),
    );
  }
}
