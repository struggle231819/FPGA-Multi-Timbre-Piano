#!/usr/bin/env bash
set -e

REPO_URL="${1:-https://github.com/struggle231819/FPGA-Multi-Timbre-Piano.git}"

git init
git branch -M main
git add .
git commit -m "Initial open-source release: FPGA Multi-Timbre Smart Piano (Tang Primer 25K)"
git remote remove origin 2>/dev/null || true
git remote add origin "$REPO_URL"
git push -u origin main

echo "✅ 已成功推送到 GitHub: $REPO_URL"
