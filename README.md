# EKS Performance Tests

This repository contains the infrastructure, test definitions, and automation for running EKS scalability and performance tests at scale.

## Repository Structure

```
├── infrastructure/
│   ├── addons/             GitOps-managed cluster addons (Tekton, Flux UI, PerfDash, ACK)
│   └── README.md           Infrastructure setup and architecture details
├── tests/
│   ├── tekton-resources/
│   │   ├── tasks/          Reusable Tekton Tasks (cluster setup, load generation, teardown)
│   │   ├── pipelines/      End-to-end test pipeline definitions
│   ├── assets/             Launch templates, VPC configs, IAM policies
│   └── images/             Container images for test tooling
└── docs/
```

## How It Works

1. **Management Cluster** — An EKS Auto Mode cluster runs Tekton Pipelines, managed via Flux GitOps from this repo. See [infrastructure/README.md](infrastructure/README.md) for details.

2. **Test Pipelines** — Tekton Pipelines orchestrate the full test lifecycle:
   - Create an EKS cluster under test (CUT)
   - Configure addons and node groups
   - Run [ClusterLoader2](https://github.com/kubernetes/perf-tests/tree/master/clusterloader2) workloads
   - Collect metrics and upload results to S3
   - Tear down the CUT

3. **Continuous Execution** — Tekton Triggers schedule tests on a recurring basis. Results are visualized in PerfDash

4. **GitOps Delivery** — All changes (new tests, addon updates, alarm definitions) are delivered by pushing to this repo. Flux reconciles the cluster state automatically.

## Quick Start

### View test runs

```bash
aws eks update-kubeconfig --name <cluster-name> --region us-west-2
kubectl get pipelineruns -n scalability
```

### Start a test manually

Use a sample PipelinRun like below, use parameters/pipelineRef from the test you are running:

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

### Monitor via Dashboard

Access the Tekton Dashboard at the cluster's ingress URL to view pipeline runs, logs, and task status.

## Test Types

| Test | Description | Scale |
|------|-------------|-------|
| Load test (CL2) | Full cluster load with SLO validation | 5,000 nodes |
| PCP throughput | Control plane throughput benchmarks | 1,000 nodes |

## Contributing

- **New test**: Add a Task under `tests/tekton-resources/tasks/` and a Pipeline under `tests/tekton-resources/pipelines/`
- **New addon**: Add a directory under `infrastructure/addons/` with a `kustomization.yaml`
- **New trigger**: Add a trigger config under `tests/tekton-resources/triggers/`

Push to the repo and Flux applies changes automatically.

## Links

- [Infrastructure Details](infrastructure/README.md)
- [Test Definitions](tests/README.md)
- [ClusterLoader2](https://github.com/kubernetes/perf-tests/tree/master/clusterloader2)
