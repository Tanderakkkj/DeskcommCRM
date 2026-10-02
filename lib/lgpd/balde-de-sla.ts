/**
 * O BALDE DE SLA da linha de solicitações — "Vencido", "Crítico", "Alerta", "OK".
 *
 * Vive aqui, e não dentro do route handler, por um motivo que é o mesmo do resto
 * deste módulo: `due_at` guarda um DIA CIVIL (ver `sla.ts`), e um dia civil não é
 * um instante. Quem decide o balde precisa de aritmética de dia, e aritmética de
 * dia testada é uma função pura — não um parágrafo dentro de um `GET`.
 *
 * ## O defeito que este arquivo conserta
 *
 * A versão anterior comparava milissegundos:
 *
 * ```ts
 * const msUntilDue = new Date(dueAt).getTime() - Date.now();
 * if (msUntilDue < 0) return "overdue";
 * if (msUntilDue < 2 * 24 * 60 * 60 * 1000) return "critical";
 * ```
 *
 * Medido em São Paulo (UTC−3), com prazo no dia **05/10** — que é como o prazo
 * aparece gravado, `2026-10-05T00:00:00.000Z`:
 *
 * | quando (hora de São Paulo) | o balde dizia | o que é verdade |
 * |---|---|---|
 * | 04/10 21:30 | **Vencido** | faltam 26h30 |
 * | 05/10 09:00 | **Crítico** | vence hoje |
 * | 05/10 20:30 | **Vencido** | vence hoje, faltam 2h |
 *
 * A virada é às 21h00 de 04/10, que é a meia-noite UTC do dia 05: um instante
 * depois do limite antigo, o prazo inteiro do dia 05 vira "Vencido". Três
 * linhas, uma causa: o prazo vai até o FIM do dia 05, e a comparação tratava a
 * meia-noite UTC do dia 05 como o fim dele. A etiqueta que o operador lê para
 * priorizar trabalho de compliance estava errada nas 26 horas em que mais importa
 * decidir.
 *
 * ## A régua agora
 *
 * `diasAtePrazo` vale `0` no dia do prazo, `1` no dia anterior, negativo quando
 * passou — então:
 *
 * - `overdue`: passou ao menos um dia civil inteiro;
 * - `critical`: 0 ou 1 dia restante, o que é o "menos de dois dias" de antes;
 * - `warning`: metade da janela já consumida. Esta continua em milissegundos de
 *   propósito — é uma RAZÃO entre duas pontas (recebido → prazo), não uma contagem
 *   de dias, e as duas pontas estão no mesmo eixo.
 *
 * `dueAt` ausente é "ok": quem não tem prazo não está vencendo nada.
 */

import { diasAtePrazo, diasDeAtraso } from "./sla";

export type SlaBucket = "overdue" | "critical" | "warning" | "ok";

/** `dias < 2` — o "menos de dois dias" do balde `critical`. */
const JANELA_CRITICA_EM_DIAS = 2;

export function computeSlaBucket(
  dueAt: string | null,
  receivedAt: string,
  agora: Date = new Date(),
): SlaBucket {
  if (!dueAt) return "ok";
  if (diasDeAtraso(dueAt, agora) > 0) return "overdue";
  if (diasAtePrazo(dueAt, agora) < JANELA_CRITICA_EM_DIAS) return "critical";

  const totalWindow = new Date(dueAt).getTime() - new Date(receivedAt).getTime();
  const ateFimDaJanela = new Date(dueAt).getTime() - agora.getTime();
  if (totalWindow > 0 && ateFimDaJanela < totalWindow * 0.5) return "warning";
  return "ok";
}
