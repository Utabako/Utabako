import 'package:flutter/material.dart';

/// Semantic colors from the v3 design (design-demo-v3/styles.css) that ColorScheme has no slot for.
@immutable
class NexColors extends ThemeExtension<NexColors> {
  /// Page background behind cards.
  final Color background;

  /// Secondary fill: chips, inputs, node tiles, icon wells.
  final Color surface2;
  final Color muted;
  final Color faint;
  final Color border;
  final Color accentSoft;
  final Color good;
  final Color warn;
  final Color bad;
  final Color goodSoft;
  final Color badSoft;

  /// Chart series: downlink, uplink, connection count.
  final Color down;
  final Color up;
  final Color conn;

  const NexColors({
    required this.background,
    required this.surface2,
    required this.muted,
    required this.faint,
    required this.border,
    required this.accentSoft,
    required this.good,
    required this.warn,
    required this.bad,
    required this.goodSoft,
    required this.badSoft,
    required this.down,
    required this.up,
    required this.conn,
  });

  static const light = NexColors(
    background: Color(0xFFF2F3F7),
    surface2: Color(0xFFECEEF4),
    muted: Color(0xFF6B7080),
    faint: Color(0xFFA3A8B5),
    border: Color(0xFFE3E5EB),
    accentSoft: Color(0x1C2F6BFF),
    good: Color(0xFF129A4C),
    warn: Color(0xFFC98000),
    bad: Color(0xFFE5484D),
    goodSoft: Color(0x1F129A4C),
    badSoft: Color(0x1CE5484D),
    down: Color(0xFF2F6BFF),
    up: Color(0xFFF08C2E),
    conn: Color(0xFF8B5CF6),
  );

  static const dark = NexColors(
    background: Color(0xFF0F1115),
    surface2: Color(0xFF252932),
    muted: Color(0xFF8F95A5),
    faint: Color(0xFF5C6270),
    border: Color(0xFF2A2E37),
    accentSoft: Color(0x2678A2FF),
    good: Color(0xFF3CCF7A),
    warn: Color(0xFFF0B232),
    bad: Color(0xFFFF6B6B),
    goodSoft: Color(0x243CCF7A),
    badSoft: Color(0x21FF6B6B),
    down: Color(0xFF78A2FF),
    up: Color(0xFFFFAD5C),
    conn: Color(0xFFB39BFF),
  );

  static NexColors of(BuildContext context) =>
      Theme.of(context).extension<NexColors>()!;

  @override
  NexColors copyWith({
    Color? background,
    Color? surface2,
    Color? muted,
    Color? faint,
    Color? border,
    Color? accentSoft,
    Color? good,
    Color? warn,
    Color? bad,
    Color? goodSoft,
    Color? badSoft,
    Color? down,
    Color? up,
    Color? conn,
  }) => NexColors(
    background: background ?? this.background,
    surface2: surface2 ?? this.surface2,
    muted: muted ?? this.muted,
    faint: faint ?? this.faint,
    border: border ?? this.border,
    accentSoft: accentSoft ?? this.accentSoft,
    good: good ?? this.good,
    warn: warn ?? this.warn,
    bad: bad ?? this.bad,
    goodSoft: goodSoft ?? this.goodSoft,
    badSoft: badSoft ?? this.badSoft,
    down: down ?? this.down,
    up: up ?? this.up,
    conn: conn ?? this.conn,
  );

  @override
  NexColors lerp(NexColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return NexColors(
      background: l(background, other.background),
      surface2: l(surface2, other.surface2),
      muted: l(muted, other.muted),
      faint: l(faint, other.faint),
      border: l(border, other.border),
      accentSoft: l(accentSoft, other.accentSoft),
      good: l(good, other.good),
      warn: l(warn, other.warn),
      bad: l(bad, other.bad),
      goodSoft: l(goodSoft, other.goodSoft),
      badSoft: l(badSoft, other.badSoft),
      down: l(down, other.down),
      up: l(up, other.up),
      conn: l(conn, other.conn),
    );
  }
}

class AppTheme {
  /// Card corner radius from the v3 design.
  static const cardRadius = 22.0;

  static ThemeData light() => _build(
    Brightness.light,
    NexColors.light,
    accent: const Color(0xFF2F6BFF),
    onAccent: Colors.white,
    surface: Colors.white,
    onSurface: const Color(0xFF15171C),
  );

  static ThemeData dark() => _build(
    Brightness.dark,
    NexColors.dark,
    accent: const Color(0xFF78A2FF),
    onAccent: const Color(0xFF0B1020),
    surface: const Color(0xFF1A1D23),
    onSurface: const Color(0xFFE9EBF0),
  );

  static ThemeData _build(
    Brightness brightness,
    NexColors nex, {
    required Color accent,
    required Color onAccent,
    required Color surface,
    required Color onSurface,
  }) {
    final cs = ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
        .copyWith(
          primary: accent,
          onPrimary: onAccent,
          surface: surface,
          onSurface: onSurface,
          onSurfaceVariant: nex.muted,
          surfaceContainerLowest: nex.background,
          surfaceContainerLow: surface,
          surfaceContainer: surface,
          surfaceContainerHigh: nex.surface2,
          surfaceContainerHighest: nex.surface2,
          outline: nex.faint,
          outlineVariant: nex.border,
          error: nex.bad,
          surfaceTint: Colors.transparent,
        );
    return ThemeData(
      colorScheme: cs,
      useMaterial3: true,
      scaffoldBackgroundColor: nex.background,
      extensions: [nex],
      dividerColor: nex.border,
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
        ),
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: nex.background,
        surfaceTintColor: Colors.transparent,
        foregroundColor: onSurface,
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: onSurface,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        height: 68,
        backgroundColor: nex.background,
        surfaceTintColor: Colors.transparent,
        indicatorColor: nex.accentSoft,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? accent : nex.muted,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
            color: states.contains(WidgetState.selected)
                ? onSurface
                : nex.muted,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: const StadiumBorder(),
          side: BorderSide(color: nex.border),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide.none,
        backgroundColor: nex.surface2,
        selectedColor: nex.accentSoft,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: nex.border, width: 1.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: nex.border, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: accent, width: 1.5),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: onSurface,
        contentTextStyle: TextStyle(color: nex.background),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16),
      ),
    );
  }
}
