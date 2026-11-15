// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// The go_sdk_checksums command checks SDK pins against Go's release list.
package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/tbhb-dev/rules/go/tools/sdkchecksums"
)

const releaseURL = "https://go.dev/dl/?mode=json&include=all"

func main() {
	client := &http.Client{Timeout: 60 * time.Second}
	os.Exit(run(os.Args[1:], os.Getenv("BUILD_WORKSPACE_DIRECTORY"), os.Stdout, client, git))
}

func git(dir string, args ...string) ([]byte, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	return cmd.Output()
}

type gitCommand func(string, ...string) ([]byte, error)

func readPins(read sdkchecksums.ReadFile) ([]sdkchecksums.Pin, error) {
	data, err := read("MODULE.bazel")
	if err != nil {
		return nil, err
	}
	pins, err := sdkchecksums.Module(data, read)
	if err != nil {
		return nil, err
	}
	data, err = read("MODULE.bazel.lock")
	if errors.Is(err, fs.ErrNotExist) {
		return pins, nil
	}
	if err != nil {
		return nil, err
	}
	locked, err := sdkchecksums.Lock(data)
	return append(pins, locked...), err
}

// changed restricts the network run to module edits that change SDK records.
// An unreadable baseline triggers validation, rather than hiding a new pin.
func changed(dir, base string, pins []sdkchecksums.Pin, command gitCommand) bool {
	diff, err := command(dir, "diff", base, "HEAD", "--", "MODULE.bazel", "MODULE.bazel.lock")
	if err != nil {
		return true
	}
	if len(diff) == 0 {
		return false
	}
	old, err := readPins(func(name string) ([]byte, error) {
		data, err := command(dir, "show", base+":./"+name)
		if err != nil && name == "MODULE.bazel.lock" {
			return nil, fs.ErrNotExist
		}
		return data, err
	})
	if err != nil {
		return true
	}
	return !slices.Equal(canonical(old), canonical(pins))
}

func canonical(pins []sdkchecksums.Pin) []string {
	result := make([]string, 0, len(pins))
	for _, pin := range pins {
		result = append(result, strings.Join([]string{pin.Version, pin.Platform, pin.Filename, pin.SHA256}, "\x00"))
	}
	slices.Sort(result)
	return result
}

func run(args []string, workspace string, out io.Writer, client *http.Client, command gitCommand) int {
	flags := flag.NewFlagSet("go_sdk_checksums", flag.ContinueOnError)
	flags.SetOutput(out)
	base := flags.String("changed-since", "", "only check SDK records changed since this Git revision")
	if err := flags.Parse(args); err != nil {
		return 1
	}
	dirs := flags.Args()
	if len(dirs) == 0 {
		dirs = []string{"."}
	}
	var pins []sdkchecksums.Pin
	selected := false
	for _, dir := range dirs {
		if !filepath.IsAbs(dir) {
			dir = filepath.Join(workspace, dir)
		}
		found, err := readPins(func(name string) ([]byte, error) {
			return os.ReadFile(filepath.Join(dir, name))
		})
		if err != nil {
			_, _ = fmt.Fprintf(out, "%s: %v\n", dir, err)
			return 1
		}
		if *base != "" && !changed(dir, *base, found, command) {
			_, _ = fmt.Fprintln(out, "Go SDK checksums: unchanged; skipping network comparison")
			continue
		}
		selected = true
		for _, pin := range found {
			pin.Source = filepath.Join(dir, pin.Source)
			pins = append(pins, pin)
		}
	}
	if !selected {
		return 0
	}
	data, err := fetch(client)
	if err == nil {
		var count int
		count, err = sdkchecksums.Compare(pins, data)
		if err == nil {
			_, _ = fmt.Fprintf(out, "Go SDK checksums: checked %d archive checksums against %s\n", count, releaseURL)
			return 0
		}
	}
	_, _ = fmt.Fprintln(out, err)
	return 1
}

func fetch(client *http.Client) ([]byte, error) {
	response, err := client.Get(releaseURL)
	if err != nil {
		return nil, err
	}
	defer func() { _ = response.Body.Close() }()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: HTTP %s", releaseURL, response.Status)
	}
	var data bytes.Buffer
	_, err = io.Copy(&data, response.Body)
	return data.Bytes(), err
}
