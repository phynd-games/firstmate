#!/usr/bin/env bash
# Behavior tests for the dashboard's read-only HTTP surface
# (bin/fm_dashboard_server.py, served by `fm-dashboard.sh serve`).
#
# These drive the REAL server over a REAL loopback socket against a fixture
# home. They assert what the server does - status codes, document shape,
# refusals - never what its source says.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASH="$ROOT/bin/fm-dashboard.sh"
APP="$ROOT/assets/dashboard"
TMP_ROOT=$(fm_test_tmproot fm-dashboard-api)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }
[ -f "$APP/index.html" ] || { echo "skip: the dashboard client is not built"; exit 0; }

SERVER_PIDS=()
stop_servers() {
  local pid
  for pid in ${SERVER_PIDS+"${SERVER_PIDS[@]}"}; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  pkill -f "fm_dashboard_server.py" 2>/dev/null || true
}
trap 'stop_servers; fm_test_cleanup' EXIT
trap 'stop_servers; fm_test_cleanup; exit 130' INT
trap 'stop_servers; fm_test_cleanup; exit 143' TERM

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
}

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data/scout-one" "$home/config" "$home/fakebin"
  fm_fake_exit0 "$(fm_fakebin "$home")" herdr no-mistakes
  printf '7500\n' > "$home/config/startup-memory-budget"
  cat > "$home/data/backlog.md" <<'MD'
# Backlog

## In flight
- [ ] worker-one - Build the thing (repo: sample) (kind: ship) (since 2026-08-01)

## Queued

## Done
MD
  printf '# Scout one\n\nA **finding**.\n' > "$home/data/scout-one/report.md"
  fm_write_meta "$home/state/worker-one.meta" \
    "window=default:w1:p1" "endpoint_task_id=worker-one" \
    "worktree=$home/wt" "project=$home/p" "harness=claude" "model=opus" \
    "effort=xhigh" "kind=ship" "mode=no-mistakes" "yolo=off" "backend=herdr"
  printf 'working: started\nneeds-decision [key=pick]: two options\n' \
    > "$home/state/worker-one.status"
  printf '%s\n' "$home"
}

# start_server <home> -> prints the port
start_server() {
  local home=$1 port ready=0 attempt=0 dev_arg=''
  port=$(free_port)
  [ "${DEV_RELOAD_OVERRIDE:-0}" = 1 ] && dev_arg=--dev
  if [ -n "${SELF_OVERRIDE:-}" ]; then
    ( PATH="$home/fakebin:$PATH" FM_HOME="$home" \
        FM_DASHBOARD_SELF="$SELF_OVERRIDE" FM_DASHBOARD_BIND_PORT="$port" \
        FM_DASHBOARD_HEALTH_HOME="$home" \
        FM_DASHBOARD_APP_DIR="${APP_DIR_OVERRIDE:-$APP}" \
        FM_DASHBOARD_MAX_STREAM_CLIENTS="${STREAM_CAP:-8}" \
        FM_DASHBOARD_CACHE_TTL="${CACHE_TTL_OVERRIDE:-2}" \
        FM_DASHBOARD_LIVE_REFRESH="${LIVE_REFRESH_OVERRIDE:-2}" \
        FM_DASHBOARD_STAMP_MAX_ENTRIES="${STAMP_MAX_ENTRIES_OVERRIDE:-512}" \
        FM_DASHBOARD_ERROR_RETRY="${ERROR_RETRY_OVERRIDE:-2}" \
        FM_DASHBOARD_STREAM_POLL="${STREAM_POLL_OVERRIDE:-1}" \
        FM_DASHBOARD_DEV_RELOAD="${DEV_RELOAD_OVERRIDE:-0}" \
        FM_DASHBOARD_REPORTS="${REPORTS_OVERRIDE:-40}" \
        python3 "$ROOT/bin/fm_dashboard_server.py" \
        >"$home/server.log" 2>&1 & echo $! > "$home/server.pid" )
  else
    ( PATH="$home/fakebin:$PATH" FM_HOME="$home" \
        FM_DASHBOARD_MAX_STREAM_CLIENTS="${STREAM_CAP:-8}" \
        FM_DASHBOARD_APP_DIR="${APP_DIR_OVERRIDE:-$APP}" \
        FM_DASHBOARD_CACHE_TTL="${CACHE_TTL_OVERRIDE:-2}" \
        FM_DASHBOARD_LIVE_REFRESH="${LIVE_REFRESH_OVERRIDE:-2}" \
        FM_DASHBOARD_STAMP_MAX_ENTRIES="${STAMP_MAX_ENTRIES_OVERRIDE:-512}" \
        FM_DASHBOARD_ERROR_RETRY="${ERROR_RETRY_OVERRIDE:-2}" \
        FM_DASHBOARD_STREAM_POLL="${STREAM_POLL_OVERRIDE:-1}" \
        FM_DASHBOARD_DEV_RELOAD="${DEV_RELOAD_OVERRIDE:-0}" \
        FM_DASHBOARD_REPORTS="${REPORTS_OVERRIDE:-40}" \
        "$DASH" serve --port "$port" $dev_arg \
        --owner-digest deadbeef >"$home/server.log" 2>&1 & echo $! > "$home/server.pid" )
  fi
  while [ "$attempt" -lt 60 ]; do
    attempt=$((attempt + 1))
    if curl -fsS --noproxy '*' --max-time 2 -o /dev/null "http://127.0.0.1:$port/healthz" 2>/dev/null; then
      ready=1; break
    fi
    sleep 0.5
  done
  [ "$ready" = 1 ] || { cat "$home/server.log" >&2; return 1; }
  SERVER_PIDS+=("$(cat "$home/server.pid")")
  printf '%s\n' "$port"
}

get() { curl -fsS --noproxy '*' --max-time 60 "http://127.0.0.1:$1$2" 2>/dev/null; }
code() { curl -s --noproxy '*' --path-as-is -o /dev/null -w '%{http_code}' --max-time 60 -X "${3:-GET}" "http://127.0.0.1:$1$2"; }

RESOURCES="overview metrics tasks queue backlog delivery supervision usage reports sources"

# Hold <n> stream clients open from one process, then report the status the
# next request gets. Deterministic, unlike racing background curls.
stream_status_past_cap() {  # <port> <n>
  python3 "$ROOT/tests/assets/stream-cap-probe.py" "$1" "$2"
}

test_every_resource_answers_a_versioned_document_with_provenance() {
  local home port r doc
  home=$(make_home envelope)
  port=$(start_server "$home") || fail "the server did not start"
  for r in $RESOURCES; do
    doc=$(get "$port" "/api/v1/$r") || fail "resource $r did not answer"
    printf '%s' "$doc" | jq -e --arg r "$r" '
      .schema == "fm-dashboard-api.v1"
      and .resource == $r
      and (.collected_at | type) == "string"
      and (.observed_at | type) == "string"
      and (.age_seconds | type) == "number"
      and (.generation | type) == "number"
      and (.upstream.schema == "fm-fleet-snapshot.v1")
      and (.data | type) == "object"' >/dev/null \
      || fail "resource $r did not carry a versioned envelope with freshness: $doc"
  done
  pass "every API resource answers a versioned document carrying its own freshness"
}

test_no_mutating_method_reaches_a_route() {
  local home port m
  home=$(make_home methods)
  port=$(start_server "$home") || fail "the server did not start"
  for m in POST PUT PATCH DELETE OPTIONS TRACE; do
    [ "$(code "$port" /api/v1/overview "$m")" = 405 ] \
      || fail "$m was not refused on an API route"
    [ "$(code "$port" / "$m")" = 405 ] || fail "$m was not refused on the app route"
  done
  curl -s --noproxy '*' -D - -o /dev/null -X POST --max-time 20 "http://127.0.0.1:$port/api/v1/overview" \
    | grep -qi '^allow: *GET, HEAD' || fail "the refusal did not advertise a read-only method set"
  pass "no mutating HTTP method reaches any route"
}

test_head_does_not_open_a_long_lived_stream() {
  local home port status
  home=$(make_home head-stream)
  port=$(start_server "$home") || fail "the server did not start"
  status=$(curl -s --noproxy '*' --max-time 3 -o /dev/null -w '%{http_code}' \
    -X HEAD "http://127.0.0.1:$port/api/v1/stream")
  [ "$status" = 405 ] || fail "HEAD stream was not refused promptly: $status"
  pass "HEAD requests cannot consume a long-lived stream slot"
}

test_asset_routes_cannot_be_turned_into_a_filesystem_read() {
  local home port
  home=$(make_home assets)
  port=$(start_server "$home") || fail "the server did not start"
  [ "$(code "$port" /assets/app.js)" = 200 ] || fail "the bundle is not served"
  [ "$(code "$port" /assets/app.css)" = 200 ] || fail "the stylesheet is not served"
  [ "$(code "$port" '/assets/../fm-dashboard.sh')" = 404 ] || fail "a traversal was not refused"
  [ "$(code "$port" '/assets/..%2f..%2fetc%2fpasswd')" = 404 ] || fail "an encoded traversal was not refused"
  [ "$(code "$port" /assets/nope.js)" = 404 ] || fail "an unknown asset was not refused"
  [ "$(code "$port" /assets/build.mjs)" = 404 ] || fail "an asset outside the allowlist was served"
  get "$port" '/assets/../fm-dashboard.sh' | grep -q 'fm-dashboard' \
    && fail "a shell script was served through the asset route"
  pass "the asset route serves the bundle and cannot be turned into a filesystem read"
}

test_asset_ancestor_symlink_is_refused_by_descriptor_boundary() {
  local home port outside wrapper app_parent
  home=$(make_home asset-ancestor)
  outside="$home/outside"
  app_parent="$home/app-parent"
  mkdir -p "$app_parent/assets" "$outside/assets"
  cp "$APP/index.html" "$APP/app.js" "$APP/app.css" "$app_parent/assets/"
  cp "$APP/index.html" "$APP/app.js" "$APP/app.css" "$outside/assets/"
  wrapper="$home/collector-wrapper"
  cat > "$wrapper" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = stamp ]; then exec "$DASH" stamp; fi
exec "$DASH" json
SH
  chmod +x "$wrapper"
  port=$(SELF_OVERRIDE="$wrapper" APP_DIR_OVERRIDE="$app_parent/assets" start_server "$home") \
    || fail "the ancestor-boundary server did not start"
  [ "$(code "$port" /assets/app.js)" = 200 ] || fail "the initial asset did not answer"
  mv "$app_parent" "$home/app-parent-old"
  ln -s "$outside" "$app_parent"
  [ "$(code "$port" /assets/app.js)" = 404 ] \
    || fail "an asset path through a swapped ancestor was served"
  pass "asset reads refuse an ancestor replaced by a symlink"
}

# The earlier traversal probes all name a path whose EXTENSION is not allowed,
# so they prove the extension allowlist, not containment. This one traverses to
# a file with an allowed extension that sits outside the application directory,
# which is the only shape that actually exercises the containment check.
test_an_allowed_extension_outside_the_app_directory_is_still_refused() {
  local home port app
  home=$(make_home containment)
  app="$home/app"
  mkdir -p "$app"
  cp "$APP/index.html" "$APP/app.js" "$APP/app.css" "$app/"
  printf 'const leaked = true;\n' > "$home/leak.js"
  port=$(APP_DIR_OVERRIDE="$app" start_server "$home") || fail "the server did not start"
  [ "$(code "$port" /assets/app.js)" = 200 ] || fail "the fixture bundle is not served"
  [ "$(code "$port" '/assets/../leak.js')" = 404 ] \
    || fail "a file with an allowed extension outside the app directory was served"
  get "$port" '/assets/../leak.js' | grep -q 'leaked' \
    && fail "content outside the application directory leaked through the asset route"
  pass "an allowed extension outside the application directory is still refused"
}

test_the_client_never_depends_on_a_file_url() {
  local home port index
  home=$(make_home nofile)
  port=$(start_server "$home") || fail "the server did not start"
  index=$(get "$port" /) || fail "the app shell did not answer"
  printf '%s' "$index" | grep -q 'id="root"' || fail "the app shell has no mount point"
  printf '%s' "$index" | grep -q 'src="/assets/app.js"' \
    || fail "the app shell does not load its bundle from a same-origin path"
  printf '%s' "$index" | grep -qi 'file://' && fail "the app shell references a file:// URL"
  get "$port" /assets/app.js | grep -qi 'file://' && fail "the bundle references a file:// URL"
  get "$port" /assets/app.js | grep -qiE 'https?://(cdn|unpkg|jsdelivr|esm\.sh)' \
    && fail "the bundle references a CDN"
  pass "the client is served same-origin and depends on no file:// URL or CDN"
}

test_unknown_versions_and_resources_are_refused() {
  local home port
  home=$(make_home unknown)
  port=$(start_server "$home") || fail "the server did not start"
  [ "$(code "$port" /api/v2/overview)" = 404 ] || fail "an unknown API version was accepted"
  [ "$(code "$port" /api/v1/nope)" = 404 ] || fail "an unknown resource was accepted"
  [ "$(code "$port" /api/v1/tasks/worker-one/extra)" = 404 ] || fail "an over-long path was accepted"
  [ "$(code "$port" /api/v1/tasks/absent-task)" = 404 ] || fail "an unknown task was not refused"
  pass "unknown API versions, resources, and paths are refused"
}

test_metrics_are_evidence_backed_or_explicitly_unavailable() {
  local home port doc
  home=$(make_home metrics)
  port=$(start_server "$home") || fail "the server did not start"
  doc=$(get "$port" /api/v1/metrics) || fail "metrics did not answer"
  printf '%s' "$doc" | jq -e '
    [.data.metrics[] | select(.available)] | all(.sources | length > 0)' >/dev/null \
    || fail "an available metric carried no source path"
  printf '%s' "$doc" | jq -e '
    [.data.metrics[] | select(.available | not)] | all((.reason | length) > 0 and .value == null)' >/dev/null \
    || fail "an unavailable metric carried no reason, or carried a value anyway"
  printf '%s' "$doc" | jq -e '
    .data.metrics | map(select(.key == "token_usage")) | .[0]
    | .available == false and (.reason | test("no vendor usage meter"))' >/dev/null \
    || fail "token usage was not reported unavailable"
  printf '%s' "$doc" | jq -e '
    .data.metrics | map(select(.key == "supervision_uptime_ratio")) | .[0].available == false' >/dev/null \
    || fail "an uptime ratio was invented despite no retained time series"
  printf '%s' "$doc" | jq -e '
    .data.metrics | map(select(.key == "wip")) | .[0] | .value == 1 and .kind == "point_in_time"' >/dev/null \
    || fail "work in flight was not derived from the backlog"
  pass "metrics are evidence-backed with sources, or unavailable with a reason"
}

test_unavailable_backlog_is_not_reported_as_empty_work() {
  local home port outside backlog metrics
  home=$(make_home unavailable-backlog)
  outside="$TMP_ROOT/unavailable-backlog-outside"
  printf '# outside\n' > "$outside"
  rm -f "$home/data/backlog.md"
  ln -s "$outside" "$home/data/backlog.md"
  port=$(start_server "$home") || fail "the server did not start"
  backlog=$(get "$port" /api/v1/backlog) || fail "the backlog route did not answer"
  printf '%s' "$backlog" | jq -e '
    .data.available == false
    and (.data.reason | test("symlink"))
    and (.data.records | length) == 0' >/dev/null \
    || fail "an unavailable backlog was presented as an empty available list"
  metrics=$(get "$port" /api/v1/metrics) || fail "the metrics route did not answer"
  printf '%s' "$metrics" | jq -e '
    .data.metrics | map(select(.key == "wip" or .key == "queue_depth"))
    | length == 2 and all(.[]; .available == false and .value == null)' >/dev/null \
    || fail "unavailable backlog metrics were invented as zero"
  pass "unavailable backlog state propagates to the API and metrics"
}

test_malformed_and_missing_records_surface_through_the_api() {
  local home port
  home=$(make_home malformed)
  printf '1750000000\t7\tcheck\tworker-one\tPR merged\nhand edited line\n' > "$home/state/.wake-queue"
  # make_home already wrote a real status log; replace it with a symlink.
  rm -f "$home/state/worker-one.status"
  ln -s "$TMP_ROOT/outside-status" "$home/state/worker-one.status"
  port=$(start_server "$home") || fail "the server did not start"
  get "$port" /api/v1/queue | jq -e '
    .data.wakes.records | map(select(.malformed)) | length == 1' >/dev/null \
    || fail "a hand-edited queue record was not flagged malformed through the API"
  get "$port" /api/v1/supervision | jq -e '
    .data.degraded | map(select(.source | test("status log"))) | length == 1' >/dev/null \
    || fail "a symlinked status log was not disclosed through the API"
  pass "malformed and refused records surface through the API instead of vanishing"
}

test_the_stream_is_immediate_and_bounded() {
  local home port out held
  home=$(make_home stream)
  # Pin the cap so the bound is asserted deterministically rather than by racing
  # however many background clients happen to connect in time.
  port=$(STREAM_CAP=2 start_server "$home") || fail "the server did not start"
  out=$(timeout 8 curl -s --noproxy '*' -N "http://127.0.0.1:$port/api/v1/stream" 2>/dev/null | head -2)
  printf '%s' "$out" | grep -q '^event: hello' \
    || fail "the stream did not confirm itself immediately: $out"
  held=$(stream_status_past_cap "$port" 2)
  [ "$held" = 503 ] || fail "the stream client cap was not enforced (got $held)"
  pass "the change stream confirms immediately and refuses clients past its bound"
}

test_unchanged_collector_stamp_reuses_cached_generation() {
  local home port wrapper first second runs
  home=$(make_home unchanged-stamp)
  wrapper="$home/collector-wrapper"
  cat > "$wrapper" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = stamp ]; then exec "$DASH" stamp; fi
printf '%s\\n' run >> "$home/collector-runs"
exec "$DASH" json
SH
  chmod +x "$wrapper"
  port=$(SELF_OVERRIDE="$wrapper" CACHE_TTL_OVERRIDE=0.05 start_server "$home") \
    || fail "the unchanged-stamp server did not start"
  first=$(get "$port" /api/v1/overview) || fail "the first unchanged-stamp request failed"
  sleep 0.2
  second=$(get "$port" /api/v1/overview) || fail "the second unchanged-stamp request failed"
  runs=$(wc -l < "$home/collector-runs" | tr -d '[:space:]')
  [ "$runs" = 1 ] || fail "an unchanged collector stamp triggered recollection"
  [ "$(printf '%s' "$second" | jq -r .generation)" = "$(printf '%s' "$first" | jq -r .generation)" ] \
    || fail "an unchanged collector stamp advanced the generation"
  pass "an unchanged collector stamp reuses the cached generation"
}

test_a_report_is_served_as_data_not_as_markup() {
  local home port doc
  home=$(make_home reports)
  printf '# R\n\nA <script>alert(1)</script> tag.\n' > "$home/data/scout-one/report.md"
  port=$(start_server "$home") || fail "the server did not start"
  doc=$(get "$port" /api/v1/reports/scout-one) || fail "the report did not answer"
  printf '%s' "$doc" | jq -e '
    .data.report.readable == true and (.data.report.body | test("alert\\(1\\)"))' >/dev/null \
    || fail "the report body was not returned as data"
  curl -s --noproxy '*' -D - -o /dev/null --max-time 30 "http://127.0.0.1:$port/api/v1/reports/scout-one" \
    | grep -qi '^content-type: application/json' \
    || fail "a report was served as something other than JSON data"
  pass "a report is served as JSON data, never as markup the browser would run"
}

test_task_linked_report_overflow_is_unavailable_and_not_addressable() {
  local home port status=0 task_doc
  home=$(make_home linked-api-report-cap)
  mkdir -p "$home/data/worker-one"
  printf '# Worker one report\n' > "$home/data/worker-one/report.md"
  mkdir -p "$home/data/worker-two"
  printf '# Worker two report\n' > "$home/data/worker-two/report.md"
  fm_write_meta "$home/state/worker-two.meta" \
    "window=firstmate:fm-worker-two" "endpoint_task_id=worker-two" \
    "worktree=$home/wt-two" "project=$home/p" "harness=claude" \
    "model=opus" "effort=xhigh" "kind=ship" "mode=no-mistakes" \
    "yolo=off" "backend=herdr"
  port=$(REPORTS_OVERRIDE=1 start_server "$home") || fail "the report-cap server did not start"
  curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 20 \
    "http://127.0.0.1:$port/api/v1/reports/worker-two" > "$home/report-status" || status=$?
  [ "$status" -eq 0 ] || fail "the overflow report request failed to complete"
  [ "$(cat "$home/report-status")" = 404 ] || fail "an overflow task report remained addressable"
  task_doc=$(get "$port" /api/v1/tasks/worker-two) || fail "the overflow task did not answer"
  printf '%s' "$task_doc" | jq -e '
    .data.task.paths.report.present == false
    and .data.task.paths.report.available == false
    and (.data.task.paths.report.reason | test("bounded report index"))' >/dev/null \
    || fail "the task API advertised a report omitted by the global cap"
  pass "task-linked report overflow is unavailable and not addressable"
}

test_unreadable_delivery_evidence_is_unavailable_not_absent() {
  local home port doc real_python
  home=$(make_home unreadable-delivery)
  real_python=$(command -v python3)
  # The status log is where this home records a worker's pull request. When that
  # record cannot be read, the delivery view must say so: a dropped row would
  # read exactly like a worker that has delivered nothing.
  cat > "$home/fakebin/python3" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "$ROOT/bin/fm-dashboard-read.py" ] && [[ "\${2:-}" == *worker-one.status ]]; then
  printf '%s\\n' 'status log read failed' >&2
  exit 1
fi
exec "$real_python" "\$@"
SH
  chmod +x "$home/fakebin/python3"
  port=$(start_server "$home") || fail "the server did not start"
  doc=$(get "$port" /api/v1/delivery) || fail "the delivery resource did not answer"
  printf '%s' "$doc" | jq -e '
    [.data.records[] | select(.task_id == "worker-one")] as $rows
    | ($rows | length) == 1
    and $rows[0].available == false
    and $rows[0].url == null
    and ($rows[0].reason | test("status log read failed"))' >/dev/null \
    || fail "unreadable delivery evidence was hidden instead of reported unavailable: $(printf '%s' "$doc" | jq -c '.data.records')"
  doc=$(get "$port" /api/v1/tasks/worker-one) || fail "the task resource did not answer"
  printf '%s' "$doc" | jq -e '
    .data.task.pr.available == false and (.data.task.pr.reason | length) > 0' >/dev/null \
    || fail "the task view lost the unavailable delivery reason"
  pass "unreadable delivery evidence stays unavailable rather than absent"
}

test_report_provenance_names_the_file_that_was_read() {
  local home port doc data_real
  home=$(make_home report-provenance)
  # A report directory that is a symlink is refused by discovery, so it keeps
  # that refusal and names no source. An ordinary report names the exact file
  # its bytes came from. Both facts have to reach the API, because a row with
  # neither would leave a consumer guessing which file it is looking at.
  ln -s scout-one "$home/data/aliased"
  data_real=$(cd "$home/data" && pwd -P)
  port=$(start_server "$home") || fail "the server did not start"
  doc=$(get "$port" /api/v1/reports) || fail "the report index did not answer"
  printf '%s' "$doc" | jq -e --arg resolved "$data_real/scout-one/report.md" '
    [.data.reports[] | select(.id == "scout-one")] as $read
    | ($read | length) == 1
    and $read[0].readable == true
    and $read[0].resolved_path == $resolved
    and ([.data.reports[] | select(.id == "aliased")] | length) == 1
    and ([.data.reports[] | select(.id == "aliased")][0] | .readable == false
         and .resolved_path == null and (.reason | test("symlink")))' >/dev/null \
    || fail "the report index did not name the file it read: $(printf '%s' "$doc" | jq -c '[.data.reports[]|{id,readable,path,resolved_path,reason}]')"
  doc=$(get "$port" /api/v1/sources) || fail "the sources resource did not answer"
  printf '%s' "$doc" | jq -e --arg resolved "$data_real/scout-one/report.md" '
    [.data.sources[] | select(.surface == "report scout-one")] as $rows
    | ($rows | length) == 1 and $rows[0].resolved_path == $resolved' >/dev/null \
    || fail "the source list did not name the file it read: $(printf '%s' "$doc" | jq -c '[.data.sources[]|select(.surface|startswith("report"))]')"
  pass "report provenance names the file that was read, and a refusal names none"
}

test_evidence_collected_mid_change_is_reported_as_what_it_is() {
  local home port wrapper doc
  home=$(make_home torn-alert)
  wrapper="$home/self-torn.sh"
  # The collector discloses a mid-collection change in degraded[]. The alert the
  # page shows for it must say that, not "evidence not shown": the evidence WAS
  # shown, and what the reader needs to know is that it may not be of one moment.
  cat > "$wrapper" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = stamp ]; then exec "$DASH" stamp; fi
"$DASH" json | jq -c --arg home "$home" '
  .degraded += [{source:"evidence freshness", path:\$home,
                 reason:"a record changed while this evidence was being collected"}]'
SH
  chmod +x "$wrapper"
  port=$(SELF_OVERRIDE="$wrapper" start_server "$home") \
    || fail "the torn-evidence server did not start"
  doc=$(get "$port" /api/v1/overview) || fail "the overview did not answer"
  printf '%s' "$doc" | jq -e '
    [.data.alerts[] | select(.key == "freshness")] as $rows
    | ($rows | length) == 1
    and ($rows[0].severity == "warning")
    and ($rows[0].title | test("collected"))
    and ($rows[0].title | test("not shown") | not)' >/dev/null \
    || fail "a mid-collection change was not reported as what it is: $(printf '%s' "$doc" | jq -c '[.data.alerts[]|{key,title}]')"
  pass "evidence collected mid-change is reported as that, not as evidence withheld"
}

test_serve_refuses_when_the_client_is_not_built() {
  local home out status=0
  home=$(make_home unbuilt)
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_DASHBOARD_APP_DIR="$home/absent-app" \
    "$DASH" serve --port "$(free_port)" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "serve started with no client built"
  assert_contains "$out" "fm-dashboard-build.sh" \
    "the refusal did not name how to build the missing client"
  pass "serve refuses to start when the client is not built"
}

test_the_server_can_be_restarted_on_the_same_port() {
  local home port pid
  home=$(make_home restart)
  port=$(start_server "$home") || fail "the server did not start"
  pid=$(cat "$home/server.pid")
  kill -TERM "$pid" 2>/dev/null || true
  sleep 2
  curl -fsS --noproxy '*' --max-time 2 -o /dev/null "http://127.0.0.1:$port/healthz" 2>/dev/null \
    && fail "the server is still answering after it was stopped"
  ( PATH="$home/fakebin:$PATH" FM_HOME="$home" "$DASH" serve --port "$port" \
      --owner-digest deadbeef >"$home/server2.log" 2>&1 & echo $! > "$home/server2.pid" )
  local ready=0 attempt=0
  while [ "$attempt" -lt 60 ]; do
    attempt=$((attempt + 1))
    curl -fsS --noproxy '*' --max-time 2 -o /dev/null "http://127.0.0.1:$port/healthz" 2>/dev/null \
      && { ready=1; break; }
    sleep 0.5
  done
  SERVER_PIDS+=("$(cat "$home/server2.pid")")
  [ "$ready" = 1 ] || fail "the server did not come back on the same port"
  get "$port" /api/v1/overview | jq -e '.schema == "fm-dashboard-api.v1"' >/dev/null \
    || fail "the restarted server did not serve its API"
  pass "the server releases its port on stop and serves again after a restart"
}

test_nested_evidence_and_usage_inputs_advance_the_cached_generation() {
  local home port first second budget
  home=$(make_home nested-stamp)
  port=$(CACHE_TTL_OVERRIDE=0.1 start_server "$home") || fail "the server did not start"
  first=$(get "$port" /api/v1/reports/scout-one) || fail "the initial report did not answer"
  printf '# R\n\nupdated-report\n' > "$home/data/scout-one/report.md"
  sleep 0.2
  second=$(get "$port" /api/v1/reports/scout-one) || fail "the changed report did not answer"
  printf '%s' "$second" | jq -e '.data.report.body | contains("updated-report")' >/dev/null \
    || fail "a nested report change did not invalidate the cache"
  printf '9000\n' > "$home/config/startup-memory-budget"
  sleep 0.2
  budget=$(get "$port" /api/v1/usage) || fail "the usage document did not answer"
  printf '%s' "$budget" | jq -e '.data.usage.budget.effective_budget_tokens == 9000' >/dev/null \
    || fail "the startup-memory budget change did not invalidate the cache"
  [ "$(printf '%s' "$second" | jq -r .generation)" -gt "$(printf '%s' "$first" | jq -r .generation)" ] \
    || fail "the evidence generation did not advance after nested input changes"
  pass "nested reports and startup-memory configuration invalidate cached evidence"
}

test_live_herdr_change_advances_generation_without_a_local_file_change() {
  local home port first second
  home=$(make_home live-refresh)
  cat > "$home/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_HOME/herdr-dead" ]; then
  printf '%s\n' '{"error":{"code":"pane_not_found"}}'
else
  printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1"}}}'
fi
SH
  chmod +x "$home/fakebin/herdr"
  port=$(CACHE_TTL_OVERRIDE=0.05 LIVE_REFRESH_OVERRIDE=0.1 start_server "$home") \
    || fail "the live-refresh server did not start"
  first=$(get "$port" /api/v1/overview) || fail "the initial live-refresh document did not answer"
  printf '%s\n' changed > "$home/herdr-dead"
  sleep 0.2
  second=$(get "$port" /api/v1/overview) || fail "the refreshed live document did not answer"
  [ "$(printf '%s' "$second" | jq -r .generation)" -gt "$(printf '%s' "$first" | jq -r .generation)" ] \
    || fail "a live Herdr change did not advance freshness without a local record change"
  pass "a live Herdr change advances freshness without a local record change"
}

test_dev_reload_stream_reports_a_rebuilt_bundle() {
  local home port app stream_pid
  home=$(make_home dev-reload)
  app="$home/app"
  mkdir -p "$app"
  cp "$APP/index.html" "$APP/app.js" "$APP/app.css" "$app/"
  port=$(DEV_RELOAD_OVERRIDE=1 STREAM_POLL_OVERRIDE=0.1 APP_DIR_OVERRIDE="$app" \
    start_server "$home") || fail "the dev-reload server did not start"
  curl -s --noproxy '*' -N --max-time 6 "http://127.0.0.1:$port/api/v1/stream" \
    > "$home/stream.out" 2>/dev/null & stream_pid=$!
  sleep 0.4
  printf '\n' >> "$app/app.js"
  wait "$stream_pid" || true
  grep -q '^event: dev_reload$' "$home/stream.out" \
    || fail "a rebuilt bundle produced no observable dev-reload event"
  pass "a rebuilt bundle produces an observable dev-reload event"
}

test_stamp_traversal_stays_bounded_with_many_entries() {
  local home port doc i
  home=$(make_home bounded-stamp)
  mkdir -p "$home/data/many"
  for i in $(seq 1 2000); do
    : > "$home/data/many/entry-$i"
  done
  port=$(STAMP_MAX_ENTRIES_OVERRIDE=4 start_server "$home") \
    || fail "the bounded-stamp server did not start"
  doc=$(get "$port" /api/v1/overview) || fail "the bounded-stamp API did not answer"
  printf '%s' "$doc" | jq -e '.schema == "fm-dashboard-api.v1"' >/dev/null \
    || fail "bounded traversal did not leave the API usable"
  pass "stamp traversal remains bounded with a large evidence directory"
}

test_failed_collection_retries_after_a_bounded_backoff() {
  local home port wrapper first second third runs
  home=$(make_home retry)
  wrapper="$home/collector-wrapper"
cat > "$wrapper" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = stamp ]; then exec "$DASH" stamp; fi
count_file="$home/collector-runs"
count=0
[ -f "\$count_file" ] && count=\$(wc -l < "\$count_file")
printf '%s\n' run >> "\$count_file"
if [ "\$count" -eq 0 ]; then exit 1; fi
exec "$DASH" json
SH
  chmod +x "$wrapper"
  port=$(SELF_OVERRIDE="$wrapper" CACHE_TTL_OVERRIDE=0.05 ERROR_RETRY_OVERRIDE=0.2 start_server "$home") \
    || fail "the retry server did not start"
  first=$(curl -s --noproxy '*' --max-time 20 "http://127.0.0.1:$port/api/v1/overview")
  printf '%s' "$first" | jq -e '.error | contains("collector")' >/dev/null \
    || fail "the initial collector failure was not returned"
  second=$(curl -s --noproxy '*' --max-time 20 "http://127.0.0.1:$port/api/v1/overview")
  runs=$(wc -l < "$home/collector-runs" | tr -d '[:space:]')
  [ "$runs" = 1 ] || fail "a cached collector failure was retried before its backoff expired"
  sleep 0.3
  third=$(get "$port" /api/v1/overview) || fail "the recovered collector did not answer"
  printf '%s' "$third" | jq -e '.schema == "fm-dashboard-api.v1"' >/dev/null \
    || fail "the recovered collector response was not a dashboard document"
  [ "$(wc -l < "$home/collector-runs" | tr -d '[:space:]')" = 2 ] \
    || fail "the collector did not retry after the bounded backoff"
  pass "failed collections retry after bounded backoff and recover automatically"
}

test_concurrent_requests_share_one_in_flight_collection() {
  local home port wrapper p1 p2 runs
  home=$(make_home single-flight)
  wrapper="$home/collector-wrapper"
cat > "$wrapper" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = stamp ]; then exec "$DASH" stamp; fi
printf '%s\n' run >> "$home/collector-runs"
sleep 1
exec "$DASH" json
SH
  chmod +x "$wrapper"
  port=$(SELF_OVERRIDE="$wrapper" CACHE_TTL_OVERRIDE=0.05 start_server "$home") \
    || fail "the single-flight server did not start"
  curl -s --noproxy '*' --max-time 20 "http://127.0.0.1:$port/api/v1/overview" > "$home/one.json" & p1=$!
  curl -s --noproxy '*' --max-time 20 "http://127.0.0.1:$port/api/v1/tasks" > "$home/two.json" & p2=$!
  wait "$p1" || fail "the first concurrent request failed"
  wait "$p2" || fail "the second concurrent request failed"
  runs=$(wc -l < "$home/collector-runs" | tr -d '[:space:]')
  [ "$runs" = 1 ] || fail "concurrent API requests started multiple collectors"
  jq -e '.schema == "fm-dashboard-api.v1"' "$home/one.json" >/dev/null \
    || fail "the first concurrent response was not a dashboard document"
  jq -e '.schema == "fm-dashboard-api.v1"' "$home/two.json" >/dev/null \
    || fail "the second concurrent response was not a dashboard document"
  pass "concurrent API requests share one in-flight collection"
}

test_backlog_route_exposes_in_flight_queued_and_done_metadata() {
  local home port doc
  home=$(make_home backlog-route)
  cat > "$home/data/backlog.md" <<'MD'
# Backlog

## In flight
- [ ] active-one - Active task (repo: active-repo) (kind: ship) (since 2026-08-01)

## Queued
- [ ] queued-one - Queued task (repo: queued-repo) (kind: research) (priority: 2)

## Done
- [x] done-one - Done task (repo: done-repo) (kind: ship) (merged 2026-08-02)
MD
  port=$(start_server "$home") || fail "the backlog server did not start"
  doc=$(get "$port" /api/v1/backlog) || fail "the backlog route did not answer"
  printf '%s' "$doc" | jq -e '
    .data.records as $records
    | ($records | map(select(.id == "active-one")) | .[0]) as $active
    | ($records | map(select(.id == "queued-one")) | .[0]) as $queued
    | ($records | map(select(.id == "done-one")) | .[0]) as $done
    | $active.state == "in_flight" and $active.repo == "active-repo" and $active.kind == "ship"
    and $queued.state == "queued" and $queued.priority == "2" and $queued.repo == "queued-repo"
    and $done.state == "done" and $done.merged == "2026-08-02" and $done.repo == "done-repo"' >/dev/null \
    || fail "the backlog route did not expose all states and recorded metadata"
  pass "the backlog route exposes in-flight, queued, and done metadata"
}

test_every_resource_answers_a_versioned_document_with_provenance
test_no_mutating_method_reaches_a_route
test_head_does_not_open_a_long_lived_stream
test_asset_routes_cannot_be_turned_into_a_filesystem_read
test_asset_ancestor_symlink_is_refused_by_descriptor_boundary
test_an_allowed_extension_outside_the_app_directory_is_still_refused
test_the_client_never_depends_on_a_file_url
test_unknown_versions_and_resources_are_refused
test_metrics_are_evidence_backed_or_explicitly_unavailable
test_unavailable_backlog_is_not_reported_as_empty_work
test_malformed_and_missing_records_surface_through_the_api
test_the_stream_is_immediate_and_bounded
test_a_report_is_served_as_data_not_as_markup
test_task_linked_report_overflow_is_unavailable_and_not_addressable
test_unreadable_delivery_evidence_is_unavailable_not_absent
test_report_provenance_names_the_file_that_was_read
test_evidence_collected_mid_change_is_reported_as_what_it_is
test_serve_refuses_when_the_client_is_not_built
test_the_server_can_be_restarted_on_the_same_port
test_nested_evidence_and_usage_inputs_advance_the_cached_generation
test_unchanged_collector_stamp_reuses_cached_generation
test_live_herdr_change_advances_generation_without_a_local_file_change
test_stamp_traversal_stays_bounded_with_many_entries
test_failed_collection_retries_after_a_bounded_backoff
test_concurrent_requests_share_one_in_flight_collection
test_backlog_route_exposes_in_flight_queued_and_done_metadata
test_dev_reload_stream_reports_a_rebuilt_bundle
