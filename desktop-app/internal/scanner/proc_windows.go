//go:build windows

package scanner

import (
	"os/exec"
	"time"
)

// configure bounds how long the app waits for a cancelled scan to release its output pipes.
func configure(cmd *exec.Cmd) {
	cmd.WaitDelay = 2 * time.Second
}
