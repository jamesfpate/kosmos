import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:fvp/fvp.dart' as fvp;

import 'background.dart';
import 'fx.dart';
import 'state.dart';
import 'ui/common.dart';
import 'ui/cull.dart';
import 'ui/grid.dart';
import 'ui/screens.dart';
import 'ui/settings.dart';
import 'ui/stores.dart';
import 'version.dart';


void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Video playback on Windows and Linux (video_player covers the phone and the Mac).
  fvp.registerWith(options: {
    'platforms': ['windows', 'linux'],
  });
  initBackground();
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

  bool _capturing = false;

  @override
  void didUpdateWidget(LoadingLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.done && _outlines == null && !_capturing) {
      _capturing = true;
      // Let the wordmark settle at rest for a frame, then capture exactly what's on screen.
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final box = _key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
        final o = box == null ? const Outlines([]) : await outlinesFromImage(await box.toImage(pixelRatio: 3));
        if (!mounted) return;
        setState(() {
          _outlines = Future.value(o);
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Padding so the raised and lowered letters sit inside the captured area (the outline lines up with them).
    final logo = RepaintBoundary(
      key: _key,
      child: Padding(padding: const EdgeInsets.all(16), child: Logo(size: 40, busy: !widget.done)),
    );
    if (_outlines == null) return logo;
    return TraceFx(
        outlines: _outlines, keep: true, fadeOut: true, frame: false, thickness: 1, glow: 3, child: logo);
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
                  Screen.loading => Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        LoadingLogo(done: s.loadDone),
                        // Progress under the wordmark; fades with the outro.
                        AnimatedOpacity(
                          opacity: s.loadDone ? 0 : 1,
                          duration: const Duration(milliseconds: 300),
                          child: Text(s.loading.isEmpty ? 'Loading photos…' : s.loading,
                              style: const TextStyle(color: C.muted, fontSize: 14)),
                        ),
                      ]),
                    ),
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
                  Screen.store => StoreScreen(s, key: ValueKey(s.storeKey)),
                  Screen.google => GoogleScreen(s),
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
