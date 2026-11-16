import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'screens/home_page.dart';
import 'theme/app_theme.dart';
import 'platform/android_permissions.dart';
import 'platform/app_platform.dart';
import 'player/android_playback_engine.dart';

/// 应用入口。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (AppPlatform.current == AppPlatformKind.android) {
    await requestAndroidNotificationPermission();
    await initializeAndroidPlaybackService();
  }
  runApp(const MusicApp());
}

/// oo music 跨平台客户端。
class MusicApp extends StatelessWidget {
  /// 创建应用根节点。
  const MusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'oo music',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const <Locale>[Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: buildAppTheme(),
      home: const HomePage(),
    );
  }
}
