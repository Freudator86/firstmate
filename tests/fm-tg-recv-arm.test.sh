#!/usr/bin/env bash
# tests/fm-tg-recv-arm.test.sh - direct Telegram receiver arm wrapper behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ARM="$ROOT/bin/fm-tg-recv-arm.sh"
fm_test_tmproot TMP_ROOT fm-tg-recv-arm-tests

home="$TMP_ROOT/home"
mkdir -p "$home/config" "$home/state"

out=$(FM_HOME="$home" "$ARM" 2>&1)
case "$out" in
  *'telegram receiver: inactive (config/telegram.env absent)'*) : ;;
  *) fail "expected inactive output without telegram.env, got: $out" ;;
esac

printf 'BOT_TOKEN=x\nCHAT_ID=y\n' > "$home/config/telegram.env"
out=$(FM_HOME="$home" "$ARM" 2>&1)
case "$out" in
  *'telegram receiver: FAILED - config/fm-tg-recv.sh missing or not executable'*) : ;;
  *) fail "expected missing receiver failure, got: $out" ;;
esac

cat > "$home/config/fm-tg-recv.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/receiver.pid"
sleep 0.2
printf 'CAPTAIN-TELEGRAM: test\n'
SH
chmod +x "$home/config/fm-tg-recv.sh"

out=$(FM_HOME="$home" "$ARM" 2>&1)
case "$out" in
  *'telegram receiver: started pid='*'CAPTAIN-TELEGRAM: test'*) : ;;
  *) fail "expected started output and receiver payload, got: $out" ;;
esac

cat > "$home/config/fm-tg-recv.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/receiver.pid"
while [ ! -f "$FM_HOME/state/stop-receiver" ]; do
  sleep 0.1
done
SH
chmod +x "$home/config/fm-tg-recv.sh"
rm -f "$home/state/receiver.pid" "$home/state/stop-receiver"

FM_HOME="$home" "$ARM" > "$home/state/arm1.out" 2>&1 &
arm1=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$home/state/receiver.pid" ] && break
  sleep 0.1
done
[ -s "$home/state/receiver.pid" ] || fail "receiver did not start"

FM_HOME="$home" "$ARM" > "$home/state/arm2.out" 2>&1 &
arm2=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q 'telegram receiver: attached pid=' "$home/state/arm2.out" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
grep -q 'telegram receiver: attached pid=' "$home/state/arm2.out" || fail "second arm did not attach"

touch "$home/state/stop-receiver"
wait "$arm1"
wait "$arm2"
