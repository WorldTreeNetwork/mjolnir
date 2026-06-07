package mjolnir

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
)

// SpawnConfig configures a VM at spawn time.
type SpawnConfig struct {
	BaseImage   string  `json:"base_image,omitempty"`
	ExtraMounts []Mount `json:"extra_mounts,omitempty"`
}

// Mount describes a virtio-fs filesystem to attach to the VM.
type Mount struct {
	Tag      string `json:"tag"`
	Path     string `json:"path"`
	Readonly bool   `json:"readonly,omitempty"`
}

// VMInfo is the API representation of a running or stopped VM.
type VMInfo struct {
	ID     string `json:"id"`
	Status string `json:"status"`
}

// ExecResult holds the output of a command run inside a VM.
type ExecResult struct {
	ExitCode int    `json:"exit_code"`
	Output   string `json:"output"`
	Stderr   string `json:"stderr"`
}

// Client is an HTTP client for the Mjolnir API.
type Client struct {
	base string
	http *http.Client
}

// NewClient returns a Client targeting the given API base URL
// (e.g. "http://127.0.0.1:4000").
func NewClient(apiBase string) *Client {
	return &Client{
		base: apiBase,
		http: &http.Client{},
	}
}

// SpawnVM creates a new VM and returns its info.
// POST /api/vms
func (c *Client) SpawnVM(ctx context.Context, config SpawnConfig) (VMInfo, error) {
	var info VMInfo
	if err := c.do(ctx, http.MethodPost, "/api/vms", config, &info); err != nil {
		return VMInfo{}, fmt.Errorf("spawn vm: %w", err)
	}
	return info, nil
}

// ExecCommand runs a command inside the given VM and returns its output.
// POST /api/vms/{id}/exec
func (c *Client) ExecCommand(ctx context.Context, vmID string, command string, env map[string]string) (ExecResult, error) {
	body := struct {
		Command string            `json:"command"`
		Env     map[string]string `json:"env,omitempty"`
	}{Command: command, Env: env}

	var result ExecResult
	if err := c.do(ctx, http.MethodPost, "/api/vms/"+vmID+"/exec", body, &result); err != nil {
		return ExecResult{}, fmt.Errorf("exec command in vm %s: %w", vmID, err)
	}
	return result, nil
}

// StopVM stops and removes the given VM.
// DELETE /api/vms/{id}
func (c *Client) StopVM(ctx context.Context, vmID string) error {
	if err := c.do(ctx, http.MethodDelete, "/api/vms/"+vmID, nil, nil); err != nil {
		return fmt.Errorf("stop vm %s: %w", vmID, err)
	}
	return nil
}

// VMStatus returns the current status of the given VM.
// GET /api/vms/{id}
func (c *Client) VMStatus(ctx context.Context, vmID string) (VMInfo, error) {
	var info VMInfo
	if err := c.do(ctx, http.MethodGet, "/api/vms/"+vmID, nil, &info); err != nil {
		return VMInfo{}, fmt.Errorf("vm status %s: %w", vmID, err)
	}
	return info, nil
}

// do performs an HTTP request, encoding reqBody as JSON (if non-nil) and
// decoding a JSON response into respBody (if non-nil). Non-2xx responses
// are returned as descriptive errors including the response body.
func (c *Client) do(ctx context.Context, method, path string, reqBody, respBody any) error {
	var bodyReader io.Reader
	if reqBody != nil {
		data, err := json.Marshal(reqBody)
		if err != nil {
			return fmt.Errorf("marshal request: %w", err)
		}
		bodyReader = bytes.NewReader(data)
	}

	req, err := http.NewRequestWithContext(ctx, method, c.base+path, bodyReader)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	if reqBody != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("http %s %s: %w", method, path, err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("read response body: %w", err)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("http %s %s returned %d: %s", method, path, resp.StatusCode, string(raw))
	}

	if respBody != nil && len(raw) > 0 {
		if err := json.Unmarshal(raw, respBody); err != nil {
			return fmt.Errorf("decode response: %w", err)
		}
	}

	return nil
}
