#!/usr/bin/env bash
set -euo pipefail

echo "Installing dependencies..."
pip install --user sounddevice soundfile numpy
echo "Dependencies installed."
