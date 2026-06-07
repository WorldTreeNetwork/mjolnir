// Package mjolnir implements the Forgejo Actions executor backend
// that runs CI jobs inside Mjolnir microVMs instead of Docker containers.
package mjolnir

// This file will implement the act ContainerExecutor interface.
// The executor lifecycle per job:
//
//  1. SpawnVM  — POST /api/vms (with base image + extra virtio-fs mounts)
//  2. ExecStep — POST /api/vms/:id/exec (per workflow step)
//  3. Teardown — DELETE /api/vms/:id

// Executor talks to the Mjolnir HTTP API on localhost.
type Executor struct {
	APIBase string // e.g. "http://127.0.0.1:4000"
	VMID    string // populated after spawn
}
