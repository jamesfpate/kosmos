import 'apple.dart';
import 'b2.dart';
import 'dropbox.dart';
import 'onedrive.dart';
import 'photoprism.dart';
import 's3.dart';
import 'sftp.dart';
import 'store.dart';
import 'synology.dart';
import 'webdav.dart';

/// Every file store and album service (beyond Immich and Google Photos), in the order Settings lists them.
const storeDefs = [appleDef, androidDef, photoprismDef, synologyDef, webdavDef, sftpDef, oneDriveDef, dropboxDef, s3Def, b2Def];

StoreDef storeDef(String key) => storeDefs.firstWhere((d) => d.key == key);
