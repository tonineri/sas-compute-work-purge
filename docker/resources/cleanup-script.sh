#!/bin/bash

# Exit on any command failure
set -e

# Trap errors and call error handler
trap 'error_handler $LINENO $?' ERR

# Constants
LOG_FILE="/tmp/sas-cleanup-tool.log"
K8S_API_URL="https://kubernetes.default.svc"
K8S_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
SAS_COMPUTE_URL="https://sas-compute.${NAMESPACE}.svc.cluster.local"
SAS_LOGON_URL="https://sas-logon-app.${NAMESPACE}.svc.cluster.local"
RETRY_COUNT=${RETRY_COUNT:-3}
RETRY_DELAY=${RETRY_DELAY:-5}
TEMP_FILE=$(mktemp)

# Global arrays
active_serverIDs=()
zombie_serverIDs=()
safeDelete_serverIDs=()

# Error handler function
error_handler() {
    local line_number=$1
    local exit_code=$2
    log ERROR "Script failed at line $line_number with exit code $exit_code."
    cleanup_temp_files
    exit $exit_code
}

# Logging function
log() {
    local level=$1; shift
    local message="$@"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $level | sas-cleanup-tool | $message" | tee -a "$LOG_FILE"
}

# Cleanup temporary files
cleanup_temp_files() {
    rm -f "$TEMP_FILE"
}

# Validate environment variables
validate_env_vars() {
    local required_vars=("TIME_LIMIT_HOURS" "CLIENT_ID" "CLIENT_SECRET")
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            log ERROR "Environment variable $var is required but not set."
            exit 1
        fi
    done
}

# Retry mechanism
retry() {
    local retries=$RETRY_COUNT
    local delay=$RETRY_DELAY
    local count=0

    until "$@"; do
        count=$((count + 1))
        if [ "$count" -ge "$retries" ]; then
            log ERROR "Command '$*' failed after $retries attempts."
            return 1
        fi
        log WARN "Retrying command '$*' ($count/$retries)..."
        sleep "$delay"
    done
}

# Retrieve ACCESS_TOKEN from SAS Viya REST API
get_access_token() {
    log INFO "Retrieving access token..."
    local response
    local http_status

    response=$(curl -k -s -o "$TEMP_FILE" -w "%{http_code}" -X POST "${SAS_LOGON_URL}/SASLogon/oauth/token" \
        --user "${CLIENT_ID}:${CLIENT_SECRET}" \
        -d "grant_type=client_credentials")

    http_status=$(echo "$response" | tail -n1)

    if [ "$http_status" -ne 200 ]; then
        log ERROR "Failed to retrieve access token. HTTP status: $http_status"
        cat "$TEMP_FILE" | jq 2>/dev/null || cat "$TEMP_FILE"
        exit 1
    fi

    ACCESS_TOKEN=$(jq -r '.access_token' < "$TEMP_FILE")
    if [ -z "$ACCESS_TOKEN" ]; then
        log ERROR "Access token is empty."
        exit 1
    fi
    log INFO "Access token retrieved successfully."
}

# Function to query Kubernetes API for SAS Compute Server jobs
get_k8s_jobs() {
    log INFO "Looking for SAS Compute Server jobs in the namespace..."

    jobs=$(curl --cacert "${K8S_CA_CERT}" -s "${K8S_API_URL}/apis/batch/v1/namespaces/${NAMESPACE}/jobs" \
        -H "Authorization: Bearer ${K8S_TOKEN}" | jq -r '.items[] | select(.metadata.name | startswith("sas-compute-server-")) | .metadata.name')

    if [[ -z "$jobs" ]]; then
        log INFO "No active SAS Compute Server jobs found."
        return
    fi

    for job_name in $jobs; do
        process_k8s_job "$job_name"
    done
}

# Function to process individual Kubernetes jobs
process_k8s_job() {
    local job_name=$1

    log INFO "Processing Kubernetes job: ${job_name}"

    # Extract serverID and other metadata from the job
    server_id=$(curl --cacert "${K8S_CA_CERT}" -s "${K8S_API_URL}/apis/batch/v1/namespaces/${NAMESPACE}/jobs/${job_name}" \
        -H "Authorization: Bearer ${K8S_TOKEN}" | jq -r '.spec.template.spec.containers[0].command[] | select(contains("-serverID")) + 1')

    start_time=$(curl --cacert "${K8S_CA_CERT}" -s "${K8S_API_URL}/apis/batch/v1/namespaces/${NAMESPACE}/jobs/${job_name}" \
        -H "Authorization: Bearer ${K8S_TOKEN}" | jq -r '.status.startTime')

    if [[ -z "$server_id" || -z "$start_time" ]]; then
        log WARN "Could not retrieve server ID or start time for job: ${job_name}. Skipping."
        return
    fi

    # Calculate runtime in hours
    start_time_seconds=$(date --date="$start_time" +%s)
    current_time_seconds=$(date +%s)
    runtime_hours=$(( (current_time_seconds - start_time_seconds) / 3600 ))

    log INFO "Job ${job_name} - Server ID: ${server_id}, Runtime: ${runtime_hours} hours"

    # Call check_session_status with server_id and runtime_hours
    check_session_status "$server_id" "$runtime_hours"
}

# Extract specific details from job spec
extract_job_detail() {
    local job_name=$1
    local key=$2

    curl --cacert "${K8S_CA_CERT}" -s "${K8S_API_URL}/apis/batch/v1/namespaces/${NAMESPACE}/jobs/${job_name}" \
        -H "Authorization: Bearer ${K8S_TOKEN}" \
        | jq -r ".spec.template.spec.containers[0].command | index(\"$key\") + 1 | .[]"
}

# Function to check session status via SAS Viya REST API by searching for a session ID starting with server_id.
check_session_status() {
    local server_id=$1
    local job_name="sas-compute-server-${server_id}"

    # Query SAS Viya Compute API to get all sessions and find the one that starts with server_id.
    response=$(curl --cacert "${VIYA_CA_CERT}" -s "${SAS_COMPUTE_URL}/compute/sessions" \
              -H "Authorization: Bearer ${ACCESS_TOKEN}" \
              -H "Accept: application/json")

    # Extract session ID that starts with server_id.
    session_id=$(echo "$response" | jq -r --arg server_id "$server_id" '.items[] | select(.id | startswith($server_id)) | .id')

    # Check if a session was found.
    if [ -z "$session_id" ]; then
        log INFO "No session found for server ID: ${server_id}."
        zombie_serverIDs+=("$server_id")
        return 0
    fi

    # Query SAS Viya Compute API to get the state of the found session.
    response=$(curl --cacert "${VIYA_CA_CERT}" -s "${SAS_COMPUTE_URL}/compute/sessions/${session_id}/state" \
              -H "Authorization: Bearer ${ACCESS_TOKEN}" \
              -H "Accept: application/vnd.sas.compute.session.state+json")

    # Extract the state of the session.
    state=$(echo "$response" | jq -r '.state')

    # Check session state and runtime hours
    if [[ "$runtime_hours" -lt "$TIME_LIMIT_HOURS" && "$state" == "running" ]]; then
        log INFO "Session ${session_id} is in 'running' state."
        active_serverIDs+=("$server_id")

    elif [[ "$runtime_hours" -ge "$TIME_LIMIT_HOURS" && "$state" == "running" ]]; then
        log WARN "Session ${session_id} has been active for the past $runtime_hours hours, which exceeds the time limit. The script won't delete it as it's in a 'running' state. To manually delete it, issue the following command: 'kubectl -n ${NAMESPACE} delete job ${job_name}'"
        active_serverIDs+=("$server_id")

    elif [[ "$runtime_hours" -ge "$TIME_LIMIT_HOURS" && "$state" != "running" ]]; then
        log INFO "Session ${session_id} is a zombie. Marked for deletion."
        zombie_serverIDs+=("$server_id")

    elif [[ "$runtime_hours" -ge "$TIME_LIMIT_HOURS" && "$state" == "pending" ]]; then
        log INFO "Session ${session_id} is a zombie. Marked for deletion."
        zombie_serverIDs+=("$server_id")

    elif [[ "$runtime_hours" -lt "$TIME_LIMIT_HOURS" && "$state" == "pending" ]]; then
        log INFO "Session ${session_id} marked for deletion."
        zombie_serverIDs+=("$server_id")

    elif [[ "$state" == "canceled" || "$state" == "error" || "$state" == "failed" || "$state" == "warning" || "$state" == "completed" ]]; then
        log INFO "Session ${session_id} is marked for deletion."
        safeDelete_serverIDs+=("$server_id")

    else
        log INFO "Session ${session_id} is in an unrecognized state: $state. Marked for deletion."
        zombie_serverIDs+=("$server_id")
    fi
}

# Cleanup directories
cleanup_directories() {
    log INFO "Scanning and cleaning orphaned directories..."
    find /sastmp/*/*/default/* -type d | while read -r dir; do
        server_id=$(basename "$dir")
        if [[ ! " ${active_serverIDs[*]} " =~ " ${server_id} " ]]; then
            log INFO "Deleting orphaned directory: $dir"
            rm -rf "$dir"
        fi
    done
}

# Main function
main() {
    log INFO "Starting cleanup process."
    validate_env_vars
    get_access_token
    get_k8s_jobs
    cleanup_directories
    log INFO "Cleanup process completed successfully."
    cleanup_temp_files
}

main
