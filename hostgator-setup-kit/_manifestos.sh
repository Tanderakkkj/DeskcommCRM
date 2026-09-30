#!/usr/bin/env bash
# Consultas OCI somente-leitura. Pode ser sourced sem iniciar Docker ou rede.

plataforma_oci_do_host() { # <uname -m> -> linux/amd64 | linux/arm64
  case "${1:-}" in
    x86_64|amd64) printf '%s\n' linux/amd64 ;;
    aarch64|arm64) printf '%s\n' linux/arm64 ;;
    *) printf 'Arquitetura não suportada: %s\n' "${1:-desconhecida}" >&2; return 1 ;;
  esac
}

manifesto_tem_plataforma() { # <ref> <linux/platform>
  local ref="${1:-}" plataforma="${2:-}" os arch bruto config
  case "$plataforma" in
    linux/amd64|linux/arm64) ;;
    *) printf 'Plataforma OCI inválida: %s\n' "$plataforma" >&2; return 1 ;;
  esac
  [ -n "$ref" ] || { printf 'Referência de imagem vazia\n' >&2; return 1; }
  os="${plataforma%%/*}"; arch="${plataforma#*/}"
  if ! bruto="$(docker buildx imagetools inspect --raw "$ref" 2>/dev/null)"; then
    printf 'Registro inacessível ou acesso negado para %s\n' "$ref" >&2
    return 1
  fi
  if [ -z "$bruto" ] || ! jq -e 'type == "object" and (.schemaVersion == 2) and ((.manifests | type) == "array" or (.config | type) == "object")' >/dev/null 2>&1 <<<"$bruto"; then
    printf 'Manifesto OCI inválido ou vazio para %s\n' "$ref" >&2
    return 1
  fi
  if jq -e '(.manifests | type) == "array"' >/dev/null 2>&1 <<<"$bruto"; then
    if jq -e --arg os "$os" --arg arch "$arch" \
      'any(.manifests[]; .platform.os == $os and .platform.architecture == $arch)' \
      >/dev/null 2>&1 <<<"$bruto"; then return 0; fi
  else
    # Um manifesto de imagem simples não declara plataforma; ela está no config.
    # Buildx resolve o config remoto e expõe os campos .Image.os/.architecture.
    if ! config="$(docker buildx imagetools inspect --format '{{json .Image}}' "$ref" 2>/dev/null)"; then
      printf 'Registro inacessível ao consultar config OCI de %s\n' "$ref" >&2
      return 1
    fi
    if jq -e --arg os "$os" --arg arch "$arch" \
      '.os == $os and .architecture == $arch' >/dev/null 2>&1 <<<"$config"; then return 0; fi
  fi
  printf 'Imagem %s não oferece %s\n' "$ref" "$plataforma" >&2
  return 1
}

preflight_imagens_crm() { # <tag> <linux/platform>; IMG_NS e ghcr_status vêm de _common.sh
  local tag="${1:-}" plataforma="${2:-}" img status ref
  [ -n "$tag" ] || { printf 'Versão de imagem vazia\n' >&2; return 1; }
  for img in deskcommcrm deskcomm-worker deskcomm-scheduler deskcomm-voice-agent; do
    ref="${IMG_NS}/${img}:${tag}"
    status="$(ghcr_status "$img" "$tag")"
    case "$status" in
      200) ;;
      404) printf 'Tag inexistente: %s (404)\n' "$ref" >&2; return 1 ;;
      403) printf 'Pacote privado ou credencial necessária: %s (403)\n' "$ref" >&2; return 1 ;;
      *) printf 'Registro inacessível para %s (HTTP %s)\n' "$ref" "$status" >&2; return 1 ;;
    esac
    manifesto_tem_plataforma "$ref" "$plataforma" || return 1
  done
}
