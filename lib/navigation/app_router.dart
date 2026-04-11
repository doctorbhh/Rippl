import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../screens/home_screen.dart';
import '../screens/device_scan_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/teammates_screen.dart';
import '../screens/team_setup_screen.dart';
import '../screens/mesh_visualizer_screen.dart';

/// App navigation routes
class AppRoutes {
  static const home = '/';
  static const deviceScan = '/scan';
  static const chat = '/chat';
  static const teammates = '/teammates';
  static const teamSetup = '/team-setup';
  static const meshViz = '/mesh';
}

/// GoRouter configuration
final appRouter = GoRouter(
  initialLocation: AppRoutes.home,
  routes: [
    GoRoute(
      path: AppRoutes.home,
      builder: (context, state) => const HomeScreen(),
    ),
    GoRoute(
      path: AppRoutes.deviceScan,
      builder: (context, state) => const DeviceScanScreen(),
    ),
    GoRoute(
      path: AppRoutes.chat,
      builder: (context, state) => const ChatScreen(),
    ),
    GoRoute(
      path: AppRoutes.teammates,
      builder: (context, state) => const TeammatesScreen(),
    ),
    GoRoute(
      path: AppRoutes.meshViz,
      builder: (context, state) => const MeshVisualizerScreen(),
    ),
    GoRoute(
      path: AppRoutes.teamSetup,
      pageBuilder: (context, state) => CustomTransitionPage(
        child: const TeamSetupScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
                .animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  ),
                ),
            child: child,
          );
        },
      ),
    ),
  ],
);
