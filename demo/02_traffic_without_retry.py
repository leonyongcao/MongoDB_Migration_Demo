#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
对照组：关闭 retryWrites 的流量模拟器
用于展示切换瞬间的"原始"影响（应用层不启用 driver 重试时）

与 traffic_simulator.py 的差异:
  - retryWrites=false
  - retryReads=false
  - 能看到切换瞬间真实的失败请求
"""
import sys
import time
import threading
from datetime import datetime
from pymongo import MongoClient
from pymongo.errors import (
    AutoReconnect, NotPrimaryError, ServerSelectionTimeoutError,
    ConnectionFailure, NetworkTimeout, OperationFailure
)

MONGO_URI = (
    "mongodb://127.0.0.1:27017,127.0.0.1:27018/"
    "?replicaSet=rs_migration"
    "&retryWrites=false"             # 关键：关闭重试
    "&retryReads=false"
    "&serverSelectionTimeoutMS=2000"
    "&socketTimeoutMS=2000"
)

stats = {"total": 0, "success": 0, "failed": 0, "errors": {}, "timeline": []}
stats_lock = threading.Lock()
stop_flag = threading.Event()


def log(msg, level="INFO"):
    colors = {
        "INFO": "\033[36m", "SUCCESS": "\033[32m",
        "ERROR": "\033[31m", "SWITCH": "\033[35m",
        "WARN": "\033[33m", "RESET": "\033[0m",
    }
    ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    print(f"{colors.get(level, colors['INFO'])}[{ts}] [{level:7s}] {msg}{colors['RESET']}", flush=True)


def get_primary(client):
    try:
        p = client.primary
        return f"{p[0]}:{p[1]}" if p else "UNKNOWN"
    except Exception:
        return "UNKNOWN"


def worker(wid, client, db):
    counter = 0
    while not stop_flag.is_set():
        counter += 1
        req_id = f"w{wid}-{counter}"
        start = time.time()
        try:
            db.traffic_no_retry.insert_one({
                "req_id": req_id, "ts": datetime.now(),
            })
            elapsed = (time.time() - start) * 1000
            primary = get_primary(client)
            with stats_lock:
                stats["total"] += 1
                stats["success"] += 1
                stats["timeline"].append({
                    "ts": time.time(), "req_id": req_id,
                    "status": "OK", "elapsed": elapsed, "primary": primary
                })
            if stats["success"] % 15 == 0:
                label = "AWS" if "27017" in primary else "腾讯云" if "27018" in primary else primary
                log(f"✓ {req_id} OK [{elapsed:.1f}ms] → {label} (成功 {stats['success']})", "SUCCESS")
        except Exception as e:
            elapsed = (time.time() - start) * 1000
            err_type = type(e).__name__
            with stats_lock:
                stats["total"] += 1
                stats["failed"] += 1
                stats["errors"][err_type] = stats["errors"].get(err_type, 0) + 1
                stats["timeline"].append({
                    "ts": time.time(), "req_id": req_id,
                    "status": "FAIL", "elapsed": elapsed, "error": err_type
                })
            log(f"✗ {req_id} FAIL [{elapsed:.1f}ms] {err_type}: {str(e)[:60]}", "ERROR")
        time.sleep(0.1)


def monitor(client):
    last = None
    while not stop_flag.is_set():
        try:
            cur = get_primary(client)
            if cur != last:
                if last is not None:
                    label = "AWS" if "27017" in cur else "腾讯云" if "27018" in cur else cur
                    log(f"🔄 PRIMARY 变更: {last} → {cur} [{label}]", "SWITCH")
                last = cur
        except Exception:
            pass
        time.sleep(0.2)


def main():
    workers = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    duration = int(sys.argv[2]) if len(sys.argv) > 2 else 60

    log(f"启动【关闭重试】流量模拟（{workers} workers, {duration} 秒）", "INFO")
    log(f"关键: retryWrites=false, 能看到切换瞬间的真实失败", "WARN")

    client = MongoClient(MONGO_URI)
    db = client.migration_test

    log(f"初始 PRIMARY: {get_primary(client)}", "INFO")

    t_mon = threading.Thread(target=monitor, args=(client,), daemon=True)
    t_mon.start()

    threads = [threading.Thread(target=worker, args=(i+1, client, db), daemon=True) for i in range(workers)]
    for t in threads:
        t.start()

    t_start = time.time()
    try:
        while time.time() - t_start < duration:
            time.sleep(1)
    except KeyboardInterrupt:
        pass

    stop_flag.set()
    time.sleep(1)

    elapsed = time.time() - t_start
    print()
    print("=" * 70)
    print("  【关闭重试】业务流量测试报告")
    print("=" * 70)
    print(f"  测试时长:  {elapsed:.1f} 秒")
    print(f"  总请求:    {stats['total']}")
    print(f"  成功:      {stats['success']} ({stats['success']*100/max(stats['total'],1):.1f}%)")
    print(f"  失败:      {stats['failed']} ({stats['failed']*100/max(stats['total'],1):.1f}%)")
    if stats["errors"]:
        print(f"  错误分布:")
        for err, cnt in stats["errors"].items():
            print(f"    {err}: {cnt}")
    print("=" * 70)

    # 输出失败请求的时间线（便于看切换影响窗口）
    failures = [t for t in stats["timeline"] if t["status"] == "FAIL"]
    if failures:
        print(f"\n失败请求时间线（共 {len(failures)} 个）:")
        first_fail = failures[0]["ts"]
        last_fail = failures[-1]["ts"]
        print(f"  首个失败: {datetime.fromtimestamp(first_fail).strftime('%H:%M:%S.%f')[:-3]}")
        print(f"  末个失败: {datetime.fromtimestamp(last_fail).strftime('%H:%M:%S.%f')[:-3]}")
        print(f"  失败窗口: {last_fail - first_fail:.2f} 秒")

    client.close()


if __name__ == "__main__":
    main()
