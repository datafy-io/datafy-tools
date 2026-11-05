//go:build !windows

package scanner

import (
	"os/exec"
	"syscall"
	"time"
)

// configure makes a cancelled scan really stop. The scanner runs in its own process group and the whole group is
// killed, so nothing it started can outlive it and keep the app waiting; WaitDelay bounds the wait in any case.
func configure(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 2 * time.Second
}
