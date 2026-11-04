// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Package scratch is what the runners that run a Go tool over one package of
// a consumer's module inside Bazel have in common: the manifest the rule
// writes, a scratch copy of the module, and the go command's environment
// pointed at the toolchain's SDK, the scratch tree and an offline module
// proxy.
package scratch

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Entry is a manifest line: the file's role in the unit, where it is in the
// execution root and its path relative to the module directory.
type Entry struct {
	Role, Src, Rel string
}

// Roles: the package's own sources, its tests, data its tests read, go.mod
// and go.sum, and the sources of the packages it depends on.
const (
	RoleMut  = "mut"
	RoleTest = "test"
	RoleData = "data"
	RoleMod  = "mod"
	RoleDep  = "dep"
)

// ReadManifest reads the manifest file the rule writes.
func ReadManifest(name string) ([]Entry, error) {
	data, err := os.ReadFile(name)
	if err != nil {
		return nil, err
	}
	var entries []Entry
	for _, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		fields := strings.Split(line, "\t")
		if len(fields) != 3 {
			return nil, fmt.Errorf("manifest line %q is not <role>\\t<source>\\t<path>", line)
		}
		entries = append(entries, Entry{fields[0], fields[1], fields[2]})
	}
	return entries, nil
}

// Work is a scratch directory holding the module and the go command's
// caches and home.
type Work struct {
	// Dir is the scratch directory itself, with its symlinks resolved.
	Dir string
	// Mod is the copy of the module in it.
	Mod string
	// Env is the environment to run the go command, and tools that run it,
	// in.
	Env []string
}

// New copies entries to a new scratch directory named after prefix, and sets
// up the environment around it for the go command of goBin: modules come
// only from the GOPROXY directory proxy, none when it is empty. The caller
// closes it.
func New(prefix string, entries []Entry, goBin, proxy string) (*Work, error) {
	goBin, err := filepath.Abs(goBin)
	if err != nil {
		return nil, err
	}
	if proxy != "" {
		if proxy, err = filepath.Abs(proxy); err != nil {
			return nil, err
		}
	}
	dir, err := os.MkdirTemp("", prefix)
	if err != nil {
		return nil, err
	}
	// Tools compare the paths they are given with ones they read back, so
	// the directory is named the way the file system does.
	resolved, err := filepath.EvalSymlinks(dir)
	if err != nil {
		_ = os.RemoveAll(dir)
		return nil, err
	}
	w := &Work{Dir: resolved}
	w.Mod = filepath.Join(w.Dir, "mod")
	if err := copyTree(entries, w.Mod); err != nil {
		w.Close()
		return nil, err
	}
	for _, sub := range []string{"home", "tmp"} {
		if err := os.Mkdir(filepath.Join(w.Dir, sub), 0o755); err != nil {
			w.Close()
			return nil, err
		}
	}
	w.Env = Environ(os.Environ(), goBin, w.Dir, proxy)
	return w, nil
}

// Close removes the scratch directory.
func (w *Work) Close() {
	_ = os.RemoveAll(w.Dir)
}

// copyTree copies each entry to its path under root. Copies, not links: the
// go command reads the module tree, and Bazel's are symlinks.
func copyTree(entries []Entry, root string) error {
	for _, e := range entries {
		dest := filepath.Join(root, filepath.FromSlash(e.Rel))
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			return err
		}
		data, err := os.ReadFile(e.Src)
		if err != nil {
			return err
		}
		if err := os.WriteFile(dest, data, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// Command is name run in dir with env, its output appended to out.
func Command(name string, args []string, dir string, env []string, out *bytes.Buffer) *exec.Cmd {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Env = env
	cmd.Stdout = out
	cmd.Stderr = out
	return cmd
}

// Environ is base with the go command's settings replaced: the SDK's go
// first on PATH, caches and HOME under work, modules only from proxy.
func Environ(base []string, goBin, work, proxy string) []string {
	var env []string
	path := ""
	for _, kv := range base {
		key, value, _ := strings.Cut(kv, "=")
		upper := strings.ToUpper(key)
		switch {
		case upper == "PATH":
			path = value
		case strings.HasPrefix(upper, "GO"), strings.HasPrefix(upper, "CGO_"),
			upper == "HOME", upper == "USERPROFILE", upper == "XDG_CONFIG_HOME",
			upper == "TMPDIR", upper == "TMP", upper == "TEMP":
		default:
			env = append(env, kv)
		}
	}
	goroot := filepath.Dir(filepath.Dir(goBin))
	bin := filepath.Join(goroot, "bin")
	if path != "" {
		bin += string(os.PathListSeparator) + path
	}
	goproxy := "off"
	if proxy != "" {
		goproxy = FileURL(proxy)
	}
	home := filepath.Join(work, "home")
	tmp := filepath.Join(work, "tmp")
	return append(env,
		"PATH="+bin,
		"GOROOT="+goroot,
		"HOME="+home,
		"USERPROFILE="+home,
		"XDG_CONFIG_HOME="+filepath.Join(home, ".config"),
		"TMPDIR="+tmp,
		"TMP="+tmp,
		"TEMP="+tmp,
		"GOCACHE="+filepath.Join(work, "gocache"),
		"GOPATH="+filepath.Join(work, "gopath"),
		"GOMODCACHE="+filepath.Join(work, "gopath", "pkg", "mod"),
		"GOPROXY="+goproxy,
		// go.sum is the module's own; the checksum database is not asked.
		"GOSUMDB=off",
		// -modcacherw: the scratch tree is removed, module cache included.
		"GOFLAGS=-modcacherw",
		"GOTOOLCHAIN=local",
		"GOWORK=off",
		"GOENV=off",
		"GOTELEMETRY=off",
		// No C compiler from the host.
		"CGO_ENABLED=0",
	)
}

// PathOf returns the last PATH in env.
func PathOf(env []string) string {
	value := ""
	for _, kv := range env {
		if k, v, _ := strings.Cut(kv, "="); strings.EqualFold(k, "PATH") {
			value = v
		}
	}
	return value
}

// FileURL is the file:// URL of dir.
func FileURL(dir string) string {
	slashed := filepath.ToSlash(dir)
	if !strings.HasPrefix(slashed, "/") {
		slashed = "/" + slashed // C:/x becomes file:///C:/x
	}
	return "file://" + slashed
}
