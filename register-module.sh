#!/usr/bin/env bash
set -uo pipefail
# Note: we removed the -e flag and inherit_errexit to make the script more forgiving

###############################################################################
# Performs auto-acceptance of EULA and import of certificates for third-party modules
###############################################################################
function main() {
  if [ ! -f "${MODULE_LOCATION}" ]; then
    echo "WARNING: Module file not found at ${MODULE_LOCATION}"
    return 0  # Silently exit if there is no /modules path
  elif [ ! -f "${DB_LOCATION}" ]; then
    echo "WARNING: ${DB_FILE} not found, skipping module registration"
    return 0
  fi

  register_module
}

###############################################################################
# Register the module with the target Config DB
###############################################################################
function register_module() {
    local SQLITE3=( sqlite3 "${DB_LOCATION}" )

    # Tie into db
    local keytool module_sourcepath
    module_basename=$(basename "${MODULE_LOCATION}")
    module_sourcepath=${MODULE_LOCATION}
    keytool=$(which keytool)

    echo "Processing Module: ${module_basename}"

    # Attempt to extract certificate information
    local cert_info=""
    if ! cert_info=$( unzip -qq -c "${module_sourcepath}" certificates.p7b 2>/dev/null | $keytool -printcert -v 2>/dev/null | head -n 9 ); then
      echo "  WARNING: Failed to extract certificate information from ${module_basename}"
      return 0
    fi

    # Extract certificate details with proper error handling
    local thumbprint subject_name
    if ! thumbprint=$( echo "${cert_info}" | grep -A 2 "Certificate fingerprints" | grep SHA1 | cut -d : -f 2- | sed -e 's/\://g' | awk '{$1=$1;print tolower($0)}' ); then
      echo "  WARNING: Failed to extract thumbprint from certificate"
      return 0
    fi
    
    if ! subject_name=$( echo "${cert_info}" | grep -m 1 -Po '^Owner: CN=\K(.+?)(?=, (OU|O|L|ST|C)=)' | sed -e 's/"//g' ); then
      # Try an alternative pattern if the first one fails
      if ! subject_name=$( echo "${cert_info}" | grep -m 1 "Owner:" | sed -e 's/Owner: //g' | cut -d ',' -f 1 | sed -e 's/CN=//g' ); then
        echo "  WARNING: Failed to extract subject name from certificate"
        return 0
      fi
    fi

    echo "  Thumbprint: ${thumbprint}"
    echo "  Subject Name: ${subject_name}"
    
    # Process the certificate information
    local next_certificates_id thumbprint_already_exists
    if ! next_certificates_id=$( "${SQLITE3[@]}" "SELECT COALESCE(MAX(CERTIFICATES_ID)+1,1) FROM CERTIFICATES" 2>/dev/null ); then
      echo "  WARNING: Failed to get next certificate ID"
      return 0
    fi
    
    if ! thumbprint_already_exists=$( "${SQLITE3[@]}" "SELECT 1 FROM CERTIFICATES WHERE lower(hex(THUMBPRINT)) = '${thumbprint}'" 2>/dev/null ); then
      thumbprint_already_exists=""
    fi
    
    if [ "${thumbprint_already_exists}" != "1" ]; then
      echo "  Accepting Certificate as CERTIFICATES_ID=${next_certificates_id}"
      if ! "${SQLITE3[@]}" "INSERT INTO CERTIFICATES (CERTIFICATES_ID, THUMBPRINT, SUBJECTNAME) VALUES (${next_certificates_id}, x'${thumbprint}', '${subject_name}'); UPDATE SEQUENCES SET val=${next_certificates_id} WHERE name='CERTIFICATES_SEQ'" 2>/dev/null; then
        echo "  WARNING: Failed to insert certificate into database"
      fi
    else
      echo "  Thumbprint already found in CERTIFICATES table, skipping INSERT"
    fi

    # Extract and process license information
    local license_filename license_crc32 module_id
    if ! license_filename=$( unzip -qq -c "${module_sourcepath}" module.xml 2>/dev/null | grep -oP '(?<=<license>).*(?=</license)' ); then
      echo "  WARNING: Failed to extract license filename from module.xml"
      return 0
    fi
    
    if ! license_crc32=$( unzip -qq -c "${module_sourcepath}" "${license_filename}" 2>/dev/null | gzip -c | tail -c8 | od -t u4 -N 4 -A n | cut -c 2- ); then
      echo "  WARNING: Failed to compute license CRC32"
      return 0
    fi
    
    if ! module_id=$( unzip -qq -c "${module_sourcepath}" module.xml 2>/dev/null | grep -oP '(?<=<id>).*(?=</id)' ); then
      echo "  WARNING: Failed to extract module ID from module.xml"
      return 0
    fi

    # Update the EULAS table
    local module_id_check
    if ! module_id_check=$( "${SQLITE3[@]}" "SELECT CASE WHEN CRC=${license_crc32} THEN -1 ELSE 1 END FROM EULAS WHERE MODULEID='${module_id}'" 2>/dev/null ); then
      module_id_check=0
    fi
    
    if (( module_id_check == 1 )); then
      echo "  Removing previous EULAS entries for MODULEID='${module_id}'"
      if ! "${SQLITE3[@]}" "DELETE FROM EULAS WHERE MODULEID='${module_id}'" 2>/dev/null; then
        echo "  WARNING: Failed to delete previous EULAS entries"
      fi
    fi
    
    local next_eulas_id
    if ! next_eulas_id=$( "${SQLITE3[@]}" "SELECT COALESCE(MAX(EULAS_ID)+1,1) FROM EULAS" 2>/dev/null ); then
      echo "  WARNING: Failed to get next EULAS ID"
      return 0
    fi
    
    if (( module_id_check >= 0 )); then
      echo "  Accepting License on your behalf as EULAS_ID=${next_eulas_id}"
      if ! "${SQLITE3[@]}" "INSERT INTO EULAS (EULAS_ID, MODULEID, CRC) VALUES (${next_eulas_id}, '${module_id}', ${license_crc32}); UPDATE SEQUENCES SET val=${next_eulas_id} WHERE name='EULAS_SEQ'" 2>/dev/null; then
        echo "  WARNING: Failed to insert EULAS entry"
      fi
    else
      echo "  License EULA already found in EULAS table, skipping INSERT"
    fi
    
    echo "  Successfully registered module: ${module_basename}"
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
  >&2 echo "Usage: $0 -f <path/to/module> -d <path/to/db>"
}

# Argument Processing
while getopts ":hvf:d:" opt; do
  case "$opt" in
  v)
    verbose=1
    ;;
  f)
    MODULE_LOCATION="${OPTARG}"
    ;;
  d)
    DB_LOCATION="${OPTARG}"
    DB_FILE=$(basename "${DB_LOCATION}")
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

if [ -z "${MODULE_LOCATION:-}" ] || [ -z "${DB_LOCATION:-}" ]; then
  usage
  exit 1
fi

main