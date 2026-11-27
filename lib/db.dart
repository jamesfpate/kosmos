import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Local state in SQLite (app data; survives updates, cleared on uninstall). Each table is id -> JSON.
class Db {
  Db._(this._db);

  final Database _db;

  static Future<Db> open() async {
    final String dir;
    if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
      // sqflite's own location on a computer is beside the program (or a build folder); use the app's data folder.
      if (!Platform.isMacOS) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }
      dir = (await getApplicationSupportDirectory()).path;
    } else {
      dir = await getDatabasesPath();
    }
    final path = p.join(dir, 'winnow.db');
    // v2: b2 (Backblaze B2 uploads). v3: webdav, gphotos.
    final db = await openDatabase(
      path,
      version: 3,
      onCreate: (db, _) async {
        for (final t in ['decisions', 'albums', 'uploads', 'meta', 'b2', 'webdav', 'gphotos']) {
          await db.execute('CREATE TABLE $t (id TEXT PRIMARY KEY, json TEXT NOT NULL)');
        }
      },
      onUpgrade: (db, from, _) async {
        if (from < 2) await db.execute('CREATE TABLE b2 (id TEXT PRIMARY KEY, json TEXT NOT NULL)');
        if (from < 3) {
          for (final t in ['webdav', 'gphotos']) {
            await db.execute('CREATE TABLE $t (id TEXT PRIMARY KEY, json TEXT NOT NULL)');
          }
        }
      },
    );
    return Db._(db);
  }

  final _tables = <String>{};

  /// File stores each get a table, made the first time it's used.
  Future<void> _ensure(String table) async {
    if (_tables.contains(table)) return;
    await _db.execute('CREATE TABLE IF NOT EXISTS $table (id TEXT PRIMARY KEY, json TEXT NOT NULL)');
    _tables.add(table);
  }

  Future<List<Map<String, Object?>>> all(String table) async {
    await _ensure(table);
    final rows = await _db.query(table);
    return [for (final r in rows) jsonDecode(r['json'] as String) as Map<String, Object?>];
  }

  Future<void> put(String table, String id, Object? value) async {
    await _ensure(table);
    await _db.insert(table, {'id': id, 'json': jsonEncode(value)}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> putAll(String table, Map<String, Object?> values) async {
    await _ensure(table);
    final batch = _db.batch();
    values.forEach((id, v) {
      batch.insert(table, {'id': id, 'json': jsonEncode(v)}, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    await batch.commit(noResult: true);
  }

  Future<void> removeAll(String table, List<String> ids) async {
    final batch = _db.batch();
    for (final id in ids) {
      batch.delete(table, where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  Future<void> remove(String table, String id) => _db.delete(table, where: 'id = ?', whereArgs: [id]);

  Future<T?> getMeta<T>(String key) async {
    final rows = await _db.query('meta', where: 'id = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['json'] as String) as T?;
  }

  Future<void> setMeta(String key, Object? value) => put('meta', key, value);

  Future<Map<String, Object?>> allMeta() async {
    final rows = await _db.query('meta');
    return {for (final r in rows) r['id'] as String: jsonDecode(r['json'] as String)};
  }
}
