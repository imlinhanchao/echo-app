#!/usr/bin/env bash
# Echo 播放链路全链路验证脚本（宿主机侧）：
#   配 zlib 账号 → 搜索 → 下载入库 → 转换首章（edge-tts 最快）→ 轮询任务完成 → 输出可播有声书 ID。
#
# 用法（凭据建议用临时小号；只提交给本机 echo-service，AES-256-GCM 落库）：
#   ZLIB_EMAIL=you@example.com ZLIB_PASSWORD='secret' ./scripts/verify-playback-chain.sh
#
# 可选环境变量：
#   ECHO_EMAIL / ECHO_PASSWORD  App 测试账号（默认为模拟器验证账号）
#   QUERY       搜索关键词（默认 老人与海）
#   MODEL       TTS 模型（默认 edge-tts，最快）
#   VOICE       音色（留空取模型第一个可用音色）
#   CHAPTERS    转换章节列表，逗号分隔（默认 0，仅首章，控制转换时长）
#   BASE        echo-service 地址（默认 http://127.0.0.1:8090）
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:8090}"
ECHO_EMAIL="${ECHO_EMAIL:-echo-emu-20261120@example.com}"
ECHO_PASSWORD="${ECHO_PASSWORD:-EchoTest2026!}"
ZLIB_EMAIL="${ZLIB_EMAIL:?需要 ZLIB_EMAIL（zlib 测试账号邮箱）}"
ZLIB_PASSWORD="${ZLIB_PASSWORD:?需要 ZLIB_PASSWORD（zlib 测试账号密码）}"
QUERY="${QUERY:-老人与海}"
MODEL="${MODEL:-edge-tts}"
VOICE="${VOICE:-}"
CHAPTERS="${CHAPTERS:-0}"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

step "1/7 App 测试账号登录换 Token"
TOKEN=$(curl -fsS -X POST "$BASE/api/auth/token" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ECHO_EMAIL\",\"password\":\"$ECHO_PASSWORD\"}" | jq -r '.token')
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || die "登录失败（检查 ECHO_EMAIL/ECHO_PASSWORD）"
api() { curl -fsS -H "Authorization: Bearer $TOKEN" "$@"; }
echo "token: ${TOKEN:0:12}..."

step "2/7 配置 zlib 账号（password 模式，服务端验证并返回配额）"
ACCOUNT=$(curl -fsS -X PUT "$BASE/api/providers/zlib/account" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"mode\":\"password\",\"email\":\"$ZLIB_EMAIL\",\"password\":\"$ZLIB_PASSWORD\"}")
echo "$ACCOUNT" | jq -r '.account | "status=\(.status) email=\(.email) 配额=\(.daily_used)/\(.daily_limit) 剩余=\(.daily_remaining)"'
[ "$(echo "$ACCOUNT" | jq -r '.account.status')" = "ok" ] || die "zlib 账号验证未通过（检查凭据或镜像可用性）"

step "3/7 搜索「$QUERY」并选取首个 EPUB 结果"
SEARCH=$(api -G "$BASE/api/search" --data-urlencode "q=$QUERY" --data-urlencode "ext=EPUB")
BOOK_REF=$(echo "$SEARCH" | jq -r '.books[0].ref')
BOOK_TITLE=$(echo "$SEARCH" | jq -r '.books[0].title')
[ -n "$BOOK_REF" ] && [ "$BOOK_REF" != "null" ] || die "搜索无结果（换个 QUERY 再试）"
echo "选中：$BOOK_TITLE ($BOOK_REF)"

step "4/7 发起下载任务并等待完成"
JOB=$(curl -fsS -X POST "$BASE/api/library/download" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"provider\":\"zlib\",\"ref\":\"$BOOK_REF\"}")
JOB_ID=$(echo "$JOB" | jq -r '.job.id')
echo "下载任务 #$JOB_ID"
for i in $(seq 1 40); do
  J=$(api "$BASE/api/jobs/$JOB_ID")
  S=$(echo "$J" | jq -r '.job.status')
  echo "  [$((i*5))s] status=$S progress=$(echo "$J" | jq -r '.job.progress')%"
  if [ "$S" = "done" ]; then break; fi
  if [ "$S" = "failed" ] || [ "$S" = "cancelled" ]; then
    die "下载失败：$(echo "$J" | jq -r '.job.error')"
  fi
  sleep 5
done
[ "$S" = "done" ] || die "下载超时"
BOOK_ID=$(echo "$J" | jq -r '.job.ref_id')
echo "入库书籍 #$BOOK_ID"

step "5/7 解析章节并选择 TTS 音色"
CHAPTER_COUNT=$(api "$BASE/api/library/$BOOK_ID/chapters" | jq '.chapters | length')
echo "全书 $CHAPTER_COUNT 章，转换章节：[$CHAPTERS]"
[ "$CHAPTER_COUNT" -gt 0 ] || die "章节解析失败（非 EPUB？）"
if [ -z "$VOICE" ]; then
  VOICE=$(api -G "$BASE/api/tts/voices" --data-urlencode "model=$MODEL" | jq -r '.voices[0].id')
  echo "使用模型 $MODEL 默认音色：$VOICE"
fi

step "6/7 发起转换任务并等待完成（edge-tts 约 1-3 分钟）"
JOB2=$(curl -fsS -X POST "$BASE/api/library/$BOOK_ID/audiobooks" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"voice\":\"$VOICE\",\"speed\":1.0,\"chapters\":[$CHAPTERS]}")
JOB2_ID=$(echo "$JOB2" | jq -r '.job.id')
echo "转换任务 #$JOB2_ID"
for i in $(seq 1 72); do
  J2=$(api "$BASE/api/jobs/$JOB2_ID")
  S2=$(echo "$J2" | jq -r '.job.status')
  echo "  [$((i*5))s] status=$S2 progress=$(echo "$J2" | jq -r '.job.progress')%"
  if [ "$S2" = "done" ]; then break; fi
  if [ "$S2" = "failed" ] || [ "$S2" = "cancelled" ]; then
    die "转换失败：$(echo "$J2" | jq -r '.job.error')"
  fi
  sleep 5
done
[ "$S2" = "done" ] || die "转换超时"

step "7/7 就绪：有声书已可播"
AUDIO_ID=$(echo "$J2" | jq -r '.job.ref_id')
api "$BASE/api/audiobooks" | jq -r --argjson id "$AUDIO_ID" \
  '.audiobooks[] | select(.id == $id) | "有声书 #\(.id) · \(.book_title) · \(.model)/\(.voice) · 时长 \(.duration_s)s · \(.status)"'
echo
echo "下一步（模拟器上点播验证锁屏播控）："
echo "  adb shell am force-stop org.hancel.echo && adb shell am start -n org.hancel.echo/org.hancel.echo.MainActivity"
echo "  → 书架 Tab 点击「$BOOK_TITLE」播放按钮 → dumpsys media_session 查看锁屏元数据"
