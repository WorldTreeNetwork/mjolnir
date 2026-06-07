// forgejo-runner-mjolnir is a Forgejo Actions runner that executes CI jobs
// inside Mjolnir microVMs instead of Docker containers.
//
// It wraps the upstream forgejo-runner, replacing the container backend with
// VMEnvironment which routes execution through the Mjolnir HTTP API.
//
// Usage:
//
//	forgejo-runner-mjolnir daemon --config /path/to/config.yaml
//
// Environment variables:
//
//	MJOLNIR_API_BASE  - Mjolnir API URL (default: http://127.0.0.1:4000)
//	MJOLNIR_VM_IMAGE  - Base VM image name (default: ci-ubuntu-24.04)
package main

import (
	"fmt"
	"os"
)

func main() {
	// TODO: Wire into the forgejo-runner's main entry point with our
	// VMEnvironment as the container backend. For now, print usage.
	//
	// The integration requires one of:
	// 1. The upstream runner exposes a ContainerFactory hook
	// 2. We patch the runner's run.go to accept a custom backend
	// 3. We vendor the runner and modify container creation in-tree
	//
	// Until then, the stock forgejo-runner runs in host mode and the
	// VMEnvironment implementation is available for integration.

	apiBase := os.Getenv("MJOLNIR_API_BASE")
	if apiBase == "" {
		apiBase = "http://127.0.0.1:4000"
	}

	fmt.Printf("forgejo-runner-mjolnir\n")
	fmt.Printf("  Mjolnir API: %s\n", apiBase)
	fmt.Printf("  VM Image:    %s\n", getEnvOr("MJOLNIR_VM_IMAGE", "ci-ubuntu-24.04"))
	fmt.Printf("\nThis binary is a stub. The VMEnvironment implementation\n")
	fmt.Printf("is at pkg/mjolnir/executor.go, ready for integration with\n")
	fmt.Printf("the forgejo-runner's container backend.\n")
	fmt.Printf("\nTo use now: run the stock forgejo-runner in host mode.\n")
}

func getEnvOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
