import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';
import 'package:installed_apps/installed_apps.dart';

import 'theme.dart';

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
  List<AppInfo>? _apps;
  bool _failed = false;
  late final _saved = widget.config.includedApplications.toSet();
  late final _selected = {..._saved};
  String _query = '';
  bool _saving = false;

  bool get _changed => _selected.length != _saved.length || !_selected.containsAll(_saved);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final apps = await InstalledApps.getInstalledApps(excludeSystemApps: false, withIcon: true);
      // The plugin reports failure as an empty list.
      if (apps.isEmpty) throw Exception();
      // Chosen apps first, as they were on opening: rows mustn't jump while tapping.
      apps.sort((a, b) {
        final chosen = (_saved.contains(b.packageName) ? 1 : 0) - (_saved.contains(a.packageName) ? 1 : 0);
        return chosen != 0 ? chosen : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (mounted) setState(() => _apps = apps);
    } on Exception {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.vpn.setIncludedApps(widget.config.name, _selected.toList());
      if (mounted) Navigator.pop(context);
    } on Exception {
      if (!mounted) return;
      setState(() => _saving = false);
      showMessage(context, "Couldn't save your apps. Try again.");
    }
  }

  Future<void> _leave() async {
    final discard = await confirm(
      context,
      title: 'Discard changes?',
      message: "Your app selection hasn't been saved.",
      action: 'Discard',
    );
    if (discard && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final apps = _apps;
    final query = _query.toLowerCase();
    final visible = [
      for (final app in apps ?? const <AppInfo>[])
        if (app.name.toLowerCase().contains(query)) app,
    ];
    return PopScope(
      canPop: !_changed || _saving,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _leave();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Apps using the VPN')),
        body: _failed
            ? EmptyState(
                icon: Icons.apps,
                title: "Couldn't list your apps",
                body: 'Try again in a moment.',
                action: FilledButton.tonal(onPressed: _load, child: const Text('Try again')),
              )
            : apps == null
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: TextField(
                          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search apps'),
                          onChanged: (v) => setState(() => _query = v),
                        ),
                      ),
                      Expanded(
                        child: visible.isEmpty
                            ? const EmptyState(
                                icon: Icons.search_off,
                                title: 'No matching apps',
                                body: 'Check the spelling, or search for less.',
                              )
                            : ListView.builder(itemCount: visible.length, itemBuilder: (_, i) => _app(visible[i])),
                      ),
                    ],
                  ),
        bottomNavigationBar: apps == null
            ? null
            : BottomAction(
                note: _selected.isEmpty
                    ? 'With none selected, every app uses the VPN'
                    : '${_selected.length} selected. Other apps use your normal connection',
                child: FilledButton(
                  onPressed: _changed && !_saving ? _save : null,
                  child: Text(_saving ? 'Saving…' : 'Save'),
                ),
              ),
      ),
    );
  }

  Widget _app(AppInfo app) {
    return CheckboxListTile(
      value: _selected.contains(app.packageName),
      title: Text(app.name),
      secondary: app.icon == null
          ? const Icon(Icons.android, size: 40)
          : Image.memory(app.icon!, width: 40, height: 40, cacheWidth: 120, gaplessPlayback: true),
      onChanged: (value) => setState(() {
        value == true ? _selected.add(app.packageName) : _selected.remove(app.packageName);
      }),
    );
  }
}
