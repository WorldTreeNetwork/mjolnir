package mjolnir

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"code.forgejo.org/forgejo/runner/v12/act/common"
	"code.forgejo.org/forgejo/runner/v12/act/container"
)

var _ container.Container = (*VMEnvironment)(nil)

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
	apiBase string
	config  SpawnConfig
	vmID    string
	name    string
	stdout  io.Writer
	stderr  io.Writer
	mu      sync.Mutex
}

func NewVMEnvironment(apiBase string, config SpawnConfig, name string) *VMEnvironment {
	return &VMEnvironment{
		apiBase: apiBase,
		config:  config,
		name:    name,
		stdout:  os.Stdout,
		stderr:  os.Stderr,
	}
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
	return func(_ context.Context) error { return nil }
}
func (v *VMEnvironment) Start(_ bool) common.Executor {
	return func(_ context.Context) error { return nil }
}
func (v *VMEnvironment) UpdateFromImageEnv(_ *map[string]string) common.Executor {
	return func(_ context.Context) error { return nil }
}

func (v *VMEnvironment) Exec(command []string, env map[string]string, user, workdir string) common.Executor {
	return func(ctx context.Context) error {
		cmd := strings.Join(command, " ")
		if workdir == "" {
			workdir = "/workspace/src"
		}
		shellCmd := fmt.Sprintf("cd %s && %s", sq(workdir), cmd)
		if user != "" && user != "root" {
			shellCmd = fmt.Sprintf("su -c %s %s", sq(shellCmd), user)
		}
		result, err := v.execCmd(ctx, shellCmd, env)
		if err != nil {
			return err
		}
		v.mu.Lock()
		w := v.stdout
		v.mu.Unlock()
		if w != nil && result.Output != "" {
			io.WriteString(w, result.Output)
		}
		if result.ExitCode != 0 {
			return fmt.Errorf("exit code %d", result.ExitCode)
		}
		return nil
	}
}

func (v *VMEnvironment) Copy(destPath string, files ...*container.FileEntry) common.Executor {
	return func(ctx context.Context) error {
		for _, f := range files {
			fp := filepath.Join(destPath, f.Name)
			encoded := base64.StdEncoding.EncodeToString([]byte(f.Body))
			cmd := fmt.Sprintf("mkdir -p %s && echo %s | base64 -d > %s && chmod %o %s",
				sq(filepath.Dir(fp)), encoded, sq(fp), f.Mode, sq(fp))
			if _, err := v.execCmd(ctx, cmd, nil); err != nil {
				return fmt.Errorf("copy %s: %w", f.Name, err)
			}
		}
		return nil
	}
}

func (v *VMEnvironment) CopyTarStream(ctx context.Context, destPath string, tarStream io.Reader) error {
	tr := tar.NewReader(tarStream)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		fp := filepath.Join(destPath, hdr.Name)
		if hdr.Typeflag == tar.TypeDir {
			v.execCmd(ctx, fmt.Sprintf("mkdir -p %s", sq(fp)), nil)
		} else if hdr.Typeflag == tar.TypeReg {
			var buf bytes.Buffer
			io.Copy(&buf, tr)
			encoded := base64.StdEncoding.EncodeToString(buf.Bytes())
			cmd := fmt.Sprintf("mkdir -p %s && echo %s | base64 -d > %s && chmod %o %s",
				sq(filepath.Dir(fp)), encoded, sq(fp), hdr.Mode, sq(fp))
			v.execCmd(ctx, cmd, nil)
		}
	}
	return nil
}

func (v *VMEnvironment) CopyDir(destPath, srcPath string, _ bool) common.Executor {
	return func(ctx context.Context) error {
		_, err := v.execCmd(ctx, fmt.Sprintf("mkdir -p %s", sq(destPath)), nil)
		return err
	}
}

func (v *VMEnvironment) GetContainerArchive(ctx context.Context, srcPath string) (io.ReadCloser, error) {
	result, err := v.execCmd(ctx, fmt.Sprintf("tar cf - -C %s . 2>/dev/null | base64", sq(srcPath)), nil)
	if err != nil {
		return nil, err
	}
	decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(result.Output))
	if err != nil {
		return nil, fmt.Errorf("decode archive: %w", err)
	}
	return io.NopCloser(bytes.NewReader(decoded)), nil
}

func (v *VMEnvironment) UpdateFromEnv(srcPath string, env *map[string]string) common.Executor {
	return func(ctx context.Context) error {
		if env == nil {
			return nil
		}
		result, err := v.execCmd(ctx, fmt.Sprintf("cat %s 2>/dev/null || true", sq(srcPath)), nil)
		if err != nil {
			return nil
		}
		for _, line := range strings.Split(result.Output, "\n") {
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

func (v *VMEnvironment) ToContainerPath(p string) string     { return filepath.Join("/workspace/src", p) }
func (v *VMEnvironment) GetName() string                     { return v.name }
func (v *VMEnvironment) GetRoot() string                     { return "/workspace/src" }
func (v *VMEnvironment) GetActPath() string                  { return "/workspace/src/.forgejo" }
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

func sq(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'"'"'`) + "'"
}
