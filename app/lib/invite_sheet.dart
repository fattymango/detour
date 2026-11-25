import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shows a user's connection link, with ways to send it to them.
Future<void> showInviteSheet(BuildContext context, {required String username, required String server, required String link}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    useSafeArea: true,
    builder: (_) => InviteSheet(username: username, server: server, link: link),
  );
}

class InviteSheet extends StatefulWidget {
  const InviteSheet({super.key, required this.username, required this.server, required this.link});

  final String username;
  final String server;
  final String link;

  @override
  State<InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<InviteSheet> {
  static const _share = MethodChannel('detour/share');
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.link));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.vpn_key, size: 40, color: colors.primary),
          const SizedBox(height: 12),
          Text('Invite for ${widget.username}', textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
          Text('Server: ${widget.server}', textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 20),
          Material(
            color: colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _copy,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.link,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textDirection: TextDirection.ltr,
                        style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Icon(_copied ? Icons.check : Icons.copy, color: colors.primary),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'The first phone to add this link becomes ${widget.username}, and then it stops working. '
            'Send it privately. It is shown only once; you can make a new one later.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => _share.invokeMethod<void>('text', widget.link),
            icon: const Icon(Icons.share),
            label: const Text('Share'),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: _copy,
            icon: Icon(_copied ? Icons.check : Icons.copy),
            label: Text(_copied ? 'Copied' : 'Copy link'),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
        ],
      ),
    );
  }
}
