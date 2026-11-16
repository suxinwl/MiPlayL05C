package account

import (
	"fmt"

	"golang.org/x/sys/windows"
)

// Go's Chmod(0600) only changes the read-only attribute on Windows. Use an
// explicit protected NTFS DACL instead: this process's user, SYSTEM, and local
// administrators. Never modify the ACL of an existing parent directory.
func privateDatabaseDescriptor(directory bool) (*windows.SECURITY_DESCRIPTOR, error) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return nil, fmt.Errorf("读取当前 Windows 用户: %w", err)
	}
	flags := ""
	if directory {
		flags = "OICI"
	}
	sddl := fmt.Sprintf("D:P(A;%s;FA;;;SY)(A;%s;FA;;;BA)(A;%s;FA;;;%s)",
		flags, flags, flags, user.User.Sid.String())
	return windows.SecurityDescriptorFromString(sddl)
}

func setPrivateDatabaseDirectory(path string) error {
	return setPrivateDatabaseACL(path, true)
}

func setPrivateDatabaseFile(path string) error {
	return setPrivateDatabaseACL(path, false)
}

func setPrivateDatabaseACL(path string, directory bool) error {
	descriptor, err := privateDatabaseDescriptor(directory)
	if err != nil {
		return err
	}
	acl, _, err := descriptor.DACL()
	if err != nil {
		return err
	}
	return windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION,
		nil, nil, acl, nil)
}
