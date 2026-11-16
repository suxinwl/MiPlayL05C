// Command server runs the local web backend for the oo-music desktop app.
package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/rankgice/oo-music/internal/account"
	"github.com/rankgice/oo-music/internal/admin"
	"github.com/rankgice/oo-music/internal/adminapi"
	"github.com/rankgice/oo-music/internal/api"
	"github.com/rankgice/oo-music/internal/netease"
	"github.com/rankgice/oo-music/internal/notify"
	"github.com/rankgice/oo-music/internal/qqlogin"
)

func main() {
	logger := log.New(os.Stdout, "[oo-music] ", log.LstdFlags|log.Lmicroseconds)

	envFile := strings.TrimSpace(os.Getenv("OO_MUSIC_ENV_FILE"))
	if envFile == "" {
		envFile = ".env"
	}
	if err := loadEnvFile(envFile); err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			logger.Fatalf("读取环境配置文件失败: %v", err)
		}
		logger.Printf("未找到 %s，继续使用进程环境变量", envFile)
	} else {
		logger.Printf("已加载环境配置文件 %s", envFile)
	}

	dbPath := strings.TrimSpace(os.Getenv("OO_MUSIC_DB_PATH"))
	if dbPath == "" {
		dbPath = "data/oo-music.db"
	}
	accountStore, err := account.Open(dbPath)
	if err != nil {
		logger.Fatalf("打开账号数据库失败: %v", err)
	}
	defer func() {
		if err := accountStore.Close(); err != nil {
			logger.Printf("关闭账号数据库失败: %v", err)
		}
	}()
	logger.Printf("账号数据库已加载: %s", dbPath)

	adminStore, err := admin.Open(dbPath)
	if err != nil {
		logger.Fatalf("打开后台管理员数据库失败: %v", err)
	}
	defer func() {
		if err := adminStore.Close(); err != nil {
			logger.Printf("关闭后台管理员数据库失败: %v", err)
		}
	}()
	adminUsername := strings.TrimSpace(os.Getenv("OO_MUSIC_ADMIN_USERNAME"))
	adminPassword := os.Getenv("OO_MUSIC_ADMIN_PASSWORD")
	if (adminUsername == "") != (adminPassword == "") {
		logger.Fatal("OO_MUSIC_ADMIN_USERNAME 和 OO_MUSIC_ADMIN_PASSWORD 必须同时设置")
	}
	adminCount, err := adminStore.CountUsers(context.Background())
	if err != nil {
		logger.Fatalf("统计后台管理员失败: %v", err)
	}
	if adminCount == 0 {
		if adminUsername == "" {
			logger.Fatal("后台管理员表为空，请在配置文件中设置 OO_MUSIC_ADMIN_USERNAME 和 OO_MUSIC_ADMIN_PASSWORD")
		}
		created, user, err := adminStore.EnsureInitialUser(context.Background(), adminUsername, adminPassword)
		if err != nil {
			logger.Fatalf("创建初始后台管理员失败: %v", err)
		}
		if created {
			logger.Printf("已创建初始后台管理员: %s", user.Username)
		}
	} else {
		logger.Printf("后台管理员表已有 %d 个账号，不会重复创建初始管理员", adminCount)
	}
	adminSessionTTL, err := configuredDuration("OO_MUSIC_ADMIN_SESSION_TTL", 12*time.Hour)
	if err != nil {
		logger.Fatalf("后台管理登录有效期配置无效: %v", err)
	}
	adminAuth, err := admin.NewAuthService(adminStore, adminSessionTTL)
	if err != nil {
		logger.Fatalf("创建后台管理认证服务失败: %v", err)
	}

	pool := account.NewPool(accountStore, logger)
	cardURLs := splitConfigList(os.Getenv("OO_MUSIC_EXPERIENCE_CARD_URLS"))
	cardURLs = append(cardURLs, splitConfigList(os.Getenv("OO_MUSIC_EXPERIENCE_CARD_URL"))...)
	if len(cardURLs) > 0 {
		if err := pool.SetExperienceCardURLs(cardURLs); err != nil {
			logger.Fatalf("配置 QQ 音乐官方体验卡链接失败: %v", err)
		}
	}
	logger.Printf("已启用 h.m4a.cn 体验卡实时链接源；额外静态链接 %d 个", len(cardURLs))

	refreshContext, cancelRefresh := context.WithTimeout(context.Background(), 45*time.Second)
	if err := pool.RefreshAll(refreshContext); err != nil {
		logger.Printf("部分账号会员状态刷新失败，将使用数据库中的最近状态: %v", err)
	}
	cancelRefresh()
	membershipContext, cancelMembership := context.WithTimeout(context.Background(), 90*time.Second)
	if err := pool.EnsureMemberships(membershipContext); err != nil {
		logger.Printf("自动补充平台会员权益失败: %v", err)
	}
	cancelMembership()
	selected, err := pool.SelectedStatus(context.Background())
	if err != nil {
		logger.Fatalf("读取当前 QQ 音乐账号失败: %v", err)
	}
	if selected.Available {
		expiresAt := "未知"
		if selected.VipExpiresAt != nil {
			expiresAt = selected.VipExpiresAt.In(time.Local).Format("2006-01-02 15:04:05")
		}
		logger.Printf("当前账号: %s，会员等级: %s，到期时间: %s", selected.UINMasked, selected.VipLevelName, expiresAt)
	} else {
		logger.Print("数据库中没有账号，使用匿名模式")
	}

	qrLogin, err := qqlogin.NewService(logger)
	if err != nil {
		logger.Fatalf("创建 QQ 扫码登录服务失败: %v", err)
	}
	neteaseClient, err := netease.NewClient()
	if err != nil {
		logger.Fatalf("创建网易云音乐客户端失败: %v", err)
	}
	neteaseQRLogin, err := netease.NewQRService(neteaseClient, logger)
	if err != nil {
		logger.Fatalf("创建网易云扫码登录服务失败: %v", err)
	}
	adminHandler, err := adminapi.NewHandler(
		adminStore,
		adminAuth,
		pool,
		qrLogin,
		neteaseQRLogin,
		logger,
		adminapi.Config{AllowedOrigins: splitConfigList(os.Getenv("OO_MUSIC_ADMIN_ALLOWED_ORIGINS"))},
	)
	if err != nil {
		logger.Fatalf("创建后台管理 API 失败: %v", err)
	}
	webDist := strings.TrimSpace(os.Getenv("OO_MUSIC_WEB_DIST"))
	if webDist != "" {
		indexPath := filepath.Join(webDist, "index.html")
		if info, err := os.Stat(indexPath); err != nil || info.IsDir() {
			logger.Fatalf("前端静态文件不可用，缺少 %s", indexPath)
		}
		logger.Printf("管理网页静态文件已启用: %s", webDist)
	}
	musicHandler := api.NewHandlerWithWebRootAndBothQRAndPolicy(pool, qrLogin, neteaseQRLogin, logger, webDist, adminStore)
	rootHandler := http.NewServeMux()
	rootHandler.Handle("/api/admin/", adminHandler)
	rootHandler.Handle("/", musicHandler)

	addr := strings.TrimSpace(os.Getenv("OO_MUSIC_ADDR"))
	if addr == "" {
		addr = "127.0.0.1:8787"
	}
	server := &http.Server{
		Addr:              addr,
		Handler:           rootHandler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       35 * time.Second,
		WriteTimeout:      35 * time.Second,
		IdleTimeout:       90 * time.Second,
	}

	smtpConfig, smtpConfigured, err := notify.LoadSMTPConfigFromEnv()
	if err != nil {
		logger.Fatalf("SMTP 邮件配置无效: %v", err)
	}
	var loginNotifier account.LoginCheckNotifier
	if smtpConfigured {
		mailer, err := notify.NewSMTPMailer(smtpConfig)
		if err != nil {
			logger.Fatalf("创建 SMTP 邮件客户端失败: %v", err)
		}
		loginNotifier = func(ctx context.Context, report account.LoginCheckReport) error {
			return mailer.Send(ctx, notify.LoginExpiryMessage(report, smtpConfig.To))
		}
		logger.Printf("账号登录态过期邮件通知已启用，收件人数: %d", len(smtpConfig.To))
	} else {
		logger.Print("未配置 SMTP，每日登录态自检仍会运行，但登录态过期时不会发送邮件")
	}

	scheduler, err := account.NewLoginCheckScheduler(
		pool,
		logger,
		os.Getenv("OO_MUSIC_LOGIN_CHECK_TIME"),
		os.Getenv("OO_MUSIC_LOGIN_CHECK_TIMEZONE"),
		loginNotifier,
	)
	if err != nil {
		logger.Fatalf("创建账号登录态自检定时任务失败: %v", err)
	}

	shutdownContext, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go scheduler.Run(shutdownContext)
	go func() {
		<-shutdownContext.Done()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
	}()

	logger.Printf("HTTP 服务监听 http://%s", addr)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Fatalf("HTTP 服务异常退出: %v", err)
	}
	logger.Print("HTTP 服务已停止")
}

// configuredDuration 读取可选的 duration 环境变量；空值使用默认值。
func configuredDuration(name string, fallback time.Duration) (time.Duration, error) {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return fallback, nil
	}
	value, err := time.ParseDuration(raw)
	if err != nil || value <= 0 {
		return 0, fmt.Errorf("%s 必须是大于零的 duration，例如 12h", name)
	}
	return value, nil
}

// splitConfigList 解析逗号、分号或换行分隔的配置列表，并去重。
func splitConfigList(raw string) []string {
	parts := strings.FieldsFunc(raw, func(char rune) bool {
		return char == ',' || char == ';' || char == '\n' || char == '\r'
	})
	seen := make(map[string]struct{}, len(parts))
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if _, exists := seen[part]; exists {
			continue
		}
		seen[part] = struct{}{}
		result = append(result, part)
	}
	return result
}

// loadEnvFile 将 .env 文件中的变量写入当前进程；已有环境变量优先，不会被文件覆盖。
func loadEnvFile(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	lineNumber := 0
	for scanner.Scan() {
		lineNumber++
		key, value, ok, err := parseEnvLine(scanner.Text())
		if err != nil {
			return fmt.Errorf("第 %d 行: %w", lineNumber, err)
		}
		if !ok {
			continue
		}
		if _, exists := os.LookupEnv(key); exists {
			continue
		}
		if err := os.Setenv(key, value); err != nil {
			return fmt.Errorf("设置 %s: %w", key, err)
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	return nil
}

// parseEnvLine 解析一行简单的 KEY=VALUE 配置，支持注释、export 和成对引号。
func parseEnvLine(line string) (key, value string, ok bool, err error) {
	line = strings.TrimSpace(line)
	if line == "" || strings.HasPrefix(line, "#") {
		return "", "", false, nil
	}
	line = strings.TrimSpace(strings.TrimPrefix(line, "export "))
	key, value, found := strings.Cut(line, "=")
	if !found {
		return "", "", false, errors.New("缺少 =")
	}
	key = strings.TrimSpace(key)
	if !validEnvKey(key) {
		return "", "", false, errors.New("变量名不合法")
	}
	value = strings.TrimSpace(value)
	if strings.HasPrefix(value, `"`) {
		end := closingQuote(value, '"')
		if end < 0 {
			return "", "", false, errors.New("双引号未闭合")
		}
		if err := ensureOnlyComment(value[end+1:]); err != nil {
			return "", "", false, err
		}
		unquoted, unquoteErr := strconv.Unquote(value[:end+1])
		if unquoteErr != nil {
			return "", "", false, fmt.Errorf("解析双引号值: %w", unquoteErr)
		}
		return key, unquoted, true, nil
	}
	if strings.HasPrefix(value, "'") {
		end := strings.IndexByte(value[1:], '\'')
		if end < 0 {
			return "", "", false, errors.New("单引号未闭合")
		}
		end++
		if err := ensureOnlyComment(value[end+1:]); err != nil {
			return "", "", false, err
		}
		return key, value[1:end], true, nil
	}
	if comment := strings.Index(value, " #"); comment >= 0 {
		value = strings.TrimSpace(value[:comment])
	}
	return key, value, true, nil
}

func closingQuote(value string, quote byte) int {
	escaped := false
	for index := 1; index < len(value); index++ {
		if escaped {
			escaped = false
			continue
		}
		if value[index] == '\\' {
			escaped = true
			continue
		}
		if value[index] == quote {
			return index
		}
	}
	return -1
}

func ensureOnlyComment(rest string) error {
	rest = strings.TrimSpace(rest)
	if rest != "" && !strings.HasPrefix(rest, "#") {
		return errors.New("引号后存在多余内容")
	}
	return nil
}

func validEnvKey(key string) bool {
	if key == "" {
		return false
	}
	for index, char := range key {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') || char == '_' || (index > 0 && char >= '0' && char <= '9') {
			continue
		}
		return false
	}
	return true
}
