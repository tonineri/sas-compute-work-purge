#!/bin/bash

# Exit on any command failure.
set -euo pipefail

# Trap errors and call error handler.
trap 'error_handler $LINENO $?' ERR

# Set constants.
LOG_FILE="/tmp/sas-cleanup-tool.log"
K8S_API_URL="https://kubernetes.default.svc"
K8S_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
SAS_COMPUTE_URL="https://sas-compute.${NAMESPACE}.svc.cluster.local"
SAS_LOGON_URL="https://sas-logon-app.${NAMESPACE}.svc.cluster.local"

# Retry configuration.
RETRIES=${RETRIES:-3}
DELAY=${DELAY:-5}

# Error handler function.
error_handler() {
    local line_number=$1
    local exit_code=$2
    log ERROR "Script failed at line $line_number with exit code $exit_code."
    exit $exit_code
}

# Logging function with levels.
log() {
    local level=$1
    shift
    local message="$@"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $level | sas-compute-work-purge-job | $message" | tee -a "$LOG_FILE" >&2
}

# Retry mechanism for transient failures.
retry() {
    local retries=$RETRIES
    local delay=$DELAY

    for ((i=0; i<retries; i++)); do
        "$@" && return 0
        log WARN "Command failed. Attempt $((i+1)) of $retries."
        ((i < retries - 1)) && sleep "$delay"
    done

    log ERROR "Command failed after $retries attempts."
    return 1
}

# Function to make API calls with error checking.
call_api() {
    local method=$1
    local endpoint=$2
    shift 2
    local response

    response=$(retry curl -k -s -o /tmp/response.json -w "%{http_code}" -X "$method" "$endpoint" "$@")
    local http_status=$(tail -n1 <<< "$response")

    if [[ "$http_status" -ge 400 ]]; then
        log ERROR "API call to [${endpoint}] failed with status: [${http_status}]."
        jq '.' /tmp/response.json >&2 || cat /tmp/response.json
        exit 1
    fi
    
    # Check if the `/tmp/response.json` file exists and is not empty.
    if [ ! -s /tmp/response.json ]; then
        log ERROR "Failed to query API or empty response received."
        return 1
    fi
    jq '.' /tmp/response.json
}

# Validate required environment variables.
validate_env() {
    local required_vars=("K8S_API_URL" "K8S_TOKEN" "NAMESPACE" "TIME_LIMIT_HOURS" "CLIENT_ID" "CLIENT_SECRET")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log ERROR "Environment variable [${var}] is not set."
            exit 1
        fi
    done
}

# Get `ACCESS_TOKEN` from SAS Viya REST API.
get_access_token() {
    log INFO "Attempting to retrieve ACCESS_TOKEN from SAS Logon..."
    local endpoint="${SAS_LOGON_URL}/SASLogon/oauth/token"

    ACCESS_TOKEN=$(call_api POST "$endpoint" \
        --user "${CLIENT_ID}:${CLIENT_SECRET}" \
        -d "grant_type=client_credentials" \
        | jq -r '.access_token')

    if [[ -z "$ACCESS_TOKEN" ]]; then
        log ERROR "Failed to retrieve ACCESS_TOKEN from SAS Logon."
        exit 1
    fi

    log INFO "ACCESS_TOKEN retrieved successfully from SAS Logon."
}

# Function to query Kubernetes API for `sas-compute-server` jobs and extract `serverID`, `context`, `username`, and `startTime`.
get_k8s_jobs() {
    log INFO "Scanning for Kubernetes Jobs matching 'sas-compute-server-*' in namespace [${NAMESPACE}]..."

    # Query Kubernetes API for jobs which start with `sas-compute-server-`.
    local endpoint="${K8S_API_URL}/apis/batch/v1/namespaces/${NAMESPACE}/jobs"
    jobs=$(call_api GET "$endpoint" \
        -H "Authorization: Bearer ${K8S_TOKEN}" \
        -H "Accept: application/json" \
        | jq -r '.items[] | select(.metadata.name | startswith("sas-compute-server-")) | .metadata.name')
    
    # Check if no jobs are found.
    if [ -z "$jobs" ]; then
        log INFO "No running Kubernetes Jobs matching 'sas-compute-server-*' found in namespace [${NAMESPACE}]."
        return 0  # Exit function early if no jobs are found
    fi

    # Count jobs and log result
    job_count=$(echo "$jobs" | wc -l)
    log INFO "Found [${job_count}] Kubernetes Job(s) matching 'sas-compute-server-*' in namespace [${NAMESPACE}]."

    # For each job, extract serverID, context, owner, and job start time.
    for job_name in ${jobs}; do
        log INFO "Processing Kubernetes Job: [${job_name}]"

        # Extract `serverID` from container command directly from job spec.
        local endpoint="${K8S_API_URL}/apis/batch/v1/namespaces/${NAMESPACE}/jobs/${job_name}"
        server_id=$(call_api GET "$endpoint" \
            -H "Authorization: Bearer ${K8S_TOKEN}" \
            -H "Accept: application/json" \
            | jq -r '.spec.template.spec.containers[0].command | index("-serverID") as $i | .[$i+1]')
        
        # Extract `context` from container command directly from job spec.
        context=$(call_api GET "$endpoint" \
            -H "Authorization: Bearer ${K8S_TOKEN}" \
            -H "Accept: application/json" \
            | jq -r '.spec.template.spec.containers[0].command | index("-context") as $i | .[$i+1]')

        # Extract `launcher.sas.com/username` directly from job spec.
        owner=$(call_api GET "$endpoint" \
            -H "Authorization: Bearer ${K8S_TOKEN}" \
            -H "Accept: application/json" \
            | jq -r '.spec.template.metadata.labels["launcher.sas.com/username"] // "unknown"')

        # Extract `startTime` directly from job spec.
        start_time=$(call_api GET "$endpoint" \
            -H "Authorization: Bearer ${K8S_TOKEN}" \
            -H "Accept: application/json" \
            | jq -r '.status.startTime')
        
        # Get `context_name` through SAS Viya REST API using previously extracted `serverID`.
        local endpoint="${SAS_COMPUTE_URL}/compute/contexts/${context}"
        context_name=$(call_api GET "$endpoint"  \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Accept: application/vnd.sas.compute.context+json, application/json, application/vnd.sas.compute.context.summary+json, application/vnd.sas.error+json" \
            | jq -r '.name')

        # Check if `start_time` is valid before proceeding.
        if [ -z "$start_time" ] || [ "$start_time" == "null" ]; then
            log ERROR "Start time not found for Kubernetes Job: [${job_name}]."
            exit 1
        else
            # Convert `start_time` to `runtime_hours`
            start_time_seconds=$(date --date="$start_time" +%s)
            current_time_seconds=$(date +%s)
            runtime_hours=$(( (current_time_seconds - start_time_seconds) / 3600 ))
        
            # Ensure runtime_hours is a valid integer.
            if ! [[ "$runtime_hours" =~ ^[0-9]+$ ]]; then
                log ERROR "Invalid runtime hours calculated for Kubernetes Job [${job_name}]. Skipping due to invalid runtime."
                continue  # Skip this job if runtime calculation fails.
            fi
        fi

        log INFO "Job: [${job_name}], ServerID: [${server_id}], Context: [${context_name}], Owner: [${owner}], Runtime: [${runtime_hours} hours]."

        # Check session state via SAS Viya REST API.
        check_session_state "$server_id" "$context_name"
    done
}

# Function to check session state via SAS Viya REST API by searching for a `session.id` containing `server_id`.
check_session_state() {
    local server_id=$1
    local context_name=$2
    local job_name="sas-compute-server-${server_id}"
    
    # Query SAS Viya REST API to get all Compute sessions and find the one that contains `server_id` in `session.id`.
    local endpoint="${SAS_COMPUTE_URL}/compute/sessions"
    session_id=$(call_api GET "$endpoint" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Accept: application/vnd.sas.collection+json, application/json" \
        | jq -r --arg server_id "$server_id" '.items[] | select(.id | contains($server_id)) | .id')

    # Check if a session was found.
    if [ -z "$session_id" ]; then
        log INFO "No session found for server ID: [${server_id}]."
        zombie_serverIDs+=("$server_id")
        return 0
    fi
    
    # Query SAS Viya REST API to get the state of the found session.
    local endpoint="${SAS_COMPUTE_URL}/compute/sessions/${session_id}"
    state=$(call_api GET "$endpoint" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Accept: application/vnd.sas.compute.session+json, application/json, application/vnd.sas.compute.session.summary+json, application/vnd.sas.error+json" \
        | jq -r '.state')

    # Mark session as `active` or `zombie` based on `state` and `runtime_hours` vs `TIME_LIMIT_HOURS`.
    if [[ "$runtime_hours" -lt "$TIME_LIMIT_HOURS" && "$state" == "running" ]]; then
        log INFO "Session [${session_id}] in [${context_name}] owned by [${owner}] is [${state}]."
        active_serverIDs+=("$server_id")
    elif [[ "$runtime_hours" -ge "$TIME_LIMIT_HOURS" && "$state" == "running" ]]; then
        log WARN "Session [${session_id}] in [${context_name}] owned by [${owner}] has been [${state}] for [${runtime_hours} hours], exceeding limit. To manually delete, issue the following command 'kubectl -n ${NAMESPACE} delete job ${job_name}"
        active_serverIDs+=("$server_id")
    elif [[ "$runtime_hours" -ge "$TIME_LIMIT_HOURS" && "$state" == "pending" ]]; then
        log INFO "Session [${session_id}] in [${context_name}] owned by [${owner}] is [${state}] but exceeds runtime limit. Marked for deletion."
        zombie_serverIDs+=("$server_id")
    elif [[ "$runtime_hours" -lt "$TIME_LIMIT_HOURS" && "$state" == "pending" ]]; then
        log INFO "Session [${session_id}] in [${context_name}] owned by [${owner}] is [${state}] but within time limit."
        active_serverIDs+=("$server_id")
    elif [[ "$runtime_hours" -ge "$TIME_LIMIT_HOURS" && "$state" == "idle" ]]; then
        log INFO "Session [${session_id}] in [${context_name}] owned by [${owner}] is [${state}] but exceeds runtime limit. Marked for deletion."
        zombie_serverIDs+=("$server_id")
    elif [[ "$runtime_hours" -lt "$TIME_LIMIT_HOURS" && "$state" == "idle" ]]; then
        log INFO "Session [${session_id}] in [${context_name}] owned by [${owner}] is [${state}] but within time limit."
        active_serverIDs+=("$server_id")
    elif [[ "$state" == "canceled" || "$state" == "error" || "$state" == "failed" || "$state" == "warning" || "$state" == "completed" ]]; then
        log INFO "Session [${session_id}] in [${context_name}] owned by [${owner}] is marked for deletion due to its [${state}] state."
        zombie_serverIDs+=("$server_id")
    else
        log INFO "Session [${session_id}] in [${context_name}] owned by [${owner}] is in an unrecognized state: $state. Marked for deletion."
        zombie_serverIDs+=("$server_id")
    fi
}

# Delete zombie jobs.
delete_zombie_jobs() {
    local demo=$1 # DEMO MODE

    # Iterate over all Kubernetes job names starting with "sas-compute-server-"
    for job_name in "${jobs[@]}"; do
        
        # Extract serverID from the job's spec (this was also done in get_k8s_jobs).
        local endpoint="${K8S_API_URL}/apis/batch/v1/namespaces/${NAMESPACE}/jobs/${job_name}"
        server_id=$(call_api GET "$endpoint" \
            -H "Authorization: Bearer ${K8S_TOKEN}" \
            -H "Accept: application/json" \
            | jq -r '.spec.template.spec.containers[0].command | index("-serverID") as $i | .[$i+1]')

        # Check if this `server_id` is in `zombie_serverIDs`.
        if [[ " ${zombie_serverIDs[*]} " =~ " ${server_id} " ]]; then
            # If it's a zombie, proceed with deletion.
            if [ "$demo" = true ]; then
                # In demo mode, just log what would happen.
                log INFO "DEMO MODE: Would delete zombie Kubernetes Job: [${job_name}]"
            else
                # In real mode, perform the actual API call to delete the job.
                log INFO "Deleting zombie Kubernetes Job: [${job_name}]"

                # Attempt to delete the job using the API and handle any errors.
                if call_api DELETE "$endpoint" -H "Authorization: Bearer ${K8S_TOKEN}" 2> >(error_message=$(cat)); then
                    log INFO "Zombie Kubernetes Job deleted successfully: [${job_name}]"
                else
                    # Log the captured error message if deletion fails.
                    log ERROR "Unable to delete zombie Kubernetes Job: [${job_name}]. Reason: $error_message"
                fi
            fi
        else
            log INFO "Skipping active Kubernetes Job: [${job_name}]"
        fi
    done
}

# Clean up orphaned directories.
cleanup_directories() {
    local demo=$1  # DEMO MODE

    log INFO "Scanning for orphaned work directories..."
    
    # Find directories and iterate over them.
    find /sastmp/*/*/default -mindepth 1 -maxdepth 1 -type d | while read -r dir; do
        server_id=$(basename "$dir")
        
        # Check if the directory's name is in the `active_serverIDs` array.
        if [[ ! " ${active_serverIDs[*]} " =~ " $server_id " ]]; then
            if [ "$demo" = true ]; then
                # In demo mode, just log what would happen.
                log INFO "DEMO MODE: Would delete orphaned directory: [${dir}]"
            else
                # In real mode, perform the actual deletion.
                log INFO "Deleting orphaned directory: [${dir}]"
                
                # Attempt to delete the directory and capture any error message directly.
                if rm -rf "$dir" 2> >(error_message=$(cat)); then
                    log INFO "Orphaned directory deleted successfully: [${dir}]"
                else
                    # Log the captured error message if deletion fails.
                    log ERROR "Unable to delete orphaned directory: [${dir}]. Reason: $error_message"
                fi
            fi
        else
            log INFO "Skipping active directory: [${dir}]"
        fi
    done

    log INFO "Cleanup process completed."
}

# Main script execution loop for all contexts in SAS Compute API (internal communication).
main() {
    
    local demo=true # DEMO MODE: If `true` it does not delete any Kubernetes Jobs or work directories.

    log INFO "Starting cleanup process."

    # Initialize arrays for active and zombie server IDs.
    active_serverIDs=()
    zombie_serverIDs=()

    # Validate environment variables.
    validate_env

    # Retrieve ACCESS_TOKEN from SAS Viya REST API.
    get_access_token

    # Query Kubernetes API for sas-compute-server-* jobs.
    get_k8s_jobs

    # Delete zombie jobs using Kubernetes API.
    delete_zombie_jobs $demo

    # Cleanup directories under /sastmp/.
    cleanup_directories $demo

    # Cleanup temporary files.
    rm -rf /tmp/*  
}

main   # Run main function.
