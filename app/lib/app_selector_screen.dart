import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';
import 'package:installed_apps/app_info.dart';
import 'package:installed_apps/installed_apps.dart';

/// Pick which installed apps route through a given saved [config]'s tunnel.
/// Everything left unchecked bypasses the VPN entirely at the OS level.
class AppSelectorScreen extends StatefulWidget {
  const AppSelectorScreen({super.key, required this.vpn, required this.config});

  final VpnRepository vpn;
  final TunnelConfig config;

  @override
  State<AppSelectorScreen> createState() => _AppSelectorScreenState();
}

class _AppSelectorScreenState extends State<AppSelectorScreen> {
  List<AppInfo> _apps = [];
  late Set<String> _selected;
  String _query = '';
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.config.includedApplications.toSet();
    InstalledApps.getInstalledApps(excludeSystemApps: false, withIcon: true).then((apps) {
      apps.sort((a, b) => a.name.compareTo(b.name));
      setState(() {
        _apps = apps;
        _loading = false;
      });
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.vpn.setIncludedApps(widget.config.name, _selected.toList());
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Selection saved')));
  }

  @override
  Widget build(BuildContext context) {
    final visible = _query.isEmpty
        ? _apps
        : _apps.where((a) => a.name.toLowerCase().contains(_query.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text('Apps for ${widget.config.name}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save_outlined),
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search apps',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, i) {
                      final app = visible[i];
                      final selected = _selected.contains(app.packageName);
                      return CheckboxListTile(
                        value: selected,
                        title: Text(app.name),
                        subtitle: Text(app.packageName),
                        secondary: app.icon != null ? Image.memory(app.icon!, width: 36, height: 36) : null,
                        onChanged: (value) {
                          setState(() {
                            if (value == true) {
                              _selected.add(app.packageName);
                            } else {
                              _selected.remove(app.packageName);
                            }
                          });
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
