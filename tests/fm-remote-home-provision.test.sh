#!/usr/bin/env bash
# fm-remote-home-provision.sh remote-root clone behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-home-provision)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
cleanup() { rm -rf -- "$TMP_ROOT"; }
trap cleanup EXIT

encode() { base64 | tr -d '\n'; }

fakebin=$(fm_fakebin "$TMP_ROOT/fake")
remote_root="$TMP_ROOT/root-owned-firstmate"
remote_home="$TMP_ROOT/remote-home"
mkdir -p "$remote_root/.git" "$remote_root/bin" "$remote_root/data" "$remote_root/state" "$remote_root/config" "$remote_root/projects"
printf 'root fixture\n' > "$remote_root/AGENTS.md"
cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
set -eu
log=${FM_FAKE_GIT_LOG:?}
required=${FM_FAKE_SAFE_DIRECTORY:?}
printf 'args=%s\n' "$*" >> "$log"
printf 'count=%s key0=%s value0=%s key1=%s value1=%s\n' \
  "${GIT_CONFIG_COUNT:-}" "${GIT_CONFIG_KEY_0:-}" "${GIT_CONFIG_VALUE_0:-}" \
  "${GIT_CONFIG_KEY_1:-}" "${GIT_CONFIG_VALUE_1:-}" >> "$log"
case "$*" in
  clone\ --quiet\ --\ *)
    src=${4:?}
    dest=${5:?}
    if [ "$src/.git" = "$required" ]; then
      case "${GIT_CONFIG_VALUE_0:-}|${GIT_CONFIG_VALUE_1:-}" in
        *"$required"*) ;;
        *) printf 'missing safe.directory for %s\n' "$required" >&2; exit 128 ;;
      esac
    fi
    mkdir -p "$dest/bin"
    printf 'clone fixture\n' > "$dest/AGENTS.md"
    exit 0
    ;;
esac
printf 'unexpected git call: %s\n' "$*" >&2
exit 99
SH
chmod +x "$fakebin/git"

charter="$TMP_ROOT/charter.md"
printf 'Remote charter\n' > "$charter"
manifest="$TMP_ROOT/manifest"
{
  printf 'schema=fm-remote-home-provision.v1\n'
  printf 'id_b64=%s\n' "$(printf '%s' route | encode)"
  printf 'charter_b64=%s\n' "$(encode < "$charter")"
  printf 'parent_host_b64=%s\n' "$(printf '%s' remote-host | encode)"
  printf 'project_count=0\n'
} > "$manifest"

FM_FAKE_GIT_LOG="$TMP_ROOT/git.log" \
FM_FAKE_SAFE_DIRECTORY="$remote_root/.git" \
PATH="$fakebin:$PATH" \
FM_ROOT_OVERRIDE="$remote_root" \
FM_HOME="$remote_home" \
  "$ROOT/bin/fm-remote-home-provision.sh" < "$manifest" >/dev/null \
  || fail "remote provisioning did not clone with scoped safe.directory"

assert_grep "value1=$remote_root/.git" "$TMP_ROOT/git.log" \
  "remote root clone did not authorize the source git directory for this one git invocation"
assert_present "$remote_home/.fm-secondmate-home" \
  "remote provisioning did not publish the identity marker after the guarded clone"
pass "remote provisioning authorizes a root-owned remote code root only for its own home clone"
