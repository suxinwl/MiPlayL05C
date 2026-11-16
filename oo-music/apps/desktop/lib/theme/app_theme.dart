import 'package:flutter/material.dart';

/// 全端共用的视觉常量。
///
/// 颜色、间距与圆角都从这里读取，避免 macOS、Windows 和 Android 在后续
/// 适配时形成彼此独立的视觉规则。
abstract final class AppColors {
  static const accent = Color(0xFF69DFA0);
  static const accentStrong = Color(0xFF7BE2A7);
  static const accentSoft = Color(0xFF20362A);
  static const accentBorder = Color(0xFF315440);
  static const accentOn = Color(0xFF0B2014);

  static const background = Color(0xFF101218);
  static const backgroundGlow = Color(0xFF18241E);
  static const surface = Color(0xFF171A21);
  static const surfaceRaised = Color(0xFF1A1E26);
  static const surfaceHigh = Color(0xFF20242D);
  static const surfaceHover = Color(0xFF222831);
  static const surfaceDisabled = Color(0xFF20242D);

  static const border = Color(0xFF282C36);
  static const borderStrong = Color(0xFF343A45);
  static const borderDisabled = Color(0xFF303540);

  static const textPrimary = Color(0xFFF0F3F7);
  static const textSecondary = Color(0xFFAEB6C2);
  static const textMuted = Color(0xFF7D8593);
  static const textDisabled = Color(0xFF626B78);

  static const info = Color(0xFF8AA9FF);
  static const infoSurface = Color(0xFF20283B);

  static const warning = Color(0xFFF0AD82);
  static const warningSurface = Color(0xFF3A2821);
  static const warningBorder = Color(0xFF674431);

  static const error = Color(0xFFE58A72);
  static const errorSurface = Color(0xFF382522);
  static const errorBorder = Color(0xFF623A34);

  static const lyricActive = Color(0xFF78E6A9);
  static const lyricTranslation = Color(0xFF9CA3AF);
  static const lyricRomanization = Color(0xFF757D8A);

  static const overlay = Color(0xA6000000);
  static const shadow = Color(0x66000000);
  static const shadowSoft = Color(0x33000000);
}

/// 全端共用的圆角规格。
abstract final class AppRadii {
  static const small = 8.0;
  static const control = 11.0;
  static const input = 12.0;
  static const tile = 14.0;
  static const search = 16.0;
  static const panel = 22.0;
  static const dialog = 24.0;
  static const pill = 999.0;
}

/// 全端共用的间距规格。
abstract final class AppSpacing {
  static const xxs = 4.0;
  static const xs = 6.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 18.0;
  static const xl = 24.0;
  static const xxl = 28.0;
}

/// 轻量鼠标悬停与状态过渡时长。
abstract final class AppDurations {
  static const fast = Duration(milliseconds: 140);
  static const normal = Duration(milliseconds: 220);
}

/// 创建完整应用主题。
ThemeData buildAppTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
    surface: AppColors.surface,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.surface,
    fontFamilyFallback: const <String>[
      'PingFang SC',
      'Hiragino Sans GB',
      'Noto Sans CJK SC',
    ],
    textTheme: const TextTheme(
      headlineSmall: TextStyle(
        color: AppColors.textPrimary,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
      ),
      titleMedium: TextStyle(color: Color(0xFFE8EBF0)),
      bodyMedium: TextStyle(color: Color(0xFFB4BBC7)),
      bodySmall: TextStyle(color: Color(0xFF8F97A5)),
    ),
    dividerColor: AppColors.border,
    focusColor: AppColors.accent.withValues(alpha: 0.16),
    splashFactory: InkSparkle.splashFactory,
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: AppColors.accent,
      selectionColor: Color(0x5569DFA0),
      selectionHandleColor: AppColors.accent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceRaised,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      labelStyle: const TextStyle(color: Color(0xFF98A1AF), fontSize: 13),
      floatingLabelStyle: const TextStyle(
        color: AppColors.accentStrong,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      hintStyle: const TextStyle(color: Color(0xFF656E7C), fontSize: 13),
      counterStyle: const TextStyle(color: Color(0xFF66707E), fontSize: 10),
      prefixIconColor: const Color(0xFF7C8593),
      suffixIconColor: const Color(0xFF7C8593),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.input),
        borderSide: const BorderSide(color: Color(0xFF303641)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.input),
        borderSide: const BorderSide(color: Color(0xFF303641)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.input),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.input),
        borderSide: const BorderSide(color: AppColors.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.input),
        borderSide: const BorderSide(color: AppColors.error, width: 1.2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 42)),
        padding: const WidgetStatePropertyAll<EdgeInsets>(
          EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        ),
        shape: WidgetStatePropertyAll<RoundedRectangleBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
        textStyle: const WidgetStatePropertyAll<TextStyle>(
          TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 42)),
        padding: const WidgetStatePropertyAll<EdgeInsets>(
          EdgeInsets.symmetric(horizontal: 17, vertical: 10),
        ),
        foregroundColor: const WidgetStatePropertyAll<Color>(Color(0xFFD5DBE5)),
        side: const WidgetStatePropertyAll<BorderSide>(
          BorderSide(color: Color(0xFF353B46)),
        ),
        shape: WidgetStatePropertyAll<RoundedRectangleBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 40)),
        foregroundColor: const WidgetStatePropertyAll<Color>(
          AppColors.textSecondary,
        ),
        shape: WidgetStatePropertyAll<RoundedRectangleBorder>(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: const WidgetStatePropertyAll<Color>(Color(0xFF929AA8)),
        overlayColor: WidgetStatePropertyAll<Color>(
          AppColors.accent.withValues(alpha: 0.08),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.dialog),
        side: const BorderSide(color: Color(0xFF303641)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 16,
      textStyle: const TextStyle(color: Color(0xFFDCE2EB), fontSize: 13),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.tile),
        side: const BorderSide(color: AppColors.borderStrong),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll<Color>(
          AppColors.surfaceHigh,
        ),
        surfaceTintColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
        shape: WidgetStatePropertyAll<RoundedRectangleBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.tile),
            side: const BorderSide(color: AppColors.borderStrong),
          ),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF252C35),
      contentTextStyle: const TextStyle(color: Color(0xFFE7EBF1), fontSize: 13),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.input),
      ),
      insetPadding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xFF292F39),
      thickness: 1,
      space: 1,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: const Color(0xFF252A34),
        borderRadius: BorderRadius.circular(AppRadii.small),
      ),
      textStyle: const TextStyle(color: Color(0xFFDBE0E9), fontSize: 12),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(const Color(0xFF3A404C)),
      radius: const Radius.circular(8),
      thickness: WidgetStateProperty.all(5),
    ),
  );
}

/// 应用内统一的卡片/面板背景。
BoxDecoration appPanelDecoration({
  Color? color,
  bool elevated = false,
  double radius = AppRadii.panel,
}) {
  return BoxDecoration(
    color: color ?? AppColors.surface,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: AppColors.border),
    boxShadow: elevated
        ? const <BoxShadow>[
            BoxShadow(
              color: AppColors.shadowSoft,
              blurRadius: 24,
              offset: Offset(0, 12),
            ),
          ]
        : null,
  );
}

/// 应用内统一的高层级弹窗背景。
BoxDecoration appDialogDecoration({bool elevated = true}) {
  return BoxDecoration(
    gradient: const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: <Color>[Color(0xFF1B2029), Color(0xFF14171E)],
    ),
    borderRadius: BorderRadius.circular(AppRadii.dialog),
    border: Border.all(color: AppColors.borderStrong),
    boxShadow: elevated
        ? const <BoxShadow>[
            BoxShadow(
              color: AppColors.shadow,
              blurRadius: 36,
              offset: Offset(0, 18),
            ),
          ]
        : null,
  );
}
