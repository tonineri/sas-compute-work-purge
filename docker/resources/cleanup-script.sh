#!/bin/bash

# Exit on any command failure
set -euo pipefail

# Trap errors and call error handler
trap 'error_handler $LINENO $?' ERR

# Set constants
LOG_FILE="/tmp/sas-cleanup-tool.log"
K8S_API_URL="https://kubernetes.default.svc"
K8S_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
SAS_COMPUTE_URL="https://sas-compute.${NAMESPACE}.svc.cluster.local"
SAS_LOGON_URL="https://sas-logon-app.${NAMESPACE}.svc.cluster.local"

# Retry configuration
RETRIES=${RETRIES:-3}
DELAY=${DELAY:-5}

# Error handler function
error_handler() {
    local line_number=$1
    local exit_code=$2
    log ERROR "Script failed at line $line_number with exit code $exit_code."
    exit $exit_code
}

# Logging function with levels
log() {
    local level=$1
    shift
    local message="$@"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $level | sas-compute-work-purge-job | $message" | tee -a "$LOG_FILE" >&2
}

# Retry mechanism for transient failures
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

# Function to make API calls with error checking
api_call() {
    local method=$1
    local url=$2
    shift 2
    local response

    response=$(retry curl -k -s -o response.json -w "%{http_code}" -X "$method" "$url" "$@")
    local http_status=$(tail -n1 <<< "$response")

    if [[ "$http_status" -ge 400 ]]; then
        log ERROR "API call to $url failed with status $http_status."
        jq '.' response.json >&2 || cat response.json
        exit 1
    fi

    jq '.' response.json
    rm -f response.json
}

# Validate required environment variables
validate_env() {
    local required_vars=("K8S_API_URL" "K8S_TOKEN" "NAMESPACE" "TIME_LIMIT_HOURS" "CLIENT_ID" "CLIENT_SECRET")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log ERROR "Environment variable $var is not set."
            exit 1
        fi
    done
}

# Get access token from SAS Logon App
get_access_token() {
    log INFO "Attempting to retrieve access token..."
    local url="${SAS_LOGON_URL}/SASLogon/oauth/token"

    ACCESS_TOKEN=$(api_call POST "$url" \
        --user "${CLIENT_ID}:${CLIENT_SECRET}" \
        -d "grant_type=client_credentials" | jq -r '.access_token')

    if [[ -z "$ACCESS_TOKEN" ]]; then
        log ERROR "Failed to retrieve access token."
        exit 1
    fi

    log INFO "Access token retrieved successfully."
}

# Function to query Kubernetes API for sas-compute-server-* jobs and extract serverID, context, owner, and job start time.
get_k8s_jobs() {
    log INFO "Looking for SAS Compute Server jobs in the namespace..."

    # Query Kubernetes API for jobs matching sas-compute-server-* and save response to file
    curl -k -s "${K8S_API_URL}/apis/batch/v1/namespaces/${NAMESPACE}/jobs" \
        -H "Authorization: Bearer ${K8S_TOKEN}" \
        -H "Accept: application/json" -o /tmp/k8s_response.json
    
    # Check if the response file exists and is not empty
    if [ ! -s /tmp/k8s_response.json ]; then
        log ERROR "Failed to query Kubernetes API or empty response received."
        return 1  # Exit function early if no valid response was received
    fi
    
    # Parse the response to get job names
    jobs=$(jq -r '.items[] | select(.metadata.name | startswith("sas-compute-server-")) | .metadata.name' /tmp/k8s_response.json)
    
    # Check if no jobs are found
    if [ -z "$jobs" ]; then
        log INFO "No active SAS Compute Server jobs found."
        return 0  # Exit function early if no jobs are found
    fi

    # Count jobs and log result
    job_count=$(echo "$jobs" | wc -l)
    log INFO "Found $job_count SAS Compute Server job(s)."

    # For each job, extract serverID, context, owner, and job start time.
    for job_name in ${jobs}; do
        log INFO "Processing job: [${job_name}]"

        # Extract serverID and context from container command directly from job spec.
        server_id=$(curl -k -s "${K8S_API_URL}/apis/batch/v1/namespaces/${NAMESPACE}/jobs/${job_name}" \
            -H "Authorization: Bearer ${K8S_TOKEN}" \
            -H "Accept: application/json" | jq '.spec.template.spec.containers[0].command | index("-serverID") as $i | .[$i+1]')
        server_id=$(echo "$server_id" | sed 's/^"//;s/"$//' | xargs)

        context=$(curl -k -s "${K8S_API_URL}/apis/batch/v1/namespaces/${NAMESPACE}/jobs/${job_name}" \
            -H "Authorization: Bearer ${K8S_TOKEN}" \
            -H "Accept: application/json" | jq '.spec.template.spec.containers[0].command | index("-context") as $i | .[$i+1]')
        context=$(echo "$context" | sed 's/^"//;s/"$//' | xargs)

        # Get context's name using its id.
        context_name=$(curl -k -s "${SAS_COMPUTE_URL}/compute/contexts/${context}" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Accept: application/json" | jq -r '.name')
        context_name=$(echo "$context_name" | sed 's/^"//;s/"$//')

        # Extract owner from the launcher.sas.com/username label
        owner=$(curl -k -s "${K8S_API_URL}/apis/batch/v1/namespaces/${NAMESPACE}/jobs/${job_name}" \
            -H "Authorization: Bearer ${K8S_TOKEN}" \
            -H "Accept: application/json" | jq -r '.spec.template.metadata.labels["launcher.sas.com/username"] // "unknown"')

        # Get job start time from job status.
        start_time=$(curl -k -s "${K8S_API_URL}/apis/batch/v1/namespaces/${NAMESPACE}/jobs/${job_name}" \
            -H "Authorization: Bearer ${K8S_TOKEN}" \
            -H "Accept: application/json" | jq -r '.status.startTime')
        
        # Check if start_time is valid before proceeding
        if [ -z "$start_time" ] || [ "$start_time" == "null" ]; then
            log ERROR "Start time not found for job: [${job_name}]."
            exit 1
        else
            # Calculate how many hours ago this job started.
            start_time_seconds=$(date --date="$start_time" +%s)
            current_time_seconds=$(date +%s)
            runtime_hours=$(( (current_time_seconds - start_time_seconds) / 3600 ))
        
            # Ensure runtime_hours is a valid integer
            if ! [[ "$runtime_hours" =~ ^[0-9]+$ ]]; then
                log ERROR "Invalid runtime hours calculated for job: [${job_name}]. Skipping."
                continue  # Skip this job if runtime calculation fails
            fi
        fi

        log INFO "Job: [${job_name}], ServerID: [${server_id}], Context: [${context_name}], Owner: [${owner}], Runtime: [${runtime_hours} hours]."

        # Check session status via SAS Viya REST API...
        check_session_status "$server_id" "$context_name"
    done
}

# Function to check session status via SAS Viya REST API by searching for a session ID starting with server_id.
check_session_status() {
    local server_id=$1
    local context_name=$2
    local job_name="sas-compute-server-${server_id}"

    # Query SAS Viya Compute API to get all sessions and find the one that contains server_id.
    response=$(curl -k -s "${SAS_COMPUTE_URL}/compute/sessions" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Accept: application/json")

    # Extract session ID that contains server_id.
    session_id=$(echo "$response" | jq -r --arg server_id "$server_id" '.items[] | select(.id | contains($server_id)) | .id')

    # Trim any whitespace from server_id and session_id
    server_id=$(echo "$server_id" | xargs)
    session_id=$(echo "$session_id" | xargs)

    # Check if a session was found.
    if [ -z "$session_id" ]; then
        log INFO "No session found for server ID: [${server_id}]."
        #zombie_serverIDs+=("$server_id")
        #return 0
    fi
    
    # Query SAS Viya Compute API to get the state of the found session.
    response=$(curl -k -s "${SAS_COMPUTE_URL}/compute/sessions/${session_id}" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Accept: application/json")

    # Extract the state of the session.
    state=$(echo "$response" | jq -r '.state')

    # Check session state and runtime hours
    if [[ "$runtime_hours" -lt "$TIME_LIMIT_HOURS" && "$state" == "running" ]]; then
        log INFO "Session [${session_id}] in [${context_name}] owned by [${owner}] is [${state}]."
        active_serverIDs+=("$server_id")
    elif [[ "$runtime_hours" -ge "$TIME_LIMIT_HOURS" && "$state" == "running" ]]; then
        log WARN "Session [${session_id}] in [${context_name}] owned by [${owner}] has been [${state}] for [${runtime_hours} hours], exceeding limit. To manually delete, issue the following command 'kubectl -n ${NAMESPACE} delete job ${job_name}"
        active_serverIDs+=("$server_id")
    elif [[ "$runtime_hours" -ge "$TIME_LIMIT_HOURS" && "$state" != "running" ]]; then
        log INFO "Session [${session_id}] in [${context_name}] owned by [${owner}] is a zombie. Marked for deletion."
        zombie_serverIDs+=("$server_id")
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

# Delete zombie jobs
delete_zombie_jobs() {
    for server_id in "${zombie_serverIDs[@]}"; do
        log INFO "Deleting zombie job: sas-compute-server-$server_id"
        ##DEMO##api_call DELETE "${K8S_API_URL}/apis/batch/v1/namespaces/${NAMESPACE}/jobs/sas-compute-server-${server_id}" -H "Authorization: Bearer ${K8S_TOKEN}"
    done
}

# Clean up orphaned directories
cleanup_directories() {
    log INFO "Scanning for orphaned work directories..."
    find /sastmp/*/*/default -mindepth 1 -maxdepth 1 -type d | while read -r dir; do
        server_id=$(basename "$dir")
        if [[ ! " ${active_serverIDs[*]} " =~ " $server_id " ]]; then
            log INFO "Deleting orphaned directory: $dir"
            ##DEMO##rm -rf "$dir"
            ##DEMO##if [ ! -d "$dir" ]; then
                log INFO "Orphaned directory deleted successfully: $dir"
            ##DEMO##else
            ##DEMO##    log ERROR "Unable to delete orphaned directory: $dir"
            ##DEMO##fi
        else
            log INFO "Skipping active directory: $dir"
        fi
    done
}

# Main script execution loop for all contexts in SAS Compute API (internal communication).
main() {
   log INFO "Starting cleanup process."

   # Initialize arrays for active and zombie server IDs
   active_serverIDs=()
   zombie_serverIDs=()

   # Validate environment variables
   validate_env

   # Retrieve ACCESS_TOKEN from SAS Viya REST API.
   get_access_token
   
   # Query Kubernetes API for sas-compute-server-* jobs.
   get_k8s_jobs
   
   # Delete zombie jobs using Kubernetes API.
   delete_zombie_jobs
   
   # Cleanup directories under /sastmp/.
   cleanup_directories
   
   log INFO "Cleanup process completed."
}

main   # Run main function.
