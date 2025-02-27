FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

LABEL maintainer="Antonio Neri <antoneri@proton.me>" \
      description="SAS Viya - Compute Work Purge"

# Basic environment variables
ENV LANG="en_US.UTF-8" \
    TZ="Europe/Rome"

# Install necessary packages: curl for HTTP requests and jq for JSON parsing
RUN microdnf update -y && \
    microdnf upgrade -y && \
    microdnf install -y jq findutils sudo && \
    microdnf clean all && \
    rm -rf /tmp/* /var/tmp/* /var/cache/dnf /var/cache/yum

# Copy the script to the container's filesystem
COPY resources/cleanup-script.sh /usr/local/bin/cleanup-script.sh

# Ensure the script is executable
RUN chmod +x /usr/local/bin/cleanup-script.sh

# Set the entrypoint to run the script
ENTRYPOINT ["/usr/local/bin/cleanup-script.sh"]