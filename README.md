# CodeArena Infrastructure

This repository contains the infrastructure as code (IaC) and Kubernetes manifests for the CodeArena platform.

## Directory Structure

- `terraform/`: Contains Terraform scripts to provision the cloud infrastructure.
- `k8s/`: Contains Kubernetes deployment manifests for CodeArena services (e.g. `competition`, `gateway`, `iam`).

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) (for provisioning infrastructure)
- [kubectl](https://kubernetes.io/docs/tasks/tools/) (for cluster management)
- Cloud Provider CLI configured locally (e.g. AWS CLI, Google Cloud CLI, etc.)
- Access to the target Kubernetes cluster

## Usage

You can use the provided `Makefile` to easily run common commands from the root directory.

### Terraform

To provision or update the infrastructure:

```bash
make tf-init   # Initialize Terraform workspace
make tf-plan   # Review the infrastructure changes
make tf-apply  # Apply the changes to the cloud provider
```

### Kubernetes

Once the cluster is up and running, you can deploy the applications using `kubectl`.

```bash
make k8s-apply   # Deploy all CodeArena services
make k8s-delete  # Delete all deployed CodeArena services
```

## Contributing

Make sure to run `terraform fmt` in the `terraform/` directory before opening any Pull Requests to ensure formatting consistency.
