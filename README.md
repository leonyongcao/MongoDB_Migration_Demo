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
│  │(TCloud)  │    priority=0, votes=0                │
│  └──────────┘                                       │
│                                                     │
│  阶段3: 数据同步完成，提升 priority 和 votes         │
│  ┌──────────┐     ┌──────────┐                      │
│  │ PRIMARY  │─────│SECONDARY │                      │
│  │ (AWS)    │     │(TCloud)  │  priority=5,votes=1  │
│  └──────────┘     └──────────┘                      │
│                                                     │
│  阶段4: 主从切换，腾讯云成为新主节点                  │
│  ┌──────────┐     ┌──────────┐                      │
│  │SECONDARY │─────│ PRIMARY  │  ← 新主节点           │
│  │ (AWS)    │     │(TCloud)  │                      │
│  └──────────┘     └──────────┘                      │
│                                                     │
│  阶段5: 移除 AWS 旧节点，迁移完成                    │
│  ┌──────────┐                                       │
│  │ PRIMARY  │  ← 腾讯云独立运行                      │
│  │(TCloud)  │                                       │
│  └──────────┘                                       │
└─────────────────────────────────────────────────────┘
```

## 本地测试架构

在同一台服务器上用不同端口模拟：

| 角色 | 端口 | 说明 |
|------|------|------|
| AWS 主节点 | 27017 | 模拟 AWS 上的 PRIMARY |
| 腾讯云从节点 | 27018 | 模拟腾讯云自建的 SECONDARY |

## 脚本说明

| 脚本 | 功能 |
|------|------|
| `01_install_mongodb.sh` | 安装 MongoDB 7.0 |
| `02_setup_instances.sh` | 部署双实例（AWS + 腾讯云） |
| `03_init_replicaset.sh` | 初始化副本集 + 写入测试数据 + 从节点加入 |
| `04_verify_sync.sh` | 验证数据同步完整性 |
| `05_migration_test.sh` | 完整迁移测试（增量同步/切换/验证） |
| `06_cleanup.sh` | 清理测试环境 |

## 快速开始

### 一键执行全部测试

```bash
cd /data/workspace/MongoDB_Migration_Test
bash run_all.sh
```

### 分步执行

```bash
cd /data/workspace/MongoDB_Migration_Test

# 1. 安装 MongoDB
bash scripts/01_install_mongodb.sh

# 2. 部署双实例
bash scripts/02_setup_instances.sh

# 3. 初始化副本集 + 数据 + 从节点加入
bash scripts/03_init_replicaset.sh

# 4. 验证数据同步
bash scripts/04_verify_sync.sh

# 5. 完整迁移测试
bash scripts/05_migration_test.sh

# 6. 清理环境
bash scripts/06_cleanup.sh
```

## 测试场景

### 核心测试

1. **增量数据实时同步** - 主节点写入后从节点能否实时同步
2. **高写入下同步延迟** - 大批量写入时的 replication lag
3. **从节点读取性能** - 精确查询、范围查询、聚合查询
4. **提升为可投票成员** - 修改 priority 和 votes
5. **主从切换 (Failover)** - stepDown 触发选举
6. **切换后数据完整性** - 新主节点读写验证
7. **移除旧节点** - rs.remove 移除 AWS 节点

## 真实迁移注意事项

1. **网络延迟**: 跨云网络延迟会影响同步速度，建议使用专线或 VPN
2. **Oplog 窗口**: 确保 oplog 足够大，避免从节点追不上
3. **初始同步时间**: 数据量大时 initial sync 耗时较长
4. **Priority 设置**: 加入时 priority=0 防止意外切主
5. **切换时间窗口**: 选择业务低峰期进行切换
6. **回滚方案**: 保留 AWS 节点一段时间，确认无误后再移除
7. **DNS 切换**: 切换后更新应用连接串指向新节点
8. **版本兼容**: 确保 AWS 和腾讯云 MongoDB 版本兼容
