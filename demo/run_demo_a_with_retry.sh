#!/bin/bash
###############################################
# 一键运行切换 Demo
# 
# 运行方式:
#   bash run_demo.sh
#
# 流程:
# 1. 后台启动业务流量模拟器（持续 60 秒读写）
# 2. 等待 10 秒，让流量稳定
# 3. 执行主从切换控制脚本
# 4. 继续观察流量 20 秒
# 5. 停止所有进程，输出报告
###############################################

set -e

DEMO_DIR="/data/workspace/MongoDB_Migration_Test/demo"
RESULTS_DIR="/data/workspace/MongoDB_Migration_Test/results"
mkdir -p ${RESULTS_DIR}
cd ${DEMO_DIR}

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TRAFFIC_LOG="${RESULTS_DIR}/traffic_${TIMESTAMP}.log"
SWITCH_LOG="${RESULTS_DIR}/switch_${TIMESTAMP}.log"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  MongoDB 融合迁移 - 流量切换 Demo                               ║"
echo "║                                                                ║"
echo "║  场景: 请求先打到 AWS(27017), 切主后自动打到腾讯云(27018)       ║"
echo "║  验证: 切换过程中业务影响、切换耗时、数据一致性                   ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "日志文件:"
echo "  流量日志: ${TRAFFIC_LOG}"
echo "  切换日志: ${SWITCH_LOG}"
echo ""

# ============================================
# 启动业务流量模拟器（后台）
# ============================================
echo "▶ 启动业务流量模拟器（3 workers, 持续 60 秒）..."
python3 ${DEMO_DIR}/01_traffic_with_retry.py 3 60 > ${TRAFFIC_LOG} 2>&1 &
TRAFFIC_PID=$!
echo "  流量模拟器 PID: ${TRAFFIC_PID}"
echo ""

# 给模拟器 2 秒启动时间
sleep 2

# ============================================
# 启动切换控制脚本
# ============================================
bash ${DEMO_DIR}/03_failover_controller.sh 2>&1 | tee ${SWITCH_LOG}

# ============================================
# 等待流量模拟器继续运行，观察切换后表现
# ============================================
echo ""
echo "▶ 切换完成，继续让流量跑 20 秒观察稳定性..."
sleep 25

# ============================================
# 停止流量模拟器
# ============================================
if kill -0 ${TRAFFIC_PID} 2>/dev/null; then
    kill -INT ${TRAFFIC_PID} 2>/dev/null || true
    wait ${TRAFFIC_PID} 2>/dev/null || true
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  Demo 执行完毕！                                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "▼ 业务流量日志 (最后 80 行):"
echo "────────────────────────────────────────────────────────────────"
tail -80 ${TRAFFIC_LOG}
echo "────────────────────────────────────────────────────────────────"
echo ""
echo "完整日志见: ${TRAFFIC_LOG}"
