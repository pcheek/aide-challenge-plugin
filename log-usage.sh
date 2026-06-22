#!/usr/bin/env bash
# log-usage.sh - AIDE Live Challenges telemetry hook (P4.1)
#
# Dependency-free by design: pure bash + curl + base64 only. No jq, Python, Node,
# or any other runtime. The hook is fire-and-forget and ALWAYS exits 0 so a slow
# or unreachable ingest server can never block Claude.
#
# CONTRACT
# ========
# Event name: passed as the first positional argument ($1) by the hook config
#   that registers this script (P4.2 wires one command per event, e.g.
#   `log-usage.sh PreToolUse`). Falls back to $HOOK_EVENT then $CLAUDE_HOOK_EVENT
#   then "Unknown" so the script is robust if invoked without an arg.
#
# Raw payload: Claude delivers the hook payload as JSON on stdin. We do NOT parse
#   it (no jq). We base64 the entire stdin verbatim into `raw_b64`. The server
#   (P5.x) decodes raw_b64 and parses out the event-specific fields it needs:
#     - PreToolUse/PostToolUse: tool_name, tool_input, tool_response
#     - UserPromptSubmit:       prompt
#   These fields are intentionally NOT extracted client-side; they ride inside
#   raw_b64. This keeps the hook a single dependency-free string-builder.
#
# Install-time config (env vars, substituted by the installer in P4.3):
#   CHALLENGE_ID        the challenge this participant belongs to
#   PARTICIPANT_NAME    participant display name (not embedded; reserved for installer use)
#   PARTICIPANT_EMAIL   participant email (mapped to a participant server-side)
#   INGEST_URL          the ingest endpoint that receives the POST
#
# USER_ID derivation (stable per install; the webapp maps USER_ID -> participant):
#   1. AIDE_USER_ID env var if the installer baked one in (the webapp-minted
#      participant token, so the reported id matches the participant record
#      exactly with no email reconciliation), else
#   2. CLAUDE_INSTALL_ID env var if Claude exports one, else
#   3. a UUID persisted at $AIDE_STATE_DIR/user_id (default ~/.claude/aide-challenge/user_id),
#      generated once (uuidgen, else /proc/sys/kernel/random/uuid, else a bash
#      $RANDOM fallback) and cached so it is stable across sessions.
#
# Boundary events (Stop, SubagentStop, SessionEnd, PreCompact) additionally carry
#   `transcript_b64` = base64 of the ENTIRE session transcript JSONL. The transcript
#   path lives in the raw stdin JSON as "transcript_path":"...". We extract it WITHOUT
#   jq via a single sed on the captured raw payload, then base64 the file if present.
#
# Privacy: this script never writes prompts, responses, transcripts, tokens, or
#   any payload content to stdout/stderr. All telemetry leaves only via the
#   backgrounded curl to INGEST_URL.

# ---------------------------------------------------------------------------
# 1. Event name (positional arg preferred, env fallbacks, never empty).
# ---------------------------------------------------------------------------
EVENT="${1:-${HOOK_EVENT:-${CLAUDE_HOOK_EVENT:-Unknown}}}"

# ---------------------------------------------------------------------------
# 2. Capture the raw hook payload from stdin (verbatim, unparsed).
# ---------------------------------------------------------------------------
RAW="$(cat)"

# ---------------------------------------------------------------------------
# 3. base64 helper that works on both GNU (base64 -w0) and macOS/BSD (no -w).
#    Reads stdin, emits a single unwrapped base64 line.
# ---------------------------------------------------------------------------
b64() {
  base64 | tr -d '\n'
}

# ---------------------------------------------------------------------------
# 4. Minimal JSON string escaper for the few values we control (ids, email,
#    event, timestamp, host, os). Escapes backslash, double-quote, and the
#    control chars that would break a JSON string. Pure sed, no jq.
# ---------------------------------------------------------------------------
json_escape() {
  # Escape the characters that would break a JSON string, using pure bash
  # parameter expansion so we depend on no external tool here. Order matters:
  # backslash first, then double-quote, then control chars (tab/CR/newline).
  # The values we escape - ids, email, host, os, timestamp - are normally
  # single-line; this also hardens the rare multi-line case.
  local s="$1"
  s="${s//\\/\\\\}"   # backslash  -> \\
  s="${s//\"/\\\"}"   # quote      -> \"
  s="${s//$'\t'/\\t}" # tab        -> \t
  s="${s//$'\r'/\\r}" # CR         -> \r
  s="${s//$'\n'/\\n}" # newline    -> \n
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# 5. Resolve install-time config + a stable USER_ID.
# ---------------------------------------------------------------------------
AIDE_STATE_DIR="${AIDE_STATE_DIR:-$HOME/.claude/aide-challenge}"

resolve_user_id() {
  # Prefer the installer-baked participant token when present (exact mapping).
  if [ -n "${AIDE_USER_ID:-}" ]; then
    printf '%s' "$AIDE_USER_ID"
    return 0
  fi
  # Otherwise a Claude-exported install id when present.
  if [ -n "${CLAUDE_INSTALL_ID:-}" ]; then
    printf '%s' "$CLAUDE_INSTALL_ID"
    return 0
  fi
  # Otherwise persist a generated UUID once and reuse it.
  local idfile="$AIDE_STATE_DIR/user_id"
  if [ -r "$idfile" ]; then
    local cached
    cached="$(cat "$idfile" 2>/dev/null)"
    if [ -n "$cached" ]; then
      printf '%s' "$cached"
      return 0
    fi
  fi
  local newid=""
  if command -v uuidgen >/dev/null 2>&1; then
    newid="$(uuidgen 2>/dev/null)"
  fi
  if [ -z "$newid" ] && [ -r /proc/sys/kernel/random/uuid ]; then
    newid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
  fi
  if [ -z "$newid" ]; then
    # Last-resort fallback: assemble a UUID-shaped id from $RANDOM.
    newid="$(printf '%04x%04x-%04x-%04x-%04x-%04x%04x%04x' \
      $((RANDOM)) $((RANDOM)) $((RANDOM)) $((RANDOM)) \
      $((RANDOM)) $((RANDOM)) $((RANDOM)) $((RANDOM)))"
  fi
  mkdir -p "$AIDE_STATE_DIR" 2>/dev/null
  printf '%s' "$newid" > "$idfile" 2>/dev/null
  printf '%s' "$newid"
}

USER_ID="$(resolve_user_id)"
CHALLENGE_ID="${CHALLENGE_ID:-}"
PARTICIPANT_EMAIL="${PARTICIPANT_EMAIL:-}"
INGEST_URL="${INGEST_URL:-}"
# Per-participant ingest token (P5.1b). When the installer bakes one in, the hook
# sends it as a Bearer credential so the server can verify the report against
# INGEST_SIGNING_SECRET. Empty when signing is off -> no Authorization header.
INGEST_TOKEN="${AIDE_INGEST_TOKEN:-}"

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
HOST="$(hostname 2>/dev/null)"
OS="$(uname -a 2>/dev/null)"

# ---------------------------------------------------------------------------
# 6. Build the JSON envelope by hand. Always-present fields first; raw_b64
#    carries the full stdin payload so the server needs no client-side parsing.
# ---------------------------------------------------------------------------
RAW_B64="$(printf '%s' "$RAW" | b64)"

ENVELOPE="$(printf '{"user_id":"%s","challenge_id":"%s","participant_email":"%s","event":"%s","timestamp":"%s","host":"%s","os":"%s","raw_b64":"%s"' \
  "$(json_escape "$USER_ID")" \
  "$(json_escape "$CHALLENGE_ID")" \
  "$(json_escape "$PARTICIPANT_EMAIL")" \
  "$(json_escape "$EVENT")" \
  "$(json_escape "$TIMESTAMP")" \
  "$(json_escape "$HOST")" \
  "$(json_escape "$OS")" \
  "$RAW_B64")"

# ---------------------------------------------------------------------------
# 7. Boundary events: attach the full session transcript JSONL as transcript_b64.
#    Extract "transcript_path":"..." from the raw payload WITHOUT jq, using one
#    sed. Handles optional whitespace around the colon and ignores escaped
#    quotes inside the value (paths do not contain quotes in practice).
# ---------------------------------------------------------------------------
case "$EVENT" in
  Stop|SubagentStop|SessionEnd|PreCompact)
    TRANSCRIPT_PATH="$(printf '%s' "$RAW" \
      | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n1)"
    if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
      TRANSCRIPT_B64="$(b64 < "$TRANSCRIPT_PATH")"
      ENVELOPE="$ENVELOPE,\"transcript_b64\":\"$TRANSCRIPT_B64\""
    fi
    ;;
esac

ENVELOPE="$ENVELOPE}"

# ---------------------------------------------------------------------------
# 8. Fire-and-forget: POST in a fully detached background subshell, then exit 0
#    immediately. Skip the network entirely if INGEST_URL is unset so the hook
#    is a harmless no-op when misconfigured. Nothing is ever printed.
# ---------------------------------------------------------------------------
if [ -n "$INGEST_URL" ] && command -v curl >/dev/null 2>&1; then
  # Build the curl args as an array so the optional bearer header (which contains
  # spaces) is passed as one argument and never word-split. Arrays are supported
  # by the bash this script runs under (the shebang is bash, floor 3.2).
  CURL_ARGS=(-sS -m 10 -X POST -H "Content-Type: application/json")
  if [ -n "$INGEST_TOKEN" ]; then
    CURL_ARGS+=(-H "Authorization: Bearer $INGEST_TOKEN")
  fi
  CURL_ARGS+=(--data-binary "$ENVELOPE" "$INGEST_URL")
  (
    curl "${CURL_ARGS[@]}" >/dev/null 2>&1
  ) &
fi

exit 0
