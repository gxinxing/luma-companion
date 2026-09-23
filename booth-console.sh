#!/bin/bash
# booth-console.sh — 在笔记本上起一份真的 aria-swarm，让 iPhone 走场馆局域网直连。
#
# 这是「拿不到生产操作员令牌」时的乙档方案：跑的是 aria-swarm 真代码（不是 mock），
# 令牌由我们自己设。演示时必须如实说明这是我们自己的实例，不能冒充主控那场。
#
# 一个必须知道的事实：runtime 的 nextBee() 有道门 —— 蜂只在自己局部窗口里出现
# 刺激或痕迹时才发起决策。**没有刺激就不会调模型**，modelCalls 会一直是 0。
# 所以「眼镜没连上」不等于「蜂群不思考」：观众触屏/挥手是免令牌的真入口，
# 一样能把蜂群 AI 点着。本脚本自检时会自己注入 6 条刺激当扳机。
#
# 用法（在笔记本上，连好场馆 Wi-Fi 之后）：
#   ./booth-console.sh                 # 起服务 + 自检 + 打印手机要填的地址
#   ./booth-console.sh /path/to/aria   # 指定 aria-swarm 目录
#   ARIA_OPERATOR_TOKEN=xxx ./booth-console.sh
#   ./booth-console.sh --check-only    # 服务已在跑，只做自检
#
# 退出：Ctrl-C。脚本会杀掉它自己拉起的 node 进程。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARIA_DIR="${ARIA_DIR:-$SCRIPT_DIR/../aria-swarm-local-e2e}"
PORT="${PORT:-4173}"
TOKEN="${ARIA_OPERATOR_TOKEN:-booth-2026}"
CHECK_ONLY=0
[ "${1:-}" = "--check-only" ] && CHECK_ONLY=1
[ "${1:-}" = "--help" ] && { sed -n '2,20p' "$0"; exit 0; }
if [ $CHECK_ONLY -eq 0 ] && [ -n "${1:-}" ] && [ "${1:0:2}" != "--" ]; then ARIA_DIR="$1"; fi

# 场馆 Wi-Fi 的 IP。macOS 上 Wi-Fi 一般是 en0，插了有线转接时会跑到别的口上。
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null)"
[ -z "$LAN_IP" ] && LAN_IP="$(ipconfig getifaddr en1 2>/dev/null)"
[ -z "$LAN_IP" ] && LAN_IP="$(ipconfig getifaddr en2 2>/dev/null)"

if [ -z "$LAN_IP" ]; then
  echo "!! 拿不到局域网 IP —— 笔记本没连上 Wi-Fi，手机将无从访问。先连网再跑这个脚本。"
  exit 1
fi

if [ ! -f "$ARIA_DIR/server.mjs" ]; then
  echo "!! $ARIA_DIR 里没有 server.mjs。传目录作为第一个参数，或设 ARIA_DIR。"
  exit 1
fi

# 模型凭据只从钥匙串读，不写进文件、不进命令行历史。
TYPESAFE_API_KEY="$(security find-generic-password -s aria-swarm.typesafe -w 2>/dev/null || true)"

BASE="http://$LAN_IP:$PORT"
NODE_PID=""

cleanup() {
  if [ -n "${NODE_PID:-}" ] && kill -0 "$NODE_PID" 2>/dev/null; then
    echo ""
    echo "停下 aria-swarm (pid ${NODE_PID})..."
    kill "$NODE_PID" 2>/dev/null
    NODE_PID=""   # INT 和 EXIT 都会触发 trap，清掉避免重复打印
  fi
}
trap cleanup EXIT INT TERM

if [ $CHECK_ONLY -eq 0 ]; then
  echo "起 aria-swarm：$ARIA_DIR"
  echo "  端口 $PORT / 绑定 0.0.0.0 / 局域网地址 $BASE"
  echo ""
  (
    cd "$ARIA_DIR" || exit 1
    # exec 让子 shell 被 node 替换，这样 $! 就是 node 自己的 pid，停止时能直接杀到。
    exec env \
      PORT="$PORT" \
      ARIA_BIND="0.0.0.0" \
      ARIA_OPERATOR_TOKEN="$TOKEN" \
      ARIA_PUBLIC_HOSTS="$LAN_IP:$PORT,localhost:$PORT,127.0.0.1:$PORT" \
      ARIA_AUTOSTART="1" \
      TYPESAFE_API_KEY="$TYPESAFE_API_KEY" \
      TYPESAFE_INPUT_USD_PER_MILLION="${TYPESAFE_INPUT_USD_PER_MILLION:-0.042}" \
      node server.mjs
  ) &
  NODE_PID=$!

  for _ in $(seq 1 40); do
    sleep 0.5
    if curl -s -o /dev/null "http://127.0.0.1:$PORT/api/health" 2>/dev/null; then break; fi
  done
fi

echo ""
echo "——— 自检 ———"
pass=0; fail=0
check() { # check <说明> <实际> <期望>
  if [ "$2" = "$3" ]; then echo "  ok   $1 ($2)"; pass=$((pass+1));
  else echo "  FAIL $1 — 期望 $3，实际 $2"; fail=$((fail+1)); fi
}

code() { curl -s -o /dev/null -w "%{http_code}" "$@" 2>/dev/null || echo "000"; }

check "本机 health"        "$(code "http://127.0.0.1:$PORT/api/health")" "200"
# 这一条最关键：trustedRequest 只放行 localhost 和 ARIA_PUBLIC_HOSTS，
# 手机用局域网 IP 打过来若是 403，说明 ARIA_PUBLIC_HOSTS 没带上这个 IP。
check "手机路径 health"    "$(code "http://$LAN_IP:$PORT/api/health")" "200"
check "无令牌上报被拒"     "$(code -X POST -H 'content-type: application/json' -d '{}' "$BASE/api/stimuli")" "401"

RUN_ID="$(curl -s "http://127.0.0.1:$PORT/api/snapshot" | sed -n 's/.*"runId":"\([^"]*\)".*/\1/p' | head -1)"
if [ -z "$RUN_ID" ]; then
  echo "  FAIL 没有正在运行的场次 —— ARIA_AUTOSTART 没生效，去演出页手动开一场"
  fail=$((fail+1))
else
  echo "  ok   场次在跑 runId=${RUN_ID:0:8}…"
  pass=$((pass+1))
  CHECK_CODE="$(code -X POST -H 'content-type: application/json' \
    -H "authorization: Bearer $TOKEN" \
    -d "{\"runId\":\"$RUN_ID\",\"id\":\"booth-selfcheck-$RANDOM\",\"source\":{\"kind\":\"device\",\"adapter\":\"glasses\"},\"intensity\":0.5}" \
    "$BASE/api/stimuli")"
  check "带令牌上报" "$CHECK_CODE" "200"
fi

SNAP="$(curl -s "http://127.0.0.1:$PORT/api/snapshot")"
if echo "$SNAP" | grep -q '"apiConfigured":true'; then
  echo "  ok   模型已配置"
  pass=$((pass+1))
else
  echo "  FAIL apiConfigured 不是 true —— TYPESAFE_API_KEY 没读到（钥匙串 aria-swarm.typesafe 不在？）"
  fail=$((fail+1))
fi

echo ""
echo "——— 手机要填的两行（App「设备」tab → 蜂群中台）———"
echo "  中台地址   $BASE"
echo "  操作员令牌 $TOKEN"
echo ""
echo "——— 真实模型调用（这条比眼镜重要）———"
# runtime 的 nextBee() 有一道门：蜂只在自己局部窗口里出现刺激或痕迹时才发起决策。
# 没刺激就不会调模型 —— 所以自检必须先喂刺激，否则一定看到 modelCalls=0 并误判成网络故障。
echo "  注入 6 条刺激作为扳机（会真实消耗少量模型额度）..."
for i in 1 2 3 4 5 6; do
  curl -s -o /dev/null -X POST -H 'content-type: application/json' \
    -H "authorization: Bearer $TOKEN" \
    -d "{\"runId\":\"$RUN_ID\",\"id\":\"booth-trigger-$RANDOM-$i\",\"source\":{\"kind\":\"device\",\"adapter\":\"glasses\"},\"intensity\":0.9}" \
    "$BASE/api/stimuli" 2>/dev/null
  sleep 1
done

CALLS=0
for _ in $(seq 1 9); do
  sleep 10
  CALLS="$(curl -s "http://127.0.0.1:$PORT/api/snapshot" | sed -n 's/.*"modelCalls":\([0-9]*\).*/\1/p' | head -1)"
  [ -z "$CALLS" ] && CALLS=0
  [ "$CALLS" -ge 1 ] 2>/dev/null && break
  echo "  还在等蜂发起决策...（已注入刺激，modelCalls=$CALLS）"
done

if [ "${CALLS:-0}" -ge 1 ] 2>/dev/null; then
  echo "  ok   蜂真的在思考：modelCalls=$CALLS —— 「另一位 Agent 复核」有真实模型支撑。"
else
  echo "  FAIL 刺激发了，但模型一次都没调（modelCalls=${CALLS:-未采集}）"
  FAILED="$(grep -c "model_call_failed" "$ARIA_DIR/data/ledger.jsonl" 2>/dev/null || echo 0)"
  REQUESTED="$(grep -c "provider.requested" "$ARIA_DIR/data/ledger.jsonl" 2>/dev/null || echo 0)"
  echo "       provider.requested=$REQUESTED / model_call_failed=$FAILED"
  if [ "${REQUESTED:-0}" -ge 1 ] && [ "${FAILED:-0}" -ge 1 ]; then
    echo "       请求发出去了但失败 —— 多半是出不了网。开 Clash 的增强/TUN 全局模式后重跑"
    echo "       （Node 的 fetch 不读 HTTP_PROXY，只开普通代理没用）。"
  else
    echo "       连请求都没发出 —— 检查场次是否在跑、刺激是否被接受（看上面 200 那几行）。"
  fi
  echo "       不要掩饰：页面会显示 aiDisabled，蜂群最核心的复核门会失去真实模型支撑。"
fi

echo ""
echo "自检 $pass 项通过 / $fail 项失败。"
if [ $CHECK_ONLY -eq 0 ]; then
  echo ""
  if [ -n "${NODE_PID:-}" ]; then
    echo "服务在跑（pid ${NODE_PID}）。Ctrl-C 停止。"
    wait "${NODE_PID}" 2>/dev/null
  else
    echo "服务已在跑（没能捕获 pid）。Ctrl-C 结束本脚本后，用 lsof -ti:$PORT | xargs kill 停掉。"
    while true; do sleep 60; done
  fi
fi
