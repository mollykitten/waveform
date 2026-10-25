#!/bin/bash
# PostToolUse hook: auto-format Dart files after Write/Edit
#
# Reads tool output from stdin (JSON), checks if the file is a .dart file,
# and runs dart format on it. Skips the vendored third_party/ tree — we
# don't own that code and shouldn't reformat it.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))" 2>/dev/null)

# Skip vendored third_party/ code
if [[ "$FILE_PATH" == *"/third_party/"* ]]; then
  exit 0
fi

# Only format .dart files
if [[ "$FILE_PATH" == *.dart ]]; then
  dart format "$FILE_PATH" 2>/dev/null
fi

exit 0
