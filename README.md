# MongoDB 融合迁移测试

## 背景

模拟 AWS MongoDB 副本集（一主二从）迁移到腾讯云的融合迁移方案。

**核心思路**：在腾讯云自建 MongoDB 实例，作为从节点加入 AWS 的副本集，数据自动同步后，执行主从切换，最终将流量切到腾讯云。

## 融合迁移原理

```
┌─────────────────────────────────────────────────────┐
│                 融合迁移流程                          │
│                                                     │
│  阶段1: 初始状态 (AWS 副本集)                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐          │
│  │ PRIMARY  │──│SECONDARY │──│SECONDARY │          │
│  │ (AWS)    │  │ (AWS)    │  │ (AWS)    │          │
│  └──────────┘  └──────────┘  └──────────┘          │
│                                                     │
│  阶段2: 加入腾讯云从节点 (priority=0, votes=0)      │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐          │
│  │ PRIMARY  │──│SECONDARY │──│SECONDARY │          │
│  │ (AWS)    │  │ (AWS)    │  │ (AWS)    │          │
│  └────┬─────┘  └──────────┘  └──────────┘          │
│       │ 数据同步                                     │
│  ┌────▼─────┐                                       │
│  │SECONDARY │  ← 腾讯云自建节点                      │
│  │(Tencent) │    priority=0, votes=0                │
│  └──────────┘                                       │
│                                                     │
│  阶段3: 数据同步完成，提升 priority 和 votes         │
│  ┌──────────┐     ┌──────────┐                      │
│  │ PRIMARY  │─────│SECONDARY │                      │
│  │ (AWS)    │     │(Tencent) │  priority=5,votes=1  │
│  └──────────┘     └──────────┘                      │
│                                                     │
│  阶段4: 主从切换，腾讯云成为新主节点                  │
│  ┌──────────┐     ┌──────────┐                      │
│  │SECONDARY │─────│ PRIMARY  │  ← 新主节点           │
│  │ (AWS)    │     │(Tencent) │                      │
│  └──────────┘     └──────────┘                      │
│                                                     │
│  阶段5: 移除 AWS 旧节点，迁移完成                    │
│  ┌──────────┐                                       │
│  │ PRIMARY  │  ← 腾讯云独立运行                      │
│  │(Tencent) │                                       │
│  └──────────┘                                       │
└─────────────────────────────────────────────────────┘
```

## 本地测试架构

在同一台服务器上用不同端口模拟：

| 角色 | 端口 | 说明 |
|------|------|------|
| AWS 主节点 | 27017 | 模拟 AWS 上的 PRIMARY |
| 腾讯云从节点 | 27018 | 模拟腾讯云自建的 SECONDARY |

## 项目结构

```
MongoDB_Migration_Test/
├── README.md                          # 项目说明（本文件）
├── MongoDB融合迁移技术报告.md          # 完整技术报告（1100+ 行）
├── run_all.sh                         # 一键执行全部迁移测试
│
├── config/                            # MongoDB 实例配置
│   ├── aws_primary.conf               # AWS 主节点配置 (27017)
│   └── tcloud_secondary.conf          # 腾讯云从节点配置 (27018)
│
├── scripts/                           # 迁移流程脚本（按顺序执行）
│   ├── 01_install_mongodb.sh          # 安装 MongoDB 7.0
│   ├── 02_setup_instances.sh          # 部署双实例
│   ├── 03_init_replicaset.sh          # 初始化副本集 + 写入数据 + 从节点加入
│   ├── 04_verify_sync.sh              # 验证数据同步完整性
│   ├── 05_migration_test.sh           # 完整迁移测试（同步/切换/验证）
│   └── 06_cleanup.sh                  # 清理测试环境
│
├── demo/                              # 流量切换 Demo（验证切换对业务影响）
│   ├── DEMO_VERIFICATION_REPORT.md    # Demo 验证报告
│   ├── 01_traffic_with_retry.py       # 流量模拟器 - 启用 retryWrites
│   ├── 02_traffic_without_retry.py    # 流量模拟器 - 关闭 retryWrites（对照组）
│   ├── 03_failover_controller.sh      # 主从切换控制器
│   ├── run_demo_a_with_retry.sh       # 场景A：启用重试的完整 demo
│   └── run_demo_b_without_retry.sh    # 场景B：关闭重试的对照 demo
│
├── data/                              # MongoDB 数据目录（gitignore）
├── logs/                              # MongoDB 日志（gitignore）
└── results/                           # 测试结果和报告（gitignore）
```

---

## 一、迁移流程脚本 (`scripts/`)

核心迁移测试脚本，按编号顺序执行，每个脚本对应迁移流程的一个阶段。

| 脚本 | 阶段 | 功能 |
|------|------|------|
| `01_install_mongodb.sh` | 环境准备 | 安装 MongoDB 7.0 |
| `02_setup_instances.sh` | 实例部署 | 启动 AWS(27017) 和腾讯云(27018) 双实例 |
| `03_init_replicaset.sh` | 副本集组建 | 初始化副本集 + 写入 8 万条测试数据 + 腾讯云从节点加入 |
| `04_verify_sync.sh` | 同步验证 | 验证数据量、内容、索引、Oplog 状态 |
| `05_migration_test.sh` | 迁移测试 | 增量同步 / 高写入 / 从节点读取 / 主从切换 / 数据一致性 |
| `06_cleanup.sh` | 环境清理 | 停止实例，清理数据 |

### 快速开始

```bash
cd /data/workspace/MongoDB_Migration_Test

# 方式1：一键执行全部
bash run_all.sh

# 方式2：分步执行
bash scripts/01_install_mongodb.sh
bash scripts/02_setup_instances.sh
bash scripts/03_init_replicaset.sh
bash scripts/04_verify_sync.sh
bash scripts/05_migration_test.sh
bash scripts/06_cleanup.sh      # 可选，清理环境
```

### 测试场景覆盖

1. **增量数据实时同步** - 主节点写入后从节点能否实时同步
2. **高写入下同步延迟** - 大批量写入时的 replication lag
3. **从节点读取性能** - 精确/范围/聚合/关联查询
4. **提升为可投票成员** - 修改 priority 和 votes
5. **主从切换 (Failover)** - stepDown 触发选举
6. **切换后数据完整性** - 新主节点读写验证
7. **移除旧节点** - rs.remove 移除 AWS 节点

---

## 二、流量切换 Demo (`demo/`)

专门用于验证**切换过程中业务流量的真实表现**。模拟应用持续读写的同时触发主从切换，观察请求是否会失败、切换耗时、流量如何从 AWS 自动切到腾讯云。

### 文件命名规范

采用「编号 + 作用 + 场景」的命名方式，清晰区分组件和测试场景：

| 编号 | 角色 | 文件 | 说明 |
|------|------|------|------|
| `01` | 流量模拟器 | `01_traffic_with_retry.py` | **启用** `retryWrites=true`（生产推荐配置）|
| `02` | 流量模拟器 | `02_traffic_without_retry.py` | **关闭** `retryWrites=false`（对照组，暴露原始影响）|
| `03` | 切换控制器 | `03_failover_controller.sh` | 执行 `rs.stepDown()` 触发主从切换 |
| — | 一键执行 | `run_demo_a_with_retry.sh` | 场景 A：流量(01) + 切换(03) |
| — | 一键执行 | `run_demo_b_without_retry.sh` | 场景 B：流量(02) + 切换(03) |

### 运行方式

```bash
cd /data/workspace/MongoDB_Migration_Test/demo

# 场景A：验证推荐生产配置（启用 retryWrites）
bash run_demo_a_with_retry.sh

# 场景B：对照组（关闭 retryWrites，暴露切换原始影响）
bash run_demo_b_without_retry.sh
```

### 单独运行模拟器（调试用）

```bash
# 仅启动流量模拟器（参数: worker数 持续秒数）
python3 demo/01_traffic_with_retry.py 3 60
python3 demo/02_traffic_without_retry.py 3 40

# 仅执行切换（需先启动流量）
bash demo/03_failover_controller.sh
```

### Demo 验证结果

| 测试组 | 总请求 | 成功率 | 失败 | 切换耗时 |
|--------|--------|--------|------|---------|
| **场景 A**（启用 retry） | 1,725 | **100%** ✅ | 0 | ~1.1 秒 |
| **场景 B**（关闭 retry） | 1,161 | **100%** ✅ | 0 | ~1.1 秒 |

**关键结论**：
- 切换仅耗时 **~1 秒**
- driver 自动识别新 PRIMARY，流量透明切换
- 业务零感知，零请求失败

完整验证报告见：[`demo/DEMO_VERIFICATION_REPORT.md`](./demo/DEMO_VERIFICATION_REPORT.md)

---

## 三、配置文件 (`config/`)

| 配置文件 | 对应实例 | 端口 |
|---------|---------|------|
| `aws_primary.conf` | AWS 主节点 | 27017 |
| `tcloud_secondary.conf` | 腾讯云从节点 | 27018 |

关键配置：
- `replSetName: rs_migration` - 副本集名称
- `oplogSizeMB: 256` - Oplog 大小
- `wiredTiger cacheSizeGB: 0.3` - 缓存大小

---

## 四、技术报告

[`MongoDB融合迁移技术报告.md`](./MongoDB融合迁移技术报告.md) 包含：

- 9 大章节 + 2 个附录
- 迁移背景、方案选型、技术原理
- 测试环境、实施过程、结果分析
- 关键技术点深度分析（priority/votes/Oplog/stepDown）
- 生产环境迁移方案建议（D-7 到 D+7 时间线）
- 风险评估与回滚方案
- 完整操作命令和配置参考

---

## 真实迁移注意事项

1. **网络延迟**：跨云网络延迟会影响同步速度，建议使用专线或 VPN（延迟 < 50ms）
2. **Oplog 窗口**：确保 oplog 足够大，避免从节点追不上主节点
3. **初始同步时间**：数据量大时 initial sync 耗时较长，应预估时间
4. **Priority 设置**：腾讯云节点加入时 `priority=0, votes=0`，防止意外切主
5. **切换时间窗口**：选择业务低峰期进行 `rs.stepDown()`
6. **回滚方案**：保留 AWS 节点 3-7 天，确认稳定后再 `rs.remove()`
7. **连接串更新**：切换后逐步更新应用连接串
8. **版本兼容**：确保 AWS 和腾讯云 MongoDB 版本一致或兼容
9. **应用配置**：启用 `retryWrites=true` 和 `retryReads=true`

---

## 快速参考

| 需求 | 操作 |
|------|------|
| 搭建测试环境 | `bash run_all.sh` |
| 只验证数据同步 | `bash scripts/04_verify_sync.sh` |
| 验证切换业务影响 | `bash demo/run_demo_a_with_retry.sh` |
| 查看切换原始影响（对照组） | `bash demo/run_demo_b_without_retry.sh` |
| 清理测试环境 | `bash scripts/06_cleanup.sh` |
| 查看完整技术报告 | `cat MongoDB融合迁移技术报告.md` |
| 查看 Demo 验证报告 | `cat demo/DEMO_VERIFICATION_REPORT.md` |
