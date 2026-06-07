// Package mjolnir implements the Forgejo Actions executor backend
// that runs CI jobs inside Mjolnir microVMs instead of Docker containers.
//
// It implements the act Container and ExecutionsEnvironment interfaces,
// routing all execution through the Mjolnir HTTP API.
package mjolnir

import (
	"archive/tar"
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"code.forgejo.org/forgejo/runner/v12/act/common"
	"code.forgejo.org/forgejo/runner/v12/act/container"
)

func noop(_ context.Context) error { return nil }

// Compile-time interface checks.
var _ container.Container = (*VMEnvironment)(nil)

// VMEnvironment implements container.Container backed by a Mjolnir microVM.
type VMEnvironment struct {
	client *Client
	config SpawnConfig

	// Set after Create
	vmID string

	name    string
	root    string // workspace root inside VM
	actPath string

	stdout io.Writer
	stderr io.Writer
	mu     sync.Mutex
}

// NewVMEnvironment creates a new VM-backed execution environment.
func NewVMEnvironment(apiBase string, config SpawnConfig, name string) *VMEnvironment {
	return &VMEnvironment{
		client:  NewClient(apiBase),
		config:  config,
		name:    name,
		root:    "/workspace/src",
		actPath: "/workspace/src/.forgejo",
		stdout:  os.Stdout,
		stderr:  os.Stderr,
	}
}

// ---------------------------------------------------------------------------
// Container interface
// ---------------------------------------------------------------------------

func (v *VMEnvironment) Create(capAdd, capDrop []string) common.Executor {
	return func(ctx context.Context) error {
		info, err := v.client.SpawnVM(ctx, v.config)
		if err != nil {
			return fmt.Errorf("vm create: %w", err)
		}
		v.vmID = info.ID

		// Wait for VM to boot and become responsive
		for i := 0; i < 30; i++ {
			_, err := v.client.ExecCommand(ctx, v.vmID, "true", nil)
			if err == nil {
				return nil
			}
			time.Sleep(time.Second)
		}
		return fmt.Errorf("vm %s did not become responsive after 30s", v.vmID)
	}
}

func (v *VMEnvironment) Pull(forcePull bool) common.Executor {
	return common.Executor(noop)
}

func (v *VMEnvironment) Start(attach bool) common.Executor {
	return common.Executor(noop)
}

func (v *VMEnvironment) Exec(command []string, env map[string]string, user, workdir string) common.Executor {
	return func(ctx context.Context) error {
		cmd := strings.Join(command, " ")

		// Wrap with workdir and user if specified
		if workdir == "" {
			workdir = v.root
		}
		shellCmd := fmt.Sprintf("cd %s && %s", shellQuote(workdir), cmd)
		if user != "" && user != "root" {
			shellCmd = fmt.Sprintf("su -c %s %s", shellQuote(shellCmd), user)
		}

		result, err := v.client.ExecCommand(ctx, v.vmID, shellCmd, env)
		if err != nil {
			return fmt.Errorf("vm exec: %w", err)
		}

		// Write output to log writers
		v.mu.Lock()
		stdout := v.stdout
		v.mu.Unlock()

		if stdout != nil && result.Output != "" {
			_, _ = io.WriteString(stdout, result.Output)
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
			fullPath := filepath.Join(destPath, f.Name)
			dir := filepath.Dir(fullPath)

			// Create parent directory and write file via exec
			cmd := fmt.Sprintf("mkdir -p %s && cat > %s << 'MJOLNIR_EOF'\n%s\nMJOLNIR_EOF\nchmod %o %s",
				shellQuote(dir), shellQuote(fullPath), f.Body, f.Mode, shellQuote(fullPath))

			_, err := v.client.ExecCommand(ctx, v.vmID, cmd, nil)
			if err != nil {
				return fmt.Errorf("copy file %s: %w", f.Name, err)
			}
		}
		return nil
	}
}

func (v *VMEnvironment) CopyTarStream(ctx context.Context, destPath string, tarStream io.Reader) error {
	// Extract tar and copy files individually via exec
	tr := tar.NewReader(tarStream)
	for {
		header, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("read tar: %w", err)
		}

		fullPath := filepath.Join(destPath, header.Name)

		switch header.Typeflag {
		case tar.TypeDir:
			cmd := fmt.Sprintf("mkdir -p %s", shellQuote(fullPath))
			if _, err := v.client.ExecCommand(ctx, v.vmID, cmd, nil); err != nil {
				return fmt.Errorf("mkdir %s: %w", fullPath, err)
			}
		case tar.TypeReg:
			var buf bytes.Buffer
			if _, err := io.Copy(&buf, tr); err != nil {
				return fmt.Errorf("read tar entry %s: %w", header.Name, err)
			}
			// Use base64 for binary-safe transfer
			cmd := fmt.Sprintf("mkdir -p %s && echo %s | base64 -d > %s && chmod %o %s",
				shellQuote(filepath.Dir(fullPath)),
				base64Encode(buf.Bytes()),
				shellQuote(fullPath),
				header.Mode,
				shellQuote(fullPath))
			if _, err := v.client.ExecCommand(ctx, v.vmID, cmd, nil); err != nil {
				return fmt.Errorf("write %s: %w", fullPath, err)
			}
		}
	}
	return nil
}

func (v *VMEnvironment) CopyDir(destPath, srcPath string, useGitIgnore bool) common.Executor {
	return func(ctx context.Context) error {
		// For VM execution, CopyDir is typically used for action checkout.
		// Since we mount the repo via virtio-fs, this may be a no-op in many cases.
		// For now, create the destination directory.
		cmd := fmt.Sprintf("mkdir -p %s", shellQuote(destPath))
		_, err := v.client.ExecCommand(ctx, v.vmID, cmd, nil)
		return err
	}
}

func (v *VMEnvironment) GetContainerArchive(ctx context.Context, srcPath string) (io.ReadCloser, error) {
	// Read a file from the VM and return it as a tar stream
	result, err := v.client.ExecCommand(ctx, v.vmID,
		fmt.Sprintf("tar cf - -C %s .", shellQuote(srcPath)), nil)
	if err != nil {
		return nil, fmt.Errorf("get archive %s: %w", srcPath, err)
	}
	return io.NopCloser(strings.NewReader(result.Output)), nil
}

func (v *VMEnvironment) UpdateFromEnv(srcPath string, env *map[string]string) common.Executor {
	return func(ctx context.Context) error {
		if env == nil {
			return nil
		}
		result, err := v.client.ExecCommand(ctx, v.vmID,
			fmt.Sprintf("cat %s 2>/dev/null || true", shellQuote(srcPath)), nil)
		if err != nil {
			return nil
		}
		// Parse KEY=VALUE lines
		for _, line := range strings.Split(result.Output, "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			if k, v, ok := strings.Cut(line, "="); ok {
				(*env)[k] = v
			}
		}
		return nil
	}
}

func (v *VMEnvironment) UpdateFromImageEnv(env *map[string]string) common.Executor {
	return common.Executor(noop)
}

func (v *VMEnvironment) Remove() common.Executor {
	return func(ctx context.Context) error {
		if v.vmID == "" {
			return nil
		}
		return v.client.StopVM(ctx, v.vmID)
	}
}

func (v *VMEnvironment) Close() common.Executor {
	return v.Remove()
}

func (v *VMEnvironment) ReplaceLogWriter(stdout, stderr io.Writer) (io.Writer, io.Writer) {
	v.mu.Lock()
	defer v.mu.Unlock()
	oldOut, oldErr := v.stdout, v.stderr
	v.stdout = stdout
	v.stderr = stderr
	return oldOut, oldErr
}

func (v *VMEnvironment) IsHealthy(ctx context.Context) (time.Duration, error) {
	if v.vmID == "" {
		return 0, nil
	}
	_, err := v.client.VMStatus(ctx, v.vmID)
	return 0, err
}

// ---------------------------------------------------------------------------
// ExecutionsEnvironment interface
// ---------------------------------------------------------------------------

func (v *VMEnvironment) ToContainerPath(path string) string {
	if strings.HasPrefix(path, v.root) {
		return path
	}
	return filepath.Join(v.root, path)
}

func (v *VMEnvironment) GetName() string    { return v.name }
func (v *VMEnvironment) GetRoot() string    { return v.root }
func (v *VMEnvironment) GetActPath() string { return v.actPath }
func (v *VMEnvironment) BackendID() string  { return "mjolnir-vm" }

func (v *VMEnvironment) GetRunnerContext(_ context.Context) map[string]interface{} {
	return map[string]interface{}{
		"os":         "linux",
		"arch":       runtime.GOARCH,
		"temp":       "/tmp",
		"tool_cache": "/opt/hostedtoolcache",
	}
}

func (v *VMEnvironment) GetPathVariableName() string    { return "PATH" }
func (v *VMEnvironment) DefaultPathVariable() string    { return "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" }
func (v *VMEnvironment) JoinPathVariable(elems ...string) string { return strings.Join(elems, ":") }

func (v *VMEnvironment) SupportsDockerContainerActions() bool { return false }
func (v *VMEnvironment) ManagesOwnNetworking() bool          { return true }
func (v *VMEnvironment) IsEnvironmentCaseInsensitive() bool   { return false }

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}

func base64Encode(data []byte) string {
	// Use shell-safe base64
	encoded := make([]byte, 0, len(data)*2)
	const table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i := 0; i < len(data); i += 3 {
		var b uint32
		remaining := len(data) - i
		if remaining >= 3 {
			b = uint32(data[i])<<16 | uint32(data[i+1])<<8 | uint32(data[i+2])
			encoded = append(encoded, table[b>>18&0x3F], table[b>>12&0x3F], table[b>>6&0x3F], table[b&0x3F])
		} else if remaining == 2 {
			b = uint32(data[i])<<16 | uint32(data[i+1])<<8
			encoded = append(encoded, table[b>>18&0x3F], table[b>>12&0x3F], table[b>>6&0x3F], '=')
		} else {
			b = uint32(data[i]) << 16
			encoded = append(encoded, table[b>>18&0x3F], table[b>>12&0x3F], '=', '=')
		}
	}
	return string(encoded)
}
