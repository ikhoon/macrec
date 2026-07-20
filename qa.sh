#!/bin/zsh
# qa.sh — tier-2 ON-MACHINE QA scenarios (see AGENTS.md; tier-1 scenarios ride `macrec selftest`).
#
# These exercise the integrations the in-process suite cannot: real launchd, the real claude CLI and
# its credentials, the real installed binary. Run before an install/PR that touches the digest, audio,
# or install paths — and always pre-release.
#
#   ./qa.sh            run all scenarios
#   ./qa.sh s1 s3      run selected scenarios
#
# A missing precondition SKIPs loudly (never counts as PASS); any FAIL exits non-zero with the evidence
# (the redirected output file — the "Not logged in" incident hid its reason inside one for three days).
set -u

PASS=0; FAIL=0; SKIP=0
pass() { print -r -- "  ✅ $1"; PASS=$((PASS+1)) }
fail() { print -r -- "  ❌ $1"; FAIL=$((FAIL+1)) }
skip() { print -r -- "  ⏭️  SKIP: $1"; SKIP=$((SKIP+1)) }

SCRATCH=$(mktemp -d /tmp/macrec-qa.XXXXXX)
QA_LABEL="com.ikhoon.macrec.qa-digest"
cleanup() {
  launchctl bootout "gui/$(id -u)/$QA_LABEL" 2>/dev/null || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

# The claude token, the way the app resolves it (DailyDigest.swift): the explicit Settings token from
# the 0600 credentials file, else the CLI's own current token harvested from its Keychain item.
claude_token() {
  local cred="$HOME/Library/Application Support/macrec/credentials.json"
  if [[ -f "$cred" ]]; then
    local t
    t=$(python3 -c "import json;print(json.load(open('$cred')).get('claude',''))" 2>/dev/null)
    [[ -n "$t" ]] && { print -r -- "$t"; return }
  fi
  security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | python3 -c '
import json, sys, time
try:
    d = json.load(sys.stdin); o = d.get("claudeAiOauth", d)
    tok = o.get("accessToken", ""); exp = o.get("expiresAt", 0)
    print(tok if tok and (not exp or time.time() * 1000 < exp) else "")
except Exception:
    print("")'
}

# ---- s1 — launchd claude auth (guards the "Not logged in under launchd" incident) -------------------
s1() {
  print -r -- "s1: digest-shaped claude run under REAL launchd"
  local token; token=$(claude_token)
  if [[ -z "$token" ]]; then skip "no claude token (credentials.json or CLI keychain)"; return; fi
  print -r -- 'project kickoff: decided to ship v2' > "$SCRATCH/in.md"   # mock fixture only
  # Mirrors dailyDigestInvocation's shape: redirect to .partial, promote on success — so file-exists ≡ exit-0.
  cat > "$SCRATCH/qa.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$QA_LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/zsh</string><string>-lc</string>
    <string>cat "$SCRATCH/in.md" | claude -p 'Reply with the single word OK' > "$SCRATCH/out.partial" 2>"$SCRATCH/qa.err" &amp;&amp; mv "$SCRATCH/out.partial" "$SCRATCH/out"</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>CLAUDE_CODE_OAUTH_TOKEN</key><string>$token</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/$QA_LABEL" 2>/dev/null || true
  if ! launchctl bootstrap "gui/$(id -u)" "$SCRATCH/qa.plist"; then fail "s1: launchctl bootstrap failed"; return; fi
  # RunAtLoad does NOT fire when bootstrapping from a non-login shell context (verified with a
  # trivial echo job: bootstrap alone never spawned it, kickstart ran it instantly) — so kick
  # explicitly instead of waiting 120 s for a launch that never comes.
  launchctl kickstart "gui/$(id -u)/$QA_LABEL" 2>/dev/null || true
  local waited=0
  while [[ ! -s "$SCRATCH/out" && $waited -lt 120 ]]; do sleep 3; waited=$((waited+3)); done
  launchctl bootout "gui/$(id -u)/$QA_LABEL" 2>/dev/null || true
  if [[ -s "$SCRATCH/out" ]]; then
    pass "s1: claude authenticated under launchd (out: $(head -c 60 "$SCRATCH/out" | tr -d '\n'))"
  else
    fail "s1: no output after ${waited}s — reason follows"
    [[ -f "$SCRATCH/out.partial" ]] && { print -r -- "  --- out.partial:"; head -5 "$SCRATCH/out.partial" | sed 's/^/      /' }
    [[ -f "$SCRATCH/qa.err" ]] && { print -r -- "  --- stderr:"; head -5 "$SCRATCH/qa.err" | sed 's/^/      /' }
  fi
}

# ---- s2 — summary-shaped claude run (the seam the Library Re-run and the engine auto-summary share) --
s2() {
  print -r -- "s2: summary-shaped claude run through the runner invocation shape (login shell, real CLI)"
  local token; token=$(claude_token)
  if [[ -z "$token" ]]; then skip "no claude token (credentials.json or CLI keychain)"; return; fi
  print -r -- '[10:00:05] Me: project kickoff begins' > "$SCRATCH/t.md"   # mock fixture only
  local stem="2026-03-02-1000-project-kickoff"
  local out="$SCRATCH/sum/$stem.md"
  # Mirrors postProcessInvocation(.summary, .claude) + titledPromoteTail in shape: mkdir -p, stdin
  # redirect, .partial → titled promote → rm. The Library Re-run button and the engine's automatic
  # run both execute exactly this command via runPostProcessCommand (zsh -lc + the token env).
  local cmd="mkdir -p '$SCRATCH/sum' && claude -p 'Reply with the single word OK' < '$SCRATCH/t.md' > '$out.partial' && { printf '# %s\n\n' '$stem'; cat '$out.partial'; } > '$out.partial2' && mv '$out.partial2' '$out' && rm -f '$out.partial'"
  if CLAUDE_CODE_OAUTH_TOKEN="$token" PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/bin:$PATH" \
     /bin/zsh -lc "$cmd" > "$SCRATCH/s2.log" 2>&1; then
    local head1; head1=$(head -1 "$out" 2>/dev/null)
    if [[ "$head1" == "# $stem" && ! -f "$out.partial" && -s "$out" ]]; then
      pass "s2: promote contract held (H1 title, partial reaped, body: $(sed -n '3p' "$out" | head -c 40 | tr -d '\n'))"
    else
      fail "s2: output malformed — head1='$head1' partial-left=$([[ -f "$out.partial" ]] && echo yes || echo no)"
    fi
  else
    fail "s2: runner exited non-zero — reason follows (the .partial keeps the runner's words)"
    [[ -f "$out.partial" ]] && head -3 "$out.partial" | sed 's/^/      /'
    head -3 "$SCRATCH/s2.log" | sed 's/^/      /'
  fi
}

# ---- s3 — keychain-prompt-free (guards the per-rebuild "allow access" storm) ------------------------
s3() {
  print -r -- "s3: credentials store is file-backed — the binary cannot prompt (static+state checks)"
  local bin="/Applications/macrec.app/Contents/MacOS/macrec"
  if [[ ! -x "$bin" ]]; then skip "macrec.app not installed"; return; fi
  # The app must not link any SecItem READ/WRITE — a read is an authorization check the OS may turn
  # into a prompt. SecItemDelete alone is tolerated (the optional legacy-item purge helper).
  local syms; syms=$(nm -mu "$bin" 2>/dev/null | grep -oE '_SecItem[A-Za-z]+' | sort -u | grep -v '^_SecItemDelete$' || true)
  if [[ -z "$syms" ]]; then pass "s3: no SecItem read/write symbols in the binary"
  else fail "s3: keychain symbols present: ${syms//$'\n'/ }"; fi
  local cred="$HOME/Library/Application Support/macrec/credentials.json"
  if [[ -f "$cred" ]]; then
    local mode; mode=$(stat -f '%Lp' "$cred")
    [[ "$mode" == "600" ]] && pass "s3: credentials.json is 0600" || fail "s3: credentials.json mode is $mode (want 600)"
  else
    skip "s3: no credentials.json yet (created on first key save)"
  fi
  print -r -- "  (static+state checks — an observed zero-prompt run still needs a human eye)"
}

# ---- s4 — eval runner end-to-end (real binary, real shell engines, tiny generated corpus) ----------
s4() {
  print -r -- "s4: macrec eval — corpus discovery, template engines, CER + RTF report"
  local bin=".build/debug/macrec"
  [[ -x "$bin" ]] || bin="/Applications/macrec.app/Contents/MacOS/macrec"
  if [[ ! -x "$bin" ]]; then skip "s4: no macrec binary (swift build first)"; return; fi
  local dir="$SCRATCH/eval"
  mkdir -p "$dir"
  # A 1-second silent 16 kHz wav is enough — the ENGINES are stubs; s4 proves the harness plumbing.
  python3 - "$dir/clip.ko.wav" <<'PY'
import struct, sys
n = 16000
with open(sys.argv[1], 'wb') as f:
    f.write(b'RIFF' + struct.pack('<I', 36 + n*2) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, 1, 16000, 32000, 2, 16))
    f.write(b'data' + struct.pack('<I', n*2) + b'\x00' * (n*2))
PY
  print -r -- "회의 시작하겠습니다" > "$dir/clip.ko.txt"
  local out
  out=$("$bin" eval "$dir" \
        --engine 'perfect=echo 회의 시작하겠습니다 # {wav}' \
        --engine 'wrong=echo 전부 틀린 답변입니다 # {wav}' 2>&1)
  # Anchored + discriminating (review finding): the perfect ROW must read 0.0% AND the wrong
  # row must NOT — a scorer that collapses everything to zero must turn this red.
  if print -r -- "$out" | grep -qE 'perfect[^0-9]*0\.0%' \
     && ! print -r -- "$out" | grep -qE 'wrong[^0-9]*0\.0%' \
     && print -r -- "$out" | grep -qE "RTF" && [[ -s "$dir/out/clip.ko.perfect.txt" ]]; then
    pass "s4: eval scored perfect=0.0%, wrong>0%, and dumped hypotheses"
  else
    fail "s4: eval output unexpected — $(print -r -- "$out" | head -3 | tr '\n' ' ')"
  fi
}

# ---- s5 — retention sweep end-to-end (real binary, real afconvert, backdated tiers) ----------------
s5() {
  print -r -- "s5: macrec sweep — wav→m4a archival and expiry on a backdated fixture library"
  local bin=".build/debug/macrec"
  [[ -x "$bin" ]] || bin="/Applications/macrec.app/Contents/MacOS/macrec"
  if [[ ! -x "$bin" ]]; then skip "s5: no macrec binary (swift build first)"; return; fi
  local lib="$SCRATCH/audio/2026-03"
  mkdir -p "$lib"
  # Three tiers: fresh (stays wav), old (archives to m4a), ancient (expires entirely).
  python3 - "$lib/2026-03-20-1000-fresh.wav" "$lib/2026-03-10-1000-old.wav" "$lib/2026-03-01-1000-ancient.wav" <<'PY'
import math, struct, sys
for p in sys.argv[1:]:
    n = 16000
    with open(p, 'wb') as f:
        f.write(b'RIFF' + struct.pack('<I', 36 + n*2) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, 1, 16000, 32000, 2, 16))
        f.write(b'data' + struct.pack('<I', n*2))
        f.write(b''.join(struct.pack('<h', int(9000*math.sin(i*0.13))) for i in range(n)))
PY
  touch -t "$(date -v-2d +%Y%m%d%H%M)" "$lib/2026-03-20-1000-fresh.wav"
  touch -t "$(date -v-10d +%Y%m%d%H%M)" "$lib/2026-03-10-1000-old.wav"
  touch -t "$(date -v-40d +%Y%m%d%H%M)" "$lib/2026-03-01-1000-ancient.wav"
  "$bin" sweep --audio-dir "$SCRATCH/audio" --raw-days 7 --keep-days 30 > "$SCRATCH/s5.log" 2>&1
  local ok=1
  [[ -f "$lib/2026-03-20-1000-fresh.wav" && ! -f "$lib/2026-03-20-1000-fresh.m4a" ]] || { ok=0; print -r -- "  fresh tier wrong (archived early or vanished)"; }
  [[ -f "$lib/2026-03-10-1000-old.m4a" && ! -f "$lib/2026-03-10-1000-old.wav" ]] || { ok=0; print -r -- "  old wav not archived to m4a"; }
  [[ ! -f "$lib/2026-03-01-1000-ancient.wav" && ! -f "$lib/2026-03-01-1000-ancient.m4a" ]] || { ok=0; print -r -- "  ancient file survived expiry"; }
  if [[ $ok -eq 1 ]]; then
    pass "s5: tiers held — fresh kept, old archived, ancient expired"
  else
    fail "s5: retention tiers wrong — sweep log follows"
    head -5 "$SCRATCH/s5.log" | sed 's/^/      /'
  fi
}

# ---- s6 — structured daily-log extraction (real claude, the JSON-sidecar runner seam) --------------
s6() {
  print -r -- "s6: structured JSON sidecar — real claude distills a digest into valid schema JSON"
  local token; token=$(claude_token)
  if [[ -z "$token" ]]; then skip "no claude token (credentials.json or CLI keychain)"; return; fi
  # A tiny fixture digest (mock content only). The prompt shape mirrors structuredDigestInvocation.
  print -r -- "# 2026-03-02\n\n## Decisions\n- Ship increment one first.\n\n## Action items\n- [ ] draft the plan — alex\n" > "$SCRATCH/digest.md"
  local prompt='From this daily digest, extract a structured record. Output ONLY minified JSON (no markdown, no code fence, no prose) with EXACTLY these keys: {"date":"2026-03-02","meetings":[],"decisions":[{"text":"","meeting":""}],"actionItems":[{"text":"","owner":"","due":"","done":false}],"entities":[{"name":"","kind":""}]}. Omit optional string fields when unknown; keep arrays empty if there is nothing.'
  cat "$SCRATCH/digest.md" | CLAUDE_CODE_OAUTH_TOKEN="$token" PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH" \
    /bin/zsh -lc "claude -p '$prompt'" > "$SCRATCH/struct.json" 2>"$SCRATCH/struct.err"
  # Validate the way the app does: strip an optional fence, parse, require date + array-typed collections.
  if python3 - "$SCRATCH/struct.json" <<'PY'
import json, sys, re
raw = open(sys.argv[1]).read().strip()
raw = re.sub(r'^```json|^```|```$', '', raw, flags=re.M).strip()
try: d = json.loads(raw)
except Exception as e: print("parse-fail", e); sys.exit(1)
ok = isinstance(d, dict) and isinstance(d.get("date"), str) \
     and all(not (k in d) or isinstance(d[k], list) for k in ("meetings","decisions","actionItems","entities"))
sys.exit(0 if ok else 2)
PY
  then
    pass "s6: claude produced schema-valid structured JSON ($(head -c 60 "$SCRATCH/struct.json" | tr -d '\n'))"
  else
    fail "s6: structured JSON invalid — reply follows"
    head -3 "$SCRATCH/struct.json" | sed 's/^/      /'
    head -2 "$SCRATCH/struct.err" | sed 's/^/      /'
  fi
}

# ---- s7 — recorder silent-outage detection on the REAL binary + REAL system uptime (#27) -----------
s7() {
  print -r -- "s7: outage-check — the real binary reads the real system uptime and decides an 18h gap"
  local bin=".build/debug/macrec"
  [[ -x "$bin" ]] || bin="/Applications/macrec.app/Contents/MacOS/macrec"
  if [[ ! -x "$bin" ]]; then skip "s7: no macrec binary (swift build first)"; return; fi
  # The detector calls an 18h gap benign if the mac REBOOTED during it (uptime < gap) — so a real
  # outage can only be proven when the mac has been up longer than the gap we inject. Read boot time
  # and pick a gap safely under it; if the mac just booted, SKIP loudly (never a false PASS).
  local uptime; uptime=$("$bin" outage-check --heartbeat-ago 1 | sed -nE 's/.*uptime=([0-9]+).*/\1/p')
  if [[ -z "$uptime" || "$uptime" -lt 5400 ]]; then skip "s7: mac up only ${uptime:-?}s (<90m) — can't out-span a real gap"; return; fi
  # A gap the mac was awake across → a real outage; a 1-second gap → benign. Both on the real uptime.
  local big small
  big=$("$bin" outage-check --heartbeat-ago 3600 | sed -nE 's/.*outage=([a-z0-9]+).*/\1/p')
  small=$("$bin" outage-check --heartbeat-ago 1 | sed -nE 's/.*outage=([a-z0-9]+).*/\1/p')
  if [[ "$big" == "3600" && "$small" == "none" ]]; then
    pass "s7: real binary flagged a 1h awake-mac gap (outage=$big) and cleared a 1s blip"
  else
    fail "s7: outage-check wrong — 1h gap→'$big' (want 3600), 1s→'$small' (want none), uptime=${uptime}s"
  fi
}

# ---- s8 — outage persistence is read back across a SEPARATE process launch (#27) ------------------
s8() {
  print -r -- "s8: a persisted outage written by one process is read back by a fresh outage-check launch"
  local bin="/Applications/macrec.app/Contents/MacOS/macrec"
  [[ -x "$bin" ]] || bin=".build/debug/macrec"
  if [[ ! -x "$bin" ]]; then skip "s8: no macrec binary"; return; fi
  local suite="com.ikhoon.macrec.prefs"
  # Snapshot + restore the real keys so a running recorder isn't disturbed (the incident's own seam:
  # a stamp written by a dead process must survive to the next launch).
  local savedAt savedSecs
  savedAt=$(defaults read "$suite" recorderOutageAt 2>/dev/null || echo "")
  savedSecs=$(defaults read "$suite" recorderOutageSeconds 2>/dev/null || echo "")
  local now; now=$(date +%s)
  defaults write "$suite" recorderOutageAt -float "$now"
  defaults write "$suite" recorderOutageSeconds -float 64800   # 18h
  local out; out=$("$bin" outage-check | sed -nE 's/.*last-outage-today=([a-z0-9]+).*/\1/p')
  # Restore (or clear) so we leave the tester's prefs exactly as found.
  if [[ -n "$savedAt" ]]; then defaults write "$suite" recorderOutageAt -float "$savedAt"; else defaults delete "$suite" recorderOutageAt 2>/dev/null; fi
  if [[ -n "$savedSecs" ]]; then defaults write "$suite" recorderOutageSeconds -float "$savedSecs"; else defaults delete "$suite" recorderOutageSeconds 2>/dev/null; fi
  if [[ "$out" == "64800" ]]; then
    pass "s8: fresh process read back the persisted same-day outage (last-outage-today=$out)"
  else
    fail "s8: cross-process read-back wrong — got '$out' (want 64800)"
  fi
}

print -r -- "macrec QA (tier 2) — scratch: $SCRATCH"
if [[ $# -eq 0 ]]; then s1; s2; s3; s4; s5; s6; s7; s8; else for s in "$@"; do "$s"; done; fi
print -r -- ""
print -r -- "qa: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]] || exit 1
