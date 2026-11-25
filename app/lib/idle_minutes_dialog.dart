import 'package:flutter/material.dart';

import 'limits_dialog.dart';

String formatMinutes(int minutes) => minutes == 1 ? '1 minute' : '$minutes minutes';

/// Pops with the chosen number of minutes.
class IdleMinutesDialog extends StatefulWidget {
  const IdleMinutesDialog({super.key, required this.minutes});

  final int minutes;

  @override
  State<IdleMinutesDialog> createState() => _IdleMinutesDialogState();
}

class _IdleMinutesDialogState extends State<IdleMinutesDialog> {
  late final _minutes = TextEditingController(text: '${widget.minutes}');
  String? _error;

  @override
  void dispose() {
    _minutes.dispose();
    super.dispose();
  }

  void _save() {
    final value = parseAmount(_minutes.text);
    if (value == null || value < 1 || value > 1440 || value != value.roundToDouble()) {
      setState(() => _error = 'Enter a whole number from 1 to 1440');
      return;
    }
    Navigator.pop(context, value.toInt());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('After'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final m in const [5, 10, 15, 30, 60])
                ActionChip(label: Text('$m'), onPressed: () => Navigator.pop(context, m)),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _minutes,
            keyboardType: TextInputType.number,
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              labelText: 'Minutes',
              helperText: 'Android may add a few minutes while the phone is asleep',
              helperMaxLines: 3,
              errorText: _error,
              errorMaxLines: 3,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
