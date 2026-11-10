// Beam Share: fast, offline, verified file transfer.
//
// Start here. main() loads settings, then shows the HomeScreen.
// AppScope makes the two shared objects available to every screen:
//   * AppState            settings, identity, history
//   * TransferController  the current transfer

import 'package:flutter/material.dart';

import 'app/theme.dart';
import 'screens/home_screen.dart';
import 'state/app_state.dart';
import 'state/transfer_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = await AppState.load();
  final transfers = TransferController(app);
  runApp(AppScope(app: app, transfers: transfers, child: const BeamApp()));
}

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.app, required this.transfers, required super.child});

  final AppState app;
  final TransferController transfers;

  /// Use inside build().
  static AppScope of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  /// Use outside build() (initState callbacks, button handlers, ...).
  static AppScope read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope oldWidget) => false;
}

class BeamApp extends StatelessWidget {
  const BeamApp({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context).app;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => MaterialApp(
        title: 'Beam Share',
        debugShowCheckedModeBanner: false,
        themeMode: app.themeMode,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: const HomeScreen(),
      ),
    );
  }
}
