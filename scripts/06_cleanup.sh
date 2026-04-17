#!/bin/bash
###############################################
# 清理脚本 - 停止所有 MongoDB 实例并清理数据
###############################################

BASE_DIR="/data/workspace/MongoDB_Migration_Test"

echo "=========================================="
echo "  清理 MongoDB 测试实例"
echo "=========================================="

echo "[INFO] 停止端口 27017 实例..."
mongod --shutdown --dbpath ${BASE_DIR}/data/aws_primary 2>/dev/null && echo "  ✅ 已停止" || echo "  (未运行)"

echo "[INFO] 停止端口 27018 实例..."
mongod --shutdown --dbpath ${BASE_DIR}/data/tcloud_secondary 2>/dev/null && echo "  ✅ 已停止" || echo "  (未运行)"

echo ""
read -p "是否清理数据目录? (y/N): " confirm
if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    rm -rf ${BASE_DIR}/data/aws_primary
    rm -rf ${BASE_DIR}/data/tcloud_secondary
    rm -rf ${BASE_DIR}/logs/*.log
    echo "  ✅ 数据目录已清理"
else
    echo "  保留数据目录"
fi

echo ""
echo "清理完成！"
