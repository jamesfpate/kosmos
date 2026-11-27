import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

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

/// Registers or cancels the periodic upload: runs if any integration that's on wants background upload (one entry
/// each in [wants]); only while charging / only on Wi-Fi when every one of them asks for that.
Future<void> scheduleBackground(List<({String bg, bool wifi})> wants) async {
  if (!Platform.isAndroid) return;
  try {
    if (wants.isEmpty) {
      await Workmanager().cancelByUniqueName(_task);
      return;
    }
    await Workmanager().registerPeriodicTask(
      _task,
      _task,
      frequency: const Duration(minutes: 15),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      constraints: Constraints(
        networkType: wants.every((w) => w.wifi) ? NetworkType.unmetered : NetworkType.connected,
        requiresCharging: wants.every((w) => w.bg == 'charging'),
        requiresBatteryNotLow: true,
      ),
    );
  } catch (_) {}
}
