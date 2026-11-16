import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';
import '../models/music_source.dart';
import '../platform/app_platform.dart';

/// 已完成的一次歌曲下载。
class DownloadResult {
  /// 创建下载结果。
  const DownloadResult({
    required this.file,
    required this.quality,
    required this.bytes,
  });

  /// 最终写入的文件。
  final File file;

  /// 实际下载的音质。
  final String quality;

  /// 文件字节数。
  final int bytes;
}

/// 将歌曲媒体地址流式写入系统下载目录。
class DownloadService {
  /// 创建下载服务；测试时可以注入 HTTP 客户端。
  DownloadService({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  /// 下载 [url] 对应的歌曲文件。
  ///
  /// [quality] 用于选择文件扩展名，[onProgress] 会收到已下载字节数和
  /// 服务端给出的总字节数（未知时为 -1）。
  Future<DownloadResult> download({
    required Song song,
    required String url,
    required String quality,
    void Function(int received, int total)? onProgress,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      throw const DownloadException('播放地址无效，无法下载');
    }
    final directory = await _downloadDirectory();
    final targetDirectory = Directory('${directory.path}/oo music');
    await targetDirectory.create(recursive: true);

    final extension = _extensionFor(quality, uri);
    final baseName = _safeFileName(song);
    final target = await _availableFile(targetDirectory, baseName, extension);
    final temporary = File(
      '${target.path}.part-${DateTime.now().microsecondsSinceEpoch}',
    );

    IOSink? sink;
    try {
      final request = http.Request('GET', uri)
        ..followRedirects = true
        ..headers.addAll(<String, String>{
          'Accept': '*/*',
          'Referer': song.source.referer,
          'User-Agent': AppPlatform.networkUserAgent,
        });
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 25));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final detail = await response.stream.bytesToString().timeout(
          const Duration(seconds: 5),
        );
        throw DownloadException(
          '下载失败（HTTP ${response.statusCode}）'
          '${detail.trim().isEmpty ? '' : '：${_short(detail)}'}',
        );
      }

      sink = temporary.openWrite();
      var received = 0;
      final total = response.contentLength ?? -1;
      onProgress?.call(received, total);
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      await temporary.rename(target.path);
      return DownloadResult(file: target, quality: quality, bytes: received);
    } on DownloadException {
      await _closeQuietly(sink);
      await _deleteQuietly(temporary);
      rethrow;
    } on TimeoutException {
      await _closeQuietly(sink);
      await _deleteQuietly(temporary);
      throw const DownloadException('下载超时，请稍后重试');
    } on Object catch (error) {
      await _closeQuietly(sink);
      await _deleteQuietly(temporary);
      throw DownloadException('下载失败：$error');
    }
  }

  Future<Directory> _downloadDirectory() async {
    final downloads = await getDownloadsDirectory();
    if (downloads != null) {
      return downloads;
    }
    if (AppPlatform.current == AppPlatformKind.android) {
      final support = await getApplicationSupportDirectory();
      return Directory('${support.path}/downloads');
    }
    return getApplicationDocumentsDirectory();
  }

  Future<File> _availableFile(
    Directory directory,
    String baseName,
    String extension,
  ) async {
    var candidate = File('${directory.path}/$baseName$extension');
    var index = 2;
    while (await candidate.exists()) {
      candidate = File('${directory.path}/$baseName ($index)$extension');
      index++;
    }
    return candidate;
  }

  String _safeFileName(Song song) {
    final raw = '${song.artistText} - ${song.name}'.trim();
    final cleaned = raw
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final value = cleaned.isEmpty
        ? 'song-${song.source.storageValue}-${song.id}'
        : cleaned;
    return value.length <= 160 ? value : value.substring(0, 160).trim();
  }

  String _extensionFor(String quality, Uri uri) {
    switch (quality) {
      case 'flac':
      case 'master':
        return '.flac';
      case '96aac':
        return '.m4a';
      case '128mp3':
      case '192mp3':
      case '320mp3':
        return '.mp3';
    }
    final match = RegExp(r'\.([a-zA-Z0-9]{2,5})$').firstMatch(uri.path);
    return match == null ? '.mp3' : '.${match.group(1)!.toLowerCase()}';
  }

  String _short(String value) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized.length <= 160
        ? normalized
        : '${normalized.substring(0, 160)}...';
  }

  Future<void> _closeQuietly(IOSink? sink) async {
    try {
      await sink?.close();
    } on Object {
      // 清理阶段忽略关闭错误。
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on Object {
      // 临时文件清理失败不应覆盖原始下载错误。
    }
  }

  /// 释放内部 HTTP 客户端。
  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }
}

/// 下载过程中的可展示错误。
class DownloadException implements Exception {
  /// 创建下载异常。
  const DownloadException(this.message);

  /// 面向用户的错误描述。
  final String message;

  @override
  String toString() => message;
}
