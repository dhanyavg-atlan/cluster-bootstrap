# (B) Runner image for the Devtron Job: just OpenTofu + curl + bash.
# No gcloud/helm CLI needed — the TF google/helm providers handle those.
FROM ghcr.io/opentofu/opentofu:1.12.1

# opentofu image is alpine-based; add curl + bash for register.sh
RUN apk add --no-cache curl bash

WORKDIR /work
ENTRYPOINT ["/bin/bash", "-c"]
