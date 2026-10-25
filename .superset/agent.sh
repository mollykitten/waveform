#!/bin/sh
# workspace agent roles; optional arguments are prompt text
set -eu

mode=${1-}
if [ "$#" -gt 0 ]; then
  shift
fi

case "$mode" in
  implement)
    if [ "$#" -eq 0 ]; then
      exec codex --model gpt-6.1-sol -c 'model_reasoning_effort="medium"'
    fi
    exec codex --model gpt-6.1-sol -c 'model_reasoning_effort="medium"' "Task: $*"
    ;;
  review)
    prompt='Read AGENTS.md and the repository rules it references. Review the current diff. Report actionable issues with file locations and evidence. Do not edit files.'
    if [ "$#" -gt 0 ]; then
      prompt="$prompt

Additional task context: $*"
    fi
    exec codex --model gpt-6.1-sol -c 'model_reasoning_effort="high"' "$prompt"
    ;;
  check)
    prompt='Read AGENTS.md and the repository rules it references. Run appropriate verification for the current changes and report the results. Verification only: do not edit files.'
    if [ "$#" -gt 0 ]; then
      prompt="$prompt

Additional task context: $*"
    fi
    exec codex --model gpt-6-luna -c 'model_reasoning_effort="medium"' "$prompt"
    ;;
  plan)
    prompt='Read AGENTS.md and the repository rules it references. Provide advice or a plan for the requested task. Advisory and planning only; do not implement changes.'
    if [ "$#" -gt 0 ]; then
      prompt="$prompt

Additional task context: $*"
    fi
    exec claude --model fable --effort high --permission-mode plan "$prompt"
    ;;
  *)
    printf '%s\n' 'usage: sh .superset/agent.sh implement|review|check|plan [prompt]' >&2
    exit 2
    ;;
esac
