import 'dart:io';

import 'package:flutter/services.dart';

/// Copy an Android app-private download to a location selected by the user.
/// Storage Access Framework needs no broad storage or "all files" permission.
class DownloadFileExport {
  const DownloadFileExport({
    this.channel = const MethodChannel('oo_music/file_export'),
  });

  final MethodChannel channel;

  /// Returns false when the user cancels. The original download is retained.
  Future<bool> saveAs(File file, {required String quality}) async {
    final mimeType = switch (quality) {
      'flac' || 'master' => 'audio/flac',
      '96aac' => 'audio/mp4',
      _ => 'audio/mpeg',
    };
    try {
      return await channel.invokeMethod<bool>('saveAs', {
            'path': file.path,
            'mimeType': mimeType,
          }) ??
          false;
    } on PlatformException {
      throw const DownloadExportException('文件导出失败，已下载文件仍保留在应用目录');
    } on MissingPluginException {
      throw const DownloadExportException('当前平台不支持文件导出');
    }
  }
}

class DownloadExportException implements Exception {
  const DownloadExportException(this.message);
  final String message;
  @override
  String toString() => message;
}
