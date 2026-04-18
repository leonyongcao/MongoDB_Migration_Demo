#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
模拟业务应用 - 持续读写 MongoDB 副本集
用于验证融合迁移切换过程中的业务影响

关键特性:
1. 使用副本集连接串，自动发现 PRIMARY
2. 启用 retryWrites 自动重试机制
3. 每个请求记录:
   - 连接到哪个节点 (AWS 27017 / 腾讯云 27018)
   - 请求耗时
   - 成功/失败状态
   - 错误类型
4. 实时输出，便于观察切换过程
"""
import sys
import time
import threading
import json
from datetime import datetime
from pymongo import MongoClient, ReadPreference
from pymongo.errors import (
    AutoReconnect, NotPrimaryError, ServerSelectionTimeoutError,
    ConnectionFailure, NetworkTimeout, OperationFailure
)

# 副本集连接串（包含所有节点，driver 自动发现 PRIMARY）
MONGO_URI = (
    "mongodb://127.0.0.1:27017,127.0.0.1:27018/"
    "?replicaSet=rs_migration"
    "&retryWrites=true"
    "&retryReads=true"
    "&serverSelectionTimeoutMS=5000"
    "&socketTimeoutMS=3000"
    "&w=majority"
)

# 统计信息
stats = {
    "total": 0,
    "success": 0,
    "failed": 0,
    "primary_nodes": {},    # 记录主节点变化: {"27017": count, "27018": count}
    "errors": {},           # 记录错误类型: {"NotPrimaryError": count}
    "events": [],           # 关键事件时间线
    "latencies": [],        # 响应延迟列表
}
stats_lock = threading.Lock()
stop_flag = threading.Event()


def log_event(msg, level="INFO", color=None):
    """带时间戳彩色日志输出"""
    colors = {
        "INFO":    "\033[36m",   # cyan
        "SUCCESS": "\033[32m",   # green
        "ERROR":   "\033[31m",   # red
        "WARN":    "\033[33m",   # yellow
        "SWITCH":  "\033[35m",   # magenta
        "RESET":   "\033[0m",
    }
    c = colors.get(level, colors["INFO"])
    r = colors["RESET"]
    ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    print(f"{c}[{ts}] [{level:7s}] {msg}{r}", flush=True)

    with stats_lock:
        stats["events"].append({
            "ts": ts,
            "level": level,
            "msg": msg,
        })


def get_current_primary(client):
    """获取当前连接到的主节点地址"""
    try:
        # MongoClient 的 primary 属性返回 (host, port) 元组
        primary = client.primary
        if primary:
            return f"{primary[0]}:{primary[1]}"
        return "UNKNOWN"
    except Exception:
        return "UNKNOWN"


def worker(worker_id, client, db):
    """工作线程：持续执行读写操作"""
    counter = 0
    while not stop_flag.is_set():
        counter += 1
        req_id = f"w{worker_id}-{counter}"
        start = time.time()
        current_primary = "?"
        status = "FAIL"
        error_type = None

        try:
            # 写入操作
            doc = {
                "request_id": req_id,
                "worker_id": worker_id,
                "timestamp": datetime.now(),
                "payload": f"data_{counter}",
            }
            result = db.traffic_test.insert_one(doc)

            # 获取当前 PRIMARY（写入成功后）
            current_primary = get_current_primary(client)

            # 读取验证
            db.traffic_test.find_one({"_id": result.inserted_id})

            elapsed = (time.time() - start) * 1000  # ms
            status = "OK"

            with stats_lock:
                stats["total"] += 1
                stats["success"] += 1
                port = current_primary.split(":")[-1] if ":" in current_primary else "?"
                stats["primary_nodes"][port] = stats["primary_nodes"].get(port, 0) + 1
                stats["latencies"].append(elapsed)

            # 每 20 个成功请求打印一次进度（减少噪音）
            if stats["success"] % 20 == 0:
                node_label = "AWS(27017)" if "27017" in current_primary else "腾讯云(27018)" if "27018" in current_primary else current_primary
                log_event(
                    f"✓ {req_id} OK [{elapsed:.1f}ms] → PRIMARY={node_label} (累计成功 {stats['success']})",
                    "SUCCESS"
                )

        except (NotPrimaryError, AutoReconnect) as e:
            elapsed = (time.time() - start) * 1000
            error_type = type(e).__name__
            with stats_lock:
                stats["total"] += 1
                stats["failed"] += 1
                stats["errors"][error_type] = stats["errors"].get(error_type, 0) + 1
            log_event(
                f"✗ {req_id} FAIL [{elapsed:.1f}ms] {error_type}: {str(e)[:80]}",
                "ERROR"
            )

        except (ServerSelectionTimeoutError, ConnectionFailure, NetworkTimeout) as e:
            elapsed = (time.time() - start) * 1000
            error_type = type(e).__name__
            with stats_lock:
                stats["total"] += 1
                stats["failed"] += 1
                stats["errors"][error_type] = stats["errors"].get(error_type, 0) + 1
            log_event(
                f"✗ {req_id} TIMEOUT [{elapsed:.1f}ms] {error_type}",
                "ERROR"
            )

        except OperationFailure as e:
            elapsed = (time.time() - start) * 1000
            error_type = f"OperationFailure({e.code})"
            with stats_lock:
                stats["total"] += 1
                stats["failed"] += 1
                stats["errors"][error_type] = stats["errors"].get(error_type, 0) + 1
            # 只读模式下会抛出这个
            if "not master" in str(e).lower() or "readonly" in str(e).lower() or e.code in (10107, 13435):
                log_event(
                    f"✗ {req_id} READONLY [{elapsed:.1f}ms] {str(e)[:80]}",
                    "WARN"
                )
            else:
                log_event(
                    f"✗ {req_id} FAIL [{elapsed:.1f}ms] {error_type}: {str(e)[:80]}",
                    "ERROR"
                )

        except Exception as e:
            elapsed = (time.time() - start) * 1000
            error_type = type(e).__name__
            with stats_lock:
                stats["total"] += 1
                stats["failed"] += 1
                stats["errors"][error_type] = stats["errors"].get(error_type, 0) + 1
            log_event(
                f"✗ {req_id} EXCEPTION [{elapsed:.1f}ms] {error_type}: {str(e)[:80]}",
                "ERROR"
            )

        # 控制请求速率: 每秒约 10 次请求/worker
        time.sleep(0.1)


def monitor_primary(client):
    """监控线程：定期检测 PRIMARY 变更"""
    last_primary = None
    while not stop_flag.is_set():
        try:
            current = get_current_primary(client)
            if current != last_primary:
                if last_primary is not None:
                    node_label = (
                        "AWS(27017)" if "27017" in current else
                        "腾讯云(27018)" if "27018" in current else
                        current
                    )
                    log_event(
                        f"🔄 PRIMARY 变更检测: {last_primary} → {current} [{node_label}]",
                        "SWITCH"
                    )
                last_primary = current
        except Exception:
            pass
        time.sleep(0.3)


def print_summary(duration):
    """打印最终统计报告"""
    print()
    print("=" * 70)
    print("  业务流量测试统计报告")
    print("=" * 70)
    print(f"  测试时长:     {duration:.1f} 秒")
    print(f"  总请求数:     {stats['total']}")
    print(f"  成功:         {stats['success']} ({stats['success']*100/max(stats['total'],1):.1f}%)")
    print(f"  失败:         {stats['failed']} ({stats['failed']*100/max(stats['total'],1):.1f}%)")
    print()
    print(f"  请求分布（按 PRIMARY 节点）:")
    for port, count in stats["primary_nodes"].items():
        label = "AWS(27017)" if port == "27017" else "腾讯云(27018)" if port == "27018" else port
        pct = count * 100 / max(stats["success"], 1)
        print(f"    {label:20s}: {count:5d} ({pct:.1f}%)")
    print()

    if stats["errors"]:
        print(f"  错误类型分布:")
        for err, count in stats["errors"].items():
            print(f"    {err:30s}: {count}")
    print()

    if stats["latencies"]:
        lats = sorted(stats["latencies"])
        n = len(lats)
        print(f"  延迟统计 (成功请求):")
        print(f"    最小:   {lats[0]:.2f} ms")
        print(f"    平均:   {sum(lats)/n:.2f} ms")
        print(f"    P50:    {lats[n//2]:.2f} ms")
        print(f"    P95:    {lats[int(n*0.95)]:.2f} ms")
        print(f"    P99:    {lats[int(n*0.99)]:.2f} ms")
        print(f"    最大:   {lats[-1]:.2f} ms")
    print("=" * 70)

    # 保存到 JSON
    result_file = f"/data/workspace/MongoDB_Migration_Test/results/traffic_test_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    with open(result_file, "w") as f:
        json.dump({
            "duration": duration,
            "total": stats["total"],
            "success": stats["success"],
            "failed": stats["failed"],
            "primary_nodes": stats["primary_nodes"],
            "errors": stats["errors"],
            "latency_stats": {
                "min": min(stats["latencies"]) if stats["latencies"] else 0,
                "avg": sum(stats["latencies"])/len(stats["latencies"]) if stats["latencies"] else 0,
                "max": max(stats["latencies"]) if stats["latencies"] else 0,
            } if stats["latencies"] else {},
            "events": stats["events"][-100:],  # 最后100个事件
        }, f, indent=2, default=str)
    print(f"\n详细结果已保存: {result_file}")


def main():
    workers = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    duration = int(sys.argv[2]) if len(sys.argv) > 2 else 60

    log_event(f"启动业务流量模拟（{workers} 个 worker, 持续 {duration} 秒）", "INFO")
    log_event(f"连接串: {MONGO_URI}", "INFO")

    # 建立连接
    client = MongoClient(MONGO_URI)
    db = client.migration_test

    # 初始 PRIMARY
    initial_primary = get_current_primary(client)
    node_label = "AWS(27017)" if "27017" in initial_primary else "腾讯云(27018)" if "27018" in initial_primary else initial_primary
    log_event(f"初始 PRIMARY: {initial_primary} [{node_label}]", "INFO")

    # 启动监控线程
    monitor = threading.Thread(target=monitor_primary, args=(client,), daemon=True)
    monitor.start()

    # 启动工作线程
    threads = []
    for i in range(workers):
        t = threading.Thread(target=worker, args=(i+1, client, db), daemon=True)
        t.start()
        threads.append(t)

    start_time = time.time()
    try:
        # 等待指定时长
        while time.time() - start_time < duration:
            time.sleep(1)
    except KeyboardInterrupt:
        log_event("收到中断信号，停止测试...", "WARN")

    stop_flag.set()
    time.sleep(1)  # 等待线程退出

    actual_duration = time.time() - start_time
    print_summary(actual_duration)

    client.close()


if __name__ == "__main__":
    main()
