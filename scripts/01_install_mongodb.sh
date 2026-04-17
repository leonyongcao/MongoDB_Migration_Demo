#!/bin/bash
###############################################
# MongoDB 安装脚本 (TencentOS / CentOS / RHEL)
# 安装 MongoDB 7.0 社区版
###############################################

set -e

echo "=========================================="
echo "  MongoDB 7.0 安装脚本"
echo "=========================================="

# 检查是否已安装
if command -v mongod &> /dev/null; then
    echo "[INFO] MongoDB 已安装:"
    mongod --version | head -1
    echo "[INFO] 跳过安装步骤"
    exit 0
fi

# 配置 MongoDB 官方 yum 源
echo "[INFO] 配置 MongoDB 7.0 yum 源..."
cat > /etc/yum.repos.d/mongodb-org-7.0.repo << 'EOF'
[mongodb-org-7.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/9/mongodb-org/7.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-7.0.asc
EOF

# 安装 MongoDB
echo "[INFO] 安装 MongoDB 7.0..."
yum install -y mongodb-org

# 验证安装
echo "[INFO] 验证安装..."
mongod --version
mongosh --version

echo "=========================================="
echo "  MongoDB 7.0 安装完成！"
echo "=========================================="
