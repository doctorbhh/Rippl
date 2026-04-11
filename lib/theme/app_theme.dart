import 'package:flutter/material.dart';

/// Mountain/outdoor themed dark color palette
class AppColors {
  // Primary colors
  static const deepForestGreen = Color(0xFF1B4332);
  static const forestGreen = Color(0xFF2D6A4F);
  static const lightForest = Color(0xFF40916C);

  // Accent colors
  static const safetyOrange = Color(0xFFFF6B35);
  static const alertOrange = Color(0xFFFF8C42);

  // Background colors
  static const darkSlate = Color(0xFF0D1B2A);
  static const slateGray = Color(0xFF1B263B);
  static const cardBackground = Color(0xFF243447);

  // Text colors
  static const textPrimary = Color(0xFFE0E1DD);
  static const textSecondary = Color(0xFF9BA4B5);
  static const textMuted = Color(0xFF6B7280);

  // Status colors
  static const connected = Color(0xFF4ADE80);
  static const disconnected = Color(0xFFEF4444);
  static const warning = Color(0xFFFBBF24);

  // Signal strength colors
  static const signalExcellent = Color(0xFF4ADE80);
  static const signalGood = Color(0xFF86EFAC);
  static const signalFair = Color(0xFFFBBF24);
  static const signalPoor = Color(0xFFEF4444);
}

/// App theme configuration
class AppTheme {
  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.darkSlate,
      primaryColor: AppColors.deepForestGreen,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.deepForestGreen,
        secondary: AppColors.safetyOrange,
        surface: AppColors.slateGray,
        error: AppColors.disconnected,
        onPrimary: AppColors.textPrimary,
        onSecondary: AppColors.darkSlate,
        onSurface: AppColors.textPrimary,
        onError: AppColors.textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.darkSlate,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.cardBackground,
        elevation: 4,
        shadowColor: Colors.black45,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.safetyOrange,
          foregroundColor: AppColors.darkSlate,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.safetyOrange,
          side: const BorderSide(color: AppColors.safetyOrange, width: 2),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: AppColors.safetyOrange),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.cardBackground,
        hintStyle: const TextStyle(color: AppColors.textMuted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.safetyOrange, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.disconnected, width: 2),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.safetyOrange,
        foregroundColor: AppColors.darkSlate,
      ),
      iconTheme: const IconThemeData(color: AppColors.textSecondary),
      dividerTheme: const DividerThemeData(
        color: AppColors.slateGray,
        thickness: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.cardBackground,
        contentTextStyle: const TextStyle(color: AppColors.textPrimary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.slateGray,
        selectedItemColor: AppColors.safetyOrange,
        unselectedItemColor: AppColors.textMuted,
      ),
    );
  }
}

/// Text styles for the app
class AppTextStyles {
  static const headline1 = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.bold,
    color: AppColors.textPrimary,
    letterSpacing: -0.5,
  );

  static const headline2 = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  static const headline3 = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  static const body1 = TextStyle(fontSize: 16, color: AppColors.textPrimary);

  static const body2 = TextStyle(fontSize: 14, color: AppColors.textSecondary);

  static const caption = TextStyle(fontSize: 12, color: AppColors.textMuted);

  static const button = TextStyle(fontSize: 16, fontWeight: FontWeight.w600);
}

/// Spacing constants
class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}
