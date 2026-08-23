# RunPod vLLM image

A small extension of `vllm/vllm-openai:v0.26.0` for running vLLM with direct
SSH access on RunPod.

## Publish

1. Push this repository to GitHub.
2. Open **Actions → Publish RunPod Full SSH vLLM image → Run workflow**.
3. When the workflow succeeds, set the new `private-ai-vllm` package to
   **Public** so RunPod can pull it.
4. Copy the immutable image reference from the workflow summary:

   ```text
   ghcr.io/YOUR_GITHUB_OWNER/private-ai-vllm@sha256:...
   ```

## RunPod template

- Container image: the immutable GHCR reference above.
- Container start command: vLLM arguments beginning with `--model`; do not add
  `vllm serve`.
- vLLM bind arguments: `--host 127.0.0.1 --port 8000`.
- Volume mount path: `/workspace`.
- Exposed TCP ports: `22` only.
- Exposed HTTP ports: empty.
- UDP: disabled.
- Environment: `RUNTIME_ROOT=/workspace`.
- SSH host-key mode: `PRIVATE_AI_SSH_HOST_KEY_MODE=ephemeral`.
- `VLLM_API_KEY`: unset.
- RunPod account SSH public key: configured before deployment.

`RUNTIME_ROOT` remains `/workspace` because the private worker uses it as the
persistent public-cache and recovery boundary. It is deliberately independent
from the active SSH host key. The image defaults
`PRIVATE_AI_SSH_HOST_KEY_MODE` to `ephemeral`, which keeps the key under
root-only `/run/private-ai-ssh-host` and avoids provider volume filesystems that
may not preserve OpenSSH's required `0600` private-key mode. A container
recreation generates a new fingerprint; compare the new fingerprint in
RunPod's container log before updating the controller's known-host entry.

`persistent` mode stores the key beneath
`$RUNTIME_ROOT/public/operator/ssh`. Use it only on a filesystem verified to
preserve root ownership and exact POSIX modes. The entrypoint verifies directory
and key ownership/modes after `chmod` and fails closed; it never silently falls
back from persistent to ephemeral identity.

For the current Qwen3.8 video2txt profile, use these arguments as the container
start command:

```text
--model Qwen/Qwen3.8-27B-FP8
--host 127.0.0.1
--port 8000
--dtype auto
--gpu-memory-utilization 0.95
--tensor-parallel-size 1
--max-model-len 65536
--max-num-seqs 2
--reasoning-parser qwen3
--limit-mm-per-prompt '{"image":8}'
--mm-processor-cache-gb 0
--cpu-offload-gb 0
--generation-config vllm
--no-enable-prefix-caching
--no-enable-log-requests
--no-enable-log-outputs
--disable-uvicorn-access-log
--no-log-error-stack
--no-enable-logging-iteration-details
--disable-fastapi-docs
--no-enable-tokenizer-info-endpoint
--enable-per-request-metrics
```

The two-sequence ceiling matches the app's two concurrent verification or
recheck calls; rolling requests remain serial. Keep prefix/multimodal processor
caching and request/output logging disabled for the private workload. Do not
enable FP8 KV cache as a latency shortcut without a separate quality benchmark.
The image build also verifies the base vLLM environment's Pillow dependency,
which video2txt uses for its optional RAM-only resize/JPEG request transform.

After deployment, the workflow-built image starts vLLM and SSH. RunPod's
Connect panel shows the public IP and mapped SSH port:

```bash
ssh root@PUBLIC_IP -p MAPPED_SSH_PORT -i ~/.ssh/id_ed25519
```

The container logs show the SSH host-key mode, fingerprint, and vLLM startup
progress.
