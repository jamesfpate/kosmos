import 'b2.dart';
import 's3.dart';
import 'sftp.dart';
import 'store.dart';
import 'webdav.dart';

/// Every file store, in the order Settings lists them.
const storeDefs = [webdavDef, sftpDef, s3Def, b2Def];

StoreDef storeDef(String key) => storeDefs.firstWhere((d) => d.key == key);
