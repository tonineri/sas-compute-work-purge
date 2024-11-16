<div align="center">

![SAS Viya](/.design/sasviya.png)

# **SAS Viya - Compute Work Purge**

</div>

![Divider](/.design/divider.png)

This repository contains a Kubernetes CronJob that automates the cleanup of inactive or old SAS Compute sessions and orphaned `saswork` directories in a SAS Viya environment.

![Divider](/.design/divider.png)

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Setup](#setup)
  - [Step 1: Create OAuth Client in SAS Viya](#step-1-create-oauth-client-in-sas-viya)
    - [Method 1: Using the SAS Viya REST API](#method-1-using-the-sas-viya-rest-api)
    - [Method 2: Using the sas-viya CLI](#method-2-using-the-sas-viya-cli)
  - [Step 2: Define Necessary Parameters](#step-2-define-necessary-parameters)
  - [Step 3: Deploy the Tool](#step-3-deploy-the-tool)
- [Usage](#usage)
  - [Monitoring](#monitoring)
  - [Ad-hoc Execution](#ad-hoc-execution)

![Divider](/.design/divider.png)

## Overview

The `sas-compute-work-purge-job` Kubernetes CronJob:

- Deletes inactive or old SAS Compute sessions using the SAS Compute REST API.
- Cleans up `saswork` directories associated with old or orphaned sessions.

By default, the CronJob is scheduled to run daily at midnight, ensuring that unused resources are regularly cleaned up to optimize storage and session management.

![Divider](/.design/divider.png)

## Prerequisites

Before deploying the SAS Cleanup Tool, ensure you have the following prerequisites:

- **Kubernetes Cluster**: A running Kubernetes environment with access to the SAS Viya services.
- **SAS Viya**: A valid SAS Viya environment (namespace).
- **hostPath** or **Persistent Volume Claim (PVC)**: A storage configuration for `/sastmp`, where `saswork` directories are stored. You can choose between a `hostPath` or a PVC.

> [!IMPORTANT]  
> It can be either a `hostPath` or a `persistentVolumeClaim` (PVC). By default, a `hostPath` is used.

![Divider](/.design/divider.png)

## Setup

### Step 1: Create OAuth Client in SAS Viya

To authenticate with SAS Viya, you need to create an OAuth client. Run the following commands to create an OAuth client in your SAS Viya environment.

#### Method 1: Using the SAS Viya REST API

```sh
# Define necessary variables
VIYA_NS="<viyaNamespace>"                   # Example: "sas-viya"
VIYA_URL="<viyaUrl>"                        # Example: "https://sasviya.domain.com"
CLIENT_ID="<desiredViyaClientId>"           # Example: "sas-compute-work-purge"
CLIENT_SECRET="<desiredViyaClientSecret>"   # Example: "52a36ea7ed193be4027ee212f11b9b3af8..."
```

> [!TIP]
> For your `$CLIENT_SECRET`, you can run `openssl rand -hex 32` and use its output to define the value of the `$CLIENT_SECRET` variable. Do not use `CLIENT_SECRET=$(openssl rand -hex 32)` as it will keep creating a new random hex every time you call the variable.

```sh
# Retrieve the Consul token
CONSUL_TOKEN=$(kubectl -n $VIYA_NS get secret sas-consul-client -o jsonpath='{.data.CONSUL_TOKEN}' | base64 -d)

# Obtain a Bearer token
BEARER_TOKEN=$(curl -k -X POST "${VIYA_URL}/SASLogon/oauth/clients/consul?callback=false&serviceId=sas.cli" \
  -H "X-Consul-Token: $CONSUL_TOKEN" | jq -r '.access_token')

# Create the OAuth client
curl -k -X POST "${VIYA_URL}/SASLogon/oauth/clients" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${BEARER_TOKEN}" \
  -d '{
    "client_id": "'"${CLIENT_ID}"'", 
    "client_secret": "'"${CLIENT_SECRET}"'",
    "authorized_grant_types": "client_credentials",
    "scope": "uaa.none",
    "authorities": "uaa.none",
    "redirect_uri": "urn:ietf:wg:oauth:2.0:oob",
    "refresh_token_validity": "31536000",
    "access_token_validity": "7200"
  }' | jq

# Grant necessary permissions
curl -k -X POST "${VIYA_URL}/authorization/rules" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${BEARER_TOKEN}" \
  -d '{
    "objectUri": "/compute/sessions/**",
    "clientId": "'"${CLIENT_ID}"'",
    "permission": ["read", "write", "execute"],
    "type": "grant"
  }'
```

#### Method 2: Using the sas-viya CLI

Assuming that the `sas-viya` CLI is already configured:

```sh
CLIENT_ID="<desiredViyaClientId>"           # Example: "sas-compute-work-purge"
CLIENT_SECRET="<desiredViyaClientSecret>"   # Example: "52a36ea7ed193be4027ee212f11b9b3af8..."
```

> [!TIP]
> For your `$CLIENT_SECRET`, you can run `openssl rand -hex 32` and use its output to define the value of the `$CLIENT_SECRET` variable. Do not use `CLIENT_SECRET=$(openssl rand -hex 32)` as it will keep creating a new random hex every time you call the variable.

```sh
# Login
sas-viya auth login --insecure

# Install necessary plugins
sas-viya plugins install --repo SAS oauth
sas-viya plugins install --repo SAS authorization

# Create the OAuth client
sas-viya oauth register-client \
--id ${CLIENT_ID} \
--secret ${CLIENT_SECRET} \
--authorities "uaa.none" \
--scope "openid,uaa.none" \
--valid-for 7200 \
--grant-client-credentials

# Grant necessary permissions
sas-viya authorization create-rule \
--object-uri "/compute/**" \
--user "${CLIENT_ID}" \
--permissions read,update,add,secure,create,delete,remove \
--description "SAS Compute Work Purge"
```

### Step 2: Define Necessary Parameters

Once the OAuth client is created, encode the `client_id` and `client_secret` in **Base64** and replace placeholders in the [sas-compute-work-purge.yaml](sas-compute-work-purge.yaml) manifest:

```sh
# Define the necessary values
SAS_WORK_HOSTPATH="</host/path/to/mount>" # Example: "/var/mnt/cache"
# SAS_WORK_PVC="<sasWorkPVCname>"           # IF your SASWORK is PVC-based instead. Example: sas-work-pvc
CLIENT_ID_ENC=$(echo -n "${CLIENT_ID}" | base64 -w 0)
CLIENT_SECRET_ENC=$(echo -n "${CLIENT_SECRET}" | base64 -w 0)

# Replace placeholders in the manifest file
sed -i 's|{{ SAS-VIYA-NS }}|'"${VIYA_NS}"'|g' sas-compute-work-purge/sas-compute-work-purge.yaml
sed -i 's|{{ SAS-VIYA-URL }}|'"${VIYA_URL}"'|g' sas-compute-work-purge/sas-compute-work-purge.yaml
sed -i 's|{{ CLIENT-ID }}|'"${CLIENT_ID_ENC}"'|g' sas-compute-work-purge/sas-compute-work-purge.yaml
sed -i 's|{{ CLIENT-SECRET }}|'"${CLIENT_SECRET_ENC}"'|g' sas-compute-work-purge/sas-compute-work-purge.yaml
sed -i 's|{{ TIME-LIMIT-HOURS }}|24|g' sas-compute-work-purge/sas-compute-work-purge.yaml
sed -i 's|{{ SAS-WORK-HOSTPATH }}|'"${SAS_WORK_HOSTPATH}"'|g' sas-compute-work-purge/sas-compute-work-purge.yaml
# sed -i 's|{{ SAS-WORK-PVC }}|'"${SAS_WORK_PVC}"'|g' sas-compute-work-purge/sas-compute-work-purge.yaml ## IF your SASWORK is PVC-based instead.
```

> [!IMPORTANT]
> For `persistentVolumeClaim` (PVC) instead of `hostPath`, make sure you **comment out** the `hostPath` section and **uncomment** the `persistentVolumeClaim` section of the [sas-compute-work-purge.yaml](sas-compute-work-purge.yaml) file.

> [!TIP]
> If you want to change the default schedule **(hourly)**, you can also replace the cron expression:
> ```sh
> sed -i 's|"0 * * * *"|"<yourCron>"|g' sas-compute-work-purge/sas-compute-work-purge.yaml
> ```

### Step 3: Deploy the Tool

Deploy the resources by applying the Kubernetes manifest:

```sh
cd sas-compute-work-purge
kubectl apply -f sas-compute-work-purge.yaml -n $VIYA_NS
```

![Divider](/.design/divider.png)

## Usage

### Monitoring

To check the status of the CronJob and view logs from recent runs:

```sh
kubectl get cronjob sas-compute-work-purge -n $VIYA_NS
kubectl logs --selector=app.kubernetes.io/name=sas-compute-work-purge --namespace=$VIYA_NS
```

### Ad-hoc Execution

To execute the CronJob manually without waiting for its scheduled run:

```sh
kubectl create job --from=cronjob/sas-compute-work-purge sas-compute-work-purge-manual -n $VIYA_NS
kubectl logs job/sas-compute-work-purge-manual -n $VIYA_NS
```

![Divider](/.design/divider.png)