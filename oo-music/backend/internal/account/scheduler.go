package account

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strconv"
	"strings"
	"time"
)

const (
	defaultLoginCheckTime     = "11:00"
	defaultLoginCheckTimezone = "Asia/Shanghai"
	defaultLoginCheckTimeout  = 5 * time.Minute
	defaultMembershipTimeout  = 5 * time.Minute
)

// LoginCheckNotifier sends a notification after a self-check. It is only called
// when at least one account was explicitly reported as expired.
type LoginCheckNotifier func(context.Context, LoginCheckReport) error

// LoginCheckScheduler runs a reusable login-state self-check once per day.
type LoginCheckScheduler struct {
	pool              *Pool
	logger            *log.Logger
	location          *time.Location
	hour              int
	minute            int
	notify            LoginCheckNotifier
	timeout           time.Duration
	membershipTimeout time.Duration
	now               func() time.Time
}

// NewLoginCheckScheduler creates a daily scheduler. Empty timeOfDay and timezone
// use 11:00 and Asia/Shanghai respectively. timeOfDay must use HH:MM format.
func NewLoginCheckScheduler(pool *Pool, logger *log.Logger, timeOfDay, timezone string, notifier LoginCheckNotifier) (*LoginCheckScheduler, error) {
	if pool == nil {
		return nil, errors.New("login check scheduler requires an account pool")
	}
	if logger == nil {
		logger = log.Default()
	}
	timeOfDay = strings.TrimSpace(timeOfDay)
	if timeOfDay == "" {
		timeOfDay = defaultLoginCheckTime
	}
	timezone = strings.TrimSpace(timezone)
	if timezone == "" {
		timezone = defaultLoginCheckTimezone
	}
	hour, minute, err := parseClock(timeOfDay)
	if err != nil {
		return nil, err
	}
	location, err := time.LoadLocation(timezone)
	if err != nil {
		return nil, fmt.Errorf("加载自检时区 %s: %w", timezone, err)
	}
	return &LoginCheckScheduler{
		pool:              pool,
		logger:            logger,
		location:          location,
		hour:              hour,
		minute:            minute,
		notify:            notifier,
		timeout:           defaultLoginCheckTimeout,
		membershipTimeout: defaultMembershipTimeout,
		now:               time.Now,
	}, nil
}

// Run blocks and executes the login check every day at the configured time.
// It returns promptly when ctx is canceled.
func (s *LoginCheckScheduler) Run(ctx context.Context) {
	if s == nil || s.pool == nil {
		return
	}
	for {
		next := nextDailyRun(s.now().In(s.location), s.location, s.hour, s.minute)
		s.logger.Printf("下次账号登录态自检时间: %s", next.Format(time.RFC3339))
		timer := time.NewTimer(time.Until(next))
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			return
		case <-timer.C:
			s.RunOnce(ctx)
		}
	}
}

// RunOnce executes one full login-state self-check and sends a summary email
// only for accounts explicitly marked as expired.
func (s *LoginCheckScheduler) RunOnce(ctx context.Context) {
	if s == nil || s.pool == nil {
		return
	}
	checkContext, cancel := context.WithTimeout(ctx, s.timeout)
	report, err := s.pool.CheckAllLogins(checkContext)
	cancel()
	if err != nil {
		s.logger.Printf("账号登录态自检存在错误: %v", err)
	}
	membershipTimeout := s.membershipTimeout
	if membershipTimeout <= 0 {
		membershipTimeout = defaultMembershipTimeout
	}
	membershipContext, cancelMembership := context.WithTimeout(ctx, membershipTimeout)
	defer cancelMembership()
	if err := s.pool.EnsureMemberships(membershipContext); err != nil {
		s.logger.Printf("账号会员权益自动补充存在错误: %v", err)
	}
	s.logger.Printf("账号登录态自检完成: 共 %d 个账号，明确过期 %d 个", len(report.Accounts), len(report.Expired))
	if len(report.Expired) == 0 {
		return
	}
	if s.notify == nil {
		s.logger.Printf("发现 %d 个登录态失效账号，但未配置邮件通知", len(report.Expired))
		return
	}
	if err := s.notify(checkContext, report); err != nil {
		s.logger.Printf("发送账号登录态过期邮件失败: %v", err)
		return
	}
	s.logger.Printf("账号登录态过期邮件已发送，失效账号数: %d", len(report.Expired))
}

func parseClock(value string) (hour, minute int, err error) {
	parts := strings.Split(value, ":")
	if len(parts) != 2 {
		return 0, 0, fmt.Errorf("自检时间必须使用 HH:MM 格式: %q", value)
	}
	hour, hourErr := strconv.Atoi(parts[0])
	minute, minuteErr := strconv.Atoi(parts[1])
	if hourErr != nil || minuteErr != nil || hour < 0 || hour > 23 || minute < 0 || minute > 59 {
		return 0, 0, fmt.Errorf("自检时间不合法: %q", value)
	}
	return hour, minute, nil
}

func nextDailyRun(now time.Time, location *time.Location, hour, minute int) time.Time {
	localNow := now.In(location)
	candidate := time.Date(localNow.Year(), localNow.Month(), localNow.Day(), hour, minute, 0, 0, location)
	if !candidate.After(localNow) {
		candidate = time.Date(localNow.Year(), localNow.Month(), localNow.Day()+1, hour, minute, 0, 0, location)
	}
	return candidate
}
