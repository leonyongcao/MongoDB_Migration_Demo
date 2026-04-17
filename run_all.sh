#!/bin/bash
###############################################
# MongoDB 融合迁移一键测试脚本
# 按顺序执行所有测试步骤
###############################################

set -e

BASE_DIR="/data/workspace/MongoDB_Migration_Test"
cd ${BASE_DIR}

echo "╔════════════════════════════════════════╗"
echo "║  MongoDB 融合迁移测试 - 一键执行       ║"
echo "║  模拟 AWS -> 腾讯云 迁移流程           ║"
echo "╚════════════════════════════════════════╝"
echo ""

# 步骤1: 安装 MongoDB
echo "━━━━━━━━━━ 步骤 1/5: 安装 MongoDB ━━━━━━━━━━"
bash scripts/01_install_mongodb.sh
echo ""

# 步骤2: 部署双实例
echo "━━━━━━━━━━ 步骤 2/5: 部署双实例 ━━━━━━━━━━"
bash scripts/02_setup_instances.sh
echo ""

# 步骤3: 初始化副本集 + 写入数据 + 从节点加入
echo "━━━━━━━━━━ 步骤 3/5: 初始化副本集 ━━━━━━━━━━"
bash scripts/03_init_replicaset.sh
echo ""

# 步骤4: 验证数据同步
echo "━━━━━━━━━━ 步骤 4/5: 验证数据同步 ━━━━━━━━━━"
bash scripts/04_verify_sync.sh
echo ""

# 步骤5: 完整迁移测试
echo "━━━━━━━━━━ 步骤 5/5: 融合迁移测试 ━━━━━━━━━━"
bash scripts/05_migration_test.sh
echo ""

echo "╔════════════════════════════════════════╗"
echo "║  全部测试完成！                        ║"
echo "║  结果保存在: results/ 目录             ║"
echo "║  清理请运行: bash scripts/06_cleanup.sh║"
echo "╚════════════════════════════════════════╝"
