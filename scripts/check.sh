#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check_public.py
python3 scripts/test_parsing.py
bash build_app.sh
codesign --verify --deep --strict build/CodexUsageBarTotal.app
