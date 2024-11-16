FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

LABEL version="v1.0" \
      maintainer="Antonio Neri <antoneri@proton.me>" \
      description="SAS Viya - Compute Work Purge"

# Basic environment variables
ENV LANG="en_US.UTF-8" \
    TZ="Europe/Rome"

# Install necessary packages: curl for HTTP requests and jq for JSON parsing
RUN microdnf update -y && \
    microdnf install -y jq sudo && \
    microdnf clean all

# Copy the script to the container's filesystem
COPY resources/cleanup-script.sh /usr/local/bin/cleanup-script.sh

# Ensure the script is executable
RUN chmod +x /usr/local/bin/cleanup-script.sh

# Set the entrypoint to run the script
ENTRYPOINT ["/usr/local/bin/cleanup-script.sh"]