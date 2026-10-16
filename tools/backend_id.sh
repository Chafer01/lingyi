#!/usr/bin/env bash
# 后端构建编号：由后端源码、依赖和打包配置的 git 树哈希决定。内容不变时编号不变，
# 灵译自动更新时据此判断要不要重新下载约 700 MB 的后端。
set -e
cd "$(dirname "$0")/.."
{
  git rev-parse HEAD:backend/lingyi_backend
  git rev-parse HEAD:backend/requirements.txt
  git rev-parse HEAD:backend/requirements-nodeps.txt
  git rev-parse HEAD:backend/lingyi_backend.spec
} | sha256sum | cut -c1-16
