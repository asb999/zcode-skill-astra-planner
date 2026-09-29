#!/usr/bin/env bash
# ask_astra.sh — zcode-skill-astra-planner 核心脚本
# 让 gpt-6-astra（经 Codex CLI）在开工前编译一份「傻瓜级方案 + 可执行自检 Harness + 机器可判定成功标准」。
#
# 用法:
#   ask_astra.sh plan <taskfile>     编译方案（默认命令，可省略 plan）
#   ask_astra.sh check               重跑自检 harness，输出 PASS/FAIL 汇总
#   ask_astra.sh validate [plan]     只校验 PLAN.md 八段契约
#   ask_astra.sh extract [plan]      只提取 harness 脚本
# 兼容原版 flag: --check / --validate-only / --extract
#
# 环境变量（均有默认值）:
#   ZAP_MODEL=gpt-6-astra      规划模型
#   ZAP_EFFORT=xhigh           推理档位（不支持时自动降级 high→medium）
#   ZAP_SANDBOX=read-only      Codex 沙箱（规划器只读探索仓库）
#   ZAP_BIN=codex              Codex CLI 可执行文件
#   ZAP_OUT_DIR=.astra         产物目录（相对项目根）
#   ZAP_TIMEOUT=1800           单次规划调用超时（秒）
#   ZAP_PROXY=                 代理地址，如 http://127.0.0.1:7897；留空则自动检测系统代理
#   ZAP_USE_USER_CONFIG=0      1 = 加载 ~/.codex/config.toml（默认跳过，避免被无关配置干扰）
#
# 移植自 coding-with-yiqi/workbuddy-skill-astra-planner（MIT），面向 ZCode。

set -uo pipefail

ZAP_VERSION="1.0.0"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 配置 ----------
ZAP_MODEL="${ZAP_MODEL:-gpt-6-astra}"
ZAP_EFFORT="${ZAP_EFFORT:-xhigh}"
ZAP_SANDBOX="${ZAP_SANDBOX:-read-only}"
ZAP_BIN="${ZAP_BIN:-codex}"
ZAP_OUT_DIR="${ZAP_OUT_DIR:-.astra}"
ZAP_TIMEOUT="${ZAP_TIMEOUT:-1800}"
ZAP_PROXY="${ZAP_PROXY:-}"
ZAP_USE_USER_CONFIG="${ZAP_USE_USER_CONFIG:-0}"

OUT_DIR="${ZAP_OUT_DIR#./}"  # 去掉可能的前导 ./
OUT_DIR="./$OUT_DIR"         # 统一为 ./xxx 形式
PLAN_FILE="$OUT_DIR/PLAN.md"
HARNESS_DIR="$OUT_DIR/harness"
STATUS_FILE="$OUT_DIR/run.status"
RAW_FILE="$OUT_DIR/plan.raw.md"
RUN_LOG="$OUT_DIR/run.log"

# ---------- 八段契约 ----------
# PLAN.md 必须包含以下八个段落标题（前缀精确匹配），缺一段即契约破坏。
CONTRACT_SECTIONS=(
  '[S1] 傻瓜级步骤'
  '[S2] 工具预调清单'
  '[S3] 知识库检索清单'
  '[S4] 技术细节'
  '[S5] 模具清单'
  '[S6] 自检 Harness'
  '[S7] 成功标准'
  '[S8] 风险与回滚'
)

log()  { printf '[zap] %s\n' "$*"; }
err()  { printf '[zap][ERROR] %s\n' "$*" >&2; }
die()  { err "$*"; exit "${2:-1}"; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum    >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else echo "unavailable"; fi
}

# ---------- 代理自动检测 ----------
# Codex CLI 走标准 HTTPS_PROXY 环境变量；Windows 上系统代理不会自动注入，这里补上。
detect_proxy() {
  [ -n "${ZAP_PROXY:-}" ] && { export HTTPS_PROXY="$ZAP_PROXY" HTTP_PROXY="$ZAP_PROXY"; return 0; }
  # 已有代理环境就不动
  if [ -n "${HTTPS_PROXY:-}${https_proxy:-}${ALL_PROXY:-}" ]; then return 0; fi
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      command -v reg >/dev/null 2>&1 || return 0
      local enabled server
      enabled="$(reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings' //v ProxyEnable 2>/dev/null | awk '/ProxyEnable/{print $NF}')"
      server="$(reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings' //v ProxyServer 2>/dev/null | awk '/ProxyServer/{print $NF}')"
      if [ "$enabled" = "0x1" ] && [ -n "$server" ]; then
        # ProxyServer 可能是 "host:port" 或 "http=...;https=..."
        case "$server" in
          *';'*) server="$(printf '%s' "$server" | tr ';' '\n' | awk -F= '$1=="https"{print $2}')"
        esac
        case "$server" in
          http://*|https://*|socks5://*) ;;
          *) server="http://$server" ;;
        esac
        if [ -n "$server" ]; then
          export HTTPS_PROXY="$server" HTTP_PROXY="$server"
          log "auto-detected system proxy: $server (set ZAP_PROXY to override)"
        fi
      fi
      ;;
    Darwin)
      command -v scutil >/dev/null 2>&1 || return 0
      local enabled port
      enabled="$(scutil --proxy | awk '/HTTPEnable/{print $3}')"
      port="$(scutil --proxy | awk '/HTTPPort/{print $3}')"
      if [ "$enabled" = "1" ] && [ -n "$port" ]; then
        export HTTPS_PROXY="http://127.0.0.1:$port" HTTP_PROXY="http://127.0.0.1:$port"
        log "auto-detected system proxy: http://127.0.0.1:$port"
      fi
      ;;
  esac
}

# ---------- Codex 前置检查 ----------
codex_version() { "$ZAP_BIN" --version 2>/dev/null | awk '{print $NF}'; }

check_codex() {
  command -v "$ZAP_BIN" >/dev/null 2>&1 || die "找不到 Codex CLI（$ZAP_BIN）。安装: npm install -g @openai/codex@latest 并 codex login" 5
  local ver; ver="$(codex_version)"
  log "codex-cli $ver | model=$ZAP_MODEL | effort=$ZAP_EFFORT | sandbox=$ZAP_SANDBOX"
  case "$ver" in
    0.1[0-4][0-9].*|0.[0-9][0-9].*|0.15[0-4].*)
      err "Codex CLI $ver 过旧：服务端要求 ≥0.155 才能调用 gpt-6-astra。请执行: npm install -g @openai/codex@latest" ;;
  esac
}

# ---------- PLAN 契约校验 ----------
validate_plan() {
  local plan="${1:-$PLAN_FILE}"
  [ -f "$plan" ] || die "找不到方案文件: $plan" 4
  local missing=0 s sid pat
  for s in "${CONTRACT_SECTIONS[@]}"; do
    sid="${s%% *}"                                   # [S1]
    pat="$(printf '%s' "$sid" | sed 's/\[/\\[/; s/\]/\\]/')"  # 转义为 \[S1\]
    if ! grep -q "^## $pat" "$plan"; then
      err "契约缺失段落: ## $s"
      missing=$((missing+1))
    fi
  done
  if [ "$missing" -gt 0 ]; then
    err "契约校验失败：缺 $missing 段（共需 8 段）。请重跑 plan 或手工补齐后再 validate。"
    return 2
  fi
  log "契约校验通过：8/8 段齐全（$plan）"
  return 0
}

# ---------- Harness 提取 ----------
# 提取 [S6] 段内所有 ```bash 围栏代码块为可执行脚本。
# 围栏信息串可携带名字: ```bash harness=lint  或  ```bash harness lint
extract_harness() {
  local plan="${1:-$PLAN_FILE}"
  [ -f "$plan" ] || die "找不到方案文件: $plan" 4
  mkdir -p "$HARNESS_DIR"
  rm -f "$HARNESS_DIR"/[0-9][0-9]_*.sh 2>/dev/null

  local count
  count="$(awk -v dir="$HARNESS_DIR" '
    /^## \[S6\]/ {ins=1; next}
    /^## \[S7\]/ {ins=0}
    ins && /^```(bash|sh)/ {
      info=$0; sub(/^```(bash|sh)[ \t]*/,"",info)
      name=""
      if (match(info,/harness[= ]+[A-Za-z0-9._-]+/)) {
        name=substr(info,RSTART,RLENGTH); sub(/^harness[= ]+/,"",name)
      }
      n++
      fname=sprintf("%s/%02d_%s.sh", dir, n, (name==""?"check":name))
      inblk=1
      print "#!/usr/bin/env bash" > fname
      next
    }
    ins && /^```/ && inblk { inblk=0; close(fname); next }
    inblk { print > fname }
    END { print n+0 }
  ' "$plan")"

  if [ "${count:-0}" -eq 0 ] 2>/dev/null; then
    err "[S6] 段内没有找到任何 bash 围栏块，harness 为空。"
    return 2
  fi
  chmod +x "$HARNESS_DIR"/[0-9][0-9]_*.sh 2>/dev/null
  log "已提取 $count 个自检脚本 → $HARNESS_DIR/"
}

# ---------- Harness 执行 ----------
# 判定规则（机器可判定，杜绝模型自评）:
#   PASS = 退出码 0 且输出含 ≥1 行 [PASS] 且不含任何 [FAIL]
run_harness() {
  local total=0 passed=0 failed=0 f
  for f in "$HARNESS_DIR"/[0-9][0-9]_*.sh; do
    [ -e "$f" ] || break
    total=$((total+1))
    local out; out="$(bash "$f" 2>&1)"; local rc=$?
    printf '%s\n' "$out" > "${f%.sh}.log"
    local has_pass=0 has_fail=0
    printf '%s\n' "$out" | grep -q '\[PASS\]' && has_pass=1
    printf '%s\n' "$out" | grep -q '\[FAIL\]' && has_fail=1
    if [ "$rc" -eq 0 ] && [ "$has_pass" -eq 1 ] && [ "$has_fail" -eq 0 ]; then
      passed=$((passed+1)); printf '[PASS] %s\n' "$(basename "$f")"
    else
      failed=$((failed+1)); printf '[FAIL] %s (exit=%s)\n' "$(basename "$f")" "$rc"
      printf '%s\n' "$out" | sed 's/^/       | /' | tail -15
    fi
  done
  log "自检汇总: $passed/$total passed, $failed failed"
  update_status "harness_total=$total" "harness_passed=$passed" "harness_failed=$failed"
  [ "$total" -gt 0 ] || die "harness 目录为空，请先 plan 或 extract" 4
  if [ "$failed" -eq 0 ]; then
    update_status "status=CHECKED_PASS" "exit_code=0"
    return 0
  else
    update_status "status=CHECKED_FAIL" "exit_code=1"
    return 1
  fi
}

# ---------- run.status ----------
update_status() {  # 追加或覆盖同 key 的行
  local kv k v tmp
  mkdir -p "$OUT_DIR"
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    tmp="$STATUS_FILE.tmp"
    { grep -v "^${k}=" "$STATUS_FILE" 2>/dev/null; printf '%s=%s\n' "$k" "$v"; } > "$tmp"
    mv "$tmp" "$STATUS_FILE"
  done
}

# ---------- 规划 ----------
build_prompt() {  # $1 = 任务文件
  cat <<PROMPT
You are the PLANNER for a coding task. Your job: compile a fool-proof execution plan.
You may explore the repository READ-ONLY to ground the plan in reality. DO NOT modify anything. DO NOT execute the task yourself.

Output RAW Markdown only (no outer code fence), starting with "# PLAN". It MUST contain exactly these eight section headers, copied VERBATIM (the "## [Sn]" prefix must match exactly, character for character):

## [S1] 傻瓜级步骤 Fool-proof Steps
## [S2] 工具预调清单 Tool Preflight
## [S3] 知识库检索清单 Knowledge Retrieval
## [S4] 技术细节 Technical Details
## [S5] 模具清单 Templates
## [S6] 自检 Harness Self-check Harness
## [S7] 成功标准 Success Criteria
## [S8] 风险与回滚 Risks & Rollback

Section requirements:
- [S1] 傻瓜级步骤: numbered, copy-paste level detail. Every command written out. No "as before" references. Include verification after each step where possible.
- [S2] 工具预调清单: every tool/command the executor must preflight (existence, version, login state), each with the exact check command.
- [S3] 知识库检索清单: files/dirs/docs in this repo the executor MUST read before touching code, each with path and what to look for.
- [S4] 技术细节: schemas, APIs, data structures, edge cases, platform quirks (the executor is ZCode running on the user's OS — check it).
- [S5] 模具清单: ready-to-paste code templates/stencils the executor should reuse instead of inventing.
- [S6] 自检 Harness: AT LEAST ONE runnable bash code block (fence info string may carry a name: \`\`\`bash harness=smoke). Scripts must: be idempotent, run from the repo root, work on Git Bash/Linux/macOS (POSIX-ish, no bash-4-only features), and for every check echo exactly "[PASS] <what>" or "[FAIL] <what>". A script passes only if exit code 0 AND output has >=1 [PASS] line AND no [FAIL] line.
- [S7] 成功标准: machine-judgeable criteria, each mapping 1:1 to a harness check. No "looks good" criteria.
- [S8] 风险与回滚: top risks + concrete rollback (commands or git ops).

Working directory: $(pwd)
OS: $(uname -s) ($(uname -m))

=== TASK ===
$(cat "$1")
=== END TASK ===

Respond with the plan Markdown only.
PROMPT
}

strip_fence() {  # 模型偶尔会把整份方案包进 ```markdown 围栏，剥掉最外层
  local in="$1" out="$2"
  awk '
    BEGIN { started=0 }
    { lines[NR]=$0 }
    END {
      first=0; last=0
      for (i=1;i<=NR;i++) if (lines[i] !~ /^[[:space:]]*$/) { if (!first) first=i; last=i }
      if (first && lines[first] ~ /^```/ && lines[last] ~ /^```/) { for(i=first+1;i<=last-1;i++) print lines[i] }
      else { for(i=first;i<=last;i++) print lines[i] }
    }
  ' "$in" > "$out"
}

do_plan() {
  local taskfile="${1:-}"
  [ -n "$taskfile" ] && [ -f "$taskfile" ] || die "请提供任务描述文件，如: ask_astra.sh plan task.md" 4
  mkdir -p "$OUT_DIR" "$HARNESS_DIR"

  detect_proxy
  check_codex

  local prompt_file="$OUT_DIR/prompt.txt"
  build_prompt "$taskfile" > "$prompt_file"

  local user_cfg_flag=""
  [ "$ZAP_USE_USER_CONFIG" = "1" ] || user_cfg_flag="--ignore-user-config"

  local runner=()
  if command -v timeout >/dev/null 2>&1; then runner=(timeout "$ZAP_TIMEOUT"); fi

  log "调用 $ZAP_MODEL 编译方案（effort=$ZAP_EFFORT，最长 ${ZAP_TIMEOUT}s）…"
  local rc=0
  "${runner[@]}" "$ZAP_BIN" exec \
    $user_cfg_flag \
    -m "$ZAP_MODEL" \
    -s "$ZAP_SANDBOX" \
    --skip-git-repo-check \
    -c "model_reasoning_effort=\"$ZAP_EFFORT\"" \
    --color never \
    -C "$(pwd)" \
    -o "$RAW_FILE" \
    - < "$prompt_file" > "$RUN_LOG" 2>&1 || rc=$?

  local session_id
  session_id="$(grep -oE 'session id: [0-9A-Za-z-]+' "$RUN_LOG" | head -1 | sed 's/session id: //')"
  update_status "status=PLANNED" "timestamp=$(now_iso)" \
    "planner=zcode-skill-astra-planner v$ZAP_VERSION" \
    "planner_backend=codex-cli $(codex_version)" \
    "model=$ZAP_MODEL" "effort=$ZAP_EFFORT" "sandbox=$ZAP_SANDBOX" \
    "task_file=$taskfile" "session_id=${session_id:-}"

  if [ "$rc" -ne 0 ]; then
    update_status "status=PLAN_FAILED" "exit_code=$rc"
    err "Codex 调用失败（exit=$rc）。常见原因:"
    err "  - 未登录          → codex login"
    err "  - 需要代理        → ZAP_PROXY=http://127.0.0.1:7897"
    err "  - 版本过旧        → npm install -g @openai/codex@latest"
    err "  - 模型不可用      → ZAP_MODEL=<你的模型> 覆盖"
    err "run.log 末尾:"
    tail -8 "$RUN_LOG" | sed 's/^/  | /' >&2
    return 3
  fi

  # 剥掉可能的外层围栏 → PLAN.md
  strip_fence "$RAW_FILE" "$PLAN_FILE"

  update_status "plan=$PLAN_FILE" "plan_sha256=$(sha256_of "$PLAN_FILE")" "exit_code=0"

  # 契约校验 + harness 提取
  if ! validate_plan "$PLAN_FILE"; then
    update_status "contract=BROKEN" "status=CONTRACT_BROKEN"
    die "方案契约校验失败，请重跑 plan（或手工补齐八段后 validate）" 2
  fi
  update_status "contract=OK"
  extract_harness "$PLAN_FILE" || die "harness 提取失败：[S6] 段缺少 bash 围栏块" 2

  log "完成: $PLAN_FILE + $(ls "$HARNESS_DIR" 2>/dev/null | grep -c '\.sh$') 个自检脚本"
  log "执行者照 S1→S5 动工，完成后运行: $0 check"
}

# ---------- 入口 ----------
main() {
  local cmd="${1:-help}"; shift 2>/dev/null || true
  case "$cmd" in
    plan)            do_plan "${1:-}" ;;
    --check|check)   [ -d "$HARNESS_DIR" ] || extract_harness "$PLAN_FILE"; run_harness ;;
    --validate-only|validate) validate_plan "${1:-$PLAN_FILE}" ;;
    --extract|extract)       extract_harness "${1:-$PLAN_FILE}" ;;
    -h|--help|help)
      sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *)
      # 兼容: 直接传任务文件 = plan
      if [ -f "$cmd" ]; then do_plan "$cmd"
      else die "未知命令: $cmd（可用: plan <taskfile> | check | validate | extract）" 4; fi ;;
  esac
}

main "$@"
