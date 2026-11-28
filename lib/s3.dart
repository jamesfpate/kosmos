import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'models.dart';
import 'store.dart';

// S3-compatible object storage (AWS S3, Cloudflare R2, Wasabi, MinIO, Backblaze's S3 endpoint, ...), signed with AWS
// Signature V4, path-style URLs (endpoint/bucket/key) which every provider accepts. Moving = copy, then delete.

const s3Def = StoreDef(
  key: 's3',
  title: 'S3-compatible storage',
  label: 'S3',
  intro: [
    'Kept photos are copied, original files, into a bucket by album: AWS S3, Cloudflare R2, Wasabi, MinIO and other '
        'S3-compatible storage. Moving a photo or renaming an album moves its files.',
    'Endpoint examples: https://s3.eu-central-1.amazonaws.com, https://ACCOUNT.r2.cloudflarestorage.com (region '
        'auto), https://s3.wasabisys.com, http://nas:9000 (MinIO). Use a key that can only read and write this bucket.',
  ],
  fields: [
    FieldDef('endpoint', 'Endpoint', 'https://s3.example.com', url: true),
    FieldDef('region', 'Region', 'us-east-1'),
    FieldDef('bucket', 'Bucket', 'my-photos'),
    FieldDef('accessKey', 'Access key', 'AKIA…'),
    FieldDef('secretKey', 'Secret key', 'secret', secret: true),
  ],
  folderLabel: 'Folder in the bucket',
  make: _make,
);

FileStore _make(StoreConfig c, void Function(String, String) remember) => S3Api(c);

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

List<int> _hmac(List<int> key, String data) => Hmac(sha256, key).convert(utf8.encode(data)).bytes;

/// RFC 3986 encoding as SigV4 wants it ('/' kept in paths).
String _enc(String s, {bool slash = false}) {
  final out = StringBuffer();
  for (final b in utf8.encode(s)) {
    final c = String.fromCharCode(b);
    if (RegExp(r'[A-Za-z0-9\-._~]').hasMatch(c) || (slash && c == '/')) {
      out.write(c);
    } else {
      out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

class S3Api extends FileStore {
  S3Api(this.cfg);

  final StoreConfig cfg;
  final _client = http.Client();

  String get _endpoint {
    var e = cfg['endpoint'].trim().replaceAll(RegExp(r'/+$'), '');
    if (e.isNotEmpty && !RegExp(r'^https?://').hasMatch(e)) e = 'https://$e';
    return e;
  }

  String get _bucket => cfg['bucket'].trim();
  String get _region => cfg['region'].trim().isEmpty ? 'us-east-1' : cfg['region'].trim();

  /// Path (after the host) for a key in the bucket.
  String _path(String key) => '/${_enc(_bucket)}${key.isEmpty ? '' : '/${_enc(objectKey(key), slash: true)}'}';

  /// Signs a request (SigV4) and returns its headers.
  Map<String, String> _sign(String method, Uri uri, String payloadHash, [Map<String, String> extra = const {}]) {
    final now = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final date = '${now.year}${two(now.month)}${two(now.day)}';
    final amzDate = '${date}T${two(now.hour)}${two(now.minute)}${two(now.second)}Z';
    final headers = <String, String>{
      'host': uri.hasPort && !((uri.scheme == 'https' && uri.port == 443) || (uri.scheme == 'http' && uri.port == 80))
          ? '${uri.host}:${uri.port}'
          : uri.host,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': amzDate,
      for (final e in extra.entries) e.key.toLowerCase(): e.value.trim(),
    };
    final names = headers.keys.toList()..sort();
    final query = (uri.queryParameters.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
        .map((e) => '${_enc(e.key)}=${_enc(e.value)}')
        .join('&');
    final canonical = [
      method,
      uri.path.isEmpty ? '/' : uri.path,
      query,
      for (final n in names) '$n:${headers[n]}',
      '',
      names.join(';'),
      payloadHash,
    ].join('\n');
    final scope = '$date/$_region/s3/aws4_request';
    final toSign = ['AWS4-HMAC-SHA256', amzDate, scope, _hex(sha256.convert(utf8.encode(canonical)).bytes)].join('\n');
    var key = _hmac(utf8.encode('AWS4${cfg['secretKey'].trim()}'), date);
    key = _hmac(key, _region);
    key = _hmac(key, 's3');
    key = _hmac(key, 'aws4_request');
    final sig = _hex(_hmac(key, toSign));
    return {
      ...headers..remove('host'),
      'Authorization':
          'AWS4-HMAC-SHA256 Credential=${cfg['accessKey'].trim()}/$scope, SignedHeaders=${names.join(';')}, Signature=$sig',
    };
  }

  static final _empty = _hex(sha256.convert(const []).bytes);

  Future<http.Response> _send(String method, String key, [Map<String, String> extra = const {}]) async {
    final uri = Uri.parse('$_endpoint${_path(key)}');
    final req = http.Request(method, uri)..headers.addAll(_sign(method, uri, _empty, extra));
    return http.Response.fromStream(await _client.send(req));
  }

  void _check(http.Response res, String what) {
    if (res.statusCode >= 400 || res.body.contains('<Error>')) {
      final code = RegExp(r'<Code>([^<]+)</Code>').firstMatch(res.body)?[1] ?? '';
      throw Exception('S3 ${res.statusCode}${code.isEmpty ? '' : ' $code'} $what');
    }
  }

  @override
  Future<String> authorize() async {
    final res = await _send('HEAD', '');
    if (res.statusCode == 404) throw Exception('S3: no bucket named "$_bucket" at $_endpoint');
    if (res.statusCode == 403) throw Exception('S3 403: the key can\'t access "$_bucket" (or the region is wrong)');
    _check(res, 'checking the bucket');
    return '$_endpoint/$_bucket';
  }

  @override
  Future<String> upload(Item item, String path) async {
    final file = await item.file();
    if (file == null) throw Exception('could not read ${item.name}');
    final digest = _hex((await sha256.bind(file.openRead()).first).bytes);
    final uri = Uri.parse('$_endpoint${_path(path)}');
    final length = await file.length();
    final type = item.mimeType ?? 'application/octet-stream';
    final req = http.StreamedRequest('PUT', uri)
      ..headers.addAll(_sign('PUT', uri, digest, {'content-type': type}))
      ..contentLength = length;
    file.openRead().listen(req.sink.add, onDone: req.sink.close, onError: req.sink.addError);
    final res = await http.Response.fromStream(await _client.send(req));
    _check(res, 'uploading ${item.name}');
    return objectKey(path);
  }

  @override
  Future<String> move(FileRecord r, String path) async {
    final copy = await _send('PUT', path, {'x-amz-copy-source': _path(r.fileName)});
    _check(copy, 'copying ${r.fileName}');
    final del = await _send('DELETE', r.fileName);
    if (del.statusCode >= 400 && del.statusCode != 404) _check(del, 'removing ${r.fileName}');
    return objectKey(path);
  }

  @override
  Future<bool> exists(FileRecord r) async {
    final res = await _send('HEAD', r.fileName);
    if (res.statusCode == 404) return false;
    _check(res, 'checking ${r.fileName}');
    return true;
  }

  @override
  Future<List<RemoteFile>> list(String dir) async {
    final prefix = '${objectKey(dir)}/';
    final out = <RemoteFile>[];
    String? token;
    do {
      final uri = Uri.parse('$_endpoint${_path('')}').replace(queryParameters: {
        'list-type': '2',
        'prefix': prefix,
        'delimiter': '/',
        'continuation-token': ?token,
      });
      final req = http.Request('GET', uri)..headers.addAll(_sign('GET', uri, _empty));
      final res = await http.Response.fromStream(await _client.send(req));
      _check(res, 'listing $dir');
      for (final m in RegExp(r'<Contents>(.*?)</Contents>', dotAll: true).allMatches(res.body)) {
        String? tag(String t) => RegExp('<$t>([^<]*)</$t>').firstMatch(m[1]!)?[1];
        final key = _xml(tag('Key') ?? '');
        final size = int.tryParse(tag('Size') ?? '');
        if (key.isEmpty || size == null || key.endsWith('/')) continue;
        // A single-part upload's ETag is its MD5; a multipart one's has a "-parts" suffix and isn't.
        final etag = _xml(tag('ETag') ?? '').replaceAll('"', '').toLowerCase();
        final name = key.substring(prefix.length);
        final path = dir.isEmpty ? name : '$dir/$name';
        out.add(RemoteFile(path, key, size, md5: RegExp(r'^[0-9a-f]{32}$').hasMatch(etag) ? etag : null));
      }
      token = res.body.contains('<IsTruncated>true</IsTruncated>')
          ? _xml(RegExp(r'<NextContinuationToken>([^<]*)</NextContinuationToken>').firstMatch(res.body)?[1] ?? '')
          : null;
      if (token != null && token.isEmpty) token = null;
    } while (token != null);
    return out;
  }

  @override
  Future<List<String>> folders(String dir) async {
    final prefix = objectKey(dir).isEmpty ? '' : '${objectKey(dir)}/';
    final out = <String>[];
    String? token;
    do {
      final uri = Uri.parse('$_endpoint${_path('')}').replace(queryParameters: {
        'list-type': '2',
        'prefix': prefix,
        'delimiter': '/',
        'continuation-token': ?token,
      });
      final req = http.Request('GET', uri)..headers.addAll(_sign('GET', uri, _empty));
      final res = await http.Response.fromStream(await _client.send(req));
      _check(res, 'listing $dir');
      for (final m in RegExp(r'<CommonPrefixes>\s*<Prefix>([^<]*)</Prefix>').allMatches(res.body)) {
        final name = _xml(m[1]!).substring(prefix.length).replaceAll(RegExp(r'/+$'), '');
        if (name.isNotEmpty) out.add(name);
      }
      token = res.body.contains('<IsTruncated>true</IsTruncated>')
          ? _xml(RegExp(r'<NextContinuationToken>([^<]*)</NextContinuationToken>').firstMatch(res.body)?[1] ?? '')
          : null;
      if (token != null && token.isEmpty) token = null;
    } while (token != null);
    return out;
  }

  static String _xml(String s) => s
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');

  @override
  Future<Uint8List> head(RemoteFile f, int n) async {
    final res = await _send('GET', f.path, {'range': 'bytes=0-${n - 1}'});
    _check(res, 'reading ${f.path}');
    return res.bodyBytes.length > n ? Uint8List.sublistView(res.bodyBytes, 0, n) : res.bodyBytes;
  }

  @override
  void close() {
    _client.close();
    clearFileCache();
  }
}
