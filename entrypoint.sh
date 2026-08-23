#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

die() {
  printf 'private-ai RunPod entrypoint: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 \
    || die "required container command is unavailable: $1"
}

for required_command in realpath ssh-keygen stat /usr/sbin/sshd vllm; do
  require_command "$required_command"
done

[[ ${EUID:-$(id -u)} -eq 0 ]] \
  || die 'the container entrypoint must run as root so it can start sshd'

ulimit -c 0 || die 'could not disable container core dumps'
[[ $(ulimit -c) == 0 ]] || die 'container core dumps remain enabled'

[[ -z ${VLLM_API_KEY:-} ]] \
  || die 'VLLM_API_KEY must be unset; this image keeps vLLM loopback-only and the runtime does not send API authentication'

validate_vllm_arguments() {
  local argument host_value='' host_seen=0 index
  local -a arguments=("$@")

  for ((index = 0; index < ${#arguments[@]}; index++)); do
    argument=${arguments[index]}
    case "$argument" in
      --host)
        ((host_seen == 0)) || die '--host may be specified only once'
        ((index + 1 < ${#arguments[@]})) \
          || die '--host requires a value'
        host_value=${arguments[index + 1]}
        host_seen=1
        ((index += 1))
        ;;
      --host=*)
        ((host_seen == 0)) || die '--host may be specified only once'
        host_value=${argument#--host=}
        host_seen=1
        ;;
      --api-key|--api-key=*)
        die '--api-key is unsupported; this image keeps vLLM loopback-only and the runtime does not send API authentication'
        ;;
    esac
  done

  ((host_seen == 1)) \
    || die 'container arguments must explicitly include --host 127.0.0.1'
  [[ $host_value == 127.0.0.1 ]] \
    || die 'vLLM must bind to 127.0.0.1; do not publish its HTTP port'
}

validate_vllm_arguments "$@"

verify_root_mode() {
  local path=$1 expected_mode=$2 description=$3 actual

  actual=$(stat -c '%u:%a' -- "$path") \
    || die "$description ownership and permissions could not be inspected"
  [[ $actual == "0:$expected_mode" ]] \
    || die "$description ownership or permissions are unsafe; expected uid:mode 0:$expected_mode, found $actual"
}

ensure_real_directory() {
  local directory=$1 mode=$2 resolved

  if [[ -e $directory || -L $directory ]]; then
    [[ -d $directory && ! -L $directory ]] \
      || die 'an operator SSH directory is not a real directory'
  else
    mkdir --mode="$mode" -- "$directory" \
      || die 'could not create an operator SSH directory'
  fi

  chmod "$mode" -- "$directory" \
    || die 'could not secure an operator SSH directory'
  verify_root_mode \
    "$directory" "${mode#0}" 'an operator SSH directory'
  resolved=$(realpath -e -- "$directory") \
    || die 'an operator SSH directory could not be resolved'
  [[ $resolved == "$directory" ]] \
    || die 'an operator SSH directory resolved outside its expected path'
}

host_key_mode=${PRIVATE_AI_SSH_HOST_KEY_MODE:-ephemeral}
case "$host_key_mode" in
  ephemeral)
    # Keep the active server identity away from provider volume filesystems
    # that cannot enforce OpenSSH's required private-key mode. A container
    # recreation intentionally generates a new fingerprint.
    host_key_directory=/run/private-ai-ssh-host
    ensure_real_directory "$host_key_directory" 0700
    ;;
  persistent)
    runtime_root=${RUNTIME_ROOT:-/workspace}
    [[ $runtime_root == /* ]] \
      || die 'RUNTIME_ROOT must be an absolute path'
    [[ -d $runtime_root ]] \
      || die 'RUNTIME_ROOT must already exist as a directory'

    runtime_root_real=$(realpath -e -- "$runtime_root") \
      || die 'RUNTIME_ROOT could not be resolved'
    [[ $runtime_root_real != / ]] \
      || die 'RUNTIME_ROOT must not resolve to the filesystem root'

    public_directory=$runtime_root_real/public
    operator_directory=$public_directory/operator
    host_key_directory=$operator_directory/ssh

    ensure_real_directory "$public_directory" 0755
    ensure_real_directory "$operator_directory" 0700
    ensure_real_directory "$host_key_directory" 0700

    case "$host_key_directory/" in
      "$runtime_root_real"/public/operator/ssh/) ;;
      *) die 'operator SSH host-key path escaped RUNTIME_ROOT' ;;
    esac
    ;;
  *)
    die 'PRIVATE_AI_SSH_HOST_KEY_MODE must be ephemeral or persistent'
    ;;
esac

host_key=$host_key_directory/ssh_host_ed25519_key
host_public_key=$host_key.pub

if [[ -e $host_key || -L $host_key ]]; then
  [[ -f $host_key && ! -L $host_key ]] \
    || die 'SSH host private key must be a regular, non-symlink file'
  chmod 0600 -- "$host_key" \
    || die 'could not secure the SSH host private key'
  verify_root_mode "$host_key" 600 'the SSH host private key'
  ssh-keygen -y -f "$host_key" >/dev/null \
    || die 'SSH host private key is invalid; refusing to replace it automatically'
else
  key_stage_directory=$(mktemp -d "$host_key_directory/.host-key-stage.XXXXXXXX") \
    || die 'could not create a host-key staging directory'
  cleanup_key_stage() {
    rm -rf -- "$key_stage_directory"
  }
  trap cleanup_key_stage EXIT HUP INT TERM

  ssh-keygen -q -t ed25519 -N '' -f "$key_stage_directory/ssh_host_ed25519_key" \
    || die 'could not generate the SSH host private key'
  mv -- "$key_stage_directory/ssh_host_ed25519_key" "$host_key"
  mv -- "$key_stage_directory/ssh_host_ed25519_key.pub" "$host_public_key"
  chmod 0600 -- "$host_key"
  chmod 0644 -- "$host_public_key"
  verify_root_mode "$host_key" 600 'the SSH host private key'
  verify_root_mode "$host_public_key" 644 'the SSH host public key'
  cleanup_key_stage
  trap - EXIT HUP INT TERM
fi

if [[ -e $host_public_key || -L $host_public_key ]]; then
  [[ -f $host_public_key && ! -L $host_public_key ]] \
    || die 'SSH host public key must be a regular, non-symlink file'
  chmod 0644 -- "$host_public_key" \
    || die 'could not secure the SSH host public key'
  verify_root_mode "$host_public_key" 644 'the SSH host public key'
fi

host_fingerprint=$(ssh-keygen -E sha256 -lf "$host_key" | awk 'NR == 1 {print $2}')
[[ $host_fingerprint == SHA256:* ]] \
  || die 'could not derive the SSH host-key fingerprint'
printf 'private-ai RunPod SSH host-key mode=%s fingerprint=%s\n' \
  "$host_key_mode" "$host_fingerprint"

[[ -n ${PUBLIC_KEY:-} ]] \
  || die 'RunPod PUBLIC_KEY is empty; add an account SSH public key before deploying the Pod'
(( ${#PUBLIC_KEY} <= 16384 )) \
  || die 'RunPod PUBLIC_KEY exceeds the accepted size limit'

install -d -m 0700 /run/private-ai-ssh
authorized_keys_stage=$(mktemp /run/private-ai-ssh/.authorized-keys.XXXXXXXX) \
  || die 'could not create the temporary authorized_keys file'
authorized_keys=/run/private-ai-ssh/authorized_keys
cleanup_authorized_keys_stage() {
  rm -f -- "$authorized_keys_stage"
}
trap cleanup_authorized_keys_stage EXIT HUP INT TERM

key_count=0
while IFS= read -r key_line || [[ -n $key_line ]]; do
  [[ -n $key_line ]] || continue
  IFS=' ' read -r key_type key_blob key_comment <<< "$key_line"
  case "$key_type" in
    ssh-ed25519|sk-ssh-ed25519@openssh.com|ecdsa-sha2-nistp256|sk-ecdsa-sha2-nistp256@openssh.com|ssh-rsa) ;;
    *) die 'RunPod PUBLIC_KEY contains an unsupported key type or authorized_keys option' ;;
  esac
  [[ $key_blob =~ ^[A-Za-z0-9+/]+={0,3}$ ]] \
    || die 'RunPod PUBLIC_KEY contains an invalid key body'
  printf '%s\n' "$key_line" >> "$authorized_keys_stage"
  ((key_count += 1))
done <<< "$PUBLIC_KEY"

((key_count > 0)) || die 'RunPod PUBLIC_KEY contains no usable key'
ssh-keygen -l -f "$authorized_keys_stage" >/dev/null \
  || die 'RunPod PUBLIC_KEY could not be parsed by OpenSSH'
chmod 0600 -- "$authorized_keys_stage"
mv -fT -- "$authorized_keys_stage" "$authorized_keys"
trap - EXIT HUP INT TERM

install -d -m 0755 /run/sshd

sshd_arguments=(
  -o 'AddressFamily=inet'
  -o "AuthorizedKeysFile=$authorized_keys"
  -o 'DisableForwarding=yes'
  -o "HostKey=$host_key"
  -o 'KbdInteractiveAuthentication=no'
  -o 'ListenAddress=0.0.0.0'
  -o 'PasswordAuthentication=no'
  -o 'PermitEmptyPasswords=no'
  -o 'PermitRootLogin=prohibit-password'
  -o 'PermitUserEnvironment=no'
  -o 'PermitUserRC=no'
  -o 'PidFile=/run/private-ai-sshd.pid'
  -o 'Port=22'
  -o 'PubkeyAuthentication=yes'
  -o 'UsePAM=no'
)

/usr/sbin/sshd -t "${sshd_arguments[@]}" \
  || die 'OpenSSH configuration validation failed'
/usr/sbin/sshd "${sshd_arguments[@]}" \
  || die 'OpenSSH failed to start'

exec vllm serve "$@"
