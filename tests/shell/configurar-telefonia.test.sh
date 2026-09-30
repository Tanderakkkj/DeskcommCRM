#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$ROOT/hostgator-setup-kit/configurar-telefonia.sh"
test -f "$CLI" || { echo '✗ falta CLI configurar-telefonia.sh'; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

novo_projeto() {
  local path="$1"
  mkdir -p "$path/hostgator-setup-kit" "$path/asterisk"
  cp "$CLI" "$ROOT/hostgator-setup-kit/_common.sh" \
    "$ROOT/hostgator-setup-kit/_manifestos.sh" \
    "$ROOT/hostgator-setup-kit/_i18n.sh" "$path/hostgator-setup-kit/"
  printf 'services: {}\n' > "$path/docker-compose.prod.yml"
  printf 'COMPOSE_PROFILES=\nARI_USERNAME=voice-agent-user\nARI_PASSWORD=senha-ari-existente\n' > "$path/.env"
  chmod 600 "$path/.env"
}
rodar() { local path="$1" input="$2"; printf '%s' "$input" | bash "$path/hostgator-setup-kit/configurar-telefonia.sh" >"$path/out" 2>&1; }

novo_projeto "$TMP/novo"
rodar "$TMP/novo" $'1.2.3.4\nsip.example.com\nalice\nsenha-sip-segura\n' || { echo "✗ primeiro setup: $(<"$TMP/novo/out")"; exit 1; }
test -f "$TMP/novo/asterisk/pjsip.conf" && test -f "$TMP/novo/asterisk/ari.conf"
test "$(stat -c %a "$TMP/novo/asterisk/pjsip.conf")" = 600
test "$(stat -c %a "$TMP/novo/asterisk/ari.conf")" = 600
grep -q '^external_media_address=1.2.3.4$' "$TMP/novo/asterisk/pjsip.conf"
grep -q '^contact=sip:sip.example.com:5060$' "$TMP/novo/asterisk/pjsip.conf"
grep -q '^username=alice$' "$TMP/novo/asterisk/pjsip.conf"
grep -q '^password=senha-sip-segura$' "$TMP/novo/asterisk/pjsip.conf"
grep -q '^\[voice-agent-user\]$' "$TMP/novo/asterisk/ari.conf"
grep -q '^password = senha-ari-existente$' "$TMP/novo/asterisk/ari.conf"
grep -q '^COMPOSE_PROFILES=$' "$TMP/novo/.env"
! grep -q 'senha-sip-segura\|senha-ari-existente' "$TMP/novo/out"
echo '✓ primeiro setup privado, ARI concorda com .env e profile continua desligado'

for scenario in ip host user userrealm secret; do
  novo_projeto "$TMP/$scenario"
done
if rodar "$TMP/ip" $'1.2.3.999\nsip.example.com\nalice\nsenha-sip-segura\n'; then echo '✗ IP inválido aceito'; exit 1; fi
if rodar "$TMP/host" $'1.2.3.4\nsip.example.com;evil\nalice\nsenha-sip-segura\n'; then echo '✗ host injetado aceito'; exit 1; fi
if rodar "$TMP/user" $'1.2.3.4\nsip.example.com\nalice;evil\nsenha-sip-segura\n'; then echo '✗ usuário injetado aceito'; exit 1; fi
if rodar "$TMP/userrealm" $'1.2.3.4\nsip.example.com\nalice@realm\nsenha-sip-segura\n'; then echo '✗ usuário com @ não cabe no client_uri genérico'; exit 1; fi
if rodar "$TMP/secret" $'1.2.3.4\nsip.example.com\nalice\nsenha;injetada\n'; then echo '✗ segredo injetado aceito'; exit 1; fi
for scenario in ip host user userrealm secret; do
  test ! -e "$TMP/$scenario/asterisk/pjsip.conf"
  test ! -e "$TMP/$scenario/asterisk/ari.conf"
done
echo '✓ entradas inválidas não deixam arquivo parcial'

cp "$TMP/novo/asterisk/pjsip.conf" "$TMP/pjsip-antes"
cp "$TMP/novo/asterisk/ari.conf" "$TMP/ari-antes"
cp "$TMP/novo/.env" "$TMP/env-antes"
if rodar "$TMP/novo" $'n\n'; then echo '✗ reexecução sem confirmação aceita'; exit 1; fi
cmp -s "$TMP/novo/asterisk/pjsip.conf" "$TMP/pjsip-antes"
cmp -s "$TMP/novo/asterisk/ari.conf" "$TMP/ari-antes"
cmp -s "$TMP/novo/.env" "$TMP/env-antes"
echo '✓ arquivos existentes não são sobrescritos sem confirmação'

# Uma falha de rename no meio do commit deve restaurar os três arquivos.
mkdir -p "$TMP/failbin"
cat > "$TMP/failbin/mv" <<'STUB'
#!/usr/bin/env bash
case "${*: -1}" in
  */asterisk/ari.conf)
    if [ ! -f "$FALHA_MV_MARK" ]; then : > "$FALHA_MV_MARK"; exit 73; fi ;;
esac
exec /usr/bin/mv "$@"
STUB
chmod +x "$TMP/failbin/mv"
if printf '%s' $'SUBSTITUIR\n2.3.4.5\nsip2.example.com\nbob\nsenha-sip-nova\n' \
  | FALHA_MV_MARK="$TMP/mv-falhou" PATH="$TMP/failbin:$PATH" \
    bash "$TMP/novo/hostgator-setup-kit/configurar-telefonia.sh" >"$TMP/novo/out" 2>&1; then
  echo '✗ commit interrompido aceito'; exit 1
fi
cmp -s "$TMP/novo/asterisk/pjsip.conf" "$TMP/pjsip-antes" || { echo '✗ PJSIP não foi restaurado'; exit 1; }
cmp -s "$TMP/novo/asterisk/ari.conf" "$TMP/ari-antes" || { echo '✗ ARI não foi restaurado'; exit 1; }
cmp -s "$TMP/novo/.env" "$TMP/env-antes" || { echo '✗ .env não foi restaurado'; exit 1; }
! grep -q 'senha-sip-nova' "$TMP/novo/out"
echo '✓ falha durante escrita restaura o estado anterior sem vazar segredo'

# SIGKILL/pane elétrica não executa trap. A rodada seguinte precisa reconhecer
# a transação abandonada e restaurar automaticamente antes de perguntar algo.
mkdir -p "$TMP/killbin"
cat > "$TMP/killbin/mv" <<'STUB'
#!/usr/bin/env bash
case "${*: -1}" in
  */asterisk/ari.conf) kill -KILL "$PPID"; exit 137 ;;
esac
exec /usr/bin/mv "$@"
STUB
chmod +x "$TMP/killbin/mv"
if printf '%s' $'SUBSTITUIR\n2.3.4.5\nsip2.example.com\nbob\nsenha-sip-nova\n' \
  | PATH="$TMP/killbin:$PATH" bash "$TMP/novo/hostgator-setup-kit/configurar-telefonia.sh" \
    >"$TMP/novo/out" 2>&1; then
  echo '✗ SIGKILL no meio aceito'; exit 1
fi
if rodar "$TMP/novo" $'n\n'; then echo '✗ reexecução confirmou sozinha'; exit 1; fi
cmp -s "$TMP/novo/asterisk/pjsip.conf" "$TMP/pjsip-antes" || { echo '✗ SIGKILL deixou PJSIP parcial'; exit 1; }
cmp -s "$TMP/novo/asterisk/ari.conf" "$TMP/ari-antes" || { echo '✗ SIGKILL deixou ARI parcial'; exit 1; }
cmp -s "$TMP/novo/.env" "$TMP/env-antes" || { echo '✗ SIGKILL deixou .env parcial'; exit 1; }
stages=("$TMP/novo"/.telefonia-config.*)
test ! -e "${stages[0]}" || { echo '✗ stage da interrupção permaneceu'; exit 1; }
echo '✓ reexecução recupera interrupção abrupta antes de novo consentimento'

rodar "$TMP/novo" $'SUBSTITUIR\n2.3.4.5\nsip2.example.com\nbob\nsenha-sip-nova\n'
grep -q '^username=bob$' "$TMP/novo/asterisk/pjsip.conf"
grep -q '^COMPOSE_PROFILES=$' "$TMP/novo/.env"
echo '✓ substituição explícita atualiza configurações sem ativar telefonia'

if bash "$TMP/ip/hostgator-setup-kit/configurar-telefonia.sh" --ativar >"$TMP/ip/out" 2>&1; then
  echo '✗ ativação sem configs foi aceita'; exit 1
fi
bash "$TMP/novo/hostgator-setup-kit/configurar-telefonia.sh" --ativar >"$TMP/novo/out" 2>&1
grep -q '^COMPOSE_PROFILES=telefonia$' "$TMP/novo/.env"
bash "$TMP/novo/hostgator-setup-kit/configurar-telefonia.sh" --ativar >"$TMP/novo/out" 2>&1
test "$(grep -c '^COMPOSE_PROFILES=telefonia$' "$TMP/novo/.env")" = 1
! grep -q 'senha-sip-nova\|senha-ari-existente' "$TMP/novo/out"
sed -i 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=voz/' "$TMP/novo/.env"
bash "$TMP/novo/hostgator-setup-kit/configurar-telefonia.sh" --ativar >"$TMP/novo/out" 2>&1
grep -q '^COMPOSE_PROFILES=voz,telefonia$' "$TMP/novo/.env"
echo '✓ ativação é uma escolha separada, persistente e idempotente'
