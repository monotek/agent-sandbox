#!/usr/bin/env bash

set -e

if [ $# -eq 0 ]; then
    exec /bin/bash
fi

exec "$@"
