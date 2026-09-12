#!/bin/bash
# Shared helpers for install.sh, uninstall.sh and omniroute/install-omniroute.sh.
# Not installed anywhere — those three scripts are the only consumers.
#
# Everything here is pure bash, and deliberately so. This project installs a
# contract onto someone else's machine; a tool that is missing at install time
# is the most common way that fails. jq was the original offender — absent on
# most Windows machines, and absent *silently*, because the broken pipeline
# still let the hook exit 0 and drive mode simply never engaged. The obvious
# replacements are no better: node is not on PATH when Claude Code is installed
# as a native binary, perl is missing from minimal containers, and Windows
# ships python/python3 App Execution Alias shims that satisfy `command -v` and
# then exit without running anything.
#
# So there is no JSON runtime here at all, and no awk or sed either. The floor
# is bash itself plus the handful of coreutils (cp, mv, mkdir, rm, chmod, date,
# mktemp) that exist wherever bash does.
#
# Written for bash 3.2, the version macOS still ships as /bin/bash: no
# associative arrays, no ${var^^}, no printf %()T, no mapfile.

# ---------------------------------------------------------------------------
# Markdown frontmatter
# ---------------------------------------------------------------------------

# Print a markdown file's body: every line after the second `---` delimiter.
#
# hooks/drive-mode.sh carries its own copy of this loop, because it is installed
# standalone and cannot source this file. tests/run-tests.sh asserts that the
# two produce byte-identical output. If they ever drift, the /drive skill and
# the standing mode would inject different contracts — the single claim this
# project's single-source-of-truth design rests on.
strip_frontmatter() {
  local line delims=0
  local re='^---[[:space:]]*$'
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$delims" -ge 2 ]; then
      printf '%s\n' "$line"
    elif [[ $line =~ $re ]]; then
      delims=$((delims + 1))
    fi
  done < "$1"
}

# ---------------------------------------------------------------------------
# JSON strings
# ---------------------------------------------------------------------------

# json_escape VARNAME STRING — set VARNAME to STRING escaped for use inside a
# JSON string literal (the surrounding quotes are not added).
#
# Bulk substitution rather than a character loop: the contract body is ~6 KB and
# this runs on every OmniRoute deploy. Control characters without a short escape
# are rejected rather than mangled — the only inputs here are filesystem paths
# and a markdown document, so one appearing means something is wrong upstream,
# and failing loudly is the whole reason jq is gone.
json_escape() {
  local LC_ALL=C
  local __je_var=$1 __je_s=$2
  __je_s=${__je_s//\\/\\\\}
  __je_s=${__je_s//\"/\\\"}
  __je_s=${__je_s//$'\n'/\\n}
  __je_s=${__je_s//$'\r'/\\r}
  __je_s=${__je_s//$'\t'/\\t}
  __je_s=${__je_s//$'\b'/\\b}
  __je_s=${__je_s//$'\f'/\\f}
  case $__je_s in
    *[$'\001'-$'\007'$'\013'$'\016'-$'\037']*)
      echo "ERROR: refusing to encode a control character into JSON." >&2
      return 1 ;;
  esac
  eval "$__je_var=\$__je_s"
}

# ---------------------------------------------------------------------------
# JSON scanner
#
# Not a general parser — it locates and rewrites members of an object, which is
# all settings.json needs. Every function takes an index into $JDOC and reports
# its result in a global rather than on stdout, because $( ) forks a subshell
# per call and this walks a few thousand characters.
#
# Entry points set LC_ALL=C, so indices are byte offsets. UTF-8 never encodes a
# multibyte character using ASCII bytes, so scanning bytes for JSON's ASCII
# delimiters is exact and splicing on byte offsets cannot cut a character in
# half.
# ---------------------------------------------------------------------------

# $JDOC is the document; $JC is a read-only index into it, holding $JDOC cut
# into aligned 2048-byte chunks. Every single-character read in this file is
# written `${JC[i>>JBITS]:i&JMASK:1}` rather than the obvious `${JDOC:i:1}`,
# because bash walks a string from the front to reach an offset: indexing
# directly makes a full scan quadratic, and a 100 KB settings.json took nine
# seconds to edit. Chunking bounds every read to 2048 bytes and makes it linear
# — measured at 0.5 s for the same file. A character never straddles a chunk,
# since the chunks are aligned to the same power of two the index is masked by.
#
# _j_set is the ONLY place $JDOC may be assigned; anything else leaves $JC
# stale. tests/run-tests.sh enforces that.
JBITS=11; JSIZE=2048; JMASK=2047

_j_set() {
  local n b
  JDOC=$1
  n=${#JDOC}
  JC=()
  for ((b = 0; b < n; b += JSIZE)); do JC[b>>JBITS]=${JDOC:b:JSIZE}; done
  JC[(n>>JBITS)+1]=''                   # a read at exactly $n must yield ''
}

# Advance past whitespace from index $1.
_j_ws() {
  local i=$1
  while :; do
    case ${JC[i>>JBITS]:i&JMASK:1} in
      ' '|$'\t'|$'\n'|$'\r') i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  _J=$i
}

# $1 = index of an opening '"'. _J = index of the closing '"'.
_j_string_end() {
  local i=$(($1 + 1)) n=${#JDOC}
  while [ "$i" -lt "$n" ]; do
    case ${JC[i>>JBITS]:i&JMASK:1} in
      '\') i=$((i + 2)) ;;
      '"') _J=$i; return 0 ;;
      *) i=$((i + 1)) ;;
    esac
  done
  return 1
}

# $1 = index of '{' or '['. _J = index of the matching close.
_j_span_end() {
  local i=$1 n=${#JDOC} depth=0
  while [ "$i" -lt "$n" ]; do
    case ${JC[i>>JBITS]:i&JMASK:1} in
      '"') _j_string_end "$i" || return 1; i=$((_J + 1)); continue ;;
      '{'|'[') depth=$((depth + 1)) ;;
      '}'|']')
        depth=$((depth - 1))
        if [ "$depth" -eq 0 ]; then _J=$i; return 0; fi ;;
    esac
    i=$((i + 1))
  done
  return 1
}

# $1 = index of the first character of a value. _J = index just past it.
_j_value_end() {
  local i=$1 n=${#JDOC}
  case ${JC[i>>JBITS]:i&JMASK:1} in
    '{'|'[') _j_span_end "$i" || return 1; _J=$((_J + 1)); return 0 ;;
    '"')     _j_string_end "$i" || return 1; _J=$((_J + 1)); return 0 ;;
    '')      return 1 ;;
  esac
  while [ "$i" -lt "$n" ]; do                    # number, true, false, null
    case ${JC[i>>JBITS]:i&JMASK:1} in
      ','|'}'|']'|' '|$'\t'|$'\n'|$'\r') break ;;
    esac
    i=$((i + 1))
  done
  _J=$i
  return 0
}

# $1 = index of '{'. Fills _J_KEY[] with member names and _J_MS[]/_J_ME[] with
# each member's span (key start .. just past its value). _J_N is the count.
_j_members() {
  local i=$(($1 + 1)) ks ke
  _J_KEY=(); _J_MS=(); _J_ME=(); _J_N=0
  while :; do
    _j_ws "$i"; i=$_J
    case ${JC[i>>JBITS]:i&JMASK:1} in
      '}') return 0 ;;
      ',') i=$((i + 1)); continue ;;
      '"') ;;
      *) return 1 ;;
    esac
    ks=$i
    _j_string_end "$i" || return 1
    ke=$_J
    # Compared raw, so a key written with \u escapes will not match a plain one.
    # settings.json keys are plain ASCII; anything else is out of scope.
    _J_KEY[$_J_N]=${JDOC:$((ks + 1)):$((ke - ks - 1))}
    i=$((ke + 1))
    _j_ws "$i"; i=$_J
    [ "${JC[i>>JBITS]:i&JMASK:1}" = ':' ] || return 1
    i=$((i + 1))
    _j_ws "$i"; i=$_J
    _j_value_end "$i" || return 1
    _J_MS[$_J_N]=$ks
    _J_ME[$_J_N]=$_J
    _J_N=$((_J_N + 1))
    i=$_J
  done
}

# $1 = index of '['. Fills _J_ES[]/_J_EE[] with each element's span; _J_N counts.
_j_elements() {
  local i=$(($1 + 1))
  _J_ES=(); _J_EE=(); _J_N=0
  while :; do
    _j_ws "$i"; i=$_J
    case ${JC[i>>JBITS]:i&JMASK:1} in
      ']') return 0 ;;
      ',') i=$((i + 1)); continue ;;
      '') return 1 ;;
    esac
    _j_value_end "$i" || return 1
    _J_ES[$_J_N]=$i
    _J_EE[$_J_N]=$_J
    _J_N=$((_J_N + 1))
    i=$_J
  done
}

# _j_get OBJECT_START KEY — locate a direct member by name.
# Sets _J_VAL (index of the value), _J_MSTART/_J_MEND (the member's own span).
# Returns 1 when the key is absent; _J_N still holds the member count, so a
# caller can tell an absent key in an empty object from one in a full object.
_j_get() {
  local i
  _j_members "$1" || return 1
  for ((i = 0; i < _J_N; i++)); do
    if [ "${_J_KEY[$i]}" = "$2" ]; then
      _J_MSTART=${_J_MS[$i]}
      _J_MEND=${_J_ME[$i]}
      _j_string_end "$_J_MSTART" || return 1
      _j_ws $((_J + 1))
      [ "${JC[_J>>JBITS]:_J&JMASK:1}" = ':' ] || return 1
      _j_ws $((_J + 1))
      _J_VAL=$_J
      return 0
    fi
  done
  return 1
}

# _J_INDENT = the leading whitespace of the line holding index $1.
_j_indent_at() {
  local i=$1 start
  while [ "$i" -gt 0 ] && [ "${JC[(i - 1)>>JBITS]:(i - 1)&JMASK:1}" != $'\n' ]; do i=$((i - 1)); done
  start=$i
  while :; do
    case ${JC[i>>JBITS]:i&JMASK:1} in ' '|$'\t') i=$((i + 1)) ;; *) break ;; esac
  done
  _J_INDENT=${JDOC:start:$((i - start))}
}

# Read FILE into $JDOC verbatim, trailing newline included.
_j_load() {
  local raw=''
  [ -f "$1" ] || return 1
  IFS= read -r -d '' raw < "$1"         # returns 1 at EOF having set raw
  _j_set "$raw"
  return 0
}

# Structural check: $JDOC is exactly one JSON object with nothing trailing.
# _J_ROOT is left at the index of its '{'.
_j_root() {
  local end
  _j_ws 0
  [ "${JC[_J>>JBITS]:_J&JMASK:1}" = '{' ] || return 1
  _J_ROOT=$_J
  _j_span_end "$_J_ROOT" || return 1
  end=$_J
  _j_ws $((end + 1))
  [ "$_J" -ge "${#JDOC}" ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# settings.json operations
#
# Three shapes have to be handled, because settings.json may have no hooks key,
# a hooks key with no UserPromptSubmit, or both. Each case inserts one member or
# element into an existing container and leaves every other byte of the file
# untouched — which is the point: this file is hand-edited, and a rewrite that
# reordered keys or dropped comments-by-convention would be a worse outcome than
# the jq dependency ever was.
# ---------------------------------------------------------------------------

# The hook entry this project registers. $1 is the indentation of the line the
# entry's opening brace will sit on; $2 is the already-escaped command.
_hook_group() {
  local p=$1 cmd=$2
  printf '{\n%s  "hooks": [\n%s    {\n%s      "type": "command",\n%s      "command": "%s"\n%s    }\n%s  ]\n%s}' \
    "$p" "$p" "$p" "$p" "$cmd" "$p" "$p" "$p"
}

# Append TEXT as a new member/element of the container opening at $1, given the
# per-item indent $2. Handles the empty container, where there is no preceding
# comma and the closing bracket needs a line of its own.
# Sets _J_SPLICE_AT and _J_SPLICE_TEXT for the caller to splice.
_j_append() {
  local open=$1 pad=$2 text=$3 close_pad=$4 last=-1 i
  case ${JC[open>>JBITS]:open&JMASK:1} in
    '{') _j_members "$open" || return 1; [ "$_J_N" -gt 0 ] && last=${_J_ME[$((_J_N - 1))]} ;;
    '[') _j_elements "$open" || return 1; [ "$_J_N" -gt 0 ] && last=${_J_EE[$((_J_N - 1))]} ;;
    *) return 1 ;;
  esac
  if [ "$last" -lt 0 ]; then
    _J_SPLICE_AT=$((open + 1))
    _J_SPLICE_TEXT=$'\n'"$pad$text"$'\n'"$close_pad"
  else
    _J_SPLICE_AT=$last
    _J_SPLICE_TEXT=,$'\n'"$pad$text"
  fi
  return 0
}

# settings_hook_registered FILE SUBSTRING [EVENT]
# True when some EVENT entry's command contains SUBSTRING (EVENT defaults to
# UserPromptSubmit). Structural rather than a grep over the whole file, so the
# script's name appearing anywhere else — another hook event, a path in an
# unrelated setting — cannot be mistaken for registration.
settings_hook_registered() {
  local LC_ALL=C
  local i j cmd event=${3:-UserPromptSubmit}
  _j_load "$1" || return 1
  _j_root || return 1
  _j_get "$_J_ROOT" hooks || return 1
  [ "${JC[_J_VAL>>JBITS]:_J_VAL&JMASK:1}" = '{' ] || return 1
  _j_get "$_J_VAL" "$event" || return 1
  [ "${JC[_J_VAL>>JBITS]:_J_VAL&JMASK:1}" = '[' ] || return 1
  _j_elements "$_J_VAL" || return 1
  local starts=(${_J_ES[@]+"${_J_ES[@]}"}) ends=(${_J_EE[@]+"${_J_EE[@]}"}) n=$_J_N
  for ((i = 0; i < n; i++)); do
    [ "${JC[(${starts[$i]})>>JBITS]:(${starts[$i]})&JMASK:1}" = '{' ] || continue
    _j_get "${starts[$i]}" hooks || continue
    [ "${JC[_J_VAL>>JBITS]:_J_VAL&JMASK:1}" = '[' ] || continue
    _j_elements "$_J_VAL" || continue
    local es=(${_J_ES[@]+"${_J_ES[@]}"}) ee=(${_J_EE[@]+"${_J_EE[@]}"}) m=$_J_N
    for ((j = 0; j < m; j++)); do
      _j_get "${es[$j]}" command || continue
      cmd=${JDOC:_J_VAL:$((_J_MEND - _J_VAL))}
      case $cmd in *"$2"*) return 0 ;; esac
    done
  done
  return 1
}

# settings_register_hook FILE COMMAND [EVENT]
# Add COMMAND as an EVENT hook (EVENT defaults to UserPromptSubmit). The file
# must already exist and hold a JSON object; install.sh writes it whole when it
# does not. Prints a one-line note about which container it grew.
settings_register_hook() {
  local LC_ALL=C
  local file=$1 cmd=$2 event=${3:-UserPromptSubmit} esc pad group

  json_escape esc "$cmd" || return 1
  _j_load "$file" || { echo "ERROR: cannot read $file" >&2; return 1; }
  _j_root || { echo "ERROR: $file is not a JSON object." >&2; return 1; }

  # Remember the top-level keys so the write can be checked against them.
  _j_members "$_J_ROOT" || { echo "ERROR: cannot parse $file" >&2; return 1; }
  local before=(${_J_KEY[@]+"${_J_KEY[@]}"})

  if _j_get "$_J_ROOT" hooks; then
    local hooks=$_J_VAL
    [ "${JC[hooks>>JBITS]:hooks&JMASK:1}" = '{' ] || { echo "ERROR: \"hooks\" is not an object." >&2; return 1; }
    if _j_get "$hooks" "$event"; then
      local ups=$_J_VAL
      [ "${JC[ups>>JBITS]:ups&JMASK:1}" = '[' ] || { echo "ERROR: \"$event\" is not an array." >&2; return 1; }
      _j_indent_at "$ups"; pad="$_J_INDENT  "
      group=$(_hook_group "$pad" "$esc")
      _j_append "$ups" "$pad" "$group" "$_J_INDENT" || return 1
    else
      _j_indent_at "$hooks"; pad="$_J_INDENT  "
      group=$(_hook_group "$pad  " "$esc")
      _j_append "$hooks" "$pad" \
        "\"$event\": [
$pad  $group
$pad]" "$_J_INDENT" || return 1
    fi
  else
    _j_indent_at "$_J_ROOT"; pad="$_J_INDENT  "
    group=$(_hook_group "$pad    " "$esc")
    _j_append "$_J_ROOT" "$pad" \
      "\"hooks\": {
$pad  \"$event\": [
$pad    $group
$pad  ]
$pad}" "$_J_INDENT" || return 1
  fi

  _j_set "${JDOC:0:_J_SPLICE_AT}$_J_SPLICE_TEXT${JDOC:_J_SPLICE_AT}"

  # Verify before writing. A hand-rolled editor gets exactly one chance to be
  # wrong about someone's settings file, so the result has to re-parse, still
  # carry every key it started with, and actually contain the hook.
  _j_root || { echo "ERROR: rewrite did not re-parse; $file left alone." >&2; return 1; }
  _j_members "$_J_ROOT" || { echo "ERROR: rewrite did not re-parse; $file left alone." >&2; return 1; }
  local i k found after=(${_J_KEY[@]+"${_J_KEY[@]}"})
  for k in ${before[@]+"${before[@]}"}; do
    found=0
    for i in ${after[@]+"${after[@]}"}; do [ "$i" = "$k" ] && found=1; done
    [ "$found" = 1 ] || { echo "ERROR: rewrite lost the \"$k\" setting; $file left alone." >&2; return 1; }
  done
  case $JDOC in *"$esc"*) ;; *) echo "ERROR: rewrite did not contain the hook; $file left alone." >&2; return 1 ;; esac

  _j_write "$file" || return 1
  return 0
}

# settings_deregister_hook FILE SUBSTRING [EVENT]
# Drop every EVENT entry whose command contains SUBSTRING (EVENT defaults to
# UserPromptSubmit), then drop EVENT and hooks in turn if that emptied them.
# Returns 2 when there was nothing to remove, so the caller can stay quiet
# rather than claim a change.
settings_deregister_hook() {
  local LC_ALL=C
  local file=$1 match=$2 event=${3:-UserPromptSubmit} i j cmd hit

  _j_load "$file" || return 1
  _j_root || { echo "ERROR: $file is not a JSON object." >&2; return 1; }
  _j_get "$_J_ROOT" hooks || return 2
  local hooks=$_J_VAL hooks_ms=$_J_MSTART hooks_me=$_J_MEND
  [ "${JC[hooks>>JBITS]:hooks&JMASK:1}" = '{' ] || return 2
  _j_get "$hooks" "$event" || return 2
  local ups=$_J_VAL ups_ms=$_J_MSTART ups_me=$_J_MEND
  [ "${JC[ups>>JBITS]:ups&JMASK:1}" = '[' ] || return 2

  _j_elements "$ups" || return 1
  local starts=(${_J_ES[@]+"${_J_ES[@]}"}) ends=(${_J_EE[@]+"${_J_EE[@]}"}) n=$_J_N
  local keep=() removed=0
  for ((i = 0; i < n; i++)); do
    hit=0
    if [ "${JC[(${starts[$i]})>>JBITS]:(${starts[$i]})&JMASK:1}" = '{' ] && _j_get "${starts[$i]}" hooks \
       && [ "${JC[_J_VAL>>JBITS]:_J_VAL&JMASK:1}" = '[' ] && _j_elements "$_J_VAL"; then
      local es=(${_J_ES[@]+"${_J_ES[@]}"}) m=$_J_N
      for ((j = 0; j < m; j++)); do
        if _j_get "${es[$j]}" command; then
          cmd=${JDOC:_J_VAL:$((_J_MEND - _J_VAL))}
          case $cmd in *"$match"*) hit=1 ;; esac
        fi
      done
    fi
    if [ "$hit" = 1 ]; then
      removed=$((removed + 1))
    else
      keep[${#keep[@]}]=${JDOC:${starts[$i]}:$((${ends[$i]} - ${starts[$i]}))}
    fi
  done
  [ "$removed" -gt 0 ] || return 2

  # Rebuild rather than splice out commas: reassembling the survivors is one
  # code path for "some left" and "none left", and cannot leave a dangling
  # comma behind.
  local cut_start cut_end replacement=''
  if [ "${#keep[@]}" -gt 0 ]; then
    _j_indent_at "$ups"
    local pad="$_J_INDENT  " body=''
    for ((i = 0; i < ${#keep[@]}; i++)); do
      [ -n "$body" ] && body="$body,"$'\n'
      body="$body$pad${keep[$i]}"
    done
    replacement="["$'\n'"$body"$'\n'"$_J_INDENT]"
    cut_start=$ups
    _j_span_end "$ups" || return 1
    cut_end=$((_J + 1))
  else
    # The event's array is now empty: remove the member, and hooks with it if
    # that was its only one.
    _j_members "$hooks" || return 1
    if [ "$_J_N" -le 1 ]; then
      cut_start=$hooks_ms; cut_end=$hooks_me
    else
      cut_start=$ups_ms; cut_end=$ups_me
    fi
    _j_cut_member_span "$cut_start" "$cut_end" || return 1
    cut_start=$_J_CUT_START; cut_end=$_J_CUT_END
  fi

  _j_set "${JDOC:0:cut_start}$replacement${JDOC:cut_end}"

  _j_root || { echo "ERROR: rewrite did not re-parse; $file left alone." >&2; return 1; }
  _j_members "$_J_ROOT" || { echo "ERROR: rewrite did not re-parse; $file left alone." >&2; return 1; }
  _j_write "$file" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# statusLine operations
#
# The budget module's sensor is a statusLine command, because the status line's
# stdin payload is the only place Claude Code publishes rate_limits.* — no hook
# event carries it. settings.json holds at most one statusLine, so registering
# ours is a claim on a slot the user may already be using. These functions
# therefore refuse rather than overwrite, the same stance settings_register_hook
# takes towards a "hooks" key that is not an object.
# ---------------------------------------------------------------------------

# settings_statusline_command VARNAME FILE
# Set VARNAME to the raw source text of statusLine.command, quotes and escapes
# included. Returns 1 when there is no statusLine, or it is not an object with a
# command member.
settings_statusline_command() {
  local LC_ALL=C
  local var=$1 file=$2
  _j_load "$file" || return 1
  _j_root || return 1
  _j_get "$_J_ROOT" statusLine || return 1
  [ "${JC[_J_VAL>>JBITS]:_J_VAL&JMASK:1}" = '{' ] || return 1
  _j_get "$_J_VAL" command || return 1
  eval "$var=\${JDOC:_J_VAL:\$((_J_MEND - _J_VAL))}"
}

# settings_set_statusline FILE COMMAND
# Add a top-level "statusLine" object running COMMAND. Returns 2 — and changes
# nothing — when the file already has a statusLine, whether it is ours or
# someone else's: the caller decides what to say about it.
settings_set_statusline() {
  local LC_ALL=C
  local file=$1 cmd=$2 esc pad existing

  json_escape esc "$cmd" || return 1
  _j_load "$file" || { echo "ERROR: cannot read $file" >&2; return 1; }
  _j_root || { echo "ERROR: $file is not a JSON object." >&2; return 1; }
  if _j_get "$_J_ROOT" statusLine; then return 2; fi

  _j_members "$_J_ROOT" || { echo "ERROR: cannot parse $file" >&2; return 1; }
  local before=(${_J_KEY[@]+"${_J_KEY[@]}"})

  _j_indent_at "$_J_ROOT"; pad="$_J_INDENT  "
  _j_append "$_J_ROOT" "$pad" \
    "\"statusLine\": {
$pad  \"type\": \"command\",
$pad  \"command\": \"$esc\"
$pad}" "$_J_INDENT" || return 1

  _j_set "${JDOC:0:_J_SPLICE_AT}$_J_SPLICE_TEXT${JDOC:_J_SPLICE_AT}"

  # Same verify-before-write gate settings_register_hook uses: re-parse, every
  # key that was there is still there, and the thing we added is present.
  _j_root || { echo "ERROR: rewrite did not re-parse; $file left alone." >&2; return 1; }
  _j_members "$_J_ROOT" || { echo "ERROR: rewrite did not re-parse; $file left alone." >&2; return 1; }
  local i k found after=(${_J_KEY[@]+"${_J_KEY[@]}"})
  for k in ${before[@]+"${before[@]}"}; do
    found=0
    for i in ${after[@]+"${after[@]}"}; do [ "$i" = "$k" ] && found=1; done
    [ "$found" = 1 ] || { echo "ERROR: rewrite lost the \"$k\" setting; $file left alone." >&2; return 1; }
  done
  case $JDOC in *"$esc"*) ;; *) echo "ERROR: rewrite did not contain the command; $file left alone." >&2; return 1 ;; esac

  _j_write "$file" || return 1
  return 0
}

# settings_unset_statusline FILE SUBSTRING
# Remove the top-level "statusLine" member, but only when its command contains
# SUBSTRING. Returns 2 when there is no statusLine or it belongs to someone
# else, so uninstall never takes away a status line it did not install.
settings_unset_statusline() {
  local LC_ALL=C
  local file=$1 match=$2 cmd

  _j_load "$file" || return 1
  _j_root || { echo "ERROR: $file is not a JSON object." >&2; return 1; }
  _j_get "$_J_ROOT" statusLine || return 2
  local sl=$_J_VAL sl_ms=$_J_MSTART sl_me=$_J_MEND
  [ "${JC[sl>>JBITS]:sl&JMASK:1}" = '{' ] || return 2
  _j_get "$sl" command || return 2
  cmd=${JDOC:_J_VAL:$((_J_MEND - _J_VAL))}
  case $cmd in *"$match"*) ;; *) return 2 ;; esac

  _j_cut_member_span "$sl_ms" "$sl_me" || return 1
  _j_set "${JDOC:0:_J_CUT_START}${JDOC:_J_CUT_END}"

  _j_root || { echo "ERROR: rewrite did not re-parse; $file left alone." >&2; return 1; }
  _j_members "$_J_ROOT" || { echo "ERROR: rewrite did not re-parse; $file left alone." >&2; return 1; }
  _j_write "$file" || return 1
  return 0
}

# Widen a member span [$1,$2) to swallow the comma and blank line that would
# otherwise be left behind. Sets _J_CUT_START / _J_CUT_END.
_j_cut_member_span() {
  local start=$1 end=$2
  _j_ws "$end"
  if [ "${JC[_J>>JBITS]:_J&JMASK:1}" = ',' ]; then
    end=$((_J + 1))                       # a following comma goes with it
  else
    local p=$((start - 1))                 # otherwise take the preceding one
    while [ "$p" -ge 0 ]; do
      case ${JC[p>>JBITS]:p&JMASK:1} in
        ' '|$'\t'|$'\n'|$'\r') p=$((p - 1)) ;;
        ',') start=$p; break ;;
        *) break ;;
      esac
    done
  fi
  # Pull the line's own indentation and newline in, so no blank line survives.
  local q=$start
  while [ "$q" -gt 0 ]; do
    case ${JC[(q - 1)>>JBITS]:(q - 1)&JMASK:1} in
      ' '|$'\t') q=$((q - 1)) ;;
      $'\n') q=$((q - 1)); break ;;
      *) break ;;
    esac
  done
  _J_CUT_START=$q
  _J_CUT_END=$end
  return 0
}

# Write $JDOC to FILE through a temp file in the same directory, so a crash
# cannot leave a truncated settings.json behind.
_j_write() {
  local file=$1 tmp
  tmp="$(mktemp "$file.tmp.XXXXXX")" || { echo "ERROR: cannot create a temp file next to $file" >&2; return 1; }
  # cp -p first, so the temp inherits the original's mode. mktemp creates 0600,
  # and moving that over settings.json would quietly tighten permissions the
  # user may have chosen for themselves. The content is replaced immediately.
  cp -p "$file" "$tmp" 2>/dev/null || true
  printf '%s' "$JDOC" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# Reading a value back out
# ---------------------------------------------------------------------------

# json_field VARNAME FILE KEY — set VARNAME to the raw source text of top-level
# member KEY (a string still carrying its quotes and escapes, or a bare literal
# such as `true`).
#
# Scans to the first balanced object rather than requiring the file to be one,
# because the OmniRoute CLI prints human-readable notices around its payload.
# Returns 1 when there is no such object or no such key.
json_field() {
  local LC_ALL=C
  local __jf_var=$1 file=$2 key=$3 raw='' i n
  [ -f "$file" ] || return 1
  IFS= read -r -d '' raw < "$file"
  _j_set "$raw"
  n=${#JDOC}; i=0
  while [ "$i" -lt "$n" ] && [ "${JC[i>>JBITS]:i&JMASK:1}" != '{' ]; do i=$((i + 1)); done
  [ "$i" -lt "$n" ] || return 1
  _j_span_end "$i" || return 1
  _j_get "$i" "$key" || return 1
  eval "$__jf_var=\${JDOC:_J_VAL:\$((_J_MEND - _J_VAL))}"
}
