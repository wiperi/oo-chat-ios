#!/usr/bin/env bash

set -euo pipefail

readonly ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${ROOT}/scripts/setup.sh"
