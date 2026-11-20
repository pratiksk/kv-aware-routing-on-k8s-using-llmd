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
