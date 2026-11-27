import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'models.dart';
import 'store.dart';

// SFTP to any server or NAS (Unraid, TrueNAS, Synology, a Linux box). Folders are made as needed; a photo whose album
// changes is renamed into place. The server's host key is remembered the first time and checked after that.

const sftpDef = StoreDef(
  key: 'sftp',
  title: 'SFTP (NAS or server)',
  label: 'SFTP',
  intro: [
    'Kept photos are copied, original files, into a folder on your NAS or server over SFTP, by album. Moving a photo '
        'or renaming an album moves its files.',
    'Folder: relative to the user\'s home, or a full path like /mnt/user/photos/. Sign in with a password or paste a '
        'private key (OpenSSH format). The server\'s identity is remembered on the first connection.',
  ],
  fields: [
    FieldDef('host', 'Server', 'nas.local or 192.168.1.10'),
    FieldDef('port', 'Port', '22', optional: true),
    FieldDef('user', 'User name', 'you'),
    FieldDef('password', 'Password', 'password (or use a key)', secret: true, optional: true),
    FieldDef('key', 'Private key', '-----BEGIN OPENSSH PRIVATE KEY-----', lines: 4, optional: true),
  ],
  make: _make,
);

FileStore _make(StoreConfig c, void Function(String, String) remember) => SftpApi(c, remember);

class SftpApi extends FileStore {
  SftpApi(this.cfg, this.remember);

  final StoreConfig cfg;
  final void Function(String, String) remember;
  SSHClient? _ssh;
  SftpClient? _sftp;
  final _made = <String>{};

  static String _hex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(':');

  Future<SftpClient> _connect() async {
    if (_sftp != null) return _sftp!;
    if (cfg['password'].isEmpty && cfg['key'].trim().isEmpty) throw Exception('SFTP: add a password or a private key');
    final socket = await SSHSocket.connect(cfg['host'].trim(), int.tryParse(cfg['port'].trim()) ?? 22,
        timeout: const Duration(seconds: 15));
    String? seen;
    _ssh = SSHClient(
      socket,
      username: cfg['user'].trim(),
      onPasswordRequest: cfg['password'].isEmpty ? null : () => cfg['password'],
      identities: cfg['key'].trim().isEmpty ? null : SSHKeyPair.fromPem(cfg['key'].trim()),
      onVerifyHostKey: (type, fingerprint) {
        seen = '$type ${_hex(fingerprint)}';
        final known = cfg['hostKey'];
        return known.isEmpty || known == seen;
      },
    );
    try {
      await _ssh!.authenticated;
    } catch (e) {
      final known = cfg['hostKey'];
      if (known.isNotEmpty && seen != null && seen != known) {
        throw Exception('SFTP: the server\'s identity changed (was $known, now $seen). If you reinstalled it, clear '
            'the remembered key on this page.');
      }
      throw Exception('SFTP: could not sign in ($e)');
    }
    if (cfg['hostKey'].isEmpty && seen != null) remember('hostKey', seen!);
    return _sftp = await _ssh!.sftp();
  }

  @override
  Future<String> authorize() async {
    final s = await _connect();
    final home = await s.absolute('.');
    return '${cfg['user']}@${cfg['host']} ($home)';
  }

  Future<void> _dirs(String path) async {
    final s = await _connect();
    final parts = path.split('/')..removeLast();
    var at = path.startsWith('/') ? '' : '.';
    for (final p in parts.where((p) => p.isNotEmpty)) {
      at = '$at/$p';
      if (_made.contains(at)) continue;
      try {
        await s.mkdir(at);
      } on SftpStatusError {
        // Already there (or not allowed: the upload will say so).
      }
      _made.add(at);
    }
  }

  @override
  Future<String> upload(Item item, String path) async {
    final file = await item.file();
    if (file == null) throw Exception('could not read ${item.name}');
    final s = await _connect();
    await _dirs(path);
    final f = await s.open(path,
        mode: SftpFileOpenMode.create | SftpFileOpenMode.truncate | SftpFileOpenMode.write);
    try {
      await f.write(file.openRead().map(Uint8List.fromList)).done;
    } finally {
      await f.close();
    }
    return path;
  }

  @override
  Future<String> move(FileRecord r, String path) async {
    final s = await _connect();
    await _dirs(path);
    await s.rename(r.fileName, path);
    return path;
  }

  @override
  Future<bool> exists(FileRecord r) async {
    final s = await _connect();
    try {
      await s.stat(r.fileName);
      return true;
    } on SftpStatusError {
      return false;
    }
  }

  @override
  void close() {
    _sftp?.close();
    _ssh?.close();
    clearFileCache();
  }
}
