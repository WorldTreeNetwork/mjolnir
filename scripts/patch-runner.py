#!/usr/bin/env python3
"""Patch the forgejo-runner to add Mjolnir VM backend support."""

import sys

path = "/opt/forgejo-runner-build/act/runner/run_context.go"

with open(path, "r") as f:
    code = f.read()

# 1. Add import for mjolnir package (after the model import)
old_import = '"code.forgejo.org/forgejo/runner/v12/act/model"'
new_import = old_import + '\n\t"code.forgejo.org/forgejo/runner/v12/act/container/mjolnir"'
code = code.replace(old_import, new_import, 1)

# 2. Extend IsHostEnv to include Mjolnir
code = code.replace(
    "return rc.IsBareHostEnv(ctx) || rc.IsLXCHostEnv(ctx)",
    "return rc.IsBareHostEnv(ctx) || rc.IsLXCHostEnv(ctx) || rc.IsMjolnirEnv(ctx)"
)

# 3. Patch startContainer to check Mjolnir before host
old_start = 'if rc.IsHostEnv(ctx) {\n\t\t\treturn rc.startHostEnvironment()(ctx)\n\t\t}'
new_start = 'if rc.IsMjolnirEnv(ctx) {\n\t\t\treturn rc.startMjolnirEnvironment()(ctx)\n\t\t}\n\t\tif rc.IsHostEnv(ctx) {\n\t\t\treturn rc.startHostEnvironment()(ctx)\n\t\t}'
code = code.replace(old_start, new_start, 1)

# 4. Add Mjolnir methods before stopContainer
mjolnir_methods = '''
const mjolnirPrefix = "mjolnir:"

func (rc *RunContext) IsMjolnirEnv(ctx context.Context) bool {
	platform := rc.runsOnImage(ctx)
	return strings.HasPrefix(platform, mjolnirPrefix)
}

func (rc *RunContext) getMjolnirImage(ctx context.Context) string {
	return strings.TrimPrefix(rc.runsOnImage(ctx), mjolnirPrefix)
}

func (rc *RunContext) startMjolnirEnvironment() common.Executor {
	return func(ctx context.Context) error {
		logger := common.Logger(ctx)
		rawLogger := logger.WithField("raw_output", true)
		logWriter := common.NewLineWriter(rc.commandHandler(ctx), func(s string) bool {
			if rc.Config.LogOutput {
				rawLogger.Infof("%s", s)
			} else {
				rawLogger.Debugf("%s", s)
			}
			return true
		})

		baseImage := rc.getMjolnirImage(ctx)
		apiBase := os.Getenv("MJOLNIR_API_BASE")
		if apiBase == "" {
			apiBase = "http://127.0.0.1:4000"
		}

		logger.Infof("Starting Mjolnir VM (image: %s, api: %s)", baseImage, apiBase)

		randName := common.MustRandName(8)
		vm := mjolnir.NewVMEnvironment(apiBase, mjolnir.SpawnConfig{
			BaseImage: baseImage,
		}, randName)
		vm.ReplaceLogWriter(logWriter, logWriter)

		rc.JobContainer = vm
		rc.cleanUpJobContainer = func(ctx context.Context) error {
			return vm.Remove()(ctx)
		}
		for k, v := range vm.GetRunnerContext(ctx) {
			if v, ok := v.(string); ok {
				rc.Env[fmt.Sprintf("RUNNER_%s", strings.ToUpper(k))] = v
			}
		}
		return vm.Create(nil, nil)(ctx)
	}
}

'''

code = code.replace(
    'func (rc *RunContext) stopContainer()',
    mjolnir_methods + 'func (rc *RunContext) stopContainer()'
)

with open(path, "w") as f:
    f.write(code)

print("OK: patched run_context.go")
