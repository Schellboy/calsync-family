import 'package:flutter/material.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:workmanager/workmanager.dart';

import 'screens/dashboard_screen.dart';
import 'permissions/permission_gate.dart';
import 'background/sync_task.dart';
import 'calendar/calendar_service.dart';
import 'subscriptions/subscription_service.dart';
import 'subscriptions/entitlement.dart';
import 'settings/profile_service.dart';

final subscriptionService = createSubscriptionService();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await CalendarService.initializeBuildMode();
  if (!CalendarService.isFamilyTestBuild) {
    await Workmanager().initialize(callbackDispatcher);
  }
  await subscriptionService.initialize();
  if (!subscriptionService.isSubscribed) {
    final profileService = ProfileService();
    await handleSubscriptionExpired(profileService);
  }
  subscriptionService.onStatusChanged = (isSubscribed) {
    final profileService = ProfileService();
    if (isSubscribed) {
      handleSubscriptionRestored(profileService);
    } else {
      handleSubscriptionExpired(profileService);
    }
  };
  runApp(const CalendarSyncApp());
}

class CalendarSyncApp extends StatelessWidget {
  const CalendarSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        final lightScheme = lightDynamic ?? ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
        );
        final darkScheme = darkDynamic ?? ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        );

        final lightTheme = ThemeData(
          colorScheme: lightScheme,
          useMaterial3: true,
        );

        final darkTheme = ThemeData(
          colorScheme: darkScheme,
          useMaterial3: true,
        );

        return MaterialApp(
          title: CalendarService.isFamilyTestBuild ? 'CalSync Family Test' : 'CalSync',
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: ThemeMode.system,
          home: const _SyncedGate(),
        );
      },
    );
  }
}

class _SyncedGate extends StatelessWidget {
  const _SyncedGate();

  @override
  Widget build(BuildContext context) {
    return PermissionGate(
      child: Builder(
        builder: (context) {
          return const DashboardScreen();
        },
      ),
    );
  }
}
