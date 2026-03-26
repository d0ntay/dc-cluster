# Harbor Private Registry — Design Spec

## Purpose

Deploy Harbor as the private Docker registry for all custom images in the dc-cluster. Replaces the previously planned `10.120.0.2:30003` Harbor instance that was never stood up. Primary consumer is the network-automation platform (API + dashboard images), with all future custom apps using it as well.

## Architecture

### Deployment Method

Official Harbor Helm chart from `https://helm.goharbor.io` deployed via ArgoCD Application manifest (pinned to a specific chart version). Same pattern as minio, kube-prometheus-stack, loki, and tempo.

### Harbor Components

| Component | Enabled | Purpose |
|-----------|---------|---------|
| Core + Portal | Yes | UI and API |
| Registry | Yes | Image storage |
| Jobservice | Yes | Async tasks, garbage collection |
| Redis | Yes (internal) | Cache |
| PostgreSQL | Yes (internal) | Metadata DB |
| Trivy | No | Vulnerability scanner — enable later if needed |
| Notary | No | Image signing — not needed |
| Chartmuseum | No | Deprecated in Harbor 2.x |

### Storage

All PVCs use `longhorn` storage class (3x replication across worker nodes).

| Volume | Size | Purpose |
|--------|------|---------|
| Registry | 5Gi | Docker image layers |
| Database | 2Gi | PostgreSQL metadata |
| Redis | 1Gi | Cache data |
| Jobservice | 1Gi | Job logs |

Total Longhorn allocation: 9Gi. With 3x replication, each worker node stores one full copy (~9Gi per node). Current free disk per node: ~19Gi, leaving ~10Gi headroom for other workloads' growth. Enable Harbor garbage collection early to reclaim space from old image tags. Plan node storage expansion if more projects are added.

### Networking

| Setting | Value |
|---------|-------|
| Domain | `harbor.dc.internal` |
| External URL | `http://harbor.dc.internal` |
| Ingress class | `traefik` |
| Entrypoint | `web` (HTTP) |
| TLS | Disabled (cluster is HTTP-only) |

DNS: No CoreDNS changes needed — the existing wildcard template already resolves all `*.dc.internal` to `192.168.1.100`.

### Node Scheduling

All Harbor pods scheduled on worker nodes only (exclude control plane) via node affinity — consistent with all other workloads in the cluster.

## Files

### New Files

- `apps/harbor.yaml` — ArgoCD Application manifest pointing to official Harbor Helm chart with inline values. Must reference `existingSecretAdminPassword` and `existingSecretAdminPasswordKey` to wire in the sealed secret.
- `secrets/harbor-admin.yaml` — SealedSecret for Harbor admin password

### Modified Files

None. CoreDNS wildcard already handles `harbor.dc.internal`.

## Pre-Deploy Steps

These steps must be completed BEFORE the ArgoCD Application is committed.

### 0. Seal Harbor Admin Secret

The sealed secret must exist before ArgoCD syncs the Harbor app, otherwise Harbor Core will CrashLoopBackOff.

```bash
kubectl create secret generic harbor-admin \
  --namespace harbor \
  --from-literal=HARBOR_ADMIN_PASSWORD=<your-password> \
  --dry-run=client -o yaml \
  | kubeseal --controller-name=sealed-secrets-controller \
             --controller-namespace=kube-system \
             --format yaml \
  > secrets/harbor-admin.yaml
```

Commit `secrets/harbor-admin.yaml` to git and let the sealed-secrets-store app sync it before deploying Harbor.

## Post-Deploy Steps

These steps happen after Harbor is running and healthy.

### 1. k3s Registry Configuration

All 4 nodes need `/etc/rancher/k3s/registries.yaml` so containerd knows to pull from Harbor over HTTP:

```yaml
mirrors:
  "harbor.dc.internal":
    endpoint:
      - "http://harbor.dc.internal"
```

Restart k3s/k3s-agent on each node after creating this file.

### 2. Docker Insecure Registry (build machine)

The machine where you build and push images also needs Harbor configured as an insecure registry in `/etc/docker/daemon.json`:

```json
{
  "insecure-registries": ["harbor.dc.internal"]
}
```

Restart Docker after adding this: `sudo systemctl restart docker`

### 3. Create Harbor Project

Harbor requires a project before you can push images to it. Create via API:

```bash
curl -X POST http://harbor.dc.internal/api/v2.0/projects \
  -u admin:<harbor-admin-password> \
  -H "Content-Type: application/json" \
  -d '{"project_name":"network-automation","public":false}'
```

### 4. Docker Login and Push Images

```bash
cd /home/d0ntay/code/work/netauto

docker login harbor.dc.internal -u admin -p <harbor-admin-password>

docker build -f Dockerfile.api -t harbor.dc.internal/network-automation/api:latest .
docker push harbor.dc.internal/network-automation/api:latest

docker build -f dashboard/Dockerfile -t harbor.dc.internal/network-automation/dashboard:latest dashboard/
docker push harbor.dc.internal/network-automation/dashboard:latest
```

### 5. Harbor Pull Secrets (GitOps)

Each namespace that pulls private images needs a SealedSecret of type `kubernetes.io/dockerconfigjson`. For network-automation:

```bash
kubectl create secret docker-registry harbor-pull-secret \
  --namespace network-automation \
  --docker-server=harbor.dc.internal \
  --docker-username=admin \
  --docker-password=<harbor-admin-password> \
  --dry-run=client -o yaml \
  | kubeseal --controller-name=sealed-secrets-controller \
             --controller-namespace=kube-system \
             --format yaml \
  > secrets/network-automation-harbor-pull.yaml
```

Commit to git so the sealed-secrets-store syncs it. The network-automation chart templates already reference `imagePullSecrets: [{name: harbor-pull-secret}]`.

### 6. Update network-automation Chart

Update `charts/network-automation/values.yaml` to point at Harbor:

```yaml
registry: harbor.dc.internal/network-automation
```

Commit and push — ArgoCD will redeploy with the new image registry.

## Resource Estimates

| Component | CPU Request | Memory Request | CPU Limit | Memory Limit |
|-----------|------------|----------------|-----------|--------------|
| Core | 100m | 256Mi | 500m | 512Mi |
| Portal | 50m | 64Mi | 200m | 128Mi |
| Registry | 100m | 256Mi | 500m | 512Mi |
| Jobservice | 50m | 128Mi | 200m | 256Mi |
| Redis | 50m | 64Mi | 200m | 256Mi |
| PostgreSQL | 100m | 256Mi | 500m | 512Mi |
| **Total** | **450m** | **1024Mi** | **2100m** | **2176Mi** |

Cluster has ample headroom for this across 3 worker nodes.
