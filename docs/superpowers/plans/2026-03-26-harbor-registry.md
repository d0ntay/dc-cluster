# Harbor Private Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Harbor as the cluster's private Docker registry via ArgoCD, then wire up network-automation to pull images from it.

**Architecture:** Official Harbor Helm chart (v1.18.3) deployed as an ArgoCD Application with inline values. Harbor runs in its own `harbor` namespace with Longhorn storage. Sealed secret for admin credentials, k3s registries.yaml on all nodes for HTTP pulls.

**Tech Stack:** Harbor 2.14.x, Helm, ArgoCD, kubeseal, Longhorn, Traefik ingress

**Spec:** `docs/superpowers/specs/2026-03-26-harbor-registry-design.md`

---

## File Map

| Action | File | Purpose |
|--------|------|---------|
| Create | `secrets/harbor-admin.yaml` | SealedSecret for Harbor admin password |
| Create | `apps/harbor.yaml` | ArgoCD Application for Harbor Helm chart |
| Create | `secrets/network-automation-harbor-pull.yaml` | SealedSecret for image pull credentials |
| Modify | `charts/network-automation/values.yaml` | Update registry to `harbor.dc.internal/network-automation` |

---

### Task 1: Seal the Harbor Admin Secret

This must exist before Harbor deploys or Core will CrashLoopBackOff.

**Files:**
- Create: `secrets/harbor-admin.yaml`

- [ ] **Step 1: Generate the sealed secret**

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

Replace `<your-password>` with your chosen Harbor admin password. Save this password — you'll need it for docker login, pull secrets, and API calls later.

- [ ] **Step 2: Verify the sealed secret looks correct**

```bash
cat secrets/harbor-admin.yaml
```

Expected: A `SealedSecret` with `metadata.namespace: harbor`, `encryptedData.HARBOR_ADMIN_PASSWORD` containing a long base64 string (not a placeholder).

- [ ] **Step 3: Commit the secret (do NOT push yet — push together with Task 2)**

```bash
cd /home/d0ntay/dc-cluster
git add secrets/harbor-admin.yaml
git commit -m "feat: add sealed secret for Harbor admin password"
```

Note: We commit but don't push yet. The sealed-secrets-store app will apply this SealedSecret, but the sealed-secrets controller needs the `harbor` namespace to exist before it can create the actual Secret. The Harbor ArgoCD app (Task 2) creates the namespace via `CreateNamespace=true`. Pushing both together minimizes the timing gap — the controller will retry until the namespace exists.

---

### Task 2: Create the ArgoCD Application for Harbor

**Files:**
- Create: `apps/harbor.yaml`

- [ ] **Step 1: Create the ArgoCD Application manifest**

Create `apps/harbor.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: harbor
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://helm.goharbor.io
    chart: harbor
    targetRevision: "1.18.3"
    helm:
      values: |
        expose:
          type: ingress
          tls:
            enabled: false
          ingress:
            hosts:
              core: harbor.dc.internal
            className: traefik
            annotations:
              traefik.ingress.kubernetes.io/router.entrypoints: web
        externalURL: http://harbor.dc.internal
        existingSecretAdminPassword: harbor-admin
        existingSecretAdminPasswordKey: HARBOR_ADMIN_PASSWORD
        persistence:
          persistentVolumeClaim:
            registry:
              storageClass: longhorn
              size: 5Gi
            database:
              storageClass: longhorn
              size: 2Gi
            redis:
              storageClass: longhorn
              size: 1Gi
            jobservice:
              jobLog:
                storageClass: longhorn
                size: 1Gi
        trivy:
          enabled: false
        portal:
          affinity:
            nodeAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                nodeSelectorTerms:
                  - matchExpressions:
                      - key: node-role.kubernetes.io/control-plane
                        operator: DoesNotExist
        core:
          affinity:
            nodeAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                nodeSelectorTerms:
                  - matchExpressions:
                      - key: node-role.kubernetes.io/control-plane
                        operator: DoesNotExist
        jobservice:
          affinity:
            nodeAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                nodeSelectorTerms:
                  - matchExpressions:
                      - key: node-role.kubernetes.io/control-plane
                        operator: DoesNotExist
        registry:
          affinity:
            nodeAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                nodeSelectorTerms:
                  - matchExpressions:
                      - key: node-role.kubernetes.io/control-plane
                        operator: DoesNotExist
        database:
          internal:
            affinity:
              nodeAffinity:
                requiredDuringSchedulingIgnoredDuringExecution:
                  nodeSelectorTerms:
                    - matchExpressions:
                        - key: node-role.kubernetes.io/control-plane
                          operator: DoesNotExist
        redis:
          internal:
            affinity:
              nodeAffinity:
                requiredDuringSchedulingIgnoredDuringExecution:
                  nodeSelectorTerms:
                    - matchExpressions:
                        - key: node-role.kubernetes.io/control-plane
                          operator: DoesNotExist
  destination:
    server: https://kubernetes.default.svc
    namespace: harbor
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 2: Commit and push (both secret and app together)**

```bash
git add apps/harbor.yaml
git commit -m "feat: add Harbor private registry via ArgoCD"
git push
```

This pushes both the sealed secret (Task 1) and the Harbor app. ArgoCD will sync both — the app creates the `harbor` namespace, then the sealed-secrets controller unseals the admin secret into it.

- [ ] **Step 3: Verify the admin secret unsealed**

```bash
kubectl get secret harbor-admin -n harbor
```

Expected: Secret exists with `TYPE: Opaque`. If it doesn't appear after 2 minutes, check the sealed-secrets controller logs: `kubectl logs -n kube-system -l app.kubernetes.io/name=sealed-secrets`

- [ ] **Step 4: Monitor the deployment**

```bash
kubectl get pods -n harbor -w
```

Expected: 5-6 pods spinning up (harbor-core, harbor-portal, harbor-registry, harbor-jobservice, harbor-database, harbor-redis). Wait until all show `Running` and `READY`. This can take 3-5 minutes for database initialization.

If any pods are stuck in `CrashLoopBackOff`, check logs:

```bash
kubectl logs -n harbor <pod-name>
```

- [ ] **Step 5: Verify Harbor is accessible**

```bash
curl -s http://harbor.dc.internal/api/v2.0/health | head
```

Expected: JSON with `"status":"healthy"` or similar. If DNS doesn't resolve, verify CoreDNS wildcard is working:

```bash
nslookup harbor.dc.internal 192.168.1.100
```

---

### Task 3: Configure k3s Nodes for Harbor

All nodes need to know Harbor is an HTTP (insecure) registry.

- [ ] **Step 1: Create registries.yaml on dc-control-01 (this machine)**

```bash
sudo tee /etc/rancher/k3s/registries.yaml <<'EOF'
mirrors:
  "harbor.dc.internal":
    endpoint:
      - "http://harbor.dc.internal"
EOF
```

- [ ] **Step 2: Create registries.yaml on all worker nodes**

```bash
for node in dc-worker-01 dc-worker-02 dc-worker-03; do
  ssh $node 'sudo tee /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  "harbor.dc.internal":
    endpoint:
      - "http://harbor.dc.internal"
EOF'
done
```

If SSH keys aren't set up, run the `sudo tee ...` command manually on each worker node.

- [ ] **Step 3: Restart k3s on all nodes**

```bash
# Control plane
sudo systemctl restart k3s

# Workers
for node in dc-worker-01 dc-worker-02 dc-worker-03; do
  ssh $node 'sudo systemctl restart k3s-agent'
done
```

- [ ] **Step 4: Verify nodes are back and ready**

```bash
kubectl get nodes
```

Expected: All 4 nodes show `Ready`. May take 30-60 seconds after restart.

---

### Task 4: Configure Docker for Harbor (Build Machine)

The machine where you build images needs Docker configured to push to Harbor over HTTP.

- [ ] **Step 1: Add insecure registry to Docker daemon config**

```bash
sudo tee /etc/docker/daemon.json <<'EOF'
{
  "insecure-registries": ["harbor.dc.internal"]
}
EOF
```

If `/etc/docker/daemon.json` already exists with other settings, merge the `insecure-registries` array into it instead of overwriting.

- [ ] **Step 2: Restart Docker**

```bash
sudo systemctl restart docker
```

- [ ] **Step 3: Test docker login**

```bash
docker login harbor.dc.internal -u admin -p <your-harbor-password>
```

Expected: `Login Succeeded`

---

### Task 5: Create Harbor Project and Push Images

- [ ] **Step 1: Create the `network-automation` project in Harbor**

```bash
curl -X POST http://harbor.dc.internal/api/v2.0/projects \
  -u admin:<your-harbor-password> \
  -H "Content-Type: application/json" \
  -d '{"project_name":"network-automation","public":false}'
```

Expected: HTTP 201 Created (no output on success). Verify:

```bash
curl -s http://harbor.dc.internal/api/v2.0/projects \
  -u admin:<your-harbor-password> | python3 -m json.tool
```

- [ ] **Step 2: Build and push the API image**

```bash
cd /home/d0ntay/code/work/netauto
docker build -f Dockerfile.api -t harbor.dc.internal/network-automation/api:latest .
docker push harbor.dc.internal/network-automation/api:latest
```

Expected: Push completes with layer digests and `latest: digest: sha256:...`

- [ ] **Step 3: Build and push the Dashboard image**

```bash
docker build -f dashboard/Dockerfile -t harbor.dc.internal/network-automation/dashboard:latest dashboard/
docker push harbor.dc.internal/network-automation/dashboard:latest
```

Expected: Same as above — push completes successfully.

- [ ] **Step 4: Verify images are in Harbor**

```bash
curl -s http://harbor.dc.internal/api/v2.0/projects/network-automation/repositories \
  -u admin:<your-harbor-password> | python3 -m json.tool
```

Expected: JSON listing `api` and `dashboard` repositories.

---

### Task 6: Create Harbor Pull Secret for network-automation

**Files:**
- Create: `secrets/network-automation-harbor-pull.yaml`

- [ ] **Step 1: Generate the sealed pull secret**

```bash
kubectl create secret docker-registry harbor-pull-secret \
  --namespace network-automation \
  --docker-server=harbor.dc.internal \
  --docker-username=admin \
  --docker-password=<your-harbor-password> \
  --dry-run=client -o yaml \
  | kubeseal --controller-name=sealed-secrets-controller \
             --controller-namespace=kube-system \
             --format yaml \
  > secrets/network-automation-harbor-pull.yaml
```

- [ ] **Step 2: Verify the sealed secret**

```bash
cat secrets/network-automation-harbor-pull.yaml
```

Expected: SealedSecret with `metadata.name: harbor-pull-secret`, `metadata.namespace: network-automation`, `type: kubernetes.io/dockerconfigjson`.

- [ ] **Step 3: Commit and push**

```bash
git add secrets/network-automation-harbor-pull.yaml
git commit -m "feat: add Harbor pull secret for network-automation namespace"
git push
```

- [ ] **Step 4: Verify secret syncs**

```bash
kubectl get secret harbor-pull-secret -n network-automation
```

Expected: Secret exists with type `kubernetes.io/dockerconfigjson`.

---

### Task 7: Update network-automation to Use Harbor

**Files:**
- Modify: `charts/network-automation/values.yaml` (line 1)

- [ ] **Step 1: Update the registry value**

In `charts/network-automation/values.yaml`, change:

```yaml
registry: 10.120.0.2:30003/network-automation
```

to:

```yaml
registry: harbor.dc.internal/network-automation
```

- [ ] **Step 2: Commit and push**

```bash
git add charts/network-automation/values.yaml
git commit -m "feat: point network-automation images at Harbor registry"
git push
```

- [ ] **Step 3: Verify ArgoCD syncs and pods pull from Harbor**

```bash
kubectl get pods -n network-automation -w
```

Wait for dashboard and API pods to restart with the new image source. Check a pod's image:

```bash
kubectl get pod -n network-automation -l app=api -o jsonpath='{.items[0].spec.containers[0].image}'
```

Expected: `harbor.dc.internal/network-automation/api:latest`

- [ ] **Step 4: End-to-end smoke test**

Verify the API and dashboard are actually running (not just scheduled):

```bash
kubectl get pods -n network-automation -l app=api
kubectl get pods -n network-automation -l app=dashboard
```

Expected: Both pods show `Running` with `READY 1/1`. If pods are in `ImagePullBackOff`, check that:
- k3s registries.yaml is in place on the node the pod landed on
- harbor-pull-secret exists in the namespace
- the image tag exists in Harbor

---

## Deployment Order Summary

```
Task 1: Seal admin secret → commit (don't push yet)
Task 2: Create ArgoCD app → commit → push both → wait for Harbor pods
Task 3: Configure k3s registries.yaml on all nodes → restart
Task 4: Configure Docker insecure registry → restart → docker login
Task 5: Create Harbor project → build → push images
Task 6: Seal pull secret → commit → push → wait for sync
Task 7: Update network-automation registry → commit → push → verify
```
