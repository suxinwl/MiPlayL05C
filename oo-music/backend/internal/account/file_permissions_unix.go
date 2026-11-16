//go:build !windows

package account

import "os"

func setPrivateDatabaseDirectory(path string) error {
	return os.Chmod(path, 0o700)
}

func setPrivateDatabaseFile(path string) error {
	return os.Chmod(path, 0o600)
}
