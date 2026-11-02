#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
exec elixir docs/spikes/fence-channel/spike.exs
