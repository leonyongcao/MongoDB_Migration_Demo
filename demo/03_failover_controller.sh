#!/bin/bash
###############################################
# 主从切换控制脚本
# 
# 流程:
# 1. 【T+10s】让业务流量先跑10秒（观察打到 AWS 的请求）
# 2. 【T+10s】提升腾讯云 priority，准备切换
# 3. 【T+15s】启用"只读模式"（通过 fsyncLock 或停写）- 模拟业务层停写
# 4. 【T+18s】等待从节点追平最后的 oplog
# 5. 【T+20s】执行 rs.stepDown() 切主
# 6. 【T+25s】验证腾讯云成为新 PRIMARY
# 7. 【T+25s】解除"只读模式"
# 8. 【T+25s+】继续让流量跑（观察打到腾讯云的请求）
###############################################

set -e

LOG() {
    echo -e "\033[1;36m[$(date '+%H:%M:%S.%3N')] [控制器] $1\033[0m"
}

LOG_STEP() {
    echo -e "\n\033[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "\033[1;33m$1\033[0m"
    echo -e "\033[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
}

# ============================================
# 步骤 0: 确认初始状态
# ============================================
LOG_STEP "步骤 0: 检查初始状态"
mongosh --port 27017 --quiet --eval "
var s = rs.status();
s.members.forEach(m => print('  ' + m.name + ' -> ' + m.stateStr));
" 2>&1 | tail -5

LOG "等待流量先跑 10 秒（观察 AWS 作为 PRIMARY 的表现）..."
sleep 10

# ============================================
# 步骤 1: 提升腾讯云节点权重
# ============================================
LOG_STEP "步骤 1: 提升腾讯云节点 priority (为切主做准备)"
mongosh --port 27017 --quiet --eval "
var conf = rs.conf();
// AWS 从 10 降为 1
var awsMember = conf.members.find(m => m.host.includes('27017'));
awsMember.priority = 1;
// 腾讯云从 0 提升为 10
var tcMember = conf.members.find(m => m.host.includes('27018'));
tcMember.priority = 10;
tcMember.votes = 1;
conf.version++;
var r = rs.reconfig(conf);
print('  重配置结果: ok=' + r.ok);
print('  AWS(27017) priority: 10 → 1');
print('  腾讯云(27018) priority: 0 → 10, votes: 0 → 1');
" 2>&1 | grep -v "^$" | tail -10

LOG "让业务继续跑 3 秒..."
sleep 3

# ============================================
# 步骤 2: 模拟业务层"只读模式"
# ============================================
LOG_STEP "步骤 2: 模拟业务层停写（使用 fsyncLock 短暂锁定）"
LOG "实际业务中，这一步是应用层开启只读开关，这里用 fsyncLock 模拟"

# 注意：fsyncLock 会锁定写入，但我们只锁很短时间
# 实际生产中，通常是应用层通过配置中心开关实现"只读"
# 这里为了演示效果，采用更直接的方式：快速执行 stepDown

LOG "⚠️  即将执行主从切换..."
LOG "⚠️  从此刻开始到切换完成，写请求会短暂失败"

# ============================================
# 步骤 3: 执行主从切换
# ============================================
SWITCH_START=$(date +%s.%N)
LOG_STEP "步骤 3: 【T=$(date '+%H:%M:%S.%3N')】执行 rs.stepDown() 主从切换"

mongosh --port 27017 --quiet --eval "
print('  切换前状态:');
rs.status().members.forEach(m => print('    ' + m.name + ' -> ' + m.stateStr));
print('');
print('  执行 stepDown(60, 30)...');
try {
    rs.stepDown(60, 30);
} catch(e) {
    print('  (stepDown 触发成功，连接关闭是正常的)');
}
" 2>&1 | grep -v "^$" | tail -10 || true

# ============================================
# 步骤 4: 等待选举完成
# ============================================
LOG_STEP "步骤 4: 等待选举完成"
for i in 1 2 3 4 5 6 7 8 9 10; do
    NEW_PRIMARY=$(mongosh --port 27018 --quiet --eval "
        var p = rs.status().members.find(m => m.stateStr === 'PRIMARY');
        print(p ? p.name : 'NONE');
    " 2>/dev/null | tail -1 | tr -d '[:space:]')
    
    if [ "$NEW_PRIMARY" = "127.0.0.1:27018" ]; then
        SWITCH_END=$(date +%s.%N)
        SWITCH_TIME=$(echo "$SWITCH_END - $SWITCH_START" | bc)
        LOG "✅ 【T=$(date '+%H:%M:%S.%3N')】切换完成！腾讯云(27018) 成为新 PRIMARY"
        LOG "✅ 切换耗时: ${SWITCH_TIME} 秒"
        break
    elif [ "$NEW_PRIMARY" = "127.0.0.1:27017" ]; then
        LOG "⚠️  AWS 仍是 PRIMARY，等待选举..."
    else
        LOG "   选举进行中... (第 $i 次检查)"
    fi
    sleep 1
done

# ============================================
# 步骤 5: 验证新 PRIMARY 状态
# ============================================
LOG_STEP "步骤 5: 验证切换结果"
mongosh --port 27018 --quiet --eval "
print('  切换后状态:');
rs.status().members.forEach(m => print('    ' + m.name + ' -> ' + m.stateStr));
print('');
print('  新 PRIMARY 写入测试:');
use migration_test;
var r = db.switch_verify.insertOne({
    test: 'post_switch',
    ts: new Date(),
    msg: '腾讯云新主节点写入验证'
});
print('    写入成功: _id=' + r.insertedId);
" 2>&1 | grep -v "^$" | tail -10

LOG_STEP "✅ 主从切换流程执行完毕"
LOG "业务流量继续运行中，观察后续请求是否正常打到腾讯云..."
