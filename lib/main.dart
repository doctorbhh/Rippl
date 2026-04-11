import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'navigation/app_router.dart';
import 'providers/app_state.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // [FIX L5] Global error handlers
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Unhandled error: $error\n$stack');
    return true;
  };

  runApp(const ProviderScope(child: RipplApp()));
}

/// [FIX C4] Uses ConsumerWidget so we can eagerly init the BLE router
class RipplApp extends ConsumerWidget {
  const RipplApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Eagerly initialize the centralized BLE message router
    ref.watch(bleMessageRouterProvider);

    return MaterialApp.router(
      title: 'Rippl',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      routerConfig: appRouter,
    );
  }
}
