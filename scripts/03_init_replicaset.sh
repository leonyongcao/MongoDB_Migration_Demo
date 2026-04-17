#!/bin/bash
###############################################
# 副本集初始化 & 从节点加入脚本
# 模拟真实融合迁移流程:
#   阶段1: 初始化 AWS 副本集(仅主节点)
#   阶段2: 写入模拟业务数据
#   阶段3: 启动腾讯云从节点并加入副本集
###############################################

set -e

BASE_DIR="/data/workspace/MongoDB_Migration_Test"
RS_NAME="rs_migration"
HOSTNAME=$(hostname)

echo "=========================================="
echo "  副本集初始化 & 融合迁移模拟"
echo "=========================================="

# ============================================
# 阶段1: 初始化副本集（仅 AWS 主节点）
# ============================================
echo ""
echo "====== 阶段1: 初始化 AWS 副本集 ======"
echo "[INFO] 在 AWS 主节点(27017) 上初始化副本集..."

mongosh --port 27017 --quiet << 'INITEOF'
// 初始化副本集，只包含 AWS 主节点
var config = {
    _id: "rs_migration",
    members: [
        {
            _id: 0,
            host: "127.0.0.1:27017",
            priority: 10,
            tags: { dc: "aws", role: "primary" }
        }
    ]
};

var result = rs.initiate(config);
print("副本集初始化结果:", JSON.stringify(result));

// 等待主节点选举完成
print("等待主节点选举...");
sleep(5000);

// 确认状态
var status = rs.status();
print("当前副本集状态:");
status.members.forEach(function(m) {
    print("  " + m.name + " -> " + m.stateStr);
});
INITEOF

echo "  ✅ AWS 副本集初始化完成"
sleep 3

# ============================================
# 阶段2: 在 AWS 主节点写入模拟业务数据
# ============================================
echo ""
echo "====== 阶段2: 写入模拟业务数据 ======"
echo "[INFO] 向 AWS 主节点写入测试数据..."

mongosh --port 27017 --quiet << 'DATAEOF'
// 切换到测试数据库
use migration_test;

// 创建用户表
print("[INFO] 插入用户数据...");
var users = [];
for (var i = 1; i <= 10000; i++) {
    users.push({
        user_id: i,
        username: "user_" + i,
        email: "user_" + i + "@example.com",
        age: Math.floor(Math.random() * 60) + 18,
        region: ["北京", "上海", "广州", "深圳", "成都"][Math.floor(Math.random() * 5)],
        balance: Math.round(Math.random() * 100000) / 100,
        created_at: new Date(Date.now() - Math.floor(Math.random() * 365 * 24 * 3600 * 1000)),
        tags: ["vip", "normal", "premium"][Math.floor(Math.random() * 3)],
        status: "active"
    });
}
db.users.insertMany(users);
print("  ✅ 插入 " + db.users.countDocuments() + " 条用户数据");

// 创建订单表
print("[INFO] 插入订单数据...");
var orders = [];
for (var i = 1; i <= 50000; i++) {
    orders.push({
        order_id: "ORD-" + String(i).padStart(8, "0"),
        user_id: Math.floor(Math.random() * 10000) + 1,
        product: "产品_" + Math.floor(Math.random() * 100),
        amount: Math.round(Math.random() * 10000) / 100,
        status: ["pending", "paid", "shipped", "completed"][Math.floor(Math.random() * 4)],
        created_at: new Date(Date.now() - Math.floor(Math.random() * 90 * 24 * 3600 * 1000)),
        items: Math.floor(Math.random() * 10) + 1
    });
}
db.orders.insertMany(orders);
print("  ✅ 插入 " + db.orders.countDocuments() + " 条订单数据");

// 创建日志表
print("[INFO] 插入操作日志...");
var logs = [];
for (var i = 1; i <= 20000; i++) {
    logs.push({
        log_id: i,
        action: ["login", "logout", "purchase", "view", "search"][Math.floor(Math.random() * 5)],
        user_id: Math.floor(Math.random() * 10000) + 1,
        ip: Math.floor(Math.random() * 255) + "." + Math.floor(Math.random() * 255) + "." + Math.floor(Math.random() * 255) + "." + Math.floor(Math.random() * 255),
        timestamp: new Date(Date.now() - Math.floor(Math.random() * 30 * 24 * 3600 * 1000)),
        details: { browser: "Chrome", os: "Windows" }
    });
}
db.operation_logs.insertMany(logs);
print("  ✅ 插入 " + db.operation_logs.countDocuments() + " 条日志数据");

// 创建索引
print("[INFO] 创建索引...");
db.users.createIndex({ user_id: 1 }, { unique: true });
db.users.createIndex({ region: 1, age: 1 });
db.users.createIndex({ email: 1 });
db.orders.createIndex({ order_id: 1 }, { unique: true });
db.orders.createIndex({ user_id: 1, created_at: -1 });
db.orders.createIndex({ status: 1 });
db.operation_logs.createIndex({ user_id: 1, timestamp: -1 });
db.operation_logs.createIndex({ action: 1 });
print("  ✅ 索引创建完成");

// 统计数据量
print("");
print("=== AWS 主节点数据统计 ===");
print("  users:          " + db.users.countDocuments() + " 条");
print("  orders:         " + db.orders.countDocuments() + " 条");
print("  operation_logs: " + db.operation_logs.countDocuments() + " 条");
print("  总计:           " + (db.users.countDocuments() + db.orders.countDocuments() + db.operation_logs.countDocuments()) + " 条");
DATAEOF

echo "  ✅ 模拟业务数据写入完成"

# ============================================
# 阶段3: 启动腾讯云从节点并加入副本集
# ============================================
echo ""
echo "====== 阶段3: 腾讯云从节点加入副本集 ======"
echo "[INFO] 启动腾讯云从节点 (端口 27018)..."
mongod --config ${BASE_DIR}/config/tcloud_secondary.conf
sleep 3

# 验证启动
if mongosh --port 27018 --quiet --eval "db.runCommand({ping:1})" 2>/dev/null | grep -q '"ok"\|ok'; then
    echo "  ✅ 腾讯云从节点启动成功 (端口 27018)"
else
    echo "  ⚠️ 等待腾讯云从节点启动..."
    sleep 5
fi

echo ""
echo "[INFO] 将腾讯云从节点加入副本集..."
echo "[INFO] 这模拟了真实场景中将自建 MongoDB 加入 AWS 副本集的过程"

mongosh --port 27017 --quiet << 'ADDEOF'
// 将腾讯云从节点加入副本集
print("[INFO] 添加腾讯云从节点 127.0.0.1:27018 到副本集...");

var result = rs.add({
    host: "127.0.0.1:27018",
    priority: 0,        // 初始 priority=0，防止意外成为主节点
    votes: 0,           // 初始不参与投票
    tags: { dc: "tcloud", role: "secondary" }
});

print("添加结果:", JSON.stringify(result));

// 等待同步开始
print("[INFO] 等待数据同步...");
sleep(10000);

// 查看副本集状态
var status = rs.status();
print("");
print("=== 副本集状态 ===");
status.members.forEach(function(m) {
    print("  " + m.name + " -> " + m.stateStr + 
          " (health: " + m.health + 
          ", optime: " + (m.optimeDate ? m.optimeDate : "N/A") + ")");
});
ADDEOF

echo ""
echo "=========================================="
echo "  融合迁移模拟完成！"
echo "  AWS 主节点:     127.0.0.1:27017 (PRIMARY)"
echo "  腾讯云从节点:   127.0.0.1:27018 (SECONDARY)"
echo "=========================================="
echo ""
echo "下一步: 运行 04_verify_sync.sh 验证数据同步"
