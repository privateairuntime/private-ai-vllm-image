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
- `VLLM_API_KEY`: unset.
- RunPod account SSH public key: configured before deployment.

After deployment, the workflow-built image starts vLLM and SSH. RunPod's
Connect panel shows the public IP and mapped SSH port:

```bash
ssh root@PUBLIC_IP -p MAPPED_SSH_PORT -i ~/.ssh/id_ed25519
```

The container logs show the SSH host fingerprint and vLLM startup progress.
