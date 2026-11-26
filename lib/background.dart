import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'immich.dart';
import 'state.dart';

// Upload while Winnow is closed (Android WorkManager, about every 15 minutes, when the network allows).

const _task = 'winnow-upload';

@pragma('vm:entry-point')
void backgroundMain() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      await AppState().backgroundSync();
    } catch (_) {
      return false; // retried later
    }
    return true;
  });
}

Future<void> initBackground() async {
  if (!Platform.isAndroid) return;
  await Workmanager().initialize(backgroundMain);
}

/// Registers or cancels the periodic upload to match the Immich settings.
Future<void> scheduleBackground(ImmichConfig c) async {
  if (!Platform.isAndroid) return;
  try {
    if (!c.enabled || !c.ready || c.background == 'off') {
      await Workmanager().cancelByUniqueName(_task);
      return;
    }
    await Workmanager().registerPeriodicTask(
      _task,
      _task,
      frequency: const Duration(minutes: 15),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      constraints: Constraints(
        networkType: c.wifiOnly ? NetworkType.unmetered : NetworkType.connected,
        requiresCharging: c.background == 'charging',
        requiresBatteryNotLow: true,
      ),
    );
  } catch (_) {}
}
