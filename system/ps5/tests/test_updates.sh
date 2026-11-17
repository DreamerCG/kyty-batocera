#!/bin/bash
set -eu

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
export TEST_DIR
export PATH="$TEST_DIR/bin:$PATH"
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/userdata/system/ps5" "$TEST_DIR/repo/system/ps5/emulator/KytyPS5" \
    "$TEST_DIR/repo/system/ps5/launch" "$TEST_DIR/repo/system/configs/emulationstation" \
    "$TEST_DIR/repo/system/services" "$TEST_DIR/repo/roms/ps5" "$TEST_DIR/asset"

cat > "$TEST_DIR/bin/flock" <<'EOF'
#!/bin/bash
[ ! -f "$TEST_DIR/lock-busy" ] || exit 1
: >&"$2"
EOF
cat > "$TEST_DIR/bin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$TEST_DIR/bin/batocera-services" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_DIR/services.log"
case "$1" in
    enable)
        [ -f "$TEST_DIR/fail-enable" ] || touch "$TEST_DIR/service-enabled" ;;
    list)
        if [ -f "$TEST_DIR/service-enabled" ] && [ -f "$TEST_DIR/userdata/system/services/dcg_kyty_update" ]; then
            echo 'dcg_kyty_update;*'
        fi ;;
    *) exit 1 ;;
esac
EOF
cat > "$TEST_DIR/bin/python3" <<'EOF'
#!/bin/bash
case "$(cat "$2")" in
    KytyPS5) printf 'v1\thttps://example.test/kyty.tar.gz\t\n' ;;
    U59) printf 'u1\thttps://example.test/u59.tar.gz\t\n' ;;
    *) exit 1 ;;
esac
EOF
cat > "$TEST_DIR/bin/curl" <<'EOF'
#!/bin/bash
url="" out=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --connect-timeout|--max-time|--retry|--retry-delay|-H) shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
printf '%s\n' "$url" >> "$TEST_DIR/downloads.log"
case "$url" in
    */VERSION.txt\?ref=main)
        [ ! -f "$TEST_DIR/offline" ] || exit 1
        cp "$TEST_DIR/remote-version" "$out" ;;
    */install.sh\?ref=main) cp "$TEST_DIR/remote-installer" "$out" ;;
    */KytyPS5/KytyPS5/releases/latest)
        [ ! -f "$TEST_DIR/fail-kyty" ] || exit 1
        echo KytyPS5 > "$out" ;;
    */Jetsku/KytyPS5/releases/latest) echo U59 > "$out" ;;
    */kyty.tar.gz|*/u59.tar.gz) cp "$TEST_DIR/asset.tar.gz" "$out" ;;
    *) cp "$TEST_DIR/repo.tar.gz" "$out" ;;
esac
EOF
chmod +x "$TEST_DIR/bin/"*

# Isolate absolute Batocera paths and locks from the host.
sed -e "s|/userdata|$TEST_DIR/userdata|g" \
    -e "s|/tmp/kyty-install.lock|$TEST_DIR/install.lock|g" \
    "$ROOT/install.sh" > "$TEST_DIR/installer"
sed -e "s|/userdata|$TEST_DIR/userdata|g" \
    -e "s|/tmp/dcg_kyty_update.lock|$TEST_DIR/service.lock|g" \
    -e "s|/tmp/kyty-install.lock|$TEST_DIR/install.lock|g" \
    "$ROOT/system/services/dcg_kyty_update" > "$TEST_DIR/service"

cp "$TEST_DIR/installer" "$TEST_DIR/repo/install.sh"
cp "$TEST_DIR/service" "$TEST_DIR/repo/system/services/dcg_kyty_update"
printf '1.0.1\n' > "$TEST_DIR/repo/VERSION.txt"
printf 'setting=default\nnewsetting=value\n' > "$TEST_DIR/repo/temp.conf"
touch "$TEST_DIR/repo/system/ps5/launch/run.py" \
    "$TEST_DIR/repo/system/ps5/emulator/KytyPS5/Kyty-template.ini" \
    "$TEST_DIR/repo/system/configs/emulationstation/es_systems_ps5.cfg" \
    "$TEST_DIR/repo/system/configs/emulationstation/es_features_ps5.cfg" \
    "$TEST_DIR/repo/roms/ps5/Kyty Launcher.ps5"
printf '#!/bin/sh\n' > "$TEST_DIR/asset/kyty_emulator"
cp "$TEST_DIR/asset/kyty_emulator" "$TEST_DIR/asset/kyty_launcher"
touch "$TEST_DIR/asset/u59-preset.json"
tar -czf "$TEST_DIR/asset.tar.gz" -C "$TEST_DIR/asset" .
tar -czf "$TEST_DIR/repo.tar.gz" -C "$TEST_DIR" repo

export ARCHIVE_URL=https://example.test/repo.tar.gz
bash "$TEST_DIR/installer" > "$TEST_DIR/install.log" 2>&1 || {
    cat "$TEST_DIR/install.log"; exit 1
}
grep -qx 'enable dcg_kyty_update' "$TEST_DIR/services.log"
grep -qx 'list user' "$TEST_DIR/services.log"
test -f "$TEST_DIR/service-enabled"
grep -qx '1.0.1' "$TEST_DIR/userdata/system/ps5/VERSION.txt"
test -x "$TEST_DIR/userdata/system/services/dcg_kyty_update"
test ! -e "$TEST_DIR/userdata/system/ps5/kyty-install.sh"
test -f "$TEST_DIR/userdata/system/ps5/emulator/KytyPS5-U59/u59-preset.json"
if bash "$TEST_DIR/service" --emulators-only-locked 8>&- > "$TEST_DIR/install.log" 2>&1; then
    echo "Expected missing installation lock failure" >&2; exit 1
fi

# An integration update must preserve existing user settings and service state.
printf 'setting=custom\n' > "$TEST_DIR/userdata/system/batocera.conf"
rm "$TEST_DIR/services.log"
bash "$TEST_DIR/installer" --update > "$TEST_DIR/install.log" 2>&1 || {
    cat "$TEST_DIR/install.log"; exit 1
}
grep -qx 'setting=custom' "$TEST_DIR/userdata/system/batocera.conf"
grep -qx 'newsetting=value' "$TEST_DIR/userdata/system/batocera.conf"
test ! -f "$TEST_DIR/services.log"

# A missing U59 preset triggers reinstallation even with an unchanged release.
rm "$TEST_DIR/userdata/system/ps5/emulator/KytyPS5-U59/u59-preset.json"
: > "$TEST_DIR/downloads.log"
bash "$TEST_DIR/service" --emulators-only-locked 8>"$TEST_DIR/install.lock" > "$TEST_DIR/install.log" 2>&1 || {
    cat "$TEST_DIR/install.log"; exit 1
}
test -f "$TEST_DIR/userdata/system/ps5/emulator/KytyPS5-U59/u59-preset.json"
grep -q '/u59.tar.gz' "$TEST_DIR/downloads.log"
! grep -q '/kyty.tar.gz' "$TEST_DIR/downloads.log"

# Failure of one release must not prevent checking the other.
touch "$TEST_DIR/fail-kyty"
: > "$TEST_DIR/downloads.log"
if bash "$TEST_DIR/service" --emulators-only-locked 8>"$TEST_DIR/install.lock" > "$TEST_DIR/install.log" 2>&1; then
    echo "Expected release failure" >&2; exit 1
fi
grep -q '/Jetsku/KytyPS5/releases/latest' "$TEST_DIR/downloads.log"
rm "$TEST_DIR/fail-kyty"

cat > "$TEST_DIR/remote-installer" <<'EOF'
#!/bin/bash
printf 'remote %s\n' "$*" >> "$TEST_DIR/calls.log"
EOF
printf '1.0.1\n' > "$TEST_DIR/remote-version"
: > "$TEST_DIR/downloads.log"
bash "$TEST_DIR/service" scan > "$TEST_DIR/scan.log" 2>&1
grep -q '/KytyPS5/KytyPS5/releases/latest' "$TEST_DIR/downloads.log"
grep -q '/Jetsku/KytyPS5/releases/latest' "$TEST_DIR/downloads.log"

touch "$TEST_DIR/lock-busy"
if bash "$TEST_DIR/service" scan > "$TEST_DIR/scan.log" 2>&1; then
    echo "Expected lock failure" >&2; exit 1
fi
grep -q 'déjà en cours' "$TEST_DIR/scan.log"
rm "$TEST_DIR/lock-busy"

# A complete service-driven integration update uses the service from the archive.
printf '1.0.2\n' > "$TEST_DIR/repo/VERSION.txt"
tar -czf "$TEST_DIR/repo.tar.gz" -C "$TEST_DIR" repo
cp "$TEST_DIR/installer" "$TEST_DIR/remote-installer"
printf '1.0.2\n' > "$TEST_DIR/remote-version"
bash "$TEST_DIR/service" scan > "$TEST_DIR/scan.log" 2>&1 || {
    cat "$TEST_DIR/scan.log"; exit 1
}
grep -qx '1.0.2' "$TEST_DIR/userdata/system/ps5/VERSION.txt"
grep -qx 'setting=custom' "$TEST_DIR/userdata/system/batocera.conf"
test ! -e "$TEST_DIR/userdata/system/ps5/kyty-install.sh"

cat > "$TEST_DIR/remote-installer" <<'EOF'
#!/bin/bash
printf 'remote %s\n' "$*" >> "$TEST_DIR/calls.log"
EOF
: > "$TEST_DIR/calls.log"
: > "$TEST_DIR/downloads.log"
printf '1.0.3\n' > "$TEST_DIR/remote-version"
bash "$TEST_DIR/service" scan > "$TEST_DIR/scan.log" 2>&1
grep -qx 'remote --update' "$TEST_DIR/calls.log"
! grep -q '/releases/latest' "$TEST_DIR/downloads.log"

: > "$TEST_DIR/downloads.log"
printf 'invalid\n' > "$TEST_DIR/remote-version"
if bash "$TEST_DIR/service" scan > "$TEST_DIR/scan.log" 2>&1; then
    echo "Expected invalid version failure" >&2; exit 1
fi
grep -q '/Jetsku/KytyPS5/releases/latest' "$TEST_DIR/downloads.log"
grep -q 'ERREUR' "$TEST_DIR/scan.log"

: > "$TEST_DIR/downloads.log"
touch "$TEST_DIR/offline"
if bash "$TEST_DIR/service" scan > "$TEST_DIR/scan.log" 2>&1; then
    echo "Expected network failure" >&2; exit 1
fi
grep -q '/Jetsku/KytyPS5/releases/latest' "$TEST_DIR/downloads.log"
grep -q 'ERREUR' "$TEST_DIR/scan.log"

rm "$TEST_DIR/offline"
printf '1.0.2\n' > "$TEST_DIR/remote-version"
: > "$TEST_DIR/userdata/system/logs/kyty_update.log"
bash "$TEST_DIR/service" start
for _ in {1..50}; do
    grep -q 'KytyPS5-U59 déjà à jour' "$TEST_DIR/userdata/system/logs/kyty_update.log" && break
    command -p sleep 0.1
done
grep -q 'KytyPS5-U59 déjà à jour' "$TEST_DIR/userdata/system/logs/kyty_update.log"

# An apparently successful enable command must not hide a disabled service.
rm "$TEST_DIR/service-enabled"
touch "$TEST_DIR/fail-enable"
printf '0.9.9\n' > "$TEST_DIR/userdata/system/ps5/VERSION.txt"
if bash "$TEST_DIR/installer" > "$TEST_DIR/install.log" 2>&1; then
    echo "Expected service activation failure" >&2; exit 1
fi
grep -q "service Kyty n'est pas activé" "$TEST_DIR/install.log"
grep -qx '0.9.9' "$TEST_DIR/userdata/system/ps5/VERSION.txt"

echo "Update tests passed"
