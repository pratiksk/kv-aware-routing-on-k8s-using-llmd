# Reference results — profile `1gpu-small`

**Setup:** 1× NVIDIA RTX 5060 Ti 16 GB, single-node k3s, llm-d `release-1.0` (router chart v1.0.0), vLLM 0.31.0, Qwen3-0.6B, 2 vLLM pods sharing the GPU, 4 GiB KV cache each (37,440 tokens).

**Test:** 10 `/v1/completions` requests sharing a long prefix, 3 s apart, `max_tokens` 16. Counters are vLLM's `vllm:request_success_total`, `vllm:prefix_cache_queries_total` and `vllm:prefix_cache_hits_total`, as the increase over the test.

## Through llm-d (precise prefix-cache routing), cold prefix

| Pod | Requests | Tokens queried | Tokens hit | Hit rate |
|---|---|---|---|---|
| A | **10** | ~19,100 | ~16,700 | **87%** |
| B | 0 | 0 | 0 | — |

The first request computes the prefix. vLLM publishes its blocks, and the router sends the other 9 to the same pod, where they hit.

## Through a plain Kubernetes Service, different cold prefix

| Pod | Requests | Tokens queried | Tokens hit | Hit rate |
|---|---|---|---|---|
| A | 8 | 11,289 | 9,408 | 83% |
| B | 2 | 2,822 | 1,344 | 48% |
| **Total** | 10 | 14,111 | 10,752 | **76%** |

The pod is random per connection, and this run split 8/2. Both pods computed and cached the same prefix.

## Through llm-d, prefix already cached from an earlier test

| Pod | Requests | Tokens queried | Tokens hit | Hit rate |
|---|---|---|---|---|
| A (holds the prefix) | **20** | 38,222 | 37,120 | **97%** |
| B | 0 | 0 | 0 | — |

The router remembered where the prefix lived, so even the first request was a hit.

## Many users (`test-multiuser.sh`)

Each user has their own ~2.7k-token prefix; users take turns, one request at a time. All prefixes together exceed one pod's KV cache (~37k tokens) but fit in both pods' caches.

**Through llm-d, 20 users × 6 rounds:**

```
POD     |      REQ    QUERIED        HIT   HIT%
--------+--------------------------------------
972v6   |       66     185928     153600    83%
blqrv   |       54     152232     125760    83%
--------+--------------------------------------
TOTAL   |      120     338160     279360    83%
```

**Through the plain Service, 20 users × 6 rounds:**

```
POD     |      REQ    QUERIED        HIT   HIT%
--------+--------------------------------------
972v6   |       54     151632      74432    49%
blqrv   |       66     186528      81856    44%
--------+--------------------------------------
TOTAL   |      120     338160     156288    46%
```

Same workload on both routes: 120 requests, 338,160 prompt tokens looked up. llm-d: 83% (every request after round 1 hits, 5/6). Plain Service: 46%.

**Sizing note:** with too many users (e.g. 35 × ~2.7k ≈ 96k tokens, more than both pods together), both routes drop to about 0% hits: users take turns in a fixed order, and the least-recently-used eviction always evicts the prefix that is needed next. Keep the total prefix size between one and two pods' cache size.
