import 'package:sqlite3/sqlite3.dart';

/// 对 `package:sqlite3` 的薄封装，统一数据库初始化与事务行为。
///
/// 本地歌单操作都由 UI 单线程串行触发，因此这里使用同步 API。数据库连接
/// 由官方 SQLite Dart 绑定持有，避免在应用层重复维护原生 FFI 句柄。
class SqliteDatabase {
  SqliteDatabase._(this._database);

  final Database _database;
  bool _disposed = false;

  /// 打开一个 SQLite 文件；`:memory:` 用于内存数据库和测试。
  factory SqliteDatabase.open(String path) {
    final Database database;
    try {
      database = path == ':memory:'
          ? sqlite3.openInMemory()
          : sqlite3.open(path, mode: OpenMode.readWriteCreate);
    } on SqliteException catch (error) {
      throw SqliteDatabaseException('无法打开 SQLite 数据库：${error.message}');
    }
    final wrapper = SqliteDatabase._(database);
    try {
      wrapper.execute('PRAGMA foreign_keys = ON;');
      wrapper.execute('PRAGMA busy_timeout = 3000;');
      if (path != ':memory:') {
        wrapper.execute('PRAGMA journal_mode = WAL;');
      }
      return wrapper;
    } on Object {
      wrapper.dispose();
      rethrow;
    }
  }

  /// 执行 SQL，可包含多条语句。
  void execute(String sql, [List<Object?> parameters = const <Object?>[]]) {
    _ensureOpen();
    try {
      _database.execute(sql, parameters);
    } on SqliteException catch (error) {
      throw SqliteDatabaseException(error.message, cause: error);
    }
  }

  /// 执行写语句；保留该方法名以便业务层表达意图。
  void run(String sql, [List<Object?> parameters = const <Object?>[]]) {
    execute(sql, parameters);
  }

  /// 查询多行结果。
  ResultSet select(String sql, [List<Object?> parameters = const <Object?>[]]) {
    _ensureOpen();
    try {
      return _database.select(sql, parameters);
    } on SqliteException catch (error) {
      throw SqliteDatabaseException(error.message, cause: error);
    }
  }

  /// 在立即写事务中执行一组同步操作，异常时自动回滚。
  T transaction<T>(T Function() action) {
    _ensureOpen();
    _database.execute('BEGIN IMMEDIATE;');
    try {
      final result = action();
      _database.execute('COMMIT;');
      return result;
    } on Object {
      try {
        _database.execute('ROLLBACK;');
      } on Object {
        // 原始业务异常更重要；回滚失败时仍向调用方抛出原异常。
      }
      rethrow;
    }
  }

  void _ensureOpen() {
    if (_disposed) {
      throw StateError('SQLite 数据库已经关闭');
    }
  }

  /// 关闭数据库连接。
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _database.close();
  }
}

/// SQLite 调用失败时提供给业务层的稳定异常类型。
class SqliteDatabaseException implements Exception {
  /// 创建数据库异常。
  const SqliteDatabaseException(this.message, {this.cause});

  /// 可直接展示的错误描述。
  final String message;

  /// 原始 SQLite 异常，便于诊断。
  final Object? cause;

  @override
  String toString() => message;
}
