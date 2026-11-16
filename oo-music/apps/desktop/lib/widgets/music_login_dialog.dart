import 'dart:async';

import 'package:flutter/material.dart';

import '../api/music_api.dart';
import '../models/client_account.dart';
import '../models/music_source.dart';
import '../theme/app_theme.dart';

/// 音乐平台扫码登录弹窗。
///
/// 二维码和平台凭据都由后端处理。登录成功后只通过弹窗返回
/// [ClientAccountSession]，调用方负责持久化账号 ID 与 accessKey。
class MusicLoginDialog extends StatefulWidget {
  /// 创建扫码登录弹窗。
  const MusicLoginDialog({super.key, required this.api, required this.source});

  /// 当前应用使用的后端 API 客户端。
  final MusicApi api;

  /// 本次登录的平台。
  final MusicSource source;

  /// 打开弹窗并在登录成功时返回客户端授权身份。
  static Future<ClientAccountSession?> show(
    BuildContext context, {
    required MusicApi api,
    required MusicSource source,
  }) {
    return showDialog<ClientAccountSession>(
      context: context,
      barrierDismissible: false,
      builder: (context) => MusicLoginDialog(api: api, source: source),
    );
  }

  @override
  State<MusicLoginDialog> createState() => _MusicLoginDialogState();
}

class _MusicLoginDialogState extends State<MusicLoginDialog> {
  static const Duration _pollInterval = Duration(milliseconds: 1800);

  MusicLoginSession? _session;
  String? _sessionId;
  String? _error;
  Timer? _pollTimer;
  bool _starting = true;
  bool _polling = false;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_startSession());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    final sessionId = _sessionId;
    if (!_completed && sessionId != null) {
      unawaited(_cancelSession(sessionId));
    }
    super.dispose();
  }

  Future<void> _startSession() async {
    _pollTimer?.cancel();
    final previousSessionId = _sessionId;
    _sessionId = null;
    if (mounted) {
      setState(() {
        _starting = true;
        _error = null;
        _session = null;
        _completed = false;
      });
    }
    if (previousSessionId != null) {
      unawaited(_cancelSession(previousSessionId));
    }

    try {
      final session = await widget.api.startLogin(widget.source);
      if (!mounted) {
        if (session.sessionId.isNotEmpty) {
          unawaited(_cancelSession(session.sessionId));
        }
        return;
      }
      if (session.sessionId.isEmpty) {
        throw const MusicApiException('后端没有返回扫码会话 ID');
      }
      setState(() {
        _session = session;
        _sessionId = session.sessionId;
        _starting = false;
      });
      if (_isTerminal(session.status)) {
        return;
      }
      _schedulePoll();
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _starting = false;
        _error = _messageFor(error);
      });
    }
  }

  void _schedulePoll({Duration delay = _pollInterval}) {
    _pollTimer?.cancel();
    if (!mounted || _completed) {
      return;
    }
    _pollTimer = Timer(delay, () => unawaited(_poll()));
  }

  Future<void> _poll() async {
    final sessionId = _sessionId;
    if (!mounted || _completed || _polling || sessionId == null) {
      return;
    }
    _polling = true;
    try {
      final session = await widget.api.pollLogin(widget.source, sessionId);
      if (!mounted || _completed) {
        return;
      }
      if (session.status == 'completed') {
        final account = session.account;
        if (account == null) {
          throw const MusicApiException('扫码成功，但后端没有返回完整授权信息');
        }
        _completed = true;
        _pollTimer?.cancel();
        Navigator.of(context).pop(account);
        return;
      }
      final previousImageUrl = _session?.imageUrl ?? '';
      final mergedSession = session.copyWith(
        imageUrl: session.imageUrl.isEmpty
            ? previousImageUrl
            : session.imageUrl,
      );
      setState(() {
        _session = mergedSession;
        _error = null;
      });
      if (_isTerminal(mergedSession.status)) {
        _pollTimer?.cancel();
        return;
      }
      _schedulePoll();
    } on Object catch (error) {
      if (!mounted || _completed) {
        return;
      }
      final statusCode = error is MusicApiException ? error.statusCode : null;
      if (statusCode == 404) {
        _pollTimer?.cancel();
        setState(() {
          _session = MusicLoginSession(
            sessionId: sessionId,
            status: 'expired',
            message: '二维码会话已失效，请重新获取',
            source: widget.source,
            expiresAt: _session?.expiresAt,
          );
          _error = null;
        });
      } else {
        setState(() {
          _error = '网络或服务异常，正在重试：${_messageFor(error)}';
        });
        _schedulePoll(delay: const Duration(seconds: 2));
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _cancelSession(String sessionId) async {
    try {
      await widget.api.cancelLogin(widget.source, sessionId);
    } on Object {
      // 关闭弹窗时会话可能已经过期；清理失败不影响客户端。
    }
  }

  bool _isTerminal(String status) {
    return status == 'completed' ||
        status == 'expired' ||
        status == 'rejected' ||
        status == 'canceled' ||
        status == 'error';
  }

  bool get _canRetry {
    final status = _session?.status;
    return status == null ||
        status == 'expired' ||
        status == 'rejected' ||
        status == 'canceled' ||
        status == 'error';
  }

  String _messageFor(Object error) {
    if (error is MusicApiException) {
      return error.message;
    }
    return error.toString();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final imageUrl = session?.imageUrl ?? '';
    final availableHeight = (MediaQuery.sizeOf(context).height - 40).clamp(
      360.0,
      760.0,
    );
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 440, maxHeight: availableHeight),
        child: DecoratedBox(
          decoration: appDialogDecoration(),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(26, 22, 26, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: <Color>[
                            AppColors.accentStrong,
                            AppColors.accent,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: AppColors.accent.withValues(alpha: 0.2),
                            blurRadius: 18,
                            offset: const Offset(0, 7),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.qr_code_2_rounded,
                        color: AppColors.accentOn,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '${widget.source.label}扫码登录',
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 3),
                          const Row(
                            children: <Widget>[
                              Icon(
                                Icons.lock_outline_rounded,
                                color: AppColors.textDisabled,
                                size: 12,
                              ),
                              SizedBox(width: 4),
                              Text(
                                '登录凭据仅在服务端处理',
                                style: TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const ValueKey<String>('close-login-dialog'),
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  child: _buildContent(context, session, imageUrl),
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceRaised,
                    borderRadius: BorderRadius.circular(AppRadii.input),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Icon(
                        Icons.shield_outlined,
                        color: AppColors.textDisabled,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.source == MusicSource.qq
                              ? '请使用手机 QQ 扫描二维码。登录成功后，客户端只保存账号标识和后端生成的访问密钥。'
                              : '请使用网易云音乐 App 扫描二维码。登录成功后，客户端只保存账号标识和后端生成的访问密钥。',
                          textAlign: TextAlign.left,
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 11.5,
                            height: 1.55,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    MusicLoginSession? session,
    String imageUrl,
  ) {
    if (_starting) {
      return SizedBox(
        key: const ValueKey<String>('login-starting'),
        height: 284,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const CircularProgressIndicator(strokeWidth: 2.5),
              const SizedBox(height: 16),
              Text(
                '正在获取${widget.source.label}登录二维码…',
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    if (session == null) {
      return _buildErrorContent();
    }

    if (_canRetry && _isTerminal(session.status)) {
      return _buildTerminalContent(session);
    }

    return Column(
      key: const ValueKey<String>('login-qr'),
      children: <Widget>[
        Container(
          width: 252,
          height: 252,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
          ),
          child: imageUrl.isEmpty
              ? const _QRCodeUnavailable()
              : Image.network(
                  widget.api.resolveUrl(imageUrl),
                  key: ValueKey<String>('login-image-${session.sessionId}'),
                  width: 232,
                  height: 232,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.none,
                  gaplessPlayback: true,
                  loadingBuilder: (context, child, loadingProgress) {
                    if (loadingProgress == null) {
                      return child;
                    }
                    return const Center(
                      child: SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      ),
                    );
                  },
                  errorBuilder: (_, _, _) => const _QRCodeUnavailable(),
                ),
        ),
        const SizedBox(height: 16),
        _StatusPill(
          source: widget.source,
          status: session.status,
          message: session.message,
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.warning,
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTerminalContent(MusicLoginSession session) {
    final failed = session.status == 'error';
    return SizedBox(
      key: const ValueKey<String>('login-terminal'),
      height: 284,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              failed
                  ? Icons.error_outline_rounded
                  : Icons.qr_code_scanner_rounded,
              size: 52,
              color: failed ? AppColors.warning : AppColors.accent,
            ),
            const SizedBox(height: 14),
            Text(
              session.message.isEmpty ? '该二维码已不可用' : session.message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (_error != null && _error != session.message) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.warning, fontSize: 12),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const ValueKey<String>('retry-login'),
              onPressed: _starting ? null : () => unawaited(_startSession()),
              icon: const Icon(Icons.refresh_rounded, size: 19),
              label: const Text('重新获取二维码'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorContent() {
    return SizedBox(
      key: const ValueKey<String>('login-error'),
      height: 284,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.cloud_off_rounded,
              size: 52,
              color: AppColors.warning,
            ),
            const SizedBox(height: 14),
            Text(
              _error ?? '无法获取${widget.source.label}登录二维码',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const ValueKey<String>('retry-login-start'),
              onPressed: () => unawaited(_startSession()),
              icon: const Icon(Icons.refresh_rounded, size: 19),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.source,
    required this.status,
    required this.message,
  });

  final MusicSource source;
  final String status;
  final String message;

  @override
  Widget build(BuildContext context) {
    final (Color color, IconData icon, String fallback) = switch (status) {
      'scanned' => (
        AppColors.accent,
        Icons.phone_android_rounded,
        '已扫码，请在手机${source == MusicSource.qq ? 'QQ' : '网易云音乐 App'}上确认',
      ),
      'waiting' => (
        AppColors.info,
        Icons.qr_code_scanner_rounded,
        source == MusicSource.qq ? '请使用手机 QQ 扫码' : '请使用网易云音乐 App 扫码',
      ),
      _ => (AppColors.textSecondary, Icons.sync_rounded, '正在确认登录状态'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              message.isEmpty ? fallback : message,
              style: TextStyle(color: color, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _QRCodeUnavailable extends StatelessWidget {
  const _QRCodeUnavailable();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.qr_code_2_rounded,
            color: AppColors.textDisabled,
            size: 58,
          ),
          SizedBox(height: 10),
          Text(
            '二维码图片加载失败',
            style: TextStyle(color: AppColors.textDisabled, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
