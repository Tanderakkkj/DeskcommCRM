/**
 * A lista de colunas de `ai_agent_versions` está copiada em 7 arquivos (as rotas
 * REST, a server action e a página do agente). Adicionar uma coluna nova em
 * apenas alguns deles não quebra typecheck nem teste nenhum — o sintoma aparece
 * só na tela, como um campo que "se desmarca sozinho" depois do refresh, e o
 * save seguinte grava o valor errado por cima.
 *
 * Foi exatamente o que aconteceu com `cases_enabled` (spec 15, Wave 5): entrou
 * em 2 dos 7 arquivos. Este teste trava a divergência de qualquer coluna futura,
 * não só dessa — enquanto as cópias existirem, elas têm que ser idênticas.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { versionCreateSchema } from "@/lib/ai/agents/validation";

const ROOT = process.cwd();

/** Todo arquivo que carrega uma cópia da lista de colunas de versão. */
const FILES_WITH_VERSION_COLUMNS = [
  "app/app/ai/agents/[id]/_actions.ts",
  "app/app/ai/agents/[id]/page.tsx",
  "app/api/v1/ai/agents/route.ts",
  "app/api/v1/ai/agents/[id]/versions/route.ts",
  "app/api/v1/ai/agents/[id]/versions/[vid]/route.ts",
  // A cópia da rota /duplicate mudou de casa: a implementação agora é
  // compartilhada com o botão "Duplicar" da lista, em lib/ai/agents/duplicate.ts.
  // O arquivo vigiado é onde a lista mora, não onde ela morava.
  "lib/ai/agents/duplicate.ts",
];

/** Extrai o conteúdo da string atribuída a VERSION_COLUMNS. */
function versionColumnsOf(relPath: string): string[] {
  const source = readFileSync(join(ROOT, relPath), "utf8");
  const match = /VERSION_COLUMNS\s*(?::\s*string)?\s*=\s*\n?\s*"([^"]+)"/.exec(source);
  if (match === null) {
    throw new Error(`VERSION_COLUMNS não encontrado em ${relPath}`);
  }
  return (match[1] ?? "").split(",").map((c) => c.trim()).filter((c) => c.length > 0);
}

describe("VERSION_COLUMNS de ai_agent_versions", () => {
  it("é idêntico em todos os arquivos que o copiam", () => {
    const [firstFile, ...restFiles] = FILES_WITH_VERSION_COLUMNS;
    if (firstFile === undefined) throw new Error("lista de arquivos vazia");
    const expected = versionColumnsOf(firstFile);
    expect(expected.length).toBeGreaterThan(10);

    for (const file of restFiles) {
      const columns = versionColumnsOf(file);
      // Compara como conjunto ordenado: ordem no SELECT não importa, presença sim.
      expect({ file, columns: [...columns].sort() }).toEqual({
        file,
        columns: [...expected].sort(),
      });
    }
  });

  it("inclui as flags por-agente que a tela edita", () => {
    // Regressão direta do bug do cases_enabled: uma flag que a tela grava mas o
    // SELECT não devolve volta como `false` no próximo render.
    for (const file of FILES_WITH_VERSION_COLUMNS) {
      const columns = versionColumnsOf(file);
      expect(columns).toContain("handoff_tool_enabled");
      expect(columns).toContain("cases_enabled");
      expect(columns).toContain("split_messages");
      expect(columns).toContain("split_max_chars");
    }
  });
});

/**
 * O SELECT idêntico não basta: o payload do form passa por `versionCreateSchema`,
 * que é `.strict()`. Coluna ausente do schema faz o parse REJEITAR o save inteiro
 * (ou, se fosse não-strict, silenciosamente descartar o campo). Foi o segundo elo
 * quebrado do split de mensagens: a coluna existia no banco e no runtime, mas o
 * schema não a conhecia, então a tela nunca conseguiria gravá-la.
 */
describe("versionCreateSchema aceita as flags por-agente que a tela edita", () => {
  const base = {
    system_prompt: "Você é um atendente de testes.",
    provider: "anthropic" as const,
    model: "claude-sonnet-4-6",
    credential_id: "11111111-1111-4111-8111-111111111111",
    channel_session_id: "22222222-2222-4222-8222-222222222222",
  };

  it("preserva split_messages/split_max_chars no parse", () => {
    const parsed = versionCreateSchema.safeParse({
      ...base,
      split_messages: true,
      split_max_chars: 240,
    });
    expect(parsed.success).toBe(true);
    expect(parsed.success && parsed.data.split_messages).toBe(true);
    expect(parsed.success && parsed.data.split_max_chars).toBe(240);
  });

  it("cai nos defaults da migration 0059 quando omitido", () => {
    const parsed = versionCreateSchema.safeParse(base);
    expect(parsed.success && parsed.data.split_messages).toBe(false);
    expect(parsed.success && parsed.data.split_max_chars).toBe(600);
  });

  it("aceita callback_enabled como opção independente dentro de followup", () => {
    const parsed = versionCreateSchema.safeParse({
      ...base,
      followup: {
        enabled: true,
        flow_pointer_ids: ["33333333-3333-4333-8333-333333333333"],
        callback_enabled: false,
      },
    });

    expect(parsed.success).toBe(true);
    expect(parsed.success && parsed.data.followup).toMatchObject({
      enabled: true,
      flow_pointer_ids: ["33333333-3333-4333-8333-333333333333"],
      callback_enabled: false,
    });
  });
});

/**
 * O SELECT e o schema iguais ainda não bastam: cada caminho que grava uma versão
 * monta o INSERT campo a campo. `inbound_debounce_ms` (#1856) entrou só no PATCH
 * de rascunho e ficou fora de três INSERTs; `followup` e `proposal_ai_draft_enabled`
 * também já se perderam pela mesma fenda (#2004). Este bloco lê cada
 * `.insert({ ... })` encadeado em `.from("ai_agent_versions")` de TODOS os caminhos
 * que gravam versão e cobra TODAS as chaves de `versionShapeSchema` — a lista vem
 * do próprio schema (tipada), então uma coluna nova no schema passa a ser cobrada
 * aqui sem editar este arquivo.
 */
function insertsDeVersao(source: string): string[] {
  const blocos: string[] = [];
  const re = /\.from\("ai_agent_versions"\)\s*\.insert\(\{/g;
  for (let m = re.exec(source); m !== null; m = re.exec(source)) {
    let i = m.index + m[0].length;
    let nivel = 1;
    for (; i < source.length && nivel > 0; i++) {
      if (source[i] === "{") nivel++;
      else if (source[i] === "}") nivel--;
    }
    blocos.push(source.slice(m.index, i));
  }
  return blocos;
}

/** Chaves de conteúdo de `versionShapeSchema` (as que a versão LEVA ao gravar). */
function chavesDeConteudoDaVersao(): string[] {
  return Object.keys(versionCreateSchema.shape);
}

/** Extrai os nomes de chave (`chave:` no início de linha, indentado) de um trecho.
 *  Casar por nome de chave (e não por substring) evita que um comentário que cite
 *  a palavra confunda a cerca. */
function chavesNomeadas(bloco: string): string[] {
  const nomes: string[] = [];
  const re = /^\s+([a-z_][a-z0-9_]*):/gm;
  for (let m = re.exec(bloco); m !== null; m = re.exec(bloco)) {
    const nome = m[1];
    if (nome !== undefined && !nomes.includes(nome)) nomes.push(nome);
  }
  return nomes;
}

/** Todo caminho que chama `.from("ai_agent_versions").insert(` precisa levar
 *  todas as chaves de versão. O duplicate espalha `versionPayloadFrom` (helper
 *  próprio) — aí a chave mora no corpo do helper, não no `insert`; o corpo do
 *  helper é o alvo. */
const FILES_WITH_VERSION_INSERTS = [
  "app/app/ai/agents/[id]/_actions.ts",
  "app/api/v1/ai/agents/[id]/versions/route.ts",
  "lib/ai/agents/duplicate.ts",
];

/** Corpo do `versionPayloadFrom` (os campos que a versão duplicada leva). */
function corpoDeVersionPayloadFrom(source: string): string {
  const ini = source.indexOf("function versionPayloadFrom");
  if (ini === -1) return "";
  const chove = source.indexOf("return {", ini);
  if (chove === -1) return "";
  let nivel = 1;
  let i = chove + "return {".length;
  while (nivel > 0 && i < source.length) {
    if (source[i] === "{") nivel++;
    else if (source[i] === "}") nivel--;
    i++;
  }
  return source.slice(chove, i);
}

describe("todo INSERT de versão leva todas as chaves de versionShapeSchema", () => {
  it("o extrator acusa um INSERT sem uma chave do schema (controle positivo)", () => {
    const sem = `admin.from("ai_agent_versions").insert({ split_max_chars: 1, followup: { a: 1 } })`;
    const blocos = insertsDeVersao(sem);
    expect(blocos).toHaveLength(1);
    // split_max_chars presente no objeto, mas system_prompt falta — e um comentário
    // de fora citando a palavra não conta como chave.
    expect(blocos[0]).toContain("split_max_chars");
    const faltando = chavesDeConteudoDaVersao().filter(
      (c) => !chavesNomeadas(blocos[0] ?? "").includes(c),
    );
    expect(faltando.some((c) => c === "system_prompt")).toBe(true);
  });

  it("todos os caminhos que gravam versão levam todas as chaves", () => {
    for (const file of FILES_WITH_VERSION_INSERTS) {
      const source = readFileSync(join(ROOT, file), "utf8");
      const blocos = insertsDeVersao(source);
      // duplicate espalha versionPayloadFrom: o texto do insert não lista as chaves;
      // o corpo do helper versionPayloadFrom é o ponto em que elas aparecem.
      const alvos = file.includes("duplicate.ts")
        ? [corpoDeVersionPayloadFrom(source)]
        : blocos;
      expect(alvos.length).toBeGreaterThan(0);
      for (const alvo of alvos) {
        const nomes = chavesNomeadas(alvo);
        const faltando = chavesDeConteudoDaVersao().filter((c) => !nomes.includes(c));
        expect({ file, faltando }).toEqual({ file, faltando: [] });
      }
    }
  });
});
