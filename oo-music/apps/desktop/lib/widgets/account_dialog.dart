import 'dart:async';

import 'package:flutter/material.dart';

import '../api/music_api.dart';
import '../models/client_account.dart';
import '../models/music_source.dart';
import '../models/playlist.dart';
import '../storage/local_library_store.dart';
import '../theme/app_theme.dart';
import 'music_login_dialog.dart';

/// 当前账号资料与本地多账号切换面板。
///
/// 面板只操作本机 SQLite 中的账号记录。切换账号时会向后端验证 accessKey；
/// 授权失效只清除该记录的 accessKey，不会删除后端绑定账号。
class AccountDialog extends StatefulWidget {
  /// 创建账号面板。
  const AccountDialog({
    super.key,
    required this.api,
    required this.store,
    required this.activeAccount,
    required this.source,
  });

  /// 当前应用使用的后端 API 客户端。
  final MusicApi api;

  /// 保存本地账号的 SQLite 音乐库。
  final LocalLibraryStore store;

  /// 打开面板时正在使用的本地账号。
  final ClientAccountSession? activeAccount;

  /// 当前面板管理的平台。
  final MusicSource source;

  /// 打开面板；关闭后调用方应从 [LocalLibraryStore.snapshot] 重新读取状态。
  static Future<void> show(
    BuildContext context, {
    required MusicApi api,
    required LocalLibraryStore store,
    required ClientAccountSession? activeAccount,
    required MusicSource source,
  }) {
    return showDialog<void>(
      context: context,
      builder: (context) => AccountDialog(
        api: api,
        store: store,
        activeAccount: activeAccount,
        source: source,
      ),
    );
  }

  @override
  State<AccountDialog> createState() => _AccountDialogState();
}

enum _AccountPanelView { overview, accounts }

class _AccountDialogState extends State<AccountDialog> {
  late _AccountPanelView _view;
  late List<ClientAccountSession> _accounts;
  ClientAccountSession? _activeAccount;
  bool _busy = false;
  bool _refreshingProfile = false;
  String? _busyAccountID;

  @override
  void initState() {
    super.initState();
    _view = widget.activeAccount == null
        ? _AccountPanelView.accounts
        : _AccountPanelView.overview;
    _activeAccount = widget.activeAccount;
    _reloadAccounts();
    final account = _activeAccount;
    if (account != null &&
        account.canSwitch &&
        (account.nickname.trim().isEmpty || account.avatarUrl.trim().isEmpty)) {
      unawaited(_refreshActiveProfile());
    }
  }

  void _reloadAccounts() {
    final snapshot = widget.store.snapshot();
    _accounts = snapshot.accountsFor(widget.source);
    _activeAccount = snapshot.accountFor(widget.source);
  }

  void _syncApiAccount(LibrarySnapshot snapshot) {
    final account = snapshot.accountFor(widget.source);
    widget.api.setActiveAccount(
      widget.source,
      account?.canSwitch == true ? account : null,
    );
  }

  /// 账号资料缺失时，打开面板后按需补齐昵称和头像。
  Future<void> _refreshActiveProfile() async {
    final account = _activeAccount;
    if (account == null || !account.canSwitch || _refreshingProfile) {
      return;
    }
    setState(() => _refreshingProfile = true);
    try {
      final validated = await widget.api.validateClientAccount(account);
      if (!mounted) {
        return;
      }
      // 资料刷新是后台任务。若用户已经切换账号，不能用旧请求修改或激活
      // 当前会话。
      if (widget.store.snapshot().accountFor(widget.source)?.accountId !=
          account.accountId) {
        return;
      }
      widget.store.saveClientAccountSession(validated);
      widget.api.setActiveAccount(widget.source, validated);
      final snapshot = widget.store.snapshot();
      setState(() => _reloadAccounts());
      _syncApiAccount(snapshot);
    } on MusicApiException catch (error) {
      if (!mounted) {
        return;
      }
      if (error.statusCode == 401) {
        widget.store.clearClientAccountAccessKey(
          account.source,
          account.accountId,
        );
        final snapshot = widget.store.snapshot();
        setState(() => _reloadAccounts());
        _syncApiAccount(snapshot);
        if (snapshot.accountFor(widget.source)?.accountId ==
            account.accountId) {
          _showMessage('当前账号授权已过期，已自动切换到其他可用账号');
        }
      }
    } on Object {
      // 资料补齐是增强体验，不应阻断账号面板的正常操作。
    } finally {
      if (mounted && _refreshingProfile) {
        setState(() => _refreshingProfile = false);
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _switchAccount(ClientAccountSession account) async {
    if (_busy) {
      return;
    }
    if (!account.canSwitch) {
      _showMessage('该账号授权已过期，请重新扫码授权');
      return;
    }
    setState(() {
      _busy = true;
      _busyAccountID = account.accountId;
    });
    try {
      final validated = await widget.api.validateClientAccount(account);
      if (!mounted) {
        return;
      }
      widget.store.saveClientAccountSession(validated);
      widget.api.setActiveAccount(widget.source, validated);
      setState(() {
        _busy = false;
        _busyAccountID = null;
      });
      Navigator.of(context).pop();
    } on MusicApiException catch (error) {
      if (!mounted) {
        return;
      }
      if (error.statusCode == 401) {
        widget.store.clearClientAccountAccessKey(
          account.source,
          account.accountId,
        );
        final snapshot = widget.store.snapshot();
        setState(() {
          _busy = false;
          _busyAccountID = null;
          _reloadAccounts();
        });
        _syncApiAccount(snapshot);
        _showMessage('授权已过期，请重新扫码授权');
        await _scanAccount();
        return;
      }
      _finishWithError('切换账号失败：${error.message}');
    } on Object catch (error) {
      _finishWithError('切换账号失败：$error');
    }
  }

  void _finishWithError(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _busyAccountID = null;
    });
    _showMessage(message);
  }

  Future<void> _scanAccount() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final account = await MusicLoginDialog.show(
        context,
        api: widget.api,
        source: widget.source,
      );
      if (account == null || !mounted) {
        return;
      }
      widget.store.saveClientAccountSession(account);
      widget.api.setActiveAccount(widget.source, account);
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _busyAccountID = null;
      });
      Navigator.of(context).pop();
    } on Object catch (error) {
      _finishWithError('保存授权账号失败：$error');
    } finally {
      if (mounted && _busy) {
        setState(() => _busy = false);
      }
    }
  }

  void _deleteAccount(ClientAccountSession account) {
    if (_busy) {
      return;
    }
    final deletedActive = _activeAccount?.accountId == account.accountId;
    final deleted = widget.store.deleteClientAccount(
      account.source,
      account.accountId,
    );
    if (!deleted) {
      _showMessage('本地账号已经不存在');
      return;
    }
    final snapshot = widget.store.snapshot();
    final nextActive = snapshot.accountFor(widget.source);
    if (deletedActive) {
      _syncApiAccount(snapshot);
    }
    setState(() {
      _accounts = snapshot.accountsFor(widget.source);
      _activeAccount = nextActive;
      if (_activeAccount == null) {
        _view = _AccountPanelView.accounts;
      }
    });
    _showMessage('已从本机删除账号 ${account.displayName}');
  }

  @override
  Widget build(BuildContext context) {
    final availableHeight = MediaQuery.sizeOf(context).height - 48;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 500,
          maxHeight: availableHeight.clamp(320, 780),
        ),
        child: DecoratedBox(
          decoration: appDialogDecoration(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    if (_view == _AccountPanelView.accounts &&
                        _activeAccount != null)
                      IconButton(
                        key: const ValueKey<String>('account-back-button'),
                        tooltip: '返回账号信息',
                        onPressed: _busy
                            ? null
                            : () => setState(
                                () => _view = _AccountPanelView.overview,
                              ),
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                    Text(
                      _view == _AccountPanelView.overview
                          ? '${widget.source.label}账号'
                          : '切换${widget.source.shortLabel}账号',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      key: const ValueKey<String>('close-account-dialog'),
                      tooltip: '关闭',
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const Divider(height: 24, color: AppColors.border),
                Flexible(
                  child: SingleChildScrollView(
                    child: AnimatedSwitcher(
                      duration: AppDurations.normal,
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      child: _view == _AccountPanelView.overview
                          ? _buildOverview()
                          : _buildAccountPicker(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOverview() {
    final account = _activeAccount;
    if (account == null) {
      return _buildAccountPicker();
    }
    return Column(
      key: const ValueKey<String>('account-overview'),
      children: <Widget>[
        _AccountAvatar(api: widget.api, account: account, size: 86),
        const SizedBox(height: 16),
        Text(
          account.displayName,
          key: const ValueKey<String>('account-current-nickname'),
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${widget.source.shortLabel} ${account.accountId}',
          key: const ValueKey<String>('account-full-id'),
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 14,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 12),
        _StatusChip(
          label: account.canSwitch ? '授权有效' : '授权已过期',
          color: account.canSwitch ? AppColors.accent : AppColors.warning,
        ),
        const SizedBox(height: 26),
        SizedBox(
          width: double.infinity,
          height: 46,
          child: FilledButton.icon(
            key: const ValueKey<String>('show-account-switcher'),
            onPressed: _busy
                ? null
                : () => setState(() => _view = _AccountPanelView.accounts),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: AppColors.accentOn,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: const Icon(Icons.switch_account_rounded, size: 20),
            label: const Text(
              '切换账号',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAccountPicker() {
    return Column(
      key: const ValueKey<String>('account-picker'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_accounts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 44),
            child: Column(
              children: <Widget>[
                const Icon(
                  Icons.people_outline_rounded,
                  color: AppColors.textMuted,
                  size: 44,
                ),
                const SizedBox(height: 12),
                Text(
                  '本机还没有保存过${widget.source.label}账号',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 370),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _accounts.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final account = _accounts[index];
                return _buildAccountRow(account);
              },
            ),
          ),
        const SizedBox(height: 18),
        SizedBox(
          height: 46,
          child: OutlinedButton.icon(
            key: const ValueKey<String>('scan-new-account'),
            onPressed: _busy ? null : () => unawaited(_scanAccount()),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.textPrimary,
              side: const BorderSide(color: AppColors.accentBorder),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: _busy && _busyAccountID == null
                ? const SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.qr_code_2_rounded, size: 20),
            label: const Text('扫码授权新账号'),
          ),
        ),
      ],
    );
  }

  Widget _buildAccountRow(ClientAccountSession account) {
    final isActive = _activeAccount?.accountId == account.accountId;
    final switching = _busyAccountID == account.accountId;
    return Material(
      color: isActive ? AppColors.accentSoft : AppColors.surfaceRaised,
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        key: ValueKey<String>(
          'local-account-${account.source.storageValue}-${account.accountId}',
        ),
        borderRadius: BorderRadius.circular(15),
        onTap: _busy || isActive || !account.canSwitch
            ? account.canSwitch
                  ? null
                  : () => _showMessage('该账号授权已过期，无法切换')
            : () => unawaited(_switchAccount(account)),
        hoverColor: AppColors.surfaceHover,
        focusColor: AppColors.accent.withValues(alpha: 0.08),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: isActive ? AppColors.accentBorder : AppColors.border,
            ),
          ),
          child: Row(
            children: <Widget>[
              _AccountAvatar(
                api: widget.api,
                account: account,
                size: 46,
                dimmed: !account.canSwitch,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            account.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: account.canSwitch
                                  ? AppColors.textPrimary
                                  : AppColors.textDisabled,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (isActive) ...<Widget>[
                          const SizedBox(width: 8),
                          const _StatusChip(
                            label: '当前账号',
                            color: AppColors.accent,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${widget.source.shortLabel} ${account.accountId}',
                      style: TextStyle(
                        color: account.canSwitch
                            ? AppColors.textMuted
                            : AppColors.textDisabled,
                        fontSize: 12,
                      ),
                    ),
                    if (!account.canSwitch) ...<Widget>[
                      const SizedBox(height: 4),
                      const Text(
                        '授权已过期，点击右侧删除或重新扫码',
                        style: TextStyle(
                          color: AppColors.warning,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (switching)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  key: ValueKey<String>(
                    'delete-local-account-${account.source.storageValue}-${account.accountId}',
                  ),
                  tooltip: '从本机删除',
                  onPressed: _busy ? null : () => _deleteAccount(account),
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 19,
                    color: AppColors.textMuted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountAvatar extends StatelessWidget {
  const _AccountAvatar({
    required this.api,
    required this.account,
    required this.size,
    this.dimmed = false,
  });

  final MusicApi api;
  final ClientAccountSession account;
  final double size;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: AppColors.surfaceHigh,
        shape: BoxShape.circle,
      ),
      child: Text(
        account.avatarFallbackText,
        style: TextStyle(
          color: dimmed ? AppColors.textDisabled : AppColors.textPrimary,
          fontSize: size * 0.36,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    final avatarUrl = account.avatarUrl.trim();
    return Opacity(
      opacity: dimmed ? 0.58 : 1,
      child: ClipOval(
        child: avatarUrl.isEmpty
            ? fallback
            : Image.network(
                api.resolveUrl(avatarUrl),
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
