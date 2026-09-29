# 任务书示例：给 mycli 增加 --json 输出

## 目标
`mycli list` 命令支持 `--json` 开关：开启后以 JSON 数组输出结果（UTF-8、无多余日志），
默认行为保持不变。

## 边界
- 只改 `src/commands/list.ts` 及其测试，不动其他命令。
- 不引入新依赖（用手写序列化或现有工具函数）。

## 验收意图
- `mycli list --json` 输出可被 `jq` 解析的 JSON 数组；
- Windows Git Bash 与 Linux 下输出一致（换行 `\n`）；
- 既有测试全部通过。
