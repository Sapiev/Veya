#!/usr/bin/env bash
# Human-in-the-loop reproduction loop.
#
# THIS IS OPTION 10 OF 10. It ranks last in Phase 1's ladder for a reason: it
# spends a human turn per iteration, so the loop can never be tight. Before you
# copy this file, exhaust the agent-runnable options. In this repo that is
# almost always possible: `hub` supervised processes give you a dev server or a
# looping reproduction that runs unattended, and the `browser` tool drives the
# real UI and asserts on DOM, console, and network. Between them, nearly every
# loop that looks like it needs a human does not.
#
# Reach for this only when the reproduction genuinely requires a human hand:
# a hardware authenticator touch, a passkey prompt, a real email or device the
# agent cannot reach.
#
# Copy this file into `ai-output/temp/`, edit the steps below, and run it.
# The agent runs the script; the user follows prompts in their terminal.
#
# Usage:
#   bash hitl-loop.template.sh
#
# Two helpers:
#   step "<instruction>"          -> show instruction, wait for Enter
#   capture VAR "<question>"      -> show question, read response into VAR
#
# At the end, captured values are printed as KEY=VALUE for the agent to parse.
#
# `capture` prints its value back to the terminal, where the agent reads it,
# so capture observations, and leave signing in to the user as a `step`.
#
# Redaction: whatever `capture` reads is echoed into the agent's context. Never
# ask the user to paste a token, a key, vault plaintext, or receipt bytes. Ask
# for the observation (did it throw, what did the message say) and nothing more.

set -euo pipefail

step() {
  printf '\n>>> %s\n' "$1"
  read -r -p "    [Enter when done] " _
}

capture() {
  local var="$1" question="$2" answer
  printf '\n>>> %s\n' "$question"
  read -r -p "    > " answer
  printf -v "$var" '%s' "$answer"
}

# --- edit below ---------------------------------------------------------

step "Open the app at http://localhost:3000 and sign in."

capture ERRORED "Click the 'Export' button. Did it throw an error? (y/n)"

capture ERROR_MSG "Paste the error message (or 'none'):"

# --- edit above ---------------------------------------------------------

printf '\n--- Captured ---\n'
printf 'ERRORED=%s\n' "$ERRORED"
printf 'ERROR_MSG=%s\n' "$ERROR_MSG"
