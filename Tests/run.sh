#!/bin/bash
# 回归测试：把纯逻辑文件（Models / Checkers / Scanner）和测试入口单独编一个可执行跑一遍。
# 不编进正式 App，只验证 cleanVersion / 假收据识别 / cask 映射提取这些修过 bug 的地方。
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
swiftc -o build/ur_tests \
    src/Models.swift src/Version.swift src/Checkers.swift src/Scanner.swift Tests/main.swift
./build/ur_tests
