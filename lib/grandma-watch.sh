#!/usr/bin/env bash
#
# grandma-watch — analysis campaigns over your chat sessions.
#
#   grandma-watch start "<question>" [--weeks N | --days N] [--scope <substr>]
#       Begin a watch. grandma then analyzes every session in the window (all
#       Claude Code sessions, or only project dirs matching --scope) and, when
#       the window ends, writes a report and notifies you.
#
#   grandma-watch tick        process new sessions + synthesize due reports
#                             (run by launchd daily and opportunistically at
#                             every grandma launch; safe to run any time)
#   grandma-watch list        all watches and their status
#   grandma-watch status      active watches, progress so far
#   grandma-watch report <slug|latest>   print a finished report (marks it seen)
#   grandma-watch finish <slug>          end a watch early: synthesize the report now
#   grandma-watch install-agent          install the daily launchd background job
#
# Design notes (hard lessons baked in):
# - Metrics are mechanical (python over transcript JSONL) — zero LLM, run freely.
# - LLM work (digests, synthesis) is capped per tick, guarded with
#   GRANDMA_DISTILLING=1 (so no SessionEnd hooks fire), run from the grandma repo
#   (neutral cwd, sandbox-readable repo-local files), behind a lockfile.
# - watches/ is gitignored: it contains chat-derived content.

set -uo pipefail
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${GRANDMA_HOME:-$HOME/.grandma}"   # the user's private memory home
WATCHES="$ROOT/watches"
CLAUDE_PROJECTS="$HOME/.claude/projects"
DIGEST_CAP="${GRANDMA_WATCH_DIGEST_CAP:-12}"     # max sessions digested per tick (cost bound)
QUIET_MIN=30                                      # only digest sessions idle >= this many minutes

claude_bin() {
  command -v claude 2>/dev/null && return 0
  for c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [[ -x "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

slugify() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | cut -c1-40 | sed 's/^-//; s/-$//'; }

# ---------------------------------------------------------------- start ----
cmd_start() {
  local question="" weeks="" days="" scope=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --weeks) weeks="$2"; shift 2 ;;
      --days)  days="$2"; shift 2 ;;
      --scope) scope="$2"; shift 2 ;;
      *) if [[ -z "$question" ]]; then question="$1"; fi; shift ;;
    esac
  done
  [[ -z "$question" ]] && { echo "usage: grandma-watch start \"<question>\" [--weeks N | --days N] [--scope <substr>]" >&2; exit 2; }
  local dur_days=14
  [[ -n "$weeks" ]] && dur_days=$((weeks * 7))
  [[ -n "$days"  ]] && dur_days=$days
  local now end slug dir
  now=$(date +%s); end=$((now + dur_days * 86400))
  slug="$(slugify "$question")-$(date +%m%d)"
  dir="$WATCHES/$slug"
  [[ -d "$dir" ]] && { echo "watch '$slug' already exists" >&2; exit 1; }
  mkdir -p "$dir/data" "$dir/.work"
  python3 - "$dir/watch.json" "$question" "$now" "$end" "$scope" <<'PY'
import json, sys
path, q, start, end, scope = sys.argv[1:6]
json.dump({"question": q, "start": int(start), "end": int(end),
           "scope_filter": scope, "status": "active", "last_tick": 0},
          open(path, "w"), indent=1)
PY
  echo "watch started: $slug"
  echo "  question: $question"
  echo "  window:   $dur_days days (report due $(date -r "$end" '+%Y-%m-%d'))"
  echo "  scope:    ${scope:-all sessions}"
  echo "  data:     analyzed automatically at every grandma launch; report lands in watches/$slug/report.md"
  echo "  note:     when the window ends, the report + notification arrive at your next grandma launch"
}

# --------------------------------------------------------------- helpers ----
watch_field() { python3 -c "import json,sys; print(json.load(open('$1')).get('$2',''))" 2>/dev/null; }
set_field()   { python3 -c "
import json,sys
d=json.load(open('$1')); d['$2']=$3
json.dump(d,open('$1','w'),indent=1)" 2>/dev/null; }

# transcripts touched within the watch window, optional scope substring filter
find_transcripts() { # start_epoch scope_filter
  local start="$1" scope="$2" f
  find "$CLAUDE_PROJECTS" -name '*.jsonl' -type f 2>/dev/null | while IFS= read -r f; do
    local m; m=$(stat -f %m "$f" 2>/dev/null || echo 0)
    [[ "$m" -lt "$start" ]] && continue
    if [[ -n "$scope" ]]; then
      case "$(basename "$(dirname "$f")")" in *"$scope"*) ;; *) continue ;; esac
    fi
    echo "$f"
  done
}

# ----------------------------------------------------------------- tick ----
cmd_tick() {
  mkdir -p "$WATCHES"
  # atomic lock; steal if stale (>2h). LOCK is global: the EXIT trap fires after this
  # function returns, where a `local` would be unbound under set -u.
  LOCK="$WATCHES/.tick.lock"
  if ! mkdir "$LOCK" 2>/dev/null; then
    local age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
    [[ "$age" -lt 7200 ]] && exit 0
    rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 0
  fi
  trap 'rm -rf "${LOCK:-}"' EXIT

  local sdir
  for sdir in "$WATCHES"/*/; do
    [[ -f "$sdir/watch.json" ]] || continue
    [[ "$(watch_field "$sdir/watch.json" status)" == "active" ]] || continue
    tick_one "${sdir%/}"
  done
}

tick_one() {
  local dir="$1" sj="$1/watch.json"
  mkdir -p "$dir/data" "$dir/.work"
  local start scope end question now
  start="$(watch_field "$sj" start)"; end="$(watch_field "$sj" end)"
  scope="$(watch_field "$sj" scope_filter)"; question="$(watch_field "$sj" question)"
  now=$(date +%s)

  # ---- 1. mechanical metrics (no LLM): recompute for changed transcripts ----
  find_transcripts "$start" "$scope" > "$dir/.work/transcripts.txt"
  python3 - "$dir" <<'PY'
import json, os, sys
d = sys.argv[1]
work, data = os.path.join(d, ".work"), os.path.join(d, "data")
paths = [p for p in open(os.path.join(work, "transcripts.txt")).read().split("\n") if p.strip()]
mpath = os.path.join(data, "metrics.jsonl")
old = {}
if os.path.exists(mpath):
    for line in open(mpath):
        try: r = json.loads(line); old[r["session"]] = r
        except Exception: pass
for p in paths:
    sid = os.path.basename(p)[:-6]
    mtime = int(os.path.getmtime(p))
    if sid in old and old[sid].get("mtime") == mtime:
        continue
    m = {"session": sid, "mtime": mtime, "project": os.path.basename(os.path.dirname(p)),
         "user_turns": 0, "assistant_turns": 0, "tool_calls": 0, "compactions": 0,
         "in_tok": 0, "out_tok": 0, "cache_read": 0, "cache_create": 0,
         "models": [], "t0": None, "t1": None}
    models = set()
    try:
        for line in open(p, errors="replace"):
            if '"isCompactSummary":true' in line or '"compact_boundary"' in line:
                m["compactions"] += 1
            try: e = json.loads(line)
            except Exception: continue
            ts = e.get("timestamp")
            if ts:
                if not m["t0"] or ts < m["t0"]: m["t0"] = ts
                if not m["t1"] or ts > m["t1"]: m["t1"] = ts
            t = e.get("type")
            msg = e.get("message") or {}
            if t == "user" and isinstance(msg, dict) and msg.get("role") == "user":
                m["user_turns"] += 1
            elif t == "assistant" and isinstance(msg, dict):
                m["assistant_turns"] += 1
                u = msg.get("usage") or {}
                m["in_tok"] += u.get("input_tokens", 0) or 0
                m["out_tok"] += u.get("output_tokens", 0) or 0
                m["cache_read"] += u.get("cache_read_input_tokens", 0) or 0
                m["cache_create"] += u.get("cache_creation_input_tokens", 0) or 0
                if msg.get("model"): models.add(msg["model"])
                for b in (msg.get("content") or []):
                    if isinstance(b, dict) and b.get("type") == "tool_use":
                        m["tool_calls"] += 1
    except Exception:
        continue
    m["models"] = sorted(models)
    if m["t0"] and m["t1"]:
        from datetime import datetime
        f = "%Y-%m-%dT%H:%M:%S"
        try:
            dt = (datetime.strptime(m["t1"][:19], f) - datetime.strptime(m["t0"][:19], f)).total_seconds()
            m["duration_min"] = round(dt / 60, 1)
        except Exception:
            m["duration_min"] = None
    old[sid] = m
with open(mpath, "w") as f:
    for r in old.values():
        f.write(json.dumps(r) + "\n")
print(f"metrics: {len(old)} sessions")
PY

  # ---- 2. LLM micro-digests: new, quiet sessions, capped per tick ----
  local CB; CB="$(claude_bin || true)"
  if [[ -n "$CB" ]]; then
    touch "$dir/data/digests.done"
    : > "$dir/.work/batch.md"
    local n=0 f sid m age sz
    # digest the most substantial sessions first (size as proxy); skip trivial ones
    while IFS= read -r f; do
      [[ "$n" -ge "$DIGEST_CAP" ]] && break
      sid="$(basename "$f" .jsonl)"
      grep -q "^$sid\$" "$dir/data/digests.done" && continue
      sz=$(stat -f %z "$f" 2>/dev/null || echo 0)
      [[ "$sz" -lt 20000 ]] && continue   # skip no-op / trivial sessions
      m=$(stat -f %m "$f" 2>/dev/null || echo 0); age=$(( ($(date +%s) - m) / 60 ))
      [[ "$age" -lt "$QUIET_MIN" ]] && continue
      # readable excerpt, bounded
      python3 - "$f" "$sid" >> "$dir/.work/batch.md" <<'PY'
import json, sys
p, sid = sys.argv[1], sys.argv[2]
turns = []
for line in open(p, errors="replace"):
    try: e = json.loads(line)
    except Exception: continue
    msg = e.get("message") or {}
    role = msg.get("role")
    if e.get("type") not in ("user", "assistant") or not role: continue
    c = msg.get("content")
    if isinstance(c, str): txt = c
    elif isinstance(c, list):
        txt = "\n".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    else: txt = ""
    txt = txt.strip()
    if txt: turns.append(f"{role.upper()}: {txt}")
body = "\n".join(turns)
if len(body) > 24000:
    body = body[:12000] + "\n[... middle truncated ...]\n" + body[-12000:]
print(f"\n===== SESSION {sid} =====\n{body}\n")
PY
      echo "$sid" >> "$dir/.work/batch.ids"
      n=$((n + 1))
    done < <(while IFS= read -r _p; do printf '%s\t%s\n' "$(stat -f %z "$_p" 2>/dev/null || echo 0)" "$_p"; done < "$dir/.work/transcripts.txt" | sort -rn | cut -f2)

    if [[ "$n" -gt 0 && -s "$dir/.work/batch.md" ]]; then
      local SYS OUT
      SYS="$(cat "$ENGINE/prompts/watch-digest.md")

STUDY QUESTION: $question"
      OUT="$( cd "$ROOT" && GRANDMA_DISTILLING=1 "$CB" -p \
        "Digest each session below per your instructions, focused on the watch question.

$(cat "$dir/.work/batch.md")" \
        --append-system-prompt "$SYS" 2>/dev/null )" || OUT=""
      if [[ -n "$OUT" ]]; then
        { echo; echo "----- tick $(date '+%Y-%m-%d %H:%M') -----"; printf '%s\n' "$OUT"; } >> "$dir/data/digests.md"
        cat "$dir/.work/batch.ids" >> "$dir/data/digests.done"
      fi
      rm -f "$dir/.work/batch.md" "$dir/.work/batch.ids"
    fi
  fi

  set_field "$sj" last_tick "$now"

  # ---- 3. deadline passed -> synthesize the report ----
  if [[ "$now" -ge "$end" && ! -f "$dir/report.md" && -n "${CB:-}" ]]; then
    python3 - "$dir" > "$dir/.work/metrics-summary.md" <<'PY'
import json, os, sys
d = sys.argv[1]
rows = [json.loads(l) for l in open(os.path.join(d, "data", "metrics.jsonl")) if l.strip()]
rows.sort(key=lambda r: r.get("t0") or "")
tot = lambda k: sum(r.get(k) or 0 for r in rows)
print(f"sessions analyzed: {len(rows)}")
print(f"totals: user_turns={tot('user_turns')} assistant_turns={tot('assistant_turns')} "
      f"tool_calls={tot('tool_calls')} compactions={tot('compactions')}")
print(f"tokens: input={tot('in_tok')} output={tot('out_tok')} "
      f"cache_read={tot('cache_read')} cache_create={tot('cache_create')}")
print("\nper-session:")
print("date | project | dur_min | u_turns | a_turns | tools | compact | in_tok | out_tok | cache_read | models")
for r in rows:
    print(f"{(r.get('t0') or '?')[:10]} | {r.get('project','?')[-40:]} | {r.get('duration_min')} | "
          f"{r.get('user_turns')} | {r.get('assistant_turns')} | {r.get('tool_calls')} | "
          f"{r.get('compactions')} | {r.get('in_tok')} | {r.get('out_tok')} | {r.get('cache_read')} | "
          f"{','.join(r.get('models') or [])}")
PY
    local RSYS
    RSYS="$(cat "$ENGINE/prompts/watch-report.md")

STUDY QUESTION: $question"
    ( cd "$ROOT" && GRANDMA_DISTILLING=1 "$CB" -p \
      "Write the final watch report per your instructions.

===== METRICS =====
$(cat "$dir/.work/metrics-summary.md")

===== SESSION DIGESTS =====
$(cat "$dir/data/digests.md" 2>/dev/null || echo '(no digests collected)')" \
      --append-system-prompt "$RSYS" 2>/dev/null ) > "$dir/report.md" || true
    if [[ -s "$dir/report.md" ]]; then
      set_field "$sj" status '"complete"'
      osascript -e "display notification \"Report ready: $(basename "$dir")\" with title \"grandma watch\" sound name \"Glass\"" 2>/dev/null || true
    else
      rm -f "$dir/report.md"
    fi
  fi
}

# ------------------------------------------------------- list / status ----
cmd_list() {
  local sdir found=0
  for sdir in "$WATCHES"/*/; do
    [[ -f "$sdir/watch.json" ]] || continue
    found=1
    local sj="$sdir/watch.json"
    printf '%-44s %-9s due %s  %s\n' "$(basename "$sdir")" \
      "$(watch_field "$sj" status)" \
      "$(date -r "$(watch_field "$sj" end)" '+%Y-%m-%d' 2>/dev/null)" \
      "\"$(watch_field "$sj" question | cut -c1-50)\""
  done
  [[ "$found" == "0" ]] && echo "no watches. start one: grandma-watch start \"<question>\" --weeks 2"
  return 0
}

cmd_status() {
  local sdir
  for sdir in "$WATCHES"/*/; do
    [[ -f "$sdir/watch.json" ]] || continue
    local sj="$sdir/watch.json" n=0 dn=0
    [[ -f "$sdir/data/metrics.jsonl" ]] && n=$(wc -l < "$sdir/data/metrics.jsonl" | tr -d ' ')
    [[ -f "$sdir/data/digests.done" ]] && dn=$(wc -l < "$sdir/data/digests.done" | tr -d ' ')
    echo "$(basename "$sdir") [$(watch_field "$sj" status)]"
    echo "  question:  $(watch_field "$sj" question)"
    echo "  window:    $(date -r "$(watch_field "$sj" start)" '+%Y-%m-%d') -> $(date -r "$(watch_field "$sj" end)" '+%Y-%m-%d')"
    echo "  progress:  $n sessions measured, $dn digested"
    [[ -f "$sdir/report.md" ]] && echo "  report:    $sdir/report.md"
  done
  return 0
}

cmd_report() {
  local which="${1:-latest}" f=""
  if [[ "$which" == "latest" ]]; then
    f="$(ls -t "$WATCHES"/*/report.md 2>/dev/null | head -1)"
  else
    f="$WATCHES/$which/report.md"
  fi
  [[ -f "$f" ]] || { echo "no report found${which:+ for '$which'}. grandma-watch list" >&2; exit 1; }
  cat "$f"
  touch "$(dirname "$f")/.seen"
}

# --------------------------------------------------------------- finish ----
cmd_finish() {
  local slug="${1:-}" sj="$WATCHES/${1:-}/watch.json"
  [[ -n "$slug" && -f "$sj" ]] || { echo "usage: grandma-watch finish <slug>   (see: grandma-watch list)" >&2; exit 2; }
  [[ "$(watch_field "$sj" status)" == "active" ]] || { echo "watch '$slug' is not active" >&2; exit 1; }
  set_field "$sj" end "$(( $(date +%s) - 1 ))"
  echo "ending '$slug' now: final tick + synthesis (may take a minute)..."
  cmd_tick
  [[ -f "$WATCHES/$slug/report.md" ]] && echo "report ready: grandma-watch report $slug" || echo "synthesis did not produce a report; check /tmp/grandma-watch.log and retry with: grandma-watch tick" >&2
}

# -------------------------------------------------------- install-agent ----
# OPTIONAL and macOS-caveated: launchd agents cannot read ~/Documents without a
# TCC grant (Full Disk Access for /bin/bash), so out of the box this job fails with
# "Operation not permitted" when the grandma repo lives under ~/Documents. The
# default mechanism is the opportunistic tick fired at every grandma launch, which
# runs in your terminal's (TCC-granted) context and needs no setup.
cmd_install_agent() {
  echo "NOTE: this requires Full Disk Access for /bin/bash (System Settings > Privacy &" >&2
  echo "Security > Full Disk Access), or launchd cannot read the grandma repo under" >&2
  echo "~/Documents. Without that grant, skip this: watches tick at every grandma launch." >&2
  local plist="$HOME/Library/LaunchAgents/com.grandma.watch.plist"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.grandma.watch</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$ENGINE/lib/grandma-watch.sh</string><string>tick</string>
  </array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>20</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>/tmp/grandma-watch.log</string>
  <key>StandardErrorPath</key><string>/tmp/grandma-watch.log</string>
</dict></plist>
EOF
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist" && echo "background agent installed: daily tick at 20:00 (log: /tmp/grandma-watch.log)"
}

# ----------------------------------------------------------------- main ----
case "${1:-}" in
  start)         shift; cmd_start "$@" ;;
  tick)          cmd_tick ;;
  list)          cmd_list ;;
  status)        cmd_status ;;
  report)        shift; cmd_report "$@" ;;
  finish)        shift; cmd_finish "$@" ;;
  install-agent) cmd_install_agent ;;
  *) sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
