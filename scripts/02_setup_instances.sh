#!/bin/bash
###############################################
# 双 MongoDB 实例部署脚本
# 模拟: AWS 主节点 (端口 27017) + 腾讯云从节点 (端口 27018)
# 副本集名称: rs_migration
###############################################

set -e

BASE_DIR="/data/workspace/MongoDB_Migration_Test"
RS_NAME="rs_migration"
KEYFILE="${BASE_DIR}/config/rs_keyfile"

echo "=========================================="
echo "  MongoDB 双实例部署"
echo "  模拟 AWS(27017) + 腾讯云(27018)"
echo "=========================================="

# ============================================
# 1. 停止已有实例（如果存在）
# ============================================
echo ""
echo "[步骤1] 清理已有实例..."
mongod --shutdown --dbpath ${BASE_DIR}/data/aws_primary 2>/dev/null || true
mongod --shutdown --dbpath ${BASE_DIR}/data/tcloud_secondary 2>/dev/null || true
sleep 2

# ============================================
# 2. 创建数据和日志目录
# ============================================
echo "[步骤2] 创建数据和日志目录..."
mkdir -p ${BASE_DIR}/data/aws_primary
mkdir -p ${BASE_DIR}/data/tcloud_secondary
mkdir -p ${BASE_DIR}/logs

# ============================================
# 3. 生成副本集认证 keyfile
# ============================================
echo "[步骤3] 生成副本集认证 keyfile..."
if [ ! -f "${KEYFILE}" ]; then
    openssl rand -base64 756 > ${KEYFILE}
fi
chmod 400 ${KEYFILE}

# ============================================
# 4. 创建配置文件
# ============================================
echo "[步骤4] 创建配置文件..."

# AWS 主节点配置 (端口 27017)
cat > ${BASE_DIR}/config/aws_primary.conf << EOF
# AWS 主节点配置
systemLog:
  destination: file
  path: ${BASE_DIR}/logs/aws_primary.log
  logAppend: true

storage:
  dbPath: ${BASE_DIR}/data/aws_primary
  wiredTiger:
    engineConfig:
      cacheSizeGB: 0.5

net:
  port: 27017
  bindIp: 0.0.0.0

replication:
  replSetName: ${RS_NAME}
  oplogSizeMB: 512

security:
  keyFile: ${KEYFILE}

processManagement:
  fork: true
  pidFilePath: ${BASE_DIR}/data/aws_primary/mongod.pid
EOF

# 腾讯云从节点配置 (端口 27018)
cat > ${BASE_DIR}/config/tcloud_secondary.conf << EOF
# 腾讯云从节点配置
systemLog:
  destination: file
  path: ${BASE_DIR}/logs/tcloud_secondary.log
  logAppend: true

storage:
  dbPath: ${BASE_DIR}/data/tcloud_secondary
  wiredTiger:
    engineConfig:
      cacheSizeGB: 0.5

net:
  port: 27018
  bindIp: 0.0.0.0

replication:
  replSetName: ${RS_NAME}
  oplogSizeMB: 512

security:
  keyFile: ${KEYFILE}

processManagement:
  fork: true
  pidFilePath: ${BASE_DIR}/data/tcloud_secondary/mongod.pid
EOF

echo "  - aws_primary.conf    -> 端口 27017"
echo "  - tcloud_secondary.conf -> 端口 27018"

# ============================================
# 5. 启动 AWS 主节点 (端口 27017)
# ============================================
echo ""
echo "[步骤5] 启动 AWS 主节点 (端口 27017)..."
mongod --config ${BASE_DIR}/config/aws_primary.conf
sleep 3

# 验证启动
if mongosh --port 27017 --quiet --eval "db.runCommand({ping:1})" 2>/dev/null | grep -q '"ok" : 1\|"ok":1\|ok: 1'; then
    echo "  ✅ AWS 主节点启动成功 (端口 27017)"
else
    echo "  ⚠️ AWS 主节点可能未完全启动，等待中..."
    sleep 3
fi

echo ""
echo "=========================================="
echo "  双实例部署完成！"
echo "  AWS 主节点:     localhost:27017"
echo "  腾讯云从节点配置已就绪（暂未启动）"
echo "=========================================="
echo ""
echo "下一步: 运行 03_init_replicaset.sh 初始化副本集"
