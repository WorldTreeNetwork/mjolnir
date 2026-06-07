#!/usr/bin/env python3
"""Patch the forgejo-runner labels.go to add the 'mjolnir' schema.

This adds SchemeMjolnir alongside SchemeHost/SchemeDocker/SchemeLXC,
allowing labels like: ubuntu-24.04:mjolnir:ci-ubuntu-24.04
"""

path = "/opt/forgejo-runner-build/internal/pkg/labels/labels.go"

with open(path) as f:
    code = f.read()

if "SchemeMjolnir" in code:
    print("Already patched")
    exit(0)

# 1. Add constant
code = code.replace(
    'SchemeLXC = "lxc"',
    'SchemeLXC = "lxc"\n\tSchemeMjolnir = "mjolnir"'
)

# 2. Add to schema validation in Parse()
code = code.replace(
    "label.Schema != SchemeLXC {",
    "label.Schema != SchemeLXC && label.Schema != SchemeMjolnir {"
)

# 3. Add default arg in Parse()
code = code.replace(
    "case SchemeLXC:\n\t\t\tlabel.Arg = ArgLXC",
    'case SchemeLXC:\n\t\t\tlabel.Arg = ArgLXC\n\t\tcase SchemeMjolnir:\n\t\t\tlabel.Arg = "ci-ubuntu-24.04"'
)

# 4. Add to PickPlatform()
code = code.replace(
    'case SchemeLXC:\n\t\t\tplatforms[label.Name] = "lxc:" + strings.TrimPrefix(label.Arg, "//")',
    'case SchemeLXC:\n\t\t\tplatforms[label.Name] = "lxc:" + strings.TrimPrefix(label.Arg, "//")\n\t\tcase SchemeMjolnir:\n\t\t\tplatforms[label.Name] = "mjolnir:" + strings.TrimPrefix(label.Arg, "//")'
)

with open(path, "w") as f:
    f.write(code)

print("OK: patched labels.go with SchemeMjolnir")
