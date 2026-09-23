#!/bin/zsh
# 蜂群上报一键验证：证明「App 这条形状的请求」在真实中台上能 200 且真进账本。
#
# 用法：
#   TOKEN=<操作员令牌> ./verify-swarm.sh                     # 默认打生产 https://ytd.rickyke.com
#   TOKEN=<任意值> ./verify-swarm.sh https://xxx.trycloudflare.com   # 打我们自己起的实例
#
# 契约（蜂群侧 2026-09-24 口述 + server.mjs 代码事实）：
#   POST /api/stimuli  Authorization: Bearer <token>
#   body { runId, id, source:{kind:"device",adapter:"glasses"}, intensity }
#   runId 从 GET /api/snapshot 取；atBeat 省略，服务端自动落到最早未封口的拍。
# 退出码：0 全绿 / 1 有失败。

set -u
BASE="${1:-https://ytd.rickyke.com}"
TOKEN="${TOKEN:-}"

echo "中台: $BASE"
echo "令牌: $([[ -n "$TOKEN" ]] && echo '已提供' || echo '未提供')"
echo

fail=0

echo "== 1/4 探活 =="
health=$(curl -sS --max-time 15 "$BASE/api/health" 2>&1) || { echo "  失败: $health"; fail=1; }
echo "  $health"

echo "== 2/4 取 runId =="
snap=$(curl -sS --max-time 20 "$BASE/api/snapshot" 2>&1) || { echo "  失败: $snap"; fail=1; }
runId=$(printf '%s' "$snap" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("runId",""))' 2>/dev/null)
runStatus=$(printf '%s' "$snap" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("status",""))' 2>/dev/null)
if [[ -z "$runId" || "$runStatus" != "running" ]]; then
  echo "  失败：拿不到 runId（中台可能没在演出）。原始返回前 200 字符："
  printf '%s' "$snap" | head -c 200; echo
  fail=1
else
  echo "  runId=$runId  status=$runStatus"
fi

if [[ $fail -eq 0 ]]; then
  echo "== 3/4 上报（最小形状，adapter=glasses） =="
  sid="luma-verify-$(date +%s)"
  headers=(-H "Content-Type: application/json")
  [[ -n "$TOKEN" ]] && headers+=(-H "Authorization: Bearer $TOKEN")
  code=$(curl -sS --max-time 20 -o /tmp/verify-swarm-resp.json -w '%{http_code}' -X POST "$BASE/api/stimuli" \
    "${headers[@]}" \
    -d "{\"runId\":\"$runId\",\"id\":\"$sid\",\"source\":{\"kind\":\"device\",\"adapter\":\"glasses\"},\"intensity\":0.5}" 2>&1) || { echo "  请求失败: $code"; fail=1; }
  echo "  HTTP $code"
  head -c 200 /tmp/verify-swarm-resp.json 2>/dev/null; echo
  [[ "$code" == 2* ]] || { echo "  ❌ 上报没过（401=令牌不对/没填，400=形状不对）"; fail=1; }

  echo "== 4/4 回查：这条刺激是不是真进了状态 =="
  curl -sS --max-time 20 "$BASE/api/snapshot" | python3 -c "
import json,sys
sid='$sid'
d=json.load(sys.stdin)
st=(d.get('music') or {}).get('stimuli') or []
hit=[s for s in st if s.get('id')==sid]
print('  stimuli 条数:', len(st))
if len(hit)==1 and hit[0].get('source')=={'kind':'device','adapter':'glasses'}:
    print('  ✅ 命中:', json.dumps(hit[0], ensure_ascii=False))
else:
    print('  ❌ music.stimuli 未确认设备刺激', sid)
    sys.exit(1)
" || fail=1
fi

echo
if [[ $fail -eq 0 ]]; then echo "结论：全绿。这条链路是验证过的，不是祈祷。"; else echo "结论：有失败项，照上面输出处理，别硬说成功。"; fi
exit $fail
