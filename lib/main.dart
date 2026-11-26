import 'package:flutter/material.dart';

import 'state.dart';
import 'ui/common.dart';
import 'ui/cull.dart';
import 'ui/grid.dart';
import 'ui/screens.dart';
import 'ui/settings.dart';

const version = String.fromEnvironment('WINNOW_VERSION', defaultValue: '0.0.0-dev');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WinnowApp());
}

class WinnowApp extends StatelessWidget {
  const WinnowApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Winnow',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: C.bg,
          colorScheme: const ColorScheme.dark(
            primary: C.accent,
            secondary: C.accent,
            surface: C.surface,
            error: C.trash,
          ),
          sliderTheme: const SliderThemeData(inactiveTrackColor: C.line),
        ),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  final s = AppState();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    s.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Coming back to the app (after taking photos, or from Android settings): pick up changes.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (s.screen == Screen.access) {
      s.init();
    } else if (s.screen == Screen.cull || s.screen == Screen.grid || s.screen == Screen.explore) {
      s.reload();
      s.runSync();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Stack(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: ListenableBuilder(
                listenable: s,
                builder: (context, _) => switch (s.screen) {
                  // The same wave as during a sync, while the photo library loads.
                  Screen.loading => const Center(child: Logo(size: 40, busy: true)),
                  Screen.error => Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Text('Something went wrong', style: TextStyle(fontSize: 20)),
                        Text(s.error, style: const TextStyle(color: C.muted)),
                        Btn('Try again', onTap: s.init),
                      ]),
                    ),
                  Screen.access => AccessScreen(s),
                  Screen.start => StartScreen(s),
                  Screen.cull => CullScreen(s),
                  Screen.grid || Screen.explore => GridScreen(s),
                  Screen.trash => TrashScreen(s),
                  Screen.settings => SettingsScreen(s),
                  Screen.immich => ImmichScreen(s),
                },
              ),
            ),
            const Positioned(
              right: 8,
              bottom: 0,
              child: IgnorePointer(child: Text('v$version', style: TextStyle(color: C.muted, fontSize: 10))),
            ),
          ]),
        ),
      );
}
