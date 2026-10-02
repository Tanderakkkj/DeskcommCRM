/**
 * LGPD SLA business-day calculator.
 *
 * Rules (L-04):
 *  - SLA is expressed in Brazilian business days (dias úteis).
 *  - Skip Saturdays (getDay()===6) and Sundays (getDay()===0).
 *  - Skip Brazilian national holidays from HOLIDAYS_BR_ISO.
 *  - If receivedAt itself is not a business day, counting starts on the
 *    next business day (edge: weekend/holiday receipt).
 *
 * ═══ `due_at` É UM DIA CIVIL, E ESTE ARQUIVO É O QUE O DIZ ═══
 *
 * `computeDueAt` devolve a meia-noite UTC do dia útil contado. A coluna
 * `lgpd_requests.due_at` guarda, portanto, um DIA CIVIL do calendário do
 * país — e não um instante em que o prazo acaba. O prazo vai até o FIM
 * daquele dia.
 *
 * Isso não é um detalhe de implementação: é o contrato da coluna, e ele
 * precisa sobreviver a quem lê. Os dois últimos blocos deste arquivo existem
 * porque os consumidores de `due_at` redesenhavam o instante no fuso de QUEM
 * LÊ — e, para quem está a oeste de UTC, o prazo aparecia um dia antes,
 * inclusive no e-mail que vai para o DPO e no balde `overdue` da API.
 *
 * A lista viva desses consumidores, com o que já está corrigido e o que ainda
 * está congelado (e por quê), não mora aqui: mora no teste que a vigia,
 * `tests/unit/lgpd-prazo-e-dia-civil.test.ts`. Ele é o lugar onde uma afirmação
 * de estado não envelhece — porque um consumidor novo o deixa vermelho.
 *
 * Um único escritor de produto grava a coluna (`lib/lgpd/repository.ts`), o que
 * torna a convenção verificável em vez de presumida.
 */

import { HOLIDAYS_BR_ISO } from "./holidays-br";

const _defaultHolidays = new Set(HOLIDAYS_BR_ISO);

/**
 * Format a Date to YYYY-MM-DD (UTC-based, suitable for set lookup when
 * dates are constructed as UTC midnight + 1-day increments).
 */
function toISODateStr(date: Date): string {
  const y = date.getUTCFullYear();
  const m = String(date.getUTCMonth() + 1).padStart(2, "0");
  const d = String(date.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

/**
 * Returns true when the given Date (treated as a UTC midnight point) is
 * a business day — not Saturday, not Sunday, not in the holidays set.
 */
function isBusinessDay(date: Date, holidays: Set<string>): boolean {
  const dow = date.getUTCDay(); // 0=Sun, 6=Sat
  if (dow === 0 || dow === 6) return false;
  return !holidays.has(toISODateStr(date));
}

/**
 * Advance date by one calendar day (UTC).
 */
function addOneDay(date: Date): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate() + 1));
}

// ---------------------------------------------------------------------------
// LENDO O DIA QUE A COLUNA GUARDA
//
// Tudo abaixo é PURO, não toca banco e NÃO LANÇA — os consumidores daqui são a
// tela, a API e o e-mail do DPO, e um prazo que derruba a página de compliance
// por um valor torto seria pior que um prazo sem rótulo.
// ---------------------------------------------------------------------------

/** `Date` → `"YYYY-MM-DD"` no MESMO eixo em que `computeDueAt` conta. */
function diaCivilDe(instante: Date): string {
  return toISODateStr(instante);
}

/** `"YYYY-MM-DD"` → milissegundos UTC; `null` quando a data não é uma data. */
function utcDeDiaCivil(dia: string): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dia);
  if (!m) return null;
  const ano = Number(m[1]);
  const mes = Number(m[2]);
  const diaNum = Number(m[3]);
  // `Date.UTC` normaliza overflow em vez de recusar: "2026-13-45" voltaria como
  // janeiro de 2027, e um prazo lido torto viraria um prazo inventado. A volta
  // confere o que o `Date.UTC` guardou.
  const ms = Date.UTC(ano, mes - 1, diaNum);
  const guardado = new Date(ms);
  if (
    guardado.getUTCFullYear() !== ano ||
    guardado.getUTCMonth() !== mes - 1 ||
    guardado.getUTCDate() !== diaNum
  ) {
    return null;
  }
  return Number.isFinite(ms) ? ms : null;
}

/**
 * O DIA CIVIL que `due_at` representa — `"YYYY-MM-DD"`, ou `null` quando o
 * valor não é uma data.
 *
 * ⚠️ LEIA O PORQUÊ ANTES DE USAR `new Date(due_at)` EM QUALQUER LUGAR.
 *
 * `due_at` guarda a meia-noite UTC de um dia útil. Passar esse instante por um
 * formatador com fuso — `toLocaleString` com `timeZone`, `date-fns` `format`,
 * `differenceInDays` — redesenha o DIA no eixo de quem lê, e o dia civil guardado
 * deixa de ser o dia civil mostrado. Quem lê a oeste de UTC (Brasil, Colômbia,
 * Peru) vê o prazo UM DIA **antes**; a leste (Angola, Lisboa) a meia-noite UTC
 * ainda cai no mesmo dia, e o dia mostrado acerta por acaso. No Brasil, que é
 * onde o produto roda, o prazo aparece no dia anterior.
 *
 * A correção é não "ajustar o fuso", é ler o dia que a coluna guarda — que é o
 * dia que o motor contou.
 */
export function diaDoPrazo(dueAt: string | Date | null | undefined): string | null {
  if (dueAt === null || dueAt === undefined) return null;
  const instante = typeof dueAt === "string" ? Date.parse(dueAt) : dueAt.getTime();
  if (!Number.isFinite(instante)) return null;
  return diaCivilDe(new Date(instante));
}

/**
 * Dias INTEIROS de atraso, contados em DIAS CIVIS. `0` enquanto o dia do prazo
 * não passou — um prazo vence ao FIM do dia, então o dia do prazo não está
 * atrasado, está **hoje**.
 *
 * Subtrair milissegundos e arredondar (`Math.round((agora - due) / 86_400_000)`)
 * erra por dois motivos ao mesmo tempo: pega o dia errado (metade do dia já é o
 * dia seguinte, a oeste de UTC) e arredonda meio dia para cima. O resultado é o
 * alarme anunciando "1 dia(s) em atraso" às 09h do dia do prazo, com o e-mail ao
 * lado afirmando que o prazo vence "amanhã" — dois números que não podem estar
 * certos ao mesmo tempo.
 *
 * `0` para valor ausente ou ilegível: prazo que não se lê não pode virar atraso
 * no alarme de compliance.
 */
export function diasDeAtraso(dueAt: string | Date | null | undefined, agora: Date): number {
  const prazo = diaDoPrazo(dueAt);
  if (prazo === null) return 0;
  const alvo = utcDeDiaCivil(prazo);
  const hoje = utcDeDiaCivil(diaCivilDe(agora));
  if (alvo === null || hoje === null) return 0;
  const dias = Math.round((hoje - alvo) / 86_400_000);
  // `-0` sai quando os dois dias são o mesmo, e `Object.is(-0, 0)` é falso: um
  // consumidor que compara com `toBe(0)` veria vermelho sem motivo nenhum.
  return dias === 0 ? 0 : dias;
}

/**
 * Dias INTEIROS até o prazo: `0` = vence hoje, `1` = amanhã, negativo = passou.
 *
 * O espelho de {@link diasDeAtraso}, para quem precisa da outra ponta do
 * balde (`critical`, "vence em Nd"). Comparar dias civis em vez de milissegundos
 * é o que impede o balde de acender 26 horas antes do prazo.
 */
export function diasAtePrazo(dueAt: string | Date | null | undefined, agora: Date): number {
  const dias = diasDeAtraso(dueAt, agora);
  return dias === 0 ? 0 : -dias; // sem isto sai `-0` no dia do prazo
}

/**
 * O prazo no formato de quem lê — `"DD/MM/AAAA"`.
 *
 * Sai do DIA CIVIL, não do instante: `new Date(due_at).toLocaleString("pt-BR",
 * { timeZone: "America/Sao_Paulo" })` devolve `"04/10/2026, 21:00:00"` para um
 * prazo contado no dia 05/10 — o dia anterior, com uma hora que não significa
 * nada (o prazo vai até o fim do dia). A data sai do dia, e o rótulo fica
 * igual em pt-BR e em es, porque `dd/MM/yyyy` é o mesmo nos dois.
 */
export function prazoEmBr(dueAt: string | Date | null | undefined): string | null {
  const dia = diaDoPrazo(dueAt);
  if (dia === null) return null;
  const [ano, mes, diaDoMes] = dia.split("-");
  return `${diaDoMes}/${mes}/${ano}`;
}

/**
 * Compute the due date for an LGPD SLA.
 *
 * @param receivedAt   Timestamp when the request was received.
 * @param businessDays Number of business days allowed (e.g. 15 for redact).
 * @param holidays     Override holiday set; defaults to HOLIDAYS_BR_ISO.
 * @returns            A MEIA-NOITE UTC do N-ésimo dia útil — o DIA CIVIL que a
 *                     coluna `due_at` guarda, e NÃO o instante em que o prazo
 *                     acaba. Para formatar, comparar ou contar, use
 *                     {@link diaDoPrazo} / {@link diasDeAtraso}: redesenhar
 *                     este instante com fuso devolve o dia anterior para quem
 *                     lê a oeste de UTC.
 */
export function computeDueAt(
  receivedAt: Date,
  businessDays: number,
  holidays: Set<string> = _defaultHolidays,
): Date {
  // Normalise to UTC midnight of the received day
  let cursor = new Date(
    Date.UTC(receivedAt.getUTCFullYear(), receivedAt.getUTCMonth(), receivedAt.getUTCDate()),
  );

  // If receivedAt itself is not a business day, advance to the first business day
  if (!isBusinessDay(cursor, holidays)) {
    cursor = addOneDay(cursor);
    while (!isBusinessDay(cursor, holidays)) {
      cursor = addOneDay(cursor);
    }
  }

  // Count N business days starting from (and including) the first business day
  let remaining = businessDays;
  while (remaining > 0) {
    cursor = addOneDay(cursor);
    if (isBusinessDay(cursor, holidays)) {
      remaining--;
    }
  }

  return cursor;
}
