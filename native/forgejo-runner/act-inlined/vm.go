package mjolnir

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"code.forgejo.org/forgejo/runner/v12/act/common"
	"code.forgejo.org/forgejo/runner/v12/act/container"
)

var _ container.Container = (*VMEnvironment)(nil)

// Default BTRFS root for VM subvolumes. The VM rootfs is at
// <btrfsRoot>/@vms/<vmID>/ on the host filesystem, directly writable
// since the Go runner runs on the same host.
const defaultBTRFSRoot = "/var/lib/mjolnir/btrfs"

type SpawnConfig struct {
	BaseImage   string  `json:"base_image,omitempty"`
	ExtraMounts []Mount `json:"extra_mounts,omitempty"`
}

type Mount struct {
	Tag      string `json:"tag"`
	Path     string `json:"path"`
	Readonly bool   `json:"readonly,omitempty"`
}

type VMInfo struct {
	ID     string `json:"id"`
	Status string `json:"status"`
}

type ExecResult struct {
	ExitCode int    `json:"exit_code"`
	Output   string `json:"output"`
	Stderr   string `json:"stderr"`
}

type VMEnvironment struct {
	apiBase  string
	config   SpawnConfig
	vmID     string
	name     string
	stdout   io.Writer
	stderr   io.Writer
	mu       sync.Mutex
	btrfsRoot string
}

func NewVMEnvironment(apiBase string, config SpawnConfig, name string) *VMEnvironment {
	btrfs := os.Getenv("MJOLNIR_BTRFS_ROOT")
	if btrfs == "" {
		btrfs = defaultBTRFSRoot
	}
	return &VMEnvironment{
		apiBase:   apiBase,
		config:    config,
		name:      name,
		stdout:    os.Stdout,
		stderr:    os.Stderr,
		btrfsRoot: btrfs,
	}
}

// rootfsPath returns the host-side path to the VM's rootfs directory.
func (v *VMEnvironment) rootfsPath() string {
	return filepath.Join(v.btrfsRoot, "@vms", v.vmID)
}

// hostPath translates a container-side path to the host-side rootfs path.
// e.g., "/workspace/src/.forgejo/actions/foo" → "<btrfs>/@vms/<id>/workspace/src/.forgejo/actions/foo"
func (v *VMEnvironment) hostPath(containerPath string) string {
	// Strip leading slash to make it relative
	rel := strings.TrimPrefix(containerPath, "/")
	return filepath.Join(v.rootfsPath(), rel)
}

func (v *VMEnvironment) Create(capAdd, capDrop []string) common.Executor {
	return func(ctx context.Context) error {
		data, _ := json.Marshal(v.config)
		req, _ := http.NewRequestWithContext(ctx, "POST", v.apiBase+"/api/vms", bytes.NewReader(data))
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return fmt.Errorf("vm spawn: %w", err)
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		if resp.StatusCode >= 300 {
			return fmt.Errorf("vm spawn %d: %s", resp.StatusCode, body)
		}
		var info VMInfo
		json.Unmarshal(body, &info)
		v.vmID = info.ID

		for i := 0; i < 30; i++ {
			if _, err := v.execCmd(ctx, "true", nil); err == nil {
				return nil
			}
			time.Sleep(time.Second)
		}
		return fmt.Errorf("vm %s not responsive after 30s", v.vmID)
	}
}

func (v *VMEnvironment) Pull(_ bool) common.Executor {
	return common.Executor(func(_ context.Context) error { return nil })
}
func (v *VMEnvironment) Start(_ bool) common.Executor {
	return common.Executor(func(_ context.Context) error { return nil })
}
func (v *VMEnvironment) UpdateFromImageEnv(_ *map[string]string) common.Executor {
	return common.Executor(func(_ context.Context) error { return nil })
}

func (v *VMEnvironment) Exec(command []string, env map[string]string, user, workdir string) common.Executor {
	return func(ctx context.Context) error {
		cmd := strings.Join(command, " ")
		if workdir == "" {
			workdir = "/"
		}

		// Write env vars to a file on the host-side rootfs, then source
		// it inside the VM before running the command. This avoids command
		// length limits and shell quoting issues with inline exports.
		if len(env) > 0 && v.vmID != "" {
			envFile := v.hostPath("/.forgejo/.env.sh")
			os.MkdirAll(filepath.Dir(envFile), 0o755)
			var buf bytes.Buffer
			var keys []string
			for k := range env {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, k := range keys {
				// Skip env var names that are invalid in shell (contain hyphens, etc.)
				if !isValidShellVarName(k) {
					continue
				}
				buf.WriteString(fmt.Sprintf("export %s=%s\n", k, sq(env[k])))
			}
			os.WriteFile(envFile, buf.Bytes(), 0o644)
		}

		var sourcePrefix string
		if len(env) > 0 {
			sourcePrefix = ". /.forgejo/.env.sh && "
		}

		shellCmd := fmt.Sprintf("%scd %s && %s 2>&1", sourcePrefix, sq(workdir), cmd)
		fmt.Fprintf(os.Stderr, "[mjolnir-exec] vmID=%s workdir=%s cmd=%s envCount=%d shellLen=%d\n", v.vmID, workdir, cmd, len(env), len(shellCmd))
		if user != "" && user != "root" {
			shellCmd = fmt.Sprintf("su -c %s %s", sq(shellCmd), user)
		}
		result, err := v.execCmd(ctx, shellCmd, nil)
		if err != nil {
			fmt.Fprintf(os.Stderr, "[mjolnir-exec] ERROR: %v\n", err)
			return err
		}
		fmt.Fprintf(os.Stderr, "[mjolnir-exec] result: exit=%d outLen=%d stderr=%.500s out=%.200s\n", result.ExitCode, len(result.Output), result.Stderr, result.Output)
		v.mu.Lock()
		w := v.stdout
		v.mu.Unlock()
		if w != nil && result.Output != "" {
			io.WriteString(w, result.Output)
		}
		if result.ExitCode != 0 {
			if w != nil && result.Stderr != "" {
				io.WriteString(w, result.Stderr)
			}
			return fmt.Errorf("exit code %d", result.ExitCode)
		}
		return nil
	}
}

// Copy writes individual files directly to the VM's rootfs on the host.
func (v *VMEnvironment) Copy(destPath string, files ...*container.FileEntry) common.Executor {
	return func(ctx context.Context) error {
		for _, f := range files {
			fp := v.hostPath(filepath.Join(destPath, f.Name))
			if err := os.MkdirAll(filepath.Dir(fp), 0o755); err != nil {
				return fmt.Errorf("mkdir %s: %w", filepath.Dir(fp), err)
			}
			if err := os.WriteFile(fp, []byte(f.Body), os.FileMode(f.Mode)); err != nil {
				return fmt.Errorf("write %s: %w", fp, err)
			}
		}
		return nil
	}
}

// CopyTarStream extracts a tar stream directly to the VM's rootfs on the host.
func (v *VMEnvironment) CopyTarStream(ctx context.Context, destPath string, tarStream io.Reader) error {
	hostDest := v.hostPath(destPath)
	if err := os.MkdirAll(hostDest, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", hostDest, err)
	}

	tr := tar.NewReader(tarStream)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		fp := filepath.Join(hostDest, hdr.Name)

		// Prevent path traversal
		if !strings.HasPrefix(filepath.Clean(fp), filepath.Clean(hostDest)) {
			continue
		}

		switch hdr.Typeflag {
		case tar.TypeDir:
			os.MkdirAll(fp, os.FileMode(hdr.Mode)|0o755)
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(fp), 0o755); err != nil {
				return err
			}
			out, err := os.OpenFile(fp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(hdr.Mode))
			if err != nil {
				return fmt.Errorf("create %s: %w", fp, err)
			}
			if _, err := io.Copy(out, tr); err != nil {
				out.Close()
				return fmt.Errorf("write %s: %w", fp, err)
			}
			out.Close()
		case tar.TypeSymlink:
			os.Symlink(hdr.Linkname, fp)
		}
	}
	return nil
}

// CopyDir copies a host directory directly into the VM's rootfs.
func (v *VMEnvironment) CopyDir(destPath, srcPath string, _ bool) common.Executor {
	return func(ctx context.Context) error {
		hostDest := v.hostPath(destPath)
		if err := os.MkdirAll(hostDest, 0o755); err != nil {
			return fmt.Errorf("mkdir %s: %w", hostDest, err)
		}
		// Use cp -a for full recursive copy preserving permissions
		fmt.Fprintf(os.Stderr, "[mjolnir-copydir] src=%s dest=%s hostDest=%s\n", srcPath, destPath, hostDest)

		// Check source exists
		if _, err := os.Stat(srcPath); err != nil {
			fmt.Fprintf(os.Stderr, "[mjolnir-copydir] ERROR: source does not exist: %s: %v\n", srcPath, err)
			return fmt.Errorf("copydir source missing: %s: %w", srcPath, err)
		}

		cmd := exec.CommandContext(ctx, "cp", "-a", srcPath+"/.", hostDest+"/")
		if out, err := cmd.CombinedOutput(); err != nil {
			fmt.Fprintf(os.Stderr, "[mjolnir-copydir] ERROR: cp failed: %s\n", string(out))
			return fmt.Errorf("cp -a %s → %s: %w (%s)", srcPath, hostDest, err, string(out))
		}

		// Verify dest
		count := 0
		filepath.Walk(hostDest, func(_ string, _ os.FileInfo, _ error) error { count++; return nil })
		fmt.Fprintf(os.Stderr, "[mjolnir-copydir] OK: copied %d entries to %s\n", count, hostDest)
		return nil
	}
}

func (v *VMEnvironment) GetContainerArchive(ctx context.Context, srcPath string) (io.ReadCloser, error) {
	hostSrc := v.hostPath(srcPath)

	info, err := os.Stat(hostSrc)
	if err != nil {
		// File doesn't exist — return empty tar (the runner may read state
		// files like SUMMARY.md or pathcmd.txt that haven't been created yet)
		var buf bytes.Buffer
		tw := tar.NewWriter(&buf)
		tw.Close()
		return io.NopCloser(&buf), nil
	}

	var buf bytes.Buffer
	if info.IsDir() {
		cmd := exec.CommandContext(ctx, "tar", "cf", "-", "-C", hostSrc, ".")
		cmd.Stdout = &buf
		if err := cmd.Run(); err != nil {
			return nil, fmt.Errorf("tar %s: %w", hostSrc, err)
		}
	} else {
		// Single file — tar it from its parent directory
		dir := filepath.Dir(hostSrc)
		name := filepath.Base(hostSrc)
		cmd := exec.CommandContext(ctx, "tar", "cf", "-", "-C", dir, name)
		cmd.Stdout = &buf
		if err := cmd.Run(); err != nil {
			return nil, fmt.Errorf("tar %s: %w", hostSrc, err)
		}
	}
	return io.NopCloser(&buf), nil
}

func (v *VMEnvironment) UpdateFromEnv(srcPath string, env *map[string]string) common.Executor {
	return func(ctx context.Context) error {
		if env == nil {
			return nil
		}
		// Read env file directly from rootfs
		hostSrc := v.hostPath(srcPath)
		data, err := os.ReadFile(hostSrc)
		if err != nil {
			return nil // file not existing is fine
		}
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			if k, val, ok := strings.Cut(line, "="); ok {
				(*env)[k] = val
			}
		}
		return nil
	}
}

func (v *VMEnvironment) Remove() common.Executor {
	return func(ctx context.Context) error {
		if v.vmID == "" {
			return nil
		}
		req, _ := http.NewRequestWithContext(ctx, "DELETE", v.apiBase+"/api/vms/"+v.vmID, nil)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return err
		}
		resp.Body.Close()
		return nil
	}
}

func (v *VMEnvironment) Close() common.Executor { return v.Remove() }

func (v *VMEnvironment) ReplaceLogWriter(stdout, stderr io.Writer) (io.Writer, io.Writer) {
	v.mu.Lock()
	defer v.mu.Unlock()
	old1, old2 := v.stdout, v.stderr
	v.stdout, v.stderr = stdout, stderr
	return old1, old2
}

func (v *VMEnvironment) IsHealthy(_ context.Context) (time.Duration, error) { return 0, nil }

// ExecutionsEnvironment methods

func (v *VMEnvironment) ToContainerPath(p string) string {
	if filepath.IsAbs(p) {
		return p
	}
	return filepath.Join("/", p)
}
func (v *VMEnvironment) GetName() string    { return v.name }
func (v *VMEnvironment) GetRoot() string    { return "/" }
func (v *VMEnvironment) GetActPath() string { return "/.forgejo" }
func (v *VMEnvironment) BackendID() string                   { return "mjolnir-vm" }
func (v *VMEnvironment) GetPathVariableName() string         { return "PATH" }
func (v *VMEnvironment) DefaultPathVariable() string         { return "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" }
func (v *VMEnvironment) JoinPathVariable(e ...string) string { return strings.Join(e, ":") }
func (v *VMEnvironment) SupportsDockerContainerActions() bool { return false }
func (v *VMEnvironment) ManagesOwnNetworking() bool          { return true }
func (v *VMEnvironment) IsEnvironmentCaseInsensitive() bool   { return false }
func (v *VMEnvironment) GetRunnerContext(_ context.Context) map[string]any {
	return map[string]any{"os": "linux", "arch": runtime.GOARCH, "temp": "/tmp", "tool_cache": "/opt/hostedtoolcache"}
}

// Internal helpers

func (v *VMEnvironment) execCmd(ctx context.Context, cmd string, env map[string]string) (ExecResult, error) {
	body := struct {
		Command string            `json:"command"`
		Env     map[string]string `json:"env,omitempty"`
	}{cmd, env}
	data, _ := json.Marshal(body)
	req, _ := http.NewRequestWithContext(ctx, "POST", v.apiBase+"/api/vms/"+v.vmID+"/exec", bytes.NewReader(data))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return ExecResult{}, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		return ExecResult{}, fmt.Errorf("exec %d: %s", resp.StatusCode, raw)
	}
	var r ExecResult
	json.Unmarshal(raw, &r)
	return r, nil
}

func isValidShellVarName(name string) bool {
	if len(name) == 0 {
		return false
	}
	for i, c := range name {
		if c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c == '_' {
			continue
		}
		if i > 0 && c >= '0' && c <= '9' {
			continue
		}
		return false
	}
	return true
}

func sq(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'"'"'`) + "'"
}
