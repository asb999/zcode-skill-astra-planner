# zcode-skill-astra-planner

**开工前的一道固定工序：先让 Astra 把方案编译成「傻瓜级步骤 + 可执行自检 Harness + 机器可判定的成功标准」，ZCode 照单施工，最后由 harness 机器判定 PASS / FAIL —— 不信模型自评，只信断言。**

> 🙏 **致谢 / Credits**
> 本项目移植自 [coding-with-yiqi/workbuddy-skill-astra-planner](https://github.com/coding-with-yiqi/workbuddy-skill-astra-planner)（MIT）。
> 原版面向 workbuddy；本作把同一套「Astra 规划 + 机器自检」纪律移植到 [ZCode](https://z.ai)，并向 Windows / Git Bash 用户补齐了系统代理自动检测等体验。
> All credit for the original idea and the plan-contract design goes to the original author.

**English summary** — A ZCode skill that splits *planning* from *execution*: before any non-trivial coding task, the **gpt-6-astra** model (via Codex CLI, read-only sandbox) compiles a fool-proof `PLAN.md` with a fixed 8-section contract, runnable self-check scripts, and machine-judgeable success criteria. ZCode (or any executor — human or AI) executes the plan, then a harness script machine-verifies the result with `[PASS]`/`[FAIL]` assertions. A plan missing any section is rejected; a task with any `[FAIL]` is not done. Full docs below are in Chinese.

---

## 它解决什么

大模型直接干活常犯两个错——**漏步骤**、**自己声称干完了**。这个 skill 用三条硬约束杜绝：

1. **八段方案契约**：Astra 产出的 `PLAN.md` 必须包含固定八段（见下表），缺一段直接校验失败、非零退出。
2. **自检脚本会被真的提取并运行**：方案 `[S6]` 段里的 bash 围栏块会被提取成真正的 `.sh` 文件执行，输出 `[PASS]` / `[FAIL]`；有 FAIL 则整体非零退出。
3. **全程可追溯**：每次运行的模型、推理档位、退出码、会话 ID、方案哈希都写入 `.astra/run.status`。

```
任务 → Astra 编译方案 → 契约校验 → 提取 harness → ZCode 照单施工 → 机器自检
                                              ↑                              │
                                              └──────── FAIL 则修复重跑 ─────┘
```

## 八段契约

| 段 | 内容 |
|---|---|
| `[S1]` 傻瓜级步骤 | 编号步骤，每条命令可复制粘贴，无"同上" |
| `[S2]` 工具预调清单 | 执行前要预检的工具/版本/登录态，附检查命令 |
| `[S3]` 知识库检索清单 | 动手前必读的仓库文件/文档及关注点 |
| `[S4]` 技术细节 | 接口、数据结构、边界、平台差异 |
| `[S5]` 模具清单 | 可直接复用的代码模板，执行者不得另发明 |
| `[S6]` 自检 Harness | ≥1 个可执行 bash 块，幂等，输出 `[PASS]`/`[FAIL]` |
| `[S7]` 成功标准 | 机器可判定，与 harness 检查一一对应，禁止"看起来不错" |
| `[S8]` 风险与回滚 | 主要风险 + 具体回滚操作 |

## 快速开始

前置依赖：Bash（Git Bash / Linux / macOS）、[Codex CLI](https://github.com/openai/codex) **≥ 0.155**（服务端要求，调用 `gpt-6-astra` 的硬门槛）且已 `codex login`、能访问 `chatgpt.com`（中国大陆通常需要代理，本 skill 会自动检测 Windows/macOS 系统代理，也可用 `ZAP_PROXY` 指定）。

```bash
git clone https://github.com/asb999/zcode-skill-astra-planner.git
cd zcode-skill-astra-planner
./install.sh          # 安装到 ~/.agents/skills/zcode-skill-astra-planner
```

然后在 ZCode 里直接说：「用 astra planner 帮我实现 ×××」或「先规划再干」，ZCode 会自动触发本 skill。

也可以脱离 ZCode 单独用脚本：

```bash
# 1. 写任务书（参考 examples/task-example.md）
# 2. 编译方案（调用 gpt-6-astra，只读沙箱，可自行探索仓库）
bash scripts/ask_astra.sh plan path/to/task.md

# 3. 执行者照 .astra/PLAN.md 施工后，机器自检
bash scripts/ask_astra.sh check          # 输出 [PASS]/[FAIL] 汇总，全过退出 0

# 其他子命令
bash scripts/ask_astra.sh validate       # 只校验八段契约
bash scripts/ask_astra.sh extract        # 只提取 harness 脚本
```

产物都落在 `.astra/` 下：`PLAN.md`（方案）、`harness/*.sh`（自检脚本）、`run.status`（运行审计）、`run.log`（Codex 原始日志）。

## 机器判定规则

一个 harness 脚本 **PASS** 当且仅当：退出码为 0 **且** 输出含至少一行 `[PASS]` **且** 不含任何 `[FAIL]`。
harness 有 `[FAIL]` ⇒ `check` 非零退出 ⇒ 执行者必须修复重跑，禁止口头宣布完成。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `ZAP_MODEL` | `gpt-6-astra` | 规划模型 |
| `ZAP_EFFORT` | `xhigh` | 推理档位 |
| `ZAP_SANDBOX` | `read-only` | 规划器沙箱（默认只读，规划器不得改仓库） |
| `ZAP_BIN` | `codex` | Codex CLI 路径 |
| `ZAP_OUT_DIR` | `.astra` | 产物目录 |
| `ZAP_TIMEOUT` | `1800` | 单次规划超时（秒） |
| `ZAP_PROXY` | 自动检测 | 代理地址，如 `http://127.0.0.1:7897` |
| `ZAP_USE_USER_CONFIG` | `0` | 1 = 加载 `~/.codex/config.toml`（默认跳过，避免无关配置/MCP 干扰） |

## 与原版的差异

- 面向 **ZCode**：`SKILL.md` 定义了执行者的完整纪律循环（写任务书 → 编译 → 照单施工 → 机器自检 → FAIL 修复循环 ≤3 轮 → 按 `run.status` 汇报）。
- **系统代理自动检测**：Windows（注册表）/ macOS（scutil），Codex CLI 原本只认环境变量，中国大陆用户体验大幅改善。
- 默认 `--ignore-user-config`，不读取用户 `~/.codex/config.toml`，规划行为确定性更强，也规避新旧版本配置不兼容导致的启动失败。
- 兼容原版 `--check` / `--validate-only` / `--extract` 旗标习惯。

## License

MIT（见 [LICENSE](LICENSE)）。再次感谢原项目 [workbuddy-skill-astra-planner](https://github.com/coding-with-yiqi/workbuddy-skill-astra-planner) 的开创性设计。
