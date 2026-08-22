FROM vllm/vllm-openai:v0.26.0@sha256:ffb2d59b1c059a5bd8d781320c9f5189de8293693b7d95da54befddaa54abf52

LABEL org.opencontainers.image.title="private-ai RunPod Full SSH vLLM"
LABEL org.opencontainers.image.description="Pinned vLLM image with Full SSH transport prerequisites; the ML stack is unchanged"

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && apt-get install -y --no-install-recommends \
        age \
        bash \
        ca-certificates \
        coreutils \
        diffutils \
        findutils \
        gawk \
        grep \
        openssh-client \
        openssh-server \
        tar \
        util-linux \
    && for required_command in \
        age age-keygen bash tar findmnt setsid find sort cmp grep df awk tr \
        head cat wc truncate sha256sum install mv chmod rm mkdir mkfifo env \
        sleep python3 realpath ssh-keygen /usr/sbin/sshd vllm id mktemp; do \
        command -v "$required_command" >/dev/null 2>&1 \
            || { printf 'missing required image command: %s\n' "$required_command" >&2; exit 1; }; \
    done \
    && age --version >/dev/null 2>&1 \
    && age-keygen --version >/dev/null 2>&1 \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_* \
    && install -d -m 0755 /run/sshd

COPY entrypoint.sh /usr/local/bin/private-ai-runpod-entrypoint
RUN chmod 0755 /usr/local/bin/private-ai-runpod-entrypoint \
    && bash -n /usr/local/bin/private-ai-runpod-entrypoint

# RunPod must publish TCP 22 explicitly. Do not publish the vLLM HTTP port.
EXPOSE 22/tcp

ENTRYPOINT ["/usr/local/bin/private-ai-runpod-entrypoint"]
