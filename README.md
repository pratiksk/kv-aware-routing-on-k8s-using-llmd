# KV-Cache Aware Routing Demo (llm-d)

Same vLLM pods, two ways in. See for yourself what happens when the router knows what each pod has cached.

```
                ┌─> llm-d router (Envoy + EPP) ─┐   picks the pod that already has
client ─────────┤                               ├─> the prompt's prefix cached
                └─> plain k8s Service ──────────┘   picks a random pod
                                    both front the SAME 2 vLLM pods
```

Built on the upstream [llm-d precise prefix-cache routing guide](https://llm-d.ai/docs/well-lit-paths/foundations/precise-prefix-cache-routing) (pinned to `release-1.0`). This repo adds **hardware profiles**, a **baseline** to compare against, and **scripts** to run and measure the comparison. Nothing upstream is forked.

## How it works (one paragraph)

vLLM stores the KV cache in blocks of 64 tokens and publishes a `BlockStored` / `BlockRemoved` event for each over ZMQ. The llm-d router subscribes to every pod and keeps an index of which pod holds which blocks. For each request it tokenizes the prompt, computes the same block hashes, and sends the request to the pod holding the longest cached prefix, unless that pod is overloaded. A plain Kubernetes Service picks a pod at random, so the same prefix gets computed, and cached, on several pods.

## Results you should see

10 requests sharing a ~1.5k-token prefix, sent one after another (`scripts/test-prefix.sh`):

| | Requests per pod | Prefix cache hit rate |
|---|---|---|
| **via llm-d** | **10 / 0** (all on the warm pod) | **87%** |
| via plain Service | random, e.g. 8 / 2 | 76%: the prefix is computed on both pods |

These numbers come from routing, not hardware, so they reproduce on any profile. Only latency changes. Full output: [docs/results.md](docs/results.md).

## Profiles: pick the closest to your hardware

| Profile | Hardware | Model | Status |
|---|---|---|---|
| [`1gpu-small`](profiles/1gpu-small) | 1 NVIDIA GPU, 16 GB+ (both pods share it) | Qwen3-0.6B | ✅ tested (RTX 5060 Ti 16 GB) |
| [`2gpu`](profiles/2gpu) | 2 NVIDIA GPUs, 16 GB+ each | Qwen3-0.6B | 🟡 untested |
| [`cpu`](profiles/cpu) | No GPU (~16 cores, ~24 GB RAM) | Qwen3-0.6B | 🟡 untested |
| `sim` | Anything, using [llm-d-inference-sim](https://github.com/llm-d/llm-d-inference-sim) | none (simulated) | 📋 planned |
| upstream default | 4 × H100 | Qwen3-32B | use the [upstream guide](https://llm-d.ai/docs/well-lit-paths/foundations/precise-prefix-cache-routing) as-is |

A profile is just `profile.env` (model, accelerator) plus a Kustomize patch on the upstream model server. To adapt one, copy the closest profile and change the knobs listed at the top of its `patch.yaml`. If you get one working on new hardware, a PR is welcome.

## Install

**Prerequisites:** Linux with `git`, `curl` and [`helm`](https://helm.sh/docs/intro/install/). For GPU profiles, the NVIDIA driver and the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/), installed **before** k3s so k3s picks up the `nvidia` runtime. The `2gpu` profile also needs the NVIDIA device plugin.

The steps follow the upstream [precise prefix-cache routing guide](https://llm-d.ai/docs/well-lit-paths/foundations/precise-prefix-cache-routing). The only changes are the router's model name and the model server overlay from `profiles/`.

### 1. k3s (single node)

```bash
# Optional: keep k3s data on a large disk (here an NVMe mounted at /mnt/nvme0n1)
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml <<EOF2
data-dir: /mnt/nvme0n1/k3s
kubelet-arg:
  - "root-dir=/mnt/nvme0n1/kubelet"
disable:
  - traefik
write-kubeconfig-mode: "0644"
EOF2

curl -sfL https://get.k3s.io | sh -
sudo k3s kubectl get node                   # should show one node, Ready

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml # so kubectl and helm find the cluster
```

### 2. llm-d router

```bash
export DEMO=$(pwd)          # run from the root of this repo
export PROFILE=1gpu-small   # one of profiles/

git clone https://github.com/llm-d/llm-d.git && cd llm-d && git checkout release-1.0

export REPO_ROOT=$(realpath $(git rev-parse --show-toplevel))
export GUIDE_NAME=precise-prefix-cache-routing
export NAMESPACE=llm-d-precise-prefix-cache-routing
export MODEL_SERVER=vllm
export INFRA_PROVIDER=base
export MONITORING=false
export MONITORING_VALUES=
export ENGINE_VALUES=
source ${DEMO}/profiles/${PROFILE}/profile.env    # sets ACCELERATOR_TYPE and MODEL
export ACCELERATOR_TYPE MODEL
source ${REPO_ROOT}/guides/env.sh                  # sets GAIE_URL, router chart and versions
echo $NAMESPACE $MODEL $GAIE_VERSION $ROUTER_CHART_VERSION

# Gateway API Inference Extension CRDs
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/${GAIE_URL}/v1-manifests.yaml

# Namespace and Hugging Face token (a read token from https://huggingface.co/settings/tokens;
# the pods use it to download the model)
export HF_TOKEN=<your-hf-read-token>
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic llm-d-hf-token --from-literal=HF_TOKEN=${HF_TOKEN} -n ${NAMESPACE}
```

**Set the router's model name.** In `guides/precise-prefix-cache-routing/router/precise-prefix-cache-routing.values.yaml` (line 52), change `modelName: Qwen/Qwen3-32B` to your profile's model, e.g. `modelName: Qwen/Qwen3-0.6B`. The router tokenizes prompts with this name, so it must match what vLLM serves.

```bash
# Optional: Prometheus + Grafana
./guides/recipes/observability/install-prometheus-grafana.sh
export MONITORING=true
export MONITORING_VALUES="-f ${REPO_ROOT}/guides/recipes/router/features/monitoring.values.yaml"

helm install ${GUIDE_NAME} ${ROUTER_STANDALONE_CHART} \
  -f ${REPO_ROOT}/guides/recipes/router/base.values.yaml \
  ${MONITORING_VALUES} \
  -f ${REPO_ROOT}/guides/${GUIDE_NAME}/router/${GUIDE_NAME}.values.yaml \
  ${ENGINE_VALUES} \
  -n ${NAMESPACE} --version ${ROUTER_CHART_VERSION}
```

### 3. vLLM pods (from the profile)

```bash
# The profile is a Kustomize overlay on the guide's model server
cp -r ${DEMO}/profiles/${PROFILE} ${REPO_ROOT}/guides/${GUIDE_NAME}/modelserver/${ACCELERATOR_TYPE}/vllm/${PROFILE}
kubectl apply -n ${NAMESPACE} -k ${REPO_ROOT}/guides/${GUIDE_NAME}/modelserver/${ACCELERATOR_TYPE}/vllm/${PROFILE}

# Only with monitoring: scrape vLLM metrics
kubectl apply -n ${NAMESPACE} -k ${REPO_ROOT}/guides/recipes/modelserver/components/monitoring

# Wait until both pods are 1/1 Running (the first start pulls a ~10 GB image)
kubectl get pods -n ${NAMESPACE} -w
```

### 4. Baseline: plain Service in front of the same pods

```bash
kubectl expose deployment ${GUIDE_NAME}-${ACCELERATOR_TYPE}-vllm-decode --name vllm-direct --port 8000 -n ${NAMESPACE}
```

### 5. Check it works

```bash
export IP=$(kubectl get service ${GUIDE_NAME}-epp -n ${NAMESPACE} -o jsonpath='{.spec.clusterIP}')
kubectl run curl-test --rm -i --restart=Never --image=${CURL_TEST_IMAGE} -n ${NAMESPACE} \
  --env="IP=${IP}" --env="MODEL=${MODEL}" \
  -- /bin/sh -c 'curl -sS -X POST "http://${IP}/v1/chat/completions" -H "Content-Type: application/json" \
     -d "{\"model\": \"${MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"How are you today?\"}], \"max_tokens\": 50}"'
```

A JSON reply with a `choices` field means the router and both pods are serving.

## How to use the scripts

Run them from the root of this repo, with `kubectl` pointing at the cluster. They use the default namespace and model above; override with `NAMESPACE`, `GUIDE_NAME` and `MODEL` if you changed them.

| Script | What it does |
|---|---|
| `scripts/stats.sh [reset]` | Per vLLM pod: requests, prompt tokens looked up in the prefix cache, tokens found, hit rate. Shows the change since its previous run, then saves a new baseline. `reset` saves the baseline without printing. |
| `scripts/test-prefix.sh <llmd\|direct> [label]` | 10 requests sharing a \~1.5k-token prefix, 3 s apart. `llmd` goes through the router, `direct` through the plain Service. The label goes into the prefix, so use a new label per run to start cold. |
| `scripts/test-multiuser.sh <llmd\|direct> [users] [rounds] [label]` | Many users (default 20), each with their own \~2.7k-token prefix, sending interleaved requests for several rounds (default 6). *(untested)* |

A comparison run:

```bash
# Through llm-d
./scripts/stats.sh reset
./scripts/test-prefix.sh llmd run1
./scripts/stats.sh

# Without llm-d (new label = a prefix neither pod has cached)
./scripts/stats.sh reset
./scripts/test-prefix.sh direct run2
./scripts/stats.sh
```

`stats.sh` output looks like this (a real run: `test-multiuser.sh llmd 18 5`, 18 users, 5 rounds, through llm-d):

```
Since last run (19:41:21):
POD     |      REQ    QUERIED        HIT   HIT%
--------+--------------------------------------
972v6   |       48     133584     110400    83%
blqrv   |       42     117336      96960    83%
--------+--------------------------------------
TOTAL   |       90     250920     207360    83%
```

The test scripts also print Grafana links for the run's time window. Set `GRAFANA_URL` if Grafana is not at `http://localhost:3000` in your browser.

**Empty cache:** restart both vLLM pods (counters also go back to 0):

```bash
kubectl delete pod -n llm-d-precise-prefix-cache-routing -l llm-d.ai/guide=precise-prefix-cache-routing
kubectl wait pod -n llm-d-precise-prefix-cache-routing -l llm-d.ai/guide=precise-prefix-cache-routing --for=condition=Ready --timeout=15m
./scripts/stats.sh reset
```

**Grafana** (with monitoring): `kubectl port-forward -n llm-d-monitoring svc/llmd-grafana 3000:80`, then from your laptop `ssh -L 3000:localhost:3000 <server>` and open `http://localhost:3000`. Log in as `admin`; the password is in secret `llmd-grafana`, key `admin-password`. The dashboards worth opening are **llm-d Performance Dashboard** (per-pod cache hit rates, TTFT) and **llm-d Diagnostic Drill-Down** (request distribution).

## Notes and gotchas

- **Two pods on one GPU:** set a fixed `--kv-cache-memory-bytes`, not `--gpu-memory-utilization`. Pods starting together otherwise measure each other's memory, so one crashes or gets a much smaller cache.
- **Don't `kubectl rollout restart`** on a shared GPU. It starts a third pod first. Delete the pods instead (see "Empty cache").
- **Prompts must be longer than one block (64 tokens).** Shorter prompts are never cached, so routing looks random.
- **The plain Service picks a pod per connection, not per request.** The tests open a new connection per request.
- **Model name in 3 places must match:** the vLLM model, the KV-event topic, and the router's `modelName`. The profiles set the first two; you set the third in step 2.

## License

Apache-2.0, same as llm-d.
