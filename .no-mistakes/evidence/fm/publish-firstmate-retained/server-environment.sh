#!/usr/bin/env bash
set -eu
root=$PWD
fixture="$root/.test-phase/server-environment"
mkdir -p "$fixture/bin"
cat > "$fixture/bin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1" in
  status)
    running=false; status=stopped
    if [ -f "$ENV_FIXTURE/running" ]; then running=true; status=running; fi
    printf '{"client":{"version":"0.8.2","protocol":16},"server":{"running":%s,"status":"%s","compatible":true,"protocol":16}}\n' "$running" "$status"
    ;;
  server)
    printf 'server launch\n' >> "$ENV_FIXTURE/calls"
    for name in FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE CURSOR_AGENT CURSOR_INVOKED_AS CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT FM_SUPERVISION_MODEL HERDR_SESSION FM_HERDR_SENTINEL; do
      eval 'value=${'"$name"'-<unset>}'
      printf '%s=%s\n' "$name" "$value"
    done > "$ENV_FIXTURE/child-env"
    touch "$ENV_FIXTURE/running"
    ;;
  *) exit 99 ;;
esac
SH
chmod +x "$fixture/bin/herdr"
export ENV_FIXTURE="$fixture"
export PATH="$fixture/bin:$PATH"
export FM_HOME="$fixture/polluted" FM_ROOT_OVERRIDE="$fixture/polluted" FM_STATE_OVERRIDE="$fixture/polluted"
export FM_DATA_OVERRIDE="$fixture/polluted" FM_PROJECTS_OVERRIDE="$fixture/polluted" FM_CONFIG_OVERRIDE="$fixture/polluted"
export CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent CLAUDECODE=1 PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed GROK_AGENT=1 FM_SUPERVISION_MODEL=autoarm FM_HERDR_SENTINEL=kept
. "$root/bin/backends/herdr.sh"
printf 'Production adapter with a fake Herdr server recording its received environment.\n'
printf '$ fm_backend_herdr_server_ensure fm-lab-evidence\n'
fm_backend_herdr_server_ensure fm-lab-evidence
cat "$fixture/child-env"
cp "$fixture/child-env" "$fixture/first-env"
printf '\n$ fm_backend_herdr_server_ensure fm-lab-evidence  # already running\n'
fm_backend_herdr_server_ensure fm-lab-evidence
cmp "$fixture/child-env" "$fixture/first-env"
[ "$(wc -l < "$fixture/calls" | tr -d ' ')" = 1 ]
printf 'Observed server launches after two ensure calls: 1; running server environment unchanged.\n'
