import 'package:flutter/painting.dart';

/// Палитра Waveform — тёмная по умолчанию.
/// Минимализм. Acid orange используется скупо: только активные элементы.
/// Lime — второй акцент: метки и маркеры (комментарии на waveform, ◆ профиля).
abstract final class AppColors {
  // Поверхности
  static const bg = Color(0xFF0A0A0A);
  static const surface = Color(0xFF111111);
  static const surface2 = Color(0xFF1A1A1A);

  // Границы / приглушённая waveform
  static const border = Color(0xFF2A2A2A);
  static const borderDim = Color(0xFF1A1A1A);
  static const waveDim = Color(0xFF3A3A3A);

  // Текст
  static const textHi = Color(0xFFF5F5F5);
  static const textMid = Color(0xFF888888);
  static const textLow = Color(0xFF555555);

  // Акценты
  static const acid = Color(0xFFFF5500); // SoundCloud orange — только активное
  static const lime = Color(0xFFC6FF00); // второй акцент: метки и маркеры
}
