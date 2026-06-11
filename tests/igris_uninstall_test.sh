#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains_line() {
  local contents="$1"
  local expected="$2"
  local description="$3"

  if ! grep -Fxq "$expected" <<< "$contents"; then
    fail "${description}: missing line: ${expected}"
  fi
}

export IGRIS_INSTALLER_SKIP_MAIN=1
# shellcheck source=igris.sh
source "$repo_root/igris.sh"

test_uninstall_removes_igris_and_bundled_vortex() {
  local bin_dir="$tmp_dir/bin"
  local log_file="$tmp_dir/uninstall.log"
  mkdir -p "$bin_dir"

  for cmd in systemctl rc-service rc-update launchctl; do
    cat > "$bin_dir/$cmd" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
    chmod +x "$bin_dir/$cmd"
  done

  (
    # shellcheck disable=SC2329  # test shim is invoked indirectly by sourced installer code
    id() {
      if [[ "${1:-}" == "-u" ]]; then
        printf '501\n'
        return 0
      fi
      command id "$@"
    }

    # shellcheck disable=SC2329  # test shim is invoked indirectly by sourced installer code
    sudo() {
      if [[ "${1:-}" == "-v" ]]; then
        printf 'sudo -v\n'
        return 0
      fi

      printf 'sudo'
      printf ' %q' "$@"
      printf '\n'
      return 0
    }

    PATH="$bin_dir:$PATH" uninstall_igris > "$log_file"
  )

  local contents
  contents="$(cat "$log_file")"

  assert_contains_line "$contents" "sudo -v" "sudo preflight"
  assert_contains_line "$contents" "sudo systemctl stop igris" "igris systemd stop"
  assert_contains_line "$contents" "sudo systemctl disable igris" "igris systemd disable"
  assert_contains_line "$contents" "sudo systemctl daemon-reload" "igris systemd reload"
  assert_contains_line "$contents" "sudo systemctl reset-failed igris" "igris systemd reset"
  assert_contains_line "$contents" "sudo rc-service igris stop" "igris OpenRC stop"
  assert_contains_line "$contents" "sudo rc-update del igris default" "igris OpenRC delete"
  assert_contains_line "$contents" "sudo launchctl bootout system /Library/LaunchDaemons/com.pipeops.igris.plist" "igris launchd bootout"
  assert_contains_line "$contents" "sudo rm -f /usr/local/bin/igris /usr/local/bin/igris.exe" "igris binary removal"
  assert_contains_line "$contents" "sudo rm -f /etc/default/igris /etc/conf.d/igris /etc/init.d/igris /Library/LaunchDaemons/com.pipeops.igris.plist" "igris config removal"
  assert_contains_line "$contents" "sudo rm -rf /var/lib/igris /var/log/igris /Library/Application\\ Support/Igris" "igris state removal"

  assert_contains_line "$contents" "sudo systemctl stop vortex" "vortex systemd stop"
  assert_contains_line "$contents" "sudo systemctl disable vortex" "vortex systemd disable"
  assert_contains_line "$contents" "sudo systemctl reset-failed vortex" "vortex systemd reset"
  assert_contains_line "$contents" "sudo rm -f /usr/local/bin/vortex /usr/local/bin/vortex.exe /etc/systemd/system/vortex.service" "vortex binary and service removal"
  assert_contains_line "$contents" "sudo rm -rf /etc/vortex /usr/lib/vortex /var/lib/vortex /var/log/vortex /run/vortex" "vortex state removal"
}

test_uninstall_removes_igris_and_bundled_vortex

echo "ok: igris uninstall removes services, binaries, config, and persisted state"
