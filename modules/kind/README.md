# Kind

The Kind module creates a local Kubernetes cluster that's primarily used for testing and verifying that the scripts work as intended. It can be used for local testing and PR-checks. Kind **is not** the intended target for load testing outside of verifying the general logic.

The created kind cluster has a port mapping to the local host to ports in the cluster for Ingress purposes.
