#!/usr/bin/env bash
# one-time setup for the warmer command.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/warmer.sh" setup
