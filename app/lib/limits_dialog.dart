import 'package:detour_vpn/detour_vpn.dart';
import 'package:flutter/material.dart';

String formatNumber(double value) {
  final text = value.toStringAsFixed(2);
  return text.replaceFirst(RegExp(r'\.?0+$'), '');
}

String formatBytes(int bytes) {
  if (bytes >= 1000000000) return '${formatNumber(bytes / 1e9)} GB';
  return '${formatNumber(bytes / 1e6)} MB';
}

/// Empty means 0 (unlimited); null means it isn't a valid number. Accepts
/// Arabic digits and decimal commas.
double? parseAmount(String text) {
  var plain = text.trim().replaceAll(RegExp('[,٫]'), '.');
  for (var i = 0; i < 10; i++) {
    plain = plain.replaceAll('٠١٢٣٤٥٦٧٨٩'[i], '$i').replaceAll('۰۱۲۳۴۵۶۷۸۹'[i], '$i');
  }
  if (plain.isEmpty) return 0;
  return RegExp(r'^\d{1,6}(\.\d*)?$').hasMatch(plain) ? double.parse(plain) : null;
}

/// Pops with the new limits, where 0 is unlimited.
class LimitsDialog extends StatefulWidget {
  const LimitsDialog({super.key, required this.user});

  final ServerUser user;

  @override
  State<LimitsDialog> createState() => _LimitsDialogState();
}

class _LimitsDialogState extends State<LimitsDialog> {
  late final _speed = TextEditingController(
    text: widget.user.speedKbps == 0 ? '' : formatNumber(widget.user.speedKbps / 1000),
  );
  late final _quota = TextEditingController(
    text: widget.user.quotaBytes == 0 ? '' : formatNumber(widget.user.quotaBytes / 1e9),
  );
  String? _speedError;
  String? _quotaError;

  @override
  void dispose() {
    _speed.dispose();
    _quota.dispose();
    super.dispose();
  }

  void _save() {
    final mbps = parseAmount(_speed.text);
    final gb = parseAmount(_quota.text);
    final kbps = mbps == null ? null : (mbps * 1000).round();
    final bytes = gb == null ? null : (gb * 1e9).round();
    setState(() {
      _speedError = kbps == null || (kbps == 0 && mbps != 0) || (kbps != 0 && (kbps < 64 || kbps > 10000000))
          ? 'Enter 0.07 to 10000, or leave empty'
          : null;
      _quotaError = bytes == null || (bytes < 10000000 && gb != 0) ? 'Enter at least 0.01, or leave empty' : null;
    });
    if (_speedError == null && _quotaError == null) {
      Navigator.pop(context, (speedKbps: kbps!, quotaBytes: bytes!));
    }
  }

  Widget _field(TextEditingController controller, String label, String unit, String helper, String? error) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        hintText: 'Unlimited',
        floatingLabelBehavior: FloatingLabelBehavior.always,
        suffixText: unit,
        helperText: helper,
        helperMaxLines: 3,
        errorText: error,
        errorMaxLines: 3,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text('Limits for ${widget.user.username}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _field(_speed, 'Speed', 'Mbps', 'Each way, shared by all their devices', _speedError),
          const SizedBox(height: 16),
          _field(_quota, 'Total data', 'GB', 'Upload and download. They are cut off when it runs out', _quotaError),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
