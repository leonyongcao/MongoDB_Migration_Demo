#!/bin/bash
###############################################
# 对照组 Demo - 关闭 driver retry
# 目的: 展示切换瞬间的真实失败窗口
###############################################

set -e

DEMO_DIR="/data/workspace/MongoDB_Migration_Test/demo"
RESULTS_DIR="/data/workspace/MongoDB_Migration_Test/results"
mkdir -p ${RESULTS_DIR}
cd ${DEMO_DIR}

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TRAFFIC_LOG="${RESULTS_DIR}/traffic_noretry_${TIMESTAMP}.log"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  对照组: 关闭 retryWrites 的切换影响测试                        ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# 启动流量
python3 ${DEMO_DIR}/02_traffic_without_retry.py 3 40 > ${TRAFFIC_LOG} 2>&1 &
TRAFFIC_PID=$!
echo "流量模拟器 PID: ${TRAFFIC_PID}"
sleep 2

# 等待 10 秒
echo "流量跑 10 秒（应都打到 AWS）..."
sleep 10

# 提升腾讯云 priority
echo "提升腾讯云 priority..."
mongosh --port 27017 --quiet --eval "
var conf = rs.conf();
conf.members.forEach(m => {
    if (m.host.includes('27017')) m.priority = 1;
    if (m.host.includes('27018')) { m.priority = 10; m.votes = 1; }
});
conf.version++;
rs.reconfig(conf);
print('  priority 调整完成');
" 2>&1 | tail -3

sleep 2

# 执行切换
SWITCH_TIME=$(date '+%H:%M:%S.%3N')
echo "═══ [T=${SWITCH_TIME}] 执行 rs.stepDown() ═══"
mongosh --port 27017 --quiet --eval "
try { rs.stepDown(60, 30); } catch(e) {}
" 2>&1 > /dev/null

echo "等待切换完成..."
sleep 15

# 停止流量
kill -INT ${TRAFFIC_PID} 2>/dev/null || true
wait ${TRAFFIC_PID} 2>/dev/null || true

echo ""
echo "════════════════ 测试日志 ════════════════"
cat ${TRAFFIC_LOG}
echo ""
echo "日志: ${TRAFFIC_LOG}"
