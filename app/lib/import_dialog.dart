import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Pops with true once a config is imported, and stays open on errors.
class ImportDialog extends StatefulWidget {
  const ImportDialog({super.key, required this.vpn, required this.existingNames});

  final VpnRepository vpn;
  final Set<String> existingNames;

  @override
  State<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<ImportDialog> {
  final _name = TextEditingController();
  final _text = TextEditingController();
  String? _nameError;
  String? _textError;
  TunnelConfig? _preview;
  String _suggested = '';

  @override
  void dispose() {
    _name.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    _text.text = data?.text ?? '';
    await _updatePreview();
  }

  Future<void> _updatePreview() async {
    final text = _text.text;
    TunnelConfig? preview;
    String? error;
    if (text.trim().isNotEmpty) {
      try {
        preview = await widget.vpn.previewConfig(text);
      } on VpnRepositoryException catch (e) {
        error = e.message;
      }
    }
    // A newer edit has its own preview on the way.
    if (!mounted || text != _text.text) return;
    setState(() {
      _preview = preview;
      _textError = error;
      if (preview != null && (_name.text.isEmpty || _name.text == _suggested)) {
        _suggested = _freeName(preview.name.isEmpty ? preview.endpointHost! : preview.name);
        _name.text = _suggested;
        _nameError = null;
      }
    });
  }

  String _freeName(String name) {
    var free = name;
    for (var i = 2; widget.existingNames.contains(free); i++) {
      free = '$name $i';
    }
    return free;
  }

  Future<void> _import() async {
    final name = _name.text.trim();
    setState(() {
      _nameError = name.isEmpty
          ? 'Enter a name'
          : widget.existingNames.contains(name)
              ? 'You already have a server with this name'
              : null;
      _textError = null;
    });
    if (_nameError != null) return;
    try {
      await widget.vpn.importConfig(name: name, text: _text.text);
      if (mounted) Navigator.pop(context, true);
    } on VpnRepositoryException catch (e) {
      if (mounted) setState(() => _textError = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Add server'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _text,
            minLines: 2,
            maxLines: 4,
            textDirection: TextDirection.ltr,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => _updatePreview(),
            decoration: InputDecoration(
              labelText: 'Invite link',
              hintText: 'detour://...',
              errorText: _textError,
              errorMaxLines: 3,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste),
                tooltip: 'Paste',
                onPressed: _paste,
              ),
            ),
          ),
          if (_preview case final preview?)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary),
              title: Text('${preview.endpointHost}:${preview.endpointPort}'),
              subtitle: Text('User: ${preview.username}'),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            decoration: InputDecoration(labelText: 'Name', errorText: _nameError, errorMaxLines: 3),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: _import, child: const Text('Add')),
      ],
    );
  }
}
