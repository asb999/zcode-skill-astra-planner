---
name: zcode-skill-astra-planner
description: 开工前规划纪律（Astra 规划器）：非平凡编码任务（新功能/修 bug/重构等多步骤工作）先让 gpt-6-astra（经 Codex CLI）编译「傻瓜级方案 + 可执行自检 Harness + 机器可判定成功标准」到 .astra/PLAN.md，执行后用 harness 机器判定 PASS/FAIL，FAIL 必须修复重跑直到 PASS。当用户要求实现功能、修复 bug、重构、或说"先规划 / 规划先行 / astra planner"时使用；单行修改或纯问答不要用。
---

# ZCode × Astra 规划器

把「规划」和「执行」拆开：Astra（gpt-6-astra）当规划者，ZCode 当执行者，自检 harness 当裁判。
杜绝两类大模型通病：**漏步骤**、**自己声称干完了**。一切以机器判定为准。

> 移植自 [coding-with-yiqi/workbuddy-skill-astra-planner](https://github.com/coding-with-yiqi/workbuddy-skill-astra-planner)（MIT）。

本 skill 所在目录记为 `$SKILL_DIR`（即本 SKILL.md 的父目录）。核心脚本：
`bash "$SKILL_DIR/scripts/ask_astra.sh" <子命令>`

## 什么时候用

| 场景 | 用不用 |
|---|---|
| 新功能、修 bug、重构、跨文件改造、环境搭建等多步骤任务 | ✅ 先规划 |
| 用户说"先规划" / "用 astra planner" / "规划先行" | ✅ 强制 |
| 单行修改、改个 typo、纯问答/调研、读代码 | ❌ 不用 |

## 完整循环（执行者必走）

1. **写任务书**：把用户需求整理成 `.astra/task.md`（目标、边界、约束、验收意图）。任务模糊时先向用户澄清再写。
2. **编译方案**：`bash "$SKILL_DIR/scripts/ask_astra.sh" plan .astra/task.md`
   - 产出：`.astra/PLAN.md`（八段契约）、`.astra/harness/*.sh`、`.astra/run.status`
   - 契约校验失败或调用失败时脚本非零退出，按报错修复后重跑，**不要跳过规划直接干活**。
3. **通读 PLAN.md**，严格照段执行：
   - [S1] 傻瓜级步骤 = 你的施工顺序；[S2] 工具预调先跑；[S3] 指定要读的文件先读完再动手；
   - [S5] 模具清单里的模板直接复用，不要自己另发明一套。
4. **机器自检**：`bash "$SKILL_DIR/scripts/ask_astra.sh" check`
5. **FAIL 修复循环**：有任何 `[FAIL]` → 对照 [S7] 成功标准和 [S8] 风险回滚修复 → 重跑 `check`。最多 3 轮；仍 FAIL 则如实向用户报告，不要谎报完成。
6. **汇报**：向用户汇报时引用 `run.status` 的关键字段（status / harness_passed / harness_total / plan_sha256），不要凭感觉说"完成了"。

## 子命令速查

| 命令 | 作用 |
|---|---|
| `plan <taskfile>` | 编译方案（直接传任务文件也等价） |
| `check`（`--check`） | 跑 harness，输出 `[PASS]/[FAIL]` 汇总，全过退出 0 |
| `validate`（`--validate-only`） | 只校验 PLAN.md 八段契约 |
| `extract`（`--extract`） | 只提取 harness 脚本 |

PASS 的机器定义：脚本退出码 0 **且** 输出含 ≥1 行 `[PASS]` **且** 不含 `[FAIL]`。

## 环境变量（可选）

`ZAP_MODEL`（默认 gpt-6-astra）、`ZAP_EFFORT`（xhigh）、`ZAP_SANDBOX`（read-only）、
`ZAP_BIN`、`ZAP_OUT_DIR`（.astra）、`ZAP_TIMEOUT`（1800）、
`ZAP_PROXY`（留空自动检测 Windows/macOS 系统代理）、`ZAP_USE_USER_CONFIG`（默认 0，跳过 ~/.codex/config.toml）。

## 故障排查

| 症状 | 处置 |
|---|---|
| `找不到 Codex CLI` | `npm install -g @openai/codex@latest` |
| 服务端提示模型需要更新版本 | 同上（gpt-6-astra 要求 codex ≥0.155） |
| 连接超时/中断 | 设置代理 `ZAP_PROXY=http://127.0.0.1:7897`（或确保系统代理开启让自动检测生效） |
| 未登录 | `codex login` |
| 模型不可用 | `ZAP_MODEL=<可用模型> ` 覆盖后重跑 |
| 契约校验失败 | 重跑 `plan`；偶发模型输出格式漂移属正常，重试即可 |
