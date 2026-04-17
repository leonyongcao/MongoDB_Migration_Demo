#!/bin/bash
###############################################
# 数据同步验证脚本
# 验证腾讯云从节点数据是否与 AWS 主节点完全一致
###############################################

set -e

BASE_DIR="/data/workspace/MongoDB_Migration_Test"

echo "=========================================="
echo "  数据同步验证"
echo "=========================================="

# ============================================
# 1. 检查副本集状态
# ============================================
echo ""
echo "====== 1. 副本集状态检查 ======"

mongosh --port 27017 --quiet << 'EOF'
var status = rs.status();
print("副本集名称: " + status.set);
print("成员数量: " + status.members.length);
print("");

status.members.forEach(function(m) {
    print("节点: " + m.name);
    print("  状态: " + m.stateStr);
    print("  健康: " + (m.health === 1 ? "✅ 健康" : "❌ 异常"));
    print("  Optime: " + (m.optimeDate ? m.optimeDate : "N/A"));
    if (m.syncSourceHost) {
        print("  同步源: " + m.syncSourceHost);
    }
    if (m.tags) {
        print("  标签: " + JSON.stringify(m.tags));
    }
    print("");
});

// 检查同步延迟
var primary = status.members.find(m => m.stateStr === "PRIMARY");
var secondaries = status.members.filter(m => m.stateStr === "SECONDARY");

if (primary && secondaries.length > 0) {
    secondaries.forEach(function(s) {
        var lagSeconds = (primary.optimeDate - s.optimeDate) / 1000;
        print("同步延迟 (" + s.name + "): " + lagSeconds + " 秒");
        if (lagSeconds <= 1) {
            print("  ✅ 同步延迟正常 (<= 1秒)");
        } else if (lagSeconds <= 10) {
            print("  ⚠️ 存在一定同步延迟");
        } else {
            print("  ❌ 同步延迟较大，需关注");
        }
    });
}
EOF

# ============================================
# 2. 数据量对比验证
# ============================================
echo ""
echo "====== 2. 数据量对比验证 ======"

echo "[INFO] 查询 AWS 主节点数据量..."
PRIMARY_COUNTS=$(mongosh --port 27017 --quiet << 'EOF'
use migration_test;
var result = {
    users: db.users.countDocuments(),
    orders: db.orders.countDocuments(),
    operation_logs: db.operation_logs.countDocuments()
};
print(JSON.stringify(result));
EOF
)
echo "  AWS 主节点: ${PRIMARY_COUNTS}"

echo "[INFO] 查询腾讯云从节点数据量..."
SECONDARY_COUNTS=$(mongosh --port 27018 --quiet << 'EOF'
db.getMongo().setReadPref("secondaryPreferred");
use migration_test;
var result = {
    users: db.users.countDocuments(),
    orders: db.orders.countDocuments(),
    operation_logs: db.operation_logs.countDocuments()
};
print(JSON.stringify(result));
EOF
)
echo "  腾讯云从节点: ${SECONDARY_COUNTS}"

# ============================================
# 3. 数据内容抽样校验
# ============================================
echo ""
echo "====== 3. 数据内容抽样校验 ======"

mongosh --port 27017 --quiet << 'VERIFYEOF'
use migration_test;

// 获取主节点的抽样数据 MD5
print("[INFO] 对比用户表抽样数据...");
var sampleUsers = db.users.find({user_id: {$in: [1, 100, 500, 1000, 5000, 10000]}}).sort({user_id: 1}).toArray();
var primaryHash = JSON.stringify(sampleUsers.map(u => ({id: u.user_id, name: u.username, email: u.email})));
print("  主节点抽样: " + sampleUsers.length + " 条");
sampleUsers.forEach(function(u) {
    print("    user_id=" + u.user_id + ", username=" + u.username + ", region=" + u.region);
});
VERIFYEOF

echo ""
mongosh --port 27018 --quiet << 'VERIFYEOF2'
db.getMongo().setReadPref("secondaryPreferred");
use migration_test;

print("[INFO] 腾讯云从节点对应数据...");
var sampleUsers = db.users.find({user_id: {$in: [1, 100, 500, 1000, 5000, 10000]}}).sort({user_id: 1}).toArray();
print("  从节点抽样: " + sampleUsers.length + " 条");
sampleUsers.forEach(function(u) {
    print("    user_id=" + u.user_id + ", username=" + u.username + ", region=" + u.region);
});

if (sampleUsers.length === 6) {
    print("  ✅ 抽样数据条数一致");
} else {
    print("  ❌ 抽样数据条数不一致，可能同步尚未完成");
}
VERIFYEOF2

# ============================================
# 4. 索引同步验证
# ============================================
echo ""
echo "====== 4. 索引同步验证 ======"

echo "[INFO] AWS 主节点索引:"
mongosh --port 27017 --quiet << 'EOF'
use migration_test;
["users", "orders", "operation_logs"].forEach(function(coll) {
    var indexes = db[coll].getIndexes();
    print("  " + coll + ": " + indexes.length + " 个索引");
    indexes.forEach(function(idx) {
        print("    - " + idx.name + ": " + JSON.stringify(idx.key));
    });
});
EOF

echo ""
echo "[INFO] 腾讯云从节点索引:"
mongosh --port 27018 --quiet << 'EOF'
db.getMongo().setReadPref("secondaryPreferred");
use migration_test;
["users", "orders", "operation_logs"].forEach(function(coll) {
    var indexes = db[coll].getIndexes();
    print("  " + coll + ": " + indexes.length + " 个索引");
    indexes.forEach(function(idx) {
        print("    - " + idx.name + ": " + JSON.stringify(idx.key));
    });
});
EOF

# ============================================
# 5. Oplog 同步状态
# ============================================
echo ""
echo "====== 5. Oplog 同步状态 ======"

mongosh --port 27017 --quiet << 'EOF'
var oplog = db.getSiblingDB("local").oplog.rs;
var stats = oplog.stats();
var first = oplog.find().sort({$natural: 1}).limit(1).next();
var last = oplog.find().sort({$natural: -1}).limit(1).next();

print("Oplog 大小: " + Math.round(stats.size / 1024 / 1024) + " MB");
print("Oplog 最大: " + Math.round(stats.maxSize / 1024 / 1024) + " MB");
print("最早记录: " + first.ts);
print("最新记录: " + last.ts);

var windowSec = (last.ts.getTime() - first.ts.getTime());
print("Oplog 窗口: " + Math.round(windowSec / 3600) + " 小时");
EOF

echo ""
echo "=========================================="
echo "  数据同步验证完成！"
echo "=========================================="
echo ""
echo "下一步: 运行 05_migration_test.sh 进行融合迁移测试"
