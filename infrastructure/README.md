# EKS Scalability Test Infrastructure

Infrastructure for running EKS scalability and performance tests using Tekton Pipelines on EKS Auto Mode.

## Overview

This repo provides a GitOps-managed test platform where the management cluster infrastructure and test definitions are reconciled from a single Git repository via Flux.

## Management Cluster

The management cluster runs on **EKS Auto Mode**, which natively manages:

- **Compute** — nodes are provisioned and scaled automatically, no node groups or Karpenter needed
- **Storage** — EBS volumes via the built-in `ebs.csi.eks.amazonaws.com` CSI driver. A `ebs-gp3` and `gp2` StorageClass is created as the default for workloads requiring persistent volumes (e.g., Tekton Results PostgreSQL)
- **Load Balancing** — ALB is managed by the built-in `eks.amazonaws.com/alb` ingress controller. Creating an `Ingress` resource with `ingressClassName: alb` automatically provisions an internet-facing ALB
- **DNS** — ExternalDNS watches Ingress resources and automatically creates Route53 CNAME records based on the `external-dns.alpha.kubernetes.io/hostname` annotation. New dashboards get subdomains automatically
- **Networking** — VPC CNI, CoreDNS, and kube-proxy are managed by EKS AutoMode

This eliminates ~70% of the addons that the legacy infrastructure required (Karpenter, EBS CSI, AWS LBC, metrics-server, node termination handler).

## GitOps with Flux

Flux continuously reconciles cluster state from this repository. A single **GitRepository** source points to this repo, with separate Flux Kustomizations applying different paths:

| Kustomization | Path | Purpose |
|---------------|------|---------|
| `platform-config` | `./infrastructure/addons` | Cluster addons (Tekton, Flux UI, PerfDash, ACK) |
| `tekton-tests` | `./tests/tekton-resources` | Test definitions (tasks, pipelines, triggers) |

Changes pushed to this repo are automatically applied to the cluster within 5–10 minutes.

### Addon Structure

```
infrastructure/addons/
├── kustomization.yaml          # Top-level: includes all subdirectories
├── resources.yaml              # Shared resources (scalability namespace)
├── flux/                       # Flux UI ingress + RBAC
├── tekton/                     # Tekton Operator + Dashboard
│   ├── storage-class.yaml      # ebs-gp3 (EKS Auto Mode CSI)
│   ├── storage-class-gp2.yaml      # ebs-gp3 (EKS Auto Mode CSI)
│   ├── bucket.yaml             # Flux Bucket source for Tekton releases
│   ├── operator-install.yaml   # Flux Kustomization: installs operator
│   ├── dashboards.yaml         # Flux Kustomization: config + ingress (dependsOn: operator)
│   └── dashboards/
│       ├── config.yaml         # TektonConfig CR (timeouts, workspace defaults)
│       ├── ingress.yaml
│       └── rbac.yaml
├── perfdash/                   # Performance results dashboard
└── ack/                        # AWS Controllers for Kubernetes
```

### Ordering

Plain kustomize applies resources in a single batch with no ordering. For resources that depend on other controllers being ready (e.g., Tekton Dashboard needs the Operator running first), we use **Flux Kustomization CRs** with `dependsOn`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tekton-dashboards
spec:
  dependsOn:
    - name: tekton-operator
  path: ./infrastructure/addons/tekton/dashboards
```

### Variable Substitution

Environment-specific values (domain names, certificate ARNs, IAM role ARNs) are injected via Flux's `postBuild.substituteFrom`, reading from a ConfigMap and Secret deployed by the CDK infrastructure stack.

## Tekton

The **Tekton Operator** manages all Tekton components as a single install:

| Component | Purpose |
|-----------|---------|
| Pipelines | Core CI/CD engine |
| Triggers | Event-driven pipeline execution |
| Dashboard | Web UI for viewing runs |
| Results | Persistent logs in PostgreSQL (survives pod deletion) |

### Configuration

- **Pipeline timeout**: 4 hours (240 minutes)
- **Default workspace**: `emptyDir: {}`

## Running Tests

### Connect to the cluster

```bash
aws eks update-kubeconfig --name <cluster-name> --region us-west-2
```

### View available pipelines

```bash
kubectl get pipelines -n scalability
```

### Start a test run

```yaml
apiVersion: tekton.dev/v1beta1
kind: PipelineRun
metadata:
  name: modheer-scheduler-tier-xl-100k-metrics3
  namespace: scalability
spec:
  pipelineRef:
      name: awscli-eks-cl2-pcp-scheduler-throughput
  timeouts:
    pipeline: 9h0m0s
    tasks: 8h30m0s
  workspaces:
      - name: source
        emptyDir: {}
      - name: config
        volumeClaimTemplate:
          spec:
            accessModes:
              - ReadWriteOnce
            storageClassName: gp2
            resources:
              requests:
                storage: 1Gi
      - name: results
        emptyDir: {}
  params:
    - name: cluster-name
      value: "awscli-eks-throughput-1k-xl-metrics3"
    - name: endpoint
      value: "https://api.beta.us-west-2.wesley.amazonaws.com"
    - name: desired-nodes
      value: "10"
    - name: cl2-throughput-pods
      value: 15
    - name: cl2-throughput-threshold
      value: 1
    - name: cl2-default-qps
      value: 167
    - name: cl2-default-burst
      value: 167
    - name: cl2-uniform-qps
      value: 167
    - name: results-bucket
      value: kit-eks-perflab/kit-eks-1k/$(date +%s)
    - name: slack-hook
      value: ""
    - name: slack-message
      value: "You can monitor here - https://tekton.scalability.eks.aws.dev/#/namespaces/tekton-pipelines/pipelineruns ;5k node "
    - name: vpc-cfn-url
      value: "https://raw.githubusercontent.com/awslabs/kubernetes-iteration-toolkit/main/tests/assets/amazon-eks-vpc.json"
    - name: kubernetes-version
      value: "1.34"
    - name: control-plane-tier
      value: "tier-xl"
    - name: metric-name
      value: "pcp-throughput-xl"
    - name: iterations
      value: 3
  podTemplate:
      nodeSelector:
        kubernetes.io/arch: amd64
  serviceAccountName: tekton-pipelines-executor
```

```bash
kubectl apply -f pipeline-run.yaml
```

### Monitor runs

Via CLI:
```bash
kubectl get pipelineruns -n scalability
```

Or via the Tekton Dashboard (accessible at the cluster's tekton ingress URL).

## Adding a New Dashboard

To expose a new service with automatic DNS:

1. Create an `Ingress` resource with ALB annotations:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-service
  namespace: my-namespace
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: "${CERT_ARN}"
    external-dns.alpha.kubernetes.io/hostname: "${MY_DOMAIN}"
spec:
  ingressClassName: alb
  rules:
    - host: "${MY_DOMAIN}"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-service
                port:
                  number: 8080
```

2. EKS Auto Mode provisions the ALB automatically
3. ExternalDNS creates the DNS record automatically
4. The service is accessible at `https://<MY_DOMAIN>`

## Adding a New Addon

1. Create a directory under `infrastructure/addons/`
2. Add a `kustomization.yaml` listing your resources
3. Add the directory to `infrastructure/addons/kustomization.yaml`
4. Push — Flux reconciles automatically within 5–10 minutes

## Prerequisites

- [aws-cli](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) configured
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [tkn](https://tekton.dev/docs/cli/) (optional, for Tekton CLI)
- Access to the EKS cluster
