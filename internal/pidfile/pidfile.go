package pidfile

import (
	"os"
	"strconv"
	"strings"
)

func Read(path string) int {
	raw, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 0 {
		return 0
	}
	return pid
}

func Write(path string, pid int) error {
	return os.WriteFile(path, []byte(strconv.Itoa(pid)+"\n"), 0o600)
}

func Owns(path string, pid int) bool {
	return pid > 0 && Read(path) == pid
}

func RemoveIfOwner(path string, pid int) {
	if Owns(path, pid) {
		_ = os.Remove(path)
	}
}
