#!/bin/bash

# Exit on any command failure
set -e

# Trap errors and call error handler
trap 'error_handler $LINENO $?' ERR

# Log file location
LOG_FILE="/tmp/sas-cleanup-tool.log"

# Error handler function
error_handler() {
    local line_number=$1
    local exit_code=$2
    log ERROR "Script failed at line $line_number with exit code $exit_code."
    exit $exit_code
}

# Logging function with levels (INFO, DEBUG, WARN, ERROR)
log() {
    local level=$1; shift;
    local message="$@";
    
    case "$level" in 
        INFO) echo "$(date '+%Y-%m-%d %H:%M:%S') | INFO | sas-compute-work-purge-job | $message" | tee -a "$LOG_FILE";;
        DEBUG) echo "$(date '+%Y-%m-%d %H:%M:%S') | DEBUG | sas-compute-work-purge-job | $message" | tee -a "$LOG_FILE";;
        WARN) echo "$(date '+%Y-%m-%d %H:%M:%S') | WARN | sas-compute-work-purge-job | $message" | tee -a "$LOG_FILE" >&2;;
        ERROR) echo "$(date '+%Y-%m-%d %H:%M:%S') | ERROR | sas-compute-work-purge-job | $message" | tee -a "$LOG_FILE" >&2;;
        *) echo "$(date '+%Y-%m-%d %H:%M:%S') | UNKNOWN | sas-compute-work-purge-job | $message";;
    esac;
}

# Retry mechanism for transient failures
retry() {
    local retries=3; local delay=5;
    
    for ((i=0; i<retries; i++)); do 
        "$@" && return 0;
        
        log WARN "Command failed. Attempt $((i+1)) of $retries.";
        
        if [ "$i" -lt "$((retries-1))" ]; then sleep "$delay"; fi;
        
    done
    
    log ERROR "Command failed after $retries attempts.";
    return 1   # Return failure after all retries.
}

# Set SAS Compute and SAS Logon App URLs for in-cluster communication
K8S_API_URL="https://kubernetes.default.svc"
K8S_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
SAS_COMPUTE_URL="https://sas-compute.${NAMESPACE}.svc.cluster.local"
SAS_LOGON_URL="https://sas-logon-app.${NAMESPACE}.svc.cluster.local"

# Ensure required environment variables are set
if [ -z "$K8S_API_URL" ] || [ -z "$K8S_TOKEN" ] || [ -z "$NAMESPACE" ] || [ -z "$TIME_LIMIT_HOURS" ] || [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
    log ERROR "TIME_LIMIT_HOURS, CLIENT_ID, and CLIENT_SECRET must be set through the cronjob deployment."
    exit 1
fi

# Function to retrieve ACCESS_TOKEN using client credentials from SAS Logon App (internal communication)
get_access_token() {
    log INFO "Attempting to retrieve access token..."
    
    response=$(curl -k -s -o response.json -w "%{http_code}" -X POST "${SAS_LOGON_URL}/SASLogon/oauth/token" \
      --user "${CLIENT_ID}:${CLIENT_SECRET}" \
      -d "grant_type=client_credentials")

    http_status=$(echo "$response" | tail -n1)

    if [ "$http_status" -ne 200 ]; then
        log ERROR "Failed to retrieve access token. HTTP status: $http_status"
        cat response.json | jq # Log the response body for debugging
        exit 1
    fi

    ACCESS_TOKEN=$(jq -r '.access_token' < response.json)

    if [ -z "${ACCESS_TOKEN}" ]; then
        log ERROR "Access token is empty"
        exit 1
    else
        log INFO "Access token retrieved successfully."
    fi

    rm response.json  # Clean up temporary file
}

# Function to query Kubernetes API for sas-compute-server-* jobs and extract serverID, context, owner, and job start time.
get_k8s_jobs() {
    log INFO "Looking for SAS Compute Server jobs in the namespace..."

    # Query Kubernetes API for jobs matching sas-compute-server-*
    jobs=$(curl --cacert "${K8S_CA_CERT}" -s "${K8S_API_URL}/apis/batch/v1/namespaces/${NAMESPACE}/jobs" \
        -H "Authorization: Bearer ${K8S_TOKEN}" \
        -H "Accept: application/json" | jq -r '.items[] | select(.metadata.name | startswith("sas-compute-server-")) | .metadata.name')  

    # Check number of jobs found
    job_count=$(echo "$jobs" | grep -v '^$' | wc -l)
    if [ "$job_count" -eq 0 ]; then
        log INFO "No SAS Compute Server jobs found."
        return 0  # Exit function early if no jobs are found
    else
        log INFO "Found $job_count SAS Compute Server job(s)."
    fi

    # For each job, extract serverID, context, owner, and job start time.
    for job_name in ${jobs}; do
        log INFO "Processing job: ${job_name}"
        
        # Extract serverID and context from container command directly from the job spec.
        server_id=$(curl --cacert "${K8S_CA_CERT}" -s "${K8S_API_URL}/apis/batch/v1/namespaces/${NAMESPACE}/jobs/${job_name}" \
            -H "Authorization: Bearer ${K8S_TOKEN}" \
            -H "Accept: application/json" | jq '.spec.template.spec.containers[0].command' | grep -A 1 '-serverID' | tail -n 1 | tr -d '",')
        
        context=$(curl --cacert "${K8S_CA_CERT}" -s "${K8S_API_URL}/apis/batch/v1/namespaces/${NAMESPACE}/jobs/${job_name}" \
            -H "Authorization: Bearer ${K8S_TOKEN}" \
            -H "Accept: application/json" | jq '.spec.template.spec.containers[0].command' | grep -A 1 '-context' | tail -n 1 | tr -d '",')

        # Extract owner from the launcher.sas.com/username label
        owner=$(curl --cacert "${K8S_CA_CERT}" -s "${K8S_API_URL}/apis/batch/v1/namespaces/${NAMESPACE}/jobs/${job_name}" \
            -H "Authorization: Bearer ${K8S_TOKEN}" \
            -H "Accept: application/json" | jq '.metadata.labels["launcher.sas.com/username"]')

        # Get job start time from job status.
        start_time=$(curl --cacert "${K8S_CA_CERT}" -s "${K8S_API_URL}/apis/batch/v1/namespaces/${NAMESPACE}/jobs/${job_name}" \
            -H "Authorization: Bearer ${K8S_TOKEN}" \
            -H "Accept: application/json" | jq -r '.status.startTime')

        # Calculate how many hours ago this job started.
        start_time_seconds=$(date --date="$start_time" +%s)
        current_time_seconds=$(date +%s)
        runtime_hours=$(( (current_time_seconds-start_time_seconds)/3600 ))

        log INFO "Job: ${job_name}, Server ID: ${server_id}, Context: ${context}, Owner: ${owner}, Runtime: ${runtime_hours} hours"
        
        # Check session status via SAS Viya REST API...
        check_session_status "$server_id"
        
    done
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

# Function to delete zombie jobs using Kubernetes API.
delete_zombie_jobs() {
   local all_zombie_ids=("${zombie_serverIDs[@]}" "${safeDelete_serverIDs[@]}")
   
   for server_id in "${all_zombie_ids[@]}"; do 
       job_name="sas-compute-server-${server_id}"
       log INFO "Deleting zombie job: ${job_name}"
       ##DEBUG##curl --cacert "${K8S_CA_CERT}" -X DELETE "${K8S_API_URL}/apis/batch/v1/namespaces/${NAMESPACE}/jobs/${job_name}" \
           -H "Authorization: Bearer ${K8S_TOKEN}"
   done 
}

# Cleanup directories under /sastmp based on active and zombie server IDs.
cleanup_directories() {
    # Define the base directory
    base_dir="/sastmp"

    # Loop through the main directories in /sastmp (log, run, spool, tmp)
    for dir1 in "$base_dir"/*; do
        # Check if dir1 is a directory (e.g., /log or /run)
        if [[ -d "$dir1" ]]; then
            # Loop through the subdirectories (batch, compsrv, connectserver)
            for dir2 in "$dir1"/*; do
                # Check if dir2 is a directory (e.g., /batch or /compsrv)
                if [[ -d "$dir2" ]]; then
                    default_dir="$dir2/default"
                    # Check if the "default" directory exists and contains subdirectories
                    if [[ -d "$default_dir" ]] && [[ $(ls -A "$default_dir") ]]; then
                        # Loop through each server_id directory inside "default"
                        for server_dir in "$default_dir"/*; do
                            # Ensure it's a directory before proceeding
                            if [[ -d "$server_dir" ]]; then
                                # Extract the basename of each directory (e.g., $server_id)
                                server_id=$(basename "$server_dir")
                                # Check if the server_id is NOT in the active_serverIDs array
                                if [[ ! " ${active_serverIDs[@]} " =~ " ${server_id} " ]]; then
                                    log INFO "Deleting work directory: $server_dir"
                                    ##DEBUG##rm -rf "$server_dir"
                                else
                                    log INFO "Skipping active session work directory: $server_dir"
                                fi
                            fi
                        done
                    fi
                fi
            done
        fi
    done
}

# Main script execution loop for all contexts in SAS Compute API (internal communication).
main() {
   log INFO "Starting cleanup process."

   # Retrieve ACCESS_TOKEN from SAS Viya REST API.
   get_access_token
   
   # Query Kubernetes API for sas-compute-server-* jobs.
   get_k8s_jobs
   
   # Delete zombie jobs using Kubernetes API.
   delete_zombie_jobs
   
   # Cleanup directories under /sastmp/.
   cleanup_directories
   
   log INFO "Cleanup process completed successfully."
}

main   # Run main function.