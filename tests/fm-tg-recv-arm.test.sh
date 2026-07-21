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
owner_leaks=$(find "$home/state" -maxdepth 1 -type d -name '.tg-recv.lock.owner.*' -print)
[ -z "$owner_leaks" ] || fail "receiver arm left lock owner directories behind: $owner_leaks"

cat > "$home/config/fm-tg-recv.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'CAPTAIN-TELEGRAM: already pending\n'
sleep 0.1
SH
chmod +x "$home/config/fm-tg-recv.sh"
fakebin="$TMP_ROOT/fakebin"
mkdir -p "$fakebin"
cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
sleep 0.05
exit 1
SH
chmod +x "$fakebin/ps"

out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ARM" 2>&1)
case "$out" in
  *'CAPTAIN-TELEGRAM: already pending'*)
    case "$out" in
      *'could not identify receiver process'*) fail "fast-exit receiver output was replayed with an identity failure: $out" ;;
      *) : ;;
    esac
    ;;
  *) fail "expected fast-exit receiver payload, got: $out" ;;
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

cat > "$home/config/fm-tg-recv.sh" <<'SH'
#!/usr/bin/env bash
set -u
trap ':' TERM
printf '%s\n' "$$" > "$FM_HOME/state/receiver.pid"
printf 'start\n' >> "$FM_HOME/state/receiver.starts"
while [ ! -f "$FM_HOME/state/stop-receiver" ]; do
  sleep 0.1
done
printf 'CAPTAIN-TELEGRAM: after abandoned wrapper\n'
SH
chmod +x "$home/config/fm-tg-recv.sh"
rm -f "$home/state/receiver.pid" "$home/state/receiver.starts" "$home/state/stop-receiver"

FM_HOME="$home" "$ARM" > "$home/state/term-arm1.out" 2>&1 &
term_arm1=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$home/state/receiver.pid" ] && break
  sleep 0.1
done
[ -s "$home/state/receiver.pid" ] || fail "signal cleanup receiver did not start"
receiver_pid=$(cat "$home/state/receiver.pid")

kill -TERM "$term_arm1"
wait "$term_arm1" 2>/dev/null
fm_pid_alive=$(FM_HOME="$home" bash -c '. "$1"; fm_pid_alive "$2"; printf "%s\n" "$?"' sh "$ROOT/bin/fm-wake-lib.sh" "$receiver_pid")
[ "$fm_pid_alive" = 0 ] || fail "signal cleanup killed slow receiver before bounded wait check"
[ -L "$home/state/.tg-recv.lock" ] || fail "signal cleanup dropped live receiver lock"
capture_path=$(cat "$home/state/.tg-recv.lock/output-path" 2>/dev/null || true)
[ -n "$capture_path" ] || fail "signal cleanup did not preserve output capture metadata"
[ -e "$capture_path" ] || fail "signal cleanup removed live receiver output capture"

FM_HOME="$home" "$ARM" > "$home/state/term-arm2.out" 2>&1 &
term_arm2=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q 'telegram receiver: attached pid=' "$home/state/term-arm2.out" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
grep -q 'telegram receiver: attached pid=' "$home/state/term-arm2.out" || fail "second arm did not attach after signal cleanup: $(cat "$home/state/term-arm2.out")"
[ "$(wc -l < "$home/state/receiver.starts")" -eq 1 ] || fail "signal cleanup allowed duplicate receiver start"
touch "$home/state/stop-receiver"
wait "$term_arm2"
grep -q 'CAPTAIN-TELEGRAM: after abandoned wrapper' "$home/state/term-arm2.out" || fail "attached arm did not relay abandoned receiver output: $(cat "$home/state/term-arm2.out")"

rm -f "$home/state/.tg-recv.lock"
rm -rf "$home/state"/.tg-recv.lock.owner.*
sleep 5 &
race_pid=$!
race_identity=$(FM_HOME="$home" bash -c '. "$1"; fm_pid_identity "$2"' sh "$ROOT/bin/fm-wake-lib.sh" "$race_pid")
race_owner="$home/state/.tg-recv.lock.owner.race"
mkdir "$race_owner"
printf '%s\n' "$race_pid" > "$race_owner/pid"
ln -s "$race_owner" "$home/state/.tg-recv.lock"
(
  sleep 0.3
  printf '%s\n' "$home" > "$race_owner/fm-home"
  printf '%s\n' "$race_identity" > "$race_owner/pid-identity"
  printf '%s\n' "$home/config/fm-tg-recv.sh" > "$race_owner/receiver-path"
) &
publisher=$!
FM_TG_RECV_ATTACH_CONFIRM_TIMEOUT=3 FM_TG_RECV_ATTACH_POLL=0.1 FM_HOME="$home" "$ARM" > "$home/state/race.out" 2>&1 &
race_arm=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q 'telegram receiver: attached pid=' "$home/state/race.out" 2>/dev/null; then
    break
  fi
  sleep 0.2
done
grep -q 'telegram receiver: attached pid=' "$home/state/race.out" || fail "second arm did not wait for receiver lock metadata: $(cat "$home/state/race.out")"
kill "$race_pid" 2>/dev/null || true
wait "$race_pid" 2>/dev/null || true
wait "$publisher"
wait "$race_arm"
