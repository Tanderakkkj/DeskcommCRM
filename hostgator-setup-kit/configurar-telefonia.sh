#!/usr/bin/env bash
# Configura um trunk SIP genérico, sem ligar o profile nem chamar o provedor.
set -Eeuo pipefail
umask 077
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/hostgator-setup-kit/_common.sh"

MODE=configurar
case "${1:-}" in
  '') [ "$#" -eq 0 ] || { printf 'Argumentos inesperados.\n' >&2; exit 2; } ;;
  --ativar) [ "$#" -eq 1 ] || { printf 'Use apenas --ativar.\n' >&2; exit 2; }; MODE=ativar ;;
  *) printf 'Uso: bash hostgator-setup-kit/configurar-telefonia.sh [--ativar]\n' >&2; exit 2 ;;
esac

ENV_FILE="$ROOT_DIR/.env"
PJSIP_FILE="$ROOT_DIR/asterisk/pjsip.conf"
ARI_FILE="$ROOT_DIR/asterisk/ari.conf"
[ -f "$ROOT_DIR/docker-compose.prod.yml" ] && [ -f "$ENV_FILE" ] && [ -d "$ROOT_DIR/asterisk" ] || {
  printf 'Execute após instalar o CRM, na árvore que contém .env, compose e asterisk/.\n' >&2
  exit 1
}
for file in "$ENV_FILE" "$PJSIP_FILE" "$ARI_FILE"; do
  [ ! -L "$file" ] || { printf 'Arquivo simbólico não é aceito: %s\n' "$file" >&2; exit 1; }
done

# Bloqueio estável, sem criar arquivo: duas rodadas não podem restaurar ou
# substituir as configurações uma da outra. O descritor fica aberto até sair.
command -v flock >/dev/null 2>&1 || { printf 'flock não encontrado.\n' >&2; exit 1; }
exec {lockfd}< "$ROOT_DIR/docker-compose.prod.yml"
flock -n "$lockfd" || { printf 'Outra configuração de telefonia já está em andamento.\n' >&2; exit 1; }

# SIGKILL/queda de energia não passa pelo trap. Se houve rename parcial, a
# transação anterior ficou no stage com os originais; recupera ANTES de pedir
# nova confirmação. Sem commit-started, nada foi alterado; com committed, os
# três renames terminaram e só falta descartar o stage.
for pending in "$ROOT_DIR"/.telefonia-config.*; do
  [ -d "$pending" ] || continue
  [[ "${pending##*/}" =~ ^\.telefonia-config\.[A-Za-z0-9]{6}$ ]] && [ ! -L "$pending" ] || {
    printf 'Stage de telefonia inesperado; recuso alterar arquivos.\n' >&2; exit 1;
  }
  if [ -f "$pending/commit-started" ] && [ ! -f "$pending/committed" ]; then
    [ -f "$pending/old-env" ] || { printf 'Backup do .env ausente no stage; recuso recuperar.\n' >&2; exit 1; }
    if [ -f "$pending/old-pjsip" ]; then cp -p "$pending/old-pjsip" "$PJSIP_FILE"; else rm -f "$PJSIP_FILE"; fi
    if [ -f "$pending/old-ari" ]; then cp -p "$pending/old-ari" "$ARI_FILE"; else rm -f "$ARI_FILE"; fi
    cp -p "$pending/old-env" "$ENV_FILE"
    printf 'Configuração interrompida recuperada antes de nova tentativa.\n'
  fi
  rm -f "$pending/new-pjsip" "$pending/new-ari" "$pending/new-env" \
    "$pending/old-pjsip" "$pending/old-ari" "$pending/old-env" \
    "$pending/commit-started" "$pending/committed" "$pending"/new-env.tmp.*
  rmdir "$pending" || { printf 'Stage de telefonia não pôde ser limpo; recuso continuar.\n' >&2; exit 1; }
done

if [ "$MODE" = ativar ]; then
  [ -f "$PJSIP_FILE" ] && [ -f "$ARI_FILE" ] || {
    printf 'Prepare PJSIP e ARI com este script antes de ativar.\n' >&2; exit 1;
  }
  ARI_USERNAME=''; ARI_PASSWORD=''; COMPOSE_PROFILES=''
  kit_path="$PATH"
  load_env "$ENV_FILE"
  PATH="$kit_path"
  [ -n "$ARI_USERNAME" ] && [ -n "$ARI_PASSWORD" ] \
    && grep -Fxq "[$ARI_USERNAME]" "$ARI_FILE" \
    && grep -Fxq "password = $ARI_PASSWORD" "$ARI_FILE" || {
      printf 'ARI não concorda com .env; configure novamente antes de ativar.\n' >&2; exit 1;
    }
  case ",${COMPOSE_PROFILES}," in
    *,telefonia,*) : ;;
    ,,) set_env_var "$ENV_FILE" COMPOSE_PROFILES telefonia ;;
    *) set_env_var "$ENV_FILE" COMPOSE_PROFILES "${COMPOSE_PROFILES},telefonia" ;;
  esac
  printf 'Profile telefonia habilitado no .env; nenhum contêiner foi iniciado.\n'
  printf 'Abra UDP 5060 e 10000-10200 na VCN/firewall e suba asterisk e voice-agent conforme o runbook.\n'
  exit 0
fi

if [ -e "$PJSIP_FILE" ] || [ -e "$ARI_FILE" ]; then
  read -r -p 'Já há configuração SIP/ARI. Digite SUBSTITUIR para trocar (Enter cancela): ' confirmacao
  if [ "$confirmacao" != SUBSTITUIR ]; then
    printf 'Cancelado; arquivos e .env preservados.\n'
    exit 1
  fi
fi

validar_ipv4_publico() {
  local ip="$1" a b c d parte
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r a b c d <<< "$ip"
  for parte in "$a" "$b" "$c" "$d"; do
    [ "$parte" -le 255 ] && { [ "${#parte}" -eq 1 ] || [ "${parte:0:1}" != 0 ]; } || return 1
  done
  case "$a" in 0|10|127|224|225|226|227|228|229|23[0-9]|24[0-9]|25[0-9]) return 1 ;; esac
  if [ "$a" = 169 ] && [ "$b" = 254 ]; then return 1; fi
  if [ "$a" = 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; then return 1; fi
  if [ "$a" = 192 ] && [ "$b" = 168 ]; then return 1; fi
  return 0
}

validar_host_sip() {
  local host="$1" label
  [ "${#host}" -le 253 ] && [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  [[ "$host" != *..* ]] || return 1
  local -a labels
  IFS=. read -r -a labels <<< "$host"
  for label in "${labels[@]}"; do
    [ "${#label}" -le 63 ] && [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

validar_usuario_sip() { [[ "$1" =~ ^[A-Za-z0-9._+-]{1,128}$ ]]; }
validar_senha_sip() {
  local senha="$1"
  [[ "$senha" =~ ^[[:graph:]]{8,128}$ ]] || return 1
  case "$senha" in *';'*|*'#'*|*'\'*) return 1 ;; esac
}

read -r -p 'IPv4 público da VPS: ' ip_publico
validar_ipv4_publico "$ip_publico" || { printf 'IPv4 público inválido.\n' >&2; exit 1; }
read -r -p 'Host do provedor SIP (sem porta/protocolo): ' host_sip
validar_host_sip "$host_sip" || { printf 'Host SIP inválido.\n' >&2; exit 1; }
read -r -p 'Usuário do trunk SIP: ' usuario_sip
validar_usuario_sip "$usuario_sip" || { printf 'Usuário SIP inválido.\n' >&2; exit 1; }
read -r -s -p 'Senha do trunk SIP (não será exibida): ' senha_sip
printf '\n'
validar_senha_sip "$senha_sip" || { printf 'Senha SIP inválida: use 8–128 caracteres visíveis, sem ;, # ou barra invertida.\n' >&2; exit 1; }

# Lê as credenciais ARI existentes como dados, sem imprimir. Faltantes são
# geradas; nunca deixa ari.conf e voice-agent com identidades diferentes.
ARI_USERNAME=''; ARI_PASSWORD=''
kit_path="$PATH"
load_env "$ENV_FILE"
PATH="$kit_path"
ari_usuario="${ARI_USERNAME:-voice-agent-user}"
ari_senha="${ARI_PASSWORD:-$(openssl rand -hex 32)}"
[[ "$ari_usuario" =~ ^[A-Za-z0-9_-]{1,64}$ ]] && validar_senha_sip "$ari_senha" || {
  printf 'Credencial ARI existente inválida; corrija pelo kit antes de ativar a telefonia.\n' >&2
  exit 1
}

stage="$(mktemp -d "$ROOT_DIR/.telefonia-config.XXXXXX")"
COMMITTING=0; COMMITTED=0
cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  set +e
  if [ "$COMMITTING" = 1 ] && [ "$COMMITTED" != 1 ]; then
    if [ -f "$stage/old-pjsip" ]; then cp -p "$stage/old-pjsip" "$PJSIP_FILE"; else rm -f "$PJSIP_FILE"; fi
    if [ -f "$stage/old-ari" ]; then cp -p "$stage/old-ari" "$ARI_FILE"; else rm -f "$ARI_FILE"; fi
    cp -p "$stage/old-env" "$ENV_FILE"
    printf 'Configuração interrompida; arquivos anteriores restaurados.\n' >&2
  fi
  rm -f "$stage/new-pjsip" "$stage/new-ari" "$stage/new-env" "$stage/old-pjsip" "$stage/old-ari" "$stage/old-env" "$stage/commit-started" "$stage/committed" "$stage"/new-env.tmp.*
  rmdir "$stage" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

[ ! -f "$PJSIP_FILE" ] || cp -p "$PJSIP_FILE" "$stage/old-pjsip"
[ ! -f "$ARI_FILE" ] || cp -p "$ARI_FILE" "$stage/old-ari"
cp -p "$ENV_FILE" "$stage/old-env"
cp -p "$ENV_FILE" "$stage/new-env"
set_env_var "$stage/new-env" ARI_USERNAME "$ari_usuario"
set_env_var "$stage/new-env" ARI_PASSWORD "$ari_senha"

cat > "$stage/new-pjsip" <<EOF
; Gerado por configurar-telefonia.sh. Trunk SIP genérico; profile desligado.
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
external_media_address=${ip_publico}
external_signaling_address=${ip_publico}
local_net=172.16.0.0/12

[trunk-auth]
type=auth
auth_type=userpass
username=${usuario_sip}
password=${senha_sip}

[trunk-aor]
type=aor
contact=sip:${host_sip}:5060
qualify_frequency=30

[trunk-identify]
type=identify
endpoint=trunk-endpoint
match=${host_sip}

[trunk-registration]
type=registration
outbound_auth=trunk-auth
server_uri=sip:${host_sip}
client_uri=sip:${usuario_sip}@${host_sip}
retry_interval=60

[trunk-endpoint]
type=endpoint
transport=transport-udp
context=from-trunk
disallow=all
allow=ulaw
allow=alaw
outbound_auth=trunk-auth
aors=trunk-aor
from_user=${usuario_sip}
from_domain=${ip_publico}
EOF
cat > "$stage/new-ari" <<EOF
; Gerado por configurar-telefonia.sh. ARI apenas na rede interna do Compose.
[general]
enabled = yes
pretty = yes

[${ari_usuario}]
type = user
read_only = no
password = ${ari_senha}
EOF
chmod 600 "$stage/new-pjsip" "$stage/new-ari" "$stage/new-env"

# Os três renames são atômicos individualmente; EXIT/INT/TERM/HUP restauram o
# conjunto caso qualquer passo falhe. Não liga o profile nem reinicia serviços.
COMMITTING=1
: > "$stage/commit-started"
mv "$stage/new-pjsip" "$PJSIP_FILE"
mv "$stage/new-ari" "$ARI_FILE"
mv "$stage/new-env" "$ENV_FILE"
: > "$stage/committed"
COMMITTED=1
printf 'Arquivos SIP e ARI preparados (permissão 600). A telefonia continua desligada.\n'
printf 'Provedores com PJSIP não padrão exigem configuração avançada; teste registro e mídia antes de atender clientes.\n'
