# Assistant 对话命令参考

本文是飞书 / 企业微信 / 本地 `om assistant handle` 的对话命令速查。设计原理、权限模型和
pending operation 的合同见 [Inbound Control](INBOUND_CONTROL.md)；`om` / `om-agent` 的
CLI 工具网关见 [Tool Reference](TOOL_REFERENCE.md)。

运行时权威：

```bash
./om assistant commands --format text
./om assistant commands --format json
```

源码权威：

- `src/application/assistant/capability_catalog.py` — 命令目录
- `src/application/assistant/command_parser.py` — 命令解析与 intent 路由
- `src/application/assistant/manual_trade_parser.py` — 交易记录字段解析
- `src/application/assistant/operation_policy.py` — 写操作开关与 admin 边界

命令目录随版本演进，本文表格用于快速检索；与运行时输出冲突时以运行时为准。

## 两条路径

```text
显式协议（斜杠命令 / 明确的 pending 回复）-> 确定性 Control
其他全部文本                              -> 只读 Bot
                                            -> 可选：经校验的 Control preview 请求
```

Control 不从自由文本推断业务意图，也不选择工具或综合结论。写命令一律走
preview → pending → 显式确认 → apply → readback，**模型无法进入 apply 路径**。

## 只读斜杠命令

聊天窗口中直接发送，无需任何开关或确认。

| 命令 | 作用 |
|---|---|
| `/help` `/?` | 帮助 |
| `/positions` | 持仓 |
| `/income` | 期权收益 |
| `/assigned-stock` | 指派正股 |
| `/symbols` | 监控标的 |
| `/pending` | 待确认操作 |
| `/model` | 当前模型 |
| `/status` | 运行状态 |
| `/health` `/doctor` | 健康检查 |
| `/runs` | 运行记录 |
| `/logs` | 日志 |
| `/config-check` `/config` | 配置检查 |

## 只读、无斜杠命令

这些工具**只有 Bot 能调用**（用户自然语言提问时由模型选择），不能手打命令触发。
完整清单与参数以 `./om-agent spec` 为准。

| 工具 | 作用 |
|---|---|
| `symbol_resolve` | 标的解析：名称 / 别名 / 富途代码 → 规范 OM 身份 |
| `symbol_config_query` | 标的配置：读取某标的的监控策略配置 |
| `cash_headroom_query` | 现金余量：CSP 占用与账户类现金资产对比 |
| `scheduled_tasks_read` | 部署级定时任务清单（配置 / 启用 / 活跃是三个独立事实） |
| `scheduler_status` | 当前业务调度与 scheduler 状态（不标记 scan/notify 状态） |
| `daily_decision_brief_read` | 期权监控：最近一次成功快照（不扫描、不发送） |
| `candidate_rank_explain` | 解释已落库快照中的开仓候选排序（从不重新排序） |
| `candidate_filter_explain` | 候选过滤诊断：某标的的开仓状态与被接受决策 |
| `position_exit_analysis` | 严格平仓分析：最近一次 close-advice 报告 |
| `portfolio_query` | 组合查询：账户 / 持仓 / 现金 / NAV / 分布 / 报告 |
| `portfolio_pnl_bridge` | MTD / YTD 总资产 PnL 桥 |
| `portfolio_cash_bridge` | 现金桥（在权威现金事实接入前明确报告不可用） |
| `portfolio_assignment_scenario` | 全部 short put / call 被指派后的资产分布与资金覆盖投影 |
| `notification_perception_read` | 通知感知事件 |
| `preview_notification` | 构造最终通知文本（不发送） |
| `receipt_read` | 读取留存业务回执 |
| `operation_timeline` | 操作时间线：升级状态与诊断回执 |
| `quality_status` | 最近一次 schema 校验通过的质量产物 |
| `version_check` | 本地 VERSION 与 git release tag 对比 |
| `project_context` | 项目资料入口、有效市场与授权账户导航 |
| `project_files` | 受限项目资料 / 运行证据的列举、搜索、分页读取 |

`portfolio_*` 系列需要 `assistant.bot.toolsets.portfolio: true`，缺失即关闭。

## 写命令

一律需要 preview → 确认。`target` 是确认/取消时的域标识符。

| 命令 | 作用 | target | 确认方式 |
|---|---|---|---|
| `/record-open` | 记录开仓 | `trade` | `/confirm trade <operation_id>` |
| `/record-close` | 记录平仓 | `trade` | 同上 |
| `/record-update` | 修改待确认交易 | `trade` | 同上 |
| `/record-expiry` | 记录到期失效 | `trade` | 同上 |
| （无斜杠命令） | 记录被指派 | `trade` | 同上 |
| `/symbol add` | 增加监控标的 | `symbol` | `/confirm symbol <operation_id>` |
| `/symbol edit` | 修改监控标的 | `symbol` | 同上 |
| `/symbol remove` | 删除监控标的 | `symbol` | 同上 |
| `/model use` | 切换模型 | `model` | `/confirm model <operation_id>` |
| `/upgrade` | 立即升级 | `upgrade` | `/confirm upgrade <operation_id>` |
| `/monitor-run` | 执行一次监控 | `monitor_run` | `/confirm monitor-run <operation_id>` |

`/record-expiry` 遇到一条通知含多个合约时，会**每个合约生成一个 pending operation**。

## 确认与取消

`/confirm` 和 `/cancel` 是**同一个命令被 5 个 target 共用**（`trade` / `symbol` /
`model` / `upgrade` / `monitor_run`），所以必须带 target：

```text
/confirm trade <operation_id>
/confirm symbol <operation_id>
/cancel  trade <operation_id>
```

当会话中只有一个待确认项时，可以直接回复**「确认」**两个字，会话会解析出唯一的
`command_id`。用 `/pending` 查看当前有哪些在等。

预览有效期 **600 秒**（`OM_INBOUND_CONFIRM_TTL_SECONDS` 可调）。超时需重新 preview。
pending operation 以 operation store 为权威真源，不是聊天历史。

## `/record-open` 格式与要求

必填字段（8 项）：

```text
account  symbol  side  option_type  contracts  strike  expiration_ymd  premium_per_share
```

推荐格式：

```text
/record-open <账户> <标的> <short|long> <put|call> strike <行权价> exp <YYYY-MM-DD> <张数>张 premium <权利金> [multiplier <乘数>]
```

示例：

```text
/record-open lx 泡泡玛特 short put strike 152.5 exp 2026-09-29 1张 premium 1.5
```

字段来源有三级优先级（`manual_trade_parser.py`）：① `键: 值` 标签写法 → ② 富途成交
提醒原文 → ③ 裸文本正则。标签写法最稳。

### 中文关键词对照

| 类别 | 认得的写法 |
|---|---|
| option_type | `沽` `看跌` `put` `p` → put；`购` `看涨` `call` `c` → call |
| side | `卖出` `sell` `short` → short；`买入` `buy` `long` → long |
| contracts | `N张` `N手` `N份` `N合约` |
| 中文标签 | `账户` `标的` `方向` `行权价` `到期日` `数量` `乘数` `权利金` |

### 硬性限制

- **日期必须是 `2026-09-29` 或 `2026/09/29`**。`260929` 这类 6 位写法解析不了；
  该格式只由富途生命周期通知的专用路径识别。
- **账户标签必须在配置中声明过**，形如 `^[a-z0-9][a-z0-9_-]{0,63}$`（小写字母数字加
  `-` / `_`）。
- `multiplier` 可省略，会尝试从缓存或 OpenD 解析；解析不出时需显式给出。
  乘数错误会连带影响金额、保证金与年化收益，落库前应核对。

`/record-close` 需要 `record_id`（或完整合约身份）+ `contracts_to_close` + `close_price`：

```text
/record-close record_id=<record_id> 1张 close <平仓价>
```

`/record-update` 用于修改待确认项：

```text
/record-update <field>=<value> [operation_id]
```

「记录被指派」没有斜杠命令，需发送富途生命周期通知原文（含「期权被指派通知」
「已被指派」「期权到期失效通知」「已到期失效」等字样），或由 Bot 识别后请求预览。

## 环境开关

写操作受总闸 + 领域子闸双重控制。总闸关闭时任何写命令都被拒。

| 变量 | 控制 |
|---|---|
| `OM_INBOUND_OPERATIONS_ENABLED` | **总闸**。未开时所有写操作被拒 |
| `OM_INBOUND_TRADE_WRITE_ENABLED` | `/record-*` 交易记录 |
| `OM_INBOUND_SYMBOL_WRITE_ENABLED` | `/symbol add\|edit\|remove` 监控标的 |
| `OM_INBOUND_MODEL_WRITE_ENABLED` | `/model use` 模型切换 |
| `OM_INBOUND_UPGRADE_WRITE_ENABLED` | `/upgrade` 版本升级 |
| `OM_INBOUND_MONITOR_RUN_ENABLED` | `/monitor-run` 手动触发监控 |

`OM_INBOUND_CONFIRM_TTL_SECONDS` 调整预览有效期（默认 600）。

## 权限与前置条件

写操作的校验顺序（`operation_policy.py`）：

```text
总闸开启
-> OM_INBOUND_ADMIN_OPEN_IDS 非空
-> admin 列表不含通配符
-> OM_INBOUND_OPERATION_HMAC_KEY 已配置
-> 发送者在 admin 列表内
-> 对应领域写开关已开启
```

约束：

- `OM_INBOUND_ADMIN_OPEN_IDS` **必须是显式发送者 ID**（形如 `feishu:ou_xxx`）。
  写通配符会被 `CONFIG_ERROR: wildcard inbound operation admins are not allowed` 拒绝。
- `OM_INBOUND_OPERATION_HMAC_KEY`（逻辑名 `inbound.operation_hmac_key`）用于给
  preview→confirm 之间的操作签名，防止预览内容被篡改。缺失时写路径整体不可用。
- 读命令的发送者白名单由 `OM_FEISHU_BOT_ALLOWED_OPEN_IDS` /
  `OM_FEISHU_BOT_USER_OPEN_ID` 决定。

## 诊断

```bash
# 列出全部命令与风险级别
./om assistant commands --format text

# 本地干跑一条命令（不发送真实消息）
./om assistant handle \
  --text "/record-open lx 泡泡玛特 short put strike 152.5 exp 2026-09-29 1张 premium 1.5" \
  --channel feishu --sender <open_id> --config-key hk \
  --assistant-config <runtime>/resolved/config.assistant.json \
  --env-file <runtime>/options-monitor.env \
  --format json
```

`--format json` 输出中的 `data.preview` 是解析结果（`preview.mode: "dry_run"` 表示未落库），
`data.ledger_preflight` 是账本预检。检查 `diagnostics.missing_fields` 是否为空。

## 非目标

- Control 不解析自由文本的业务意图；自然语言提问走 Bot。
- Bot 不持有写、确认、取消或 apply 工具，其唯一状态变更入口是通用 preview 请求。
- Channel 适配层不得直接导入命令解析器、工具实现或 Bot 内部模块。
