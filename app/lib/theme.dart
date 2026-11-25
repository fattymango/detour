import 'package:flutter/material.dart';

ThemeData detourTheme(Brightness brightness) {
  final light = brightness == Brightness.light;
  final colors = ColorScheme.fromSeed(seedColor: const Color(0xFF534AB7), brightness: brightness).copyWith(
    primary: Color(light ? 0xFF534AB7 : 0xFFAFA9EC),
    onPrimary: Color(light ? 0xFFFFFFFF : 0xFF26215C),
    primaryContainer: Color(light ? 0xFFE6E4FC : 0xFF3C3489),
    onPrimaryContainer: Color(light ? 0xFF3C3489 : 0xFFDCDAFA),
  );
  final base = ThemeData(colorScheme: colors, useMaterial3: true);
  const buttonSize = Size(64, 52);
  return base.copyWith(
    // Android's plain ripple, without Material 3's sparkles.
    splashFactory: InkRipple.splashFactory,
    scaffoldBackgroundColor: colors.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: colors.surface,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(fontSize: 22, fontWeight: FontWeight.w500, color: colors.onSurface),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colors.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(minimumSize: buttonSize)),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      errorMaxLines: 3,
      helperMaxLines: 3,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// Colors that mean the same thing everywhere in the app.
class StatusColors {
  const StatusColors({required this.fill, required this.halo, required this.onFill});

  final Color fill;
  final Color halo;
  final Color onFill;

  static StatusColors _pick(BuildContext context, (int, int) light, (int, int) dark) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final (fill, halo) = isDark ? dark : light;
    return StatusColors(fill: Color(fill), halo: Color(halo), onFill: Colors.white);
  }

  static StatusColors connected(BuildContext c) => _pick(c, (0xFF0F6E56, 0xFFD5F0E5), (0xFF1A8A67, 0xFF0B3A2D));
  static StatusColors busy(BuildContext c) => _pick(c, (0xFF854F0B, 0xFFFAEEDA), (0xFFA8690F, 0xFF412402));
  static StatusColors standby(BuildContext c) => _pick(c, (0xFF185FA5, 0xFFE0EEFB), (0xFF2A78C4, 0xFF042C53));
  static StatusColors error(BuildContext c) => _pick(c, (0xFFA32D2D, 0xFFFCEBEB), (0xFFC94040, 0xFF501313));

  static StatusColors off(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return StatusColors(fill: colors.primary, halo: colors.primaryContainer, onFill: colors.onPrimary);
  }
}

/// A tappable card with an icon, a title and a line of detail.
class InfoCard extends StatelessWidget {
  const InfoCard({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    this.detailColor,
    this.trailing,
    this.selected = false,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Color? detailColor;
  final Widget? trailing;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card(
      shape: selected
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: colors.primary, width: 2),
            )
          : null,
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 16, right: 8),
        minTileHeight: 68,
        onTap: onTap,
        leading: Icon(icon, color: selected ? colors.primary : colors.onSurfaceVariant),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
        subtitle: Text(
          detail,
          style: theme.textTheme.bodyMedium?.copyWith(color: detailColor ?? colors.onSurfaceVariant),
        ),
        trailing: trailing ?? (onTap == null ? null : const Padding(
          padding: EdgeInsets.only(right: 8),
          child: Icon(Icons.chevron_right),
        )),
      ),
    );
  }
}

/// What to show when a screen has nothing, or failed to load.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.body, this.action});

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 40,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(icon, size: 36, color: theme.colorScheme.onPrimaryContainer),
            ),
            const SizedBox(height: 24),
            Text(title, textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
  }
}

/// A main action pinned within thumb reach.
class BottomAction extends StatelessWidget {
  const BottomAction({super.key, required this.child, this.note});

  final Widget child;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (note != null) ...[
              Text(
                note!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

Future<bool> confirm(BuildContext context, {required String title, required String message, required String action}) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
          ],
        ),
      ) ??
      false;
}

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
