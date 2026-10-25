import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'colors.dart';

/// Дизайн-система Waveform.
///
/// - Inter — основной текст и заголовки.
/// - JetBrains Mono — все числа, тайм-коды, тех. метки
///   (через [AppTheme.mono]).
/// - Брутальные углы: радиус 3px. Тонкие границы: 0.5px.
abstract final class AppTheme {
  /// Радиус скруглений — брутальные углы.
  static const double radius = 3;
  static const BorderRadius borderRadius = BorderRadius.all(
    Radius.circular(radius),
  );

  /// Толщина границ.
  static const double borderWidth = 0.5;

  // Высоты постоянной «хромы» оболочки (контент скроллится под ними сквозь блюр).
  // topBarHeight = 28 (traffic-lights clearance на macOS fullSize content view)
  // + 48 (контент). Меньше — кнопки и светофор накладываются.
  static const double topBarHeight = 76;
  static const double playerHeight = 72;

  // Ритмика отступов (кратно 4) — единая по всем экранам.
  static const double pagePad = 28; // горизонтальные поля контента
  static const double sectionGap = 40; // между секциями-каруселями
  static const double headerGap = 16; // от заголовка секции до контента
  static const double cardGap = 14; // между карточками в карусели

  /// Длительность hover/press-переходов (UX-гайд: 150–300ms).
  static const Duration motion = Duration(milliseconds: 180);

  static Border border([Color color = AppColors.border]) =>
      Border.all(color: color, width: borderWidth);

  /// Const-вариант для использования внутри `const BoxDecoration`.
  static const BorderSide borderSideStatic = BorderSide(
    color: AppColors.border,
    width: borderWidth,
  );

  /// Моноширинный стиль (JetBrains Mono) для чисел, тайм-кодов
  /// и технических меток.
  static TextStyle mono({
    double size = 12,
    Color color = AppColors.textMid,
    FontWeight weight = FontWeight.w400,
    double? letterSpacing,
    double? height,
  }) => GoogleFonts.jetBrainsMono(
    fontSize: size,
    color: color,
    fontWeight: weight,
    letterSpacing: letterSpacing,
    height: height,
  );

  /// Тёмная тема — единственная на старте.
  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    final textTheme = GoogleFonts.interTextTheme(
      base.textTheme,
    ).apply(bodyColor: AppColors.textHi, displayColor: AppColors.textHi);

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.bg,
      canvasColor: AppColors.bg,
      textTheme: textTheme,
      colorScheme: const ColorScheme.dark(
        surface: AppColors.surface,
        primary: AppColors.acid,
        secondary: AppColors.lime,
        onPrimary: AppColors.bg,
        onSurface: AppColors.textHi,
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: borderWidth,
        space: borderWidth,
      ),
      iconTheme: const IconThemeData(color: AppColors.textMid, size: 18),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColors.surface2,
          border: border(),
          borderRadius: borderRadius,
        ),
        textStyle: mono(size: 11, color: AppColors.textHi),
      ),
    );
  }
}
