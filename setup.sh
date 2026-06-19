#!/usr/bin/env bash
# one-time bootstrap: run this once, then `warmer` works everywhere.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/warmer.sh" setup
