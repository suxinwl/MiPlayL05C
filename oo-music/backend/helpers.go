package oomusic

import (
	"crypto/rand"
	"fmt"
	"math/big"
	"strconv"
)

func randomDigits(digits int) (string, error) {
	if digits <= 0 {
		return "", fmt.Errorf("digits must be greater than zero")
	}
	max := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(digits)), nil)
	value, err := rand.Int(rand.Reader, max)
	if err != nil {
		return "", fmt.Errorf("generate random numeric ID: %w", err)
	}
	text := value.String()
	for len(text) < digits {
		text = "0" + text
	}
	return text, nil
}

func defaultPositive(value, fallback int) int {
	if value > 0 {
		return value
	}
	return fallback
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func intString(value int64) string {
	return strconv.FormatInt(value, 10)
}
