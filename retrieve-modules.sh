#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

###############################################################################
# Copies modules from local directory
###############################################################################
function main() {
  if [ -z "${SUPPLEMENTAL_MODULES}" ]; then
    echo "No supplemental modules specified, skipping"
    return 0
  fi

  # Check if modules directory exists
  if [ ! -d "/modules" ]; then
    echo "Warning: /modules directory not found, skipping module copy"
    return 0
  fi

  copy_modules
}

###############################################################################
# Copy the modules
###############################################################################
function copy_modules() {
  # We're ignoring the SUPPLEMENTAL_MODULES variable since we'll copy all .modl files
  echo "Copying modules from /modules directory"
  
  # Count the number of .modl files
  module_count=$(find /modules -maxdepth 1 -name "*.modl" | wc -l)
  
  if [ "$module_count" -eq 0 ]; then
    echo "No .modl files found in /modules directory"
    return 0
  fi
  
  echo "Found $module_count module(s) to copy"
  
  # Copy all .modl files to current directory
  cp /modules/*.modl .
  
  echo "Modules copied successfully"
}

###############################################################################
# Outputs to stderr
###############################################################################
function debug() {
  # shellcheck disable=SC2236
  if [ ! -z ${verbose+x} ]; then
    >&2 echo "  DEBUG: $*"
  fi
}

###############################################################################
# Print usage information
###############################################################################
function usage() {
  >&2 echo "Usage: $0 -m \"space-separated modules list\""
  >&2 echo "    -m: space-separated list of module identifiers (optional)"
}

# Argument Processing
while getopts ":hvm:" opt; do
  case "$opt" in
  v)
    verbose=1
    ;;
  m)
    SUPPLEMENTAL_MODULES="${OPTARG}"
    ;;
  h)
    usage
    exit 0
    ;;
  \?)
    usage
    echo "Invalid option: -${OPTARG}" >&2
    exit 1
    ;;
  :)
    usage
    echo "Invalid option: -${OPTARG} requires an argument" >&2
    exit 1
    ;;
  esac
done

# shift positional args based on number consumed by getopts
shift $((OPTIND-1))

main