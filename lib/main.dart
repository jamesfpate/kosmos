import 'package:flutter/material.dart';

import 'package:flutter/rendering.dart';

import 'fx.dart';
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

/// The wordmark waving while the library loads; when [done], its letters trace (like a kept photo) and it fades.
class LoadingLogo extends StatefulWidget {
  const LoadingLogo({super.key, required this.done});

  final bool done;

  @override
  State<LoadingLogo> createState() => _LoadingLogoState();
}

class _LoadingLogoState extends State<LoadingLogo> {
  final _key = GlobalKey();
  Future<Outlines>? _outlines;

  @override
  void didUpdateWidget(LoadingLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.done && _outlines == null) {
      final box = _key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      _outlines = box == null ? Future.value(const Outlines([])) : box.toImage(pixelRatio: 2).then(outlinesFromImage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final logo = RepaintBoundary(key: _key, child: Logo(size: 40, busy: !widget.done));
    if (_outlines == null) return logo;
    return TraceFx(outlines: _outlines, keep: true, fadeOut: true, frame: false, child: logo);
  }
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
                  Screen.loading => Center(child: LoadingLogo(done: s.loadDone)),
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
