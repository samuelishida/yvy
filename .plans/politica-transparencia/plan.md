# /politica — Painel de Transparência e Resultados (rota oculta, dado curado)

> **Revisão 2026-10-07.** Plano atualizado após revisão adversarial. Ajustes: (a)
> dependência de `../eleicao-2026/` resolvida via vendor snapshot + `data.json`
> commitado; (b) três gates distintos (provenance, recálculo numérico, citação
> jurídica ao vivo) + Gate 4 de snapshot renderizado; (c) i18n `en` exigido no
> schema; (d) `/politica` com `noindex`; (e) manifesto de arquivos brutos para
> séries/geografia; (f) dados financeiros alinhados com corpus (`suspenso_2024`,
> nenhum arredondamento para cifras banidas).
>
> **Reversão 2026-10-07 (decisão do usuário).** (i) **A rota agora É pública**:
> a aba "Política" entra no `Navbar.js` (`to="/politica"` + chave `nav.politica`
> pt/en). A decisão original "sem link no Navbar" foi revertida pelo usuário. O
> `noindex` permanece (público ≠ indexado). (j) **Os jobs de CI foram revertidos**:
> `make politica` segue como a verificação canônica, mas **não** roda no GitHub
> Actions — o job `politica-check` falhou em ambiente limpo e o usuário optou por
> manter o `ci.yml` exatamente como estava antes. Os gates e o `Makefile` seguem
> intactos; `make politica-data` / `make politica-check` continuam válidos.

## Context

O usuário quer uma rota `/politica` no Yvy — **sem link no front end**, acessível apenas
por URL direta — que reúne, num painel gráfico e didático, os resultados dos últimos
governos brasileiros e uma comparação documentada dos casos jurídicos de Lula (PT) e
Flávio Bolsonaro (PL). Público-alvo: **eleitor indeciso**, com instrução formal limitada.
O requisito explícito é "o mais gráfico e didático possível, com fontes e links de tudo,
de modo que até uma pessoa semi-analfabeta consiga processar". Como o público-alvo
inclui **eleitores de extrema direita com baixo capital político-informativo**, a
interface deve ser **visivamente redundante**: todo conceito abstrato ("anulado",
"prescrito", "denúncia rejeitada") tem um **pictograma + cor + frase de uma linha**;
números financeiros são barras proporcionais **com rótulo do objeto** (Petrobras,
Odebrecht, conta de Queiroz) para evitar leitura errada de "quem roubou quanto";
toda fonte vira botão/link, não rodapé invisível.

Existem **três fontes de insumo**, de naturezas diferentes:

1. **Números de governo — já verificados.** O projeto `eleicao-2026` produziu
   `outputs/eleicao-2026-briefing.md` com **22 afirmações registradas** em
   `bench/claims.tsv`, validadas por dois gates (`sourced_claims_rate` = 22/22,
   `assertions_verified_rate` = 62/62, `broken_raw_pointers` = 0). O painel **reutiliza
   esse corpus** e os **JSON/CSV brutos** em `eleicao-2026/evidence/**/raw/`.
2. **Casos jurídicos — pesquisa concluída e materializada em `eleicao-2026/escandalos/`.**
   O subprojeto gerou 14 afirmações em `eleicao-2026/escandalos/claims.tsv`, 18 fontes
   em `sources.tsv`, 14 arquivos de evidência sob `evidence/{lula,flavio}/`, dois gates
   independentes (`sourced_claims_rate` 14/14, `citation_support_rate` 14/14) e uma
   seção §8 já inserida no `outputs/eleicao-2026-briefing.md`. O painel `/politica`
   **reaproveita esse corpus** em vez de re-pesquisar. Achado central e vinculante:
   **todas as condenações de Lula foram anuladas** (tríplex: Fachin 08/03/2021,
   arquivado por prescrição 28/01/2022; Atibaia: Gilmar 24/06/2021, reabertura negada
   pelo TRF-1 em 30/07/2025; Lula **nunca foi réu** no mensalão), e a denúncia contra
   Flávio **foi arquivada em 16/05/2022** pelo Órgão Especial do TJ-RJ **sem
   julgamento de mérito** (RIFs do Coaf e quebras de sigilo anulados em 2021).
3. **Contrato de build do Yvy** — o front é CRA servido pelo C server; não há backend.

**Resultado pretendido:** uma página estática, sem backend novo, que um indeciso abre no
celular e entende em 20 segundos; onde cada número grande tem uma fonte clicável; e onde
a seção de escândalos é **factualmente defensável** (datas, órgãos, status), não editorial.

> **Aviso de escopo.** Os gates do `eleicao-2026` cobrem as **22 afirmações numéricas** e
> as **14 afirmações jurídicas** já materializadas em `escandalos/`. O painel `/politica`
> acrescenta séries mensais e tabelas de UF que **não** passam por esses gates. A camada
> de verificação deste plano cobre **todo número renderizado**, não só os 22 herdados.

---

## Decisões arquiteturais

- **Decisão: página 100% estática; um único JSON em `frontend/public/politica/data.json`.**
  Rationale: os números estão congelados em 07/10/2026; um backend novo adicionaria
  superfície (rotas Lua, auth, rate-limit, teste) para zero benefício, e o C server só
  serve JSON corretamente se o arquivo **tiver extensão** (`yvy-server.c:252-262` serve
  `index.html` para qualquer path sem `.`). O precedente de dado curado no repo é
  constante JS (`ALERT_TYPES` em `Dashboard.js`), mas este conteúdo é grande e não deve
  inflar o bundle. Alternativas rejeitadas: (a) módulo JS grande no bundle; (b) consultar
  as APIs ao vivo (reintroduz rede num painel cujo recorte é uma data).

- **Decisão: cada número carrega `sources: [sourceId]` e cada `sourceId` resolve para um
  registro em `sources[]` com `url`, `publisher`, `date`, `kind`, `tier`.** Rationale: é
  o mecanismo `claims.tsv` + `sources.tsv` do `eleicao-2026` transportado para o JSON.

- **Decisão: a seção de escândalos é comparativa e neutra, com um bloco de status em 4
  campos fixos por caso (`alegacao`, `status hoje`, `impacto financeiro`, `provas`).**
  Rationale: o maior risco é apresentar uma condenação anulada como fato atual; um
  esquema fixo torna impossível "esquecer" o status.

- **Decisão: o status de um caso é um enum fechado e completo** —
  `condenado_anulado` · `denunciado_arquivado` · `absolvido` · `prescrito` ·
  `em_curso` · `nunca_reu` · `nao_confirmado`. O **status das provas/alegações** é um
  enum *separado* (`alegado_na_denuncia` · `usado_no_processo` · `anulado`), aplicado a
  cada item de `evidence[]` — não ao caso. Rationale: separar os dois evita o furo de
  usar um valor de prova como se fosse status do caso. Ambos vivem no schema e são
  validados pelo gate; **nunca** escritos à mão na prosa.

- **Decisão: o dossiê não faz `fetch`; os dados chegam por contexto do shell.** Rationale:
  `CardShell` pressupõe cinco estados assíncronos + chaves i18n de dashboard; um bloco
  estático não tem estado. Alternativa rejeitada: reusar `CardShell`.

- **Decisão: o visual do dossiê jurídico usa "cartões de status" com ícone, cor e frase
  fixa por enum** (`condenado_anulado` = escudo quebrado + vermelho + "condenação anulada";
  `prescrito` = relógio + laranja + "prescreveu pelo tempo";
  `denunciado_arquivado` = pasta fechada + cinza + "denúncia rejeitada sem julgar";
  `nunca_reu` = círculo riscado + verde + "nunca foi acusado formalmente").
  Rationale: o risco maior é o eleitor mal-informado ler "foi condenado" em um caso
  anulado. Cada card carrega a frase curta, a citação e o link — o botão "entenda em
  1 minuto" expande a defesa e o trecho da fonte, mas o status fica sempre visível.

- **Decisão: reusar os tokens de `index.css` e as primitivas de `Dashboard.css`, e
  **importar `Dashboard.css` explicitamente** em `Politica.js`.** Rationale: as primitivas
  (`.stat-grid`, `.bar-row`, `.bar-fill`) vivem no **chunk lazy do Dashboard** — verificado
  no build (`main.*.css` **não** contém `.stat-grid`; `/politica` não carrega o chunk do
  Dashboard). Sem o import explícito, elas renderizam **sem estilo**. Aceito o custo de
  duplicar ~17 KB no chunk de `/politica`. Não usar Tailwind (nenhuma página usa).

- **Decisão: sem link no `Navbar.js`, sem chave `nav.politica`.** Rationale: requisito
  explícito do usuário. O link só existe se for escrito; omitir é a implementação inteira.

- **Decisão (SHOULD-FIX aplicado): o gate é ligado ao CI** por um job `politica-check` no
  `ci.yml`. Rationale: um alvo `make` manual apodrece na primeira edição de número.

- **Decisão: os gates do `eleicao-2026/escandalos/` são reaproveitados como
  pré-requisito, não reimplementados.** O `citation_support_rate` de 14/14 já garante
  que cada citação aparece na fonte. Rationale: evita duplicar a lógica de fetch.
  O painel herda o resultado e o exibe no `ScopeFooter`.

---

## Assumptions e respostas do código

- **A rota `/politica` já é alcançável em produção.** O C server trata qualquer path
  **sem ponto** como SPA route: `yvy-server.c:252-262`
  (`if (strcmp(path, "/") == 0 || strchr(path, '.') == NULL) { ...index.html }`). Só
  falta o `<Route>`. Source: code @ `backend-lua/yvy-server.c:252-262`.
- **`public/` é copiado para `build/`** por `copyPublicFolder()` do CRA
  (`node_modules/react-scripts/scripts/build.js:219-224`); servido em dev e prod. O
  arquivo de dado **precisa** terminar em `.json`, senão a requisição devolve HTML.
- **Não há harness de teste JS.** Sem `test` script, `@testing-library`, `setupTests.js`
  ou `*.test.js`. Source: `frontend/package.json:18-22`.
- **O gate de front end é o build.** CI roda `npm ci && CI=true
  DISABLE_ESLINT_PLUGIN=true npm run build` (node 20); o ESLint é desligado no CI.
  Source: `.github/workflows/ci.yml:146-166`.
- **`react/no-unescaped-entities` e `react/prop-types` NÃO estão ativos.**
  `react-hooks/exhaustive-deps` é **warn**; `rules-of-hooks`, `no-undef`, `import/*`,
  `no-unused-expressions` são **error**. Source: `eslint-config-react-app/index.js`.
- **Warnings pré-existentes** em `GeoBreakdown.js:44`, `Home.js:485`, `Home.js:1889`.
- **i18n é um objeto aninhado `pt`/`en` espelhado**, com fallback pt. Source:
  `frontend/src/i18n.js:3-10`.
- **`utils/format.js` já exporta `formatDeltaPct`** (→ `"+7,5%"`), `formatInt`,
  `formatKm2`, `formatPct`, `formatDelta`. Source: `frontend/src/utils/format.js`.
- **Não existe `frontend/public/data/` nem import de JSON** no repo — este plano
  introduz o padrão. Source: Explore #2 §6.
- **`claims.tsv` tem 4 claims de desemprego** (`econ_desoc`, `econ_desoc_min`,
  `econ_desoc_pico`, `econ_desoc_dilma`) para **um** indicador — logo o crosswalk
  **não pode ser bijeção**. Source: verificado em `eleicao-2026/bench/claims.tsv`.
- **`eleicao-2026/escandalos/` já existe e está validado.** Não é preciso criar
  `Yvy/research/`: o plano consome `claims.tsv`, `sources.tsv` e `evidence/*.txt`
  diretamente. Source: `eleicao-2026/escandalos/claims.tsv` (14 linhas) e
  `verify_citations.py` (14/14 CONFIRMADO).
- **Dado do corpus `eleicao-2026` (07/10/2026):** 22 claims numéricas OK (gates verdes)
  e 14 claims jurídicas OK (`sourced_claims_rate` 14/14, `citation_support_rate` 14/14).
  Recorte pós-1º turno: PL 47,03% (Flávio, n.22) × PT 45,16% (Lula, n.13); 2022:
  PT 48,43% × PL 43,20%.
- **`claims_crosswalk.json` cobre 36 claims:** 22 numéricas + 14 jurídicas. Os 14
  jurídicos entram via `cases[]` (agrupados em 5 casos).
- **Decisão do orquestrador (usuário ausente):** o usuário não respondeu ao question
  gate. Adotei os defaults conservadores acima e os registro em Open questions.

---

## Riscos aceitos

- **Difamação por status desatualizado ou impreciso.** Risco #1. Mitigação: enum de
  status obrigatório (dois enums, caso × prova) + `nao_confirmado` bloqueia o build +
  banner de escopo acima da dobra com a data de coleta + link para o documento oficial +
  **cada status carrega a citação textual que o sustenta** (não basta a URL existir).
  Revisitar se qualquer caso mudar de status após out/2026.
- **Semi-analfabetismo funcional / desinformação de extrema direita mal atendida.**
  Mitigação: nenhum gráfico sem rótulo em texto; todo número grande tem uma frase
  "o que isso quer dizer"; status jurídico usa **pictograma + cor + frase de uma linha**;
  impacto financeiro usa barras com rótulo do objeto para impedir a leitura "quem roubou".
  Não substitui leitura assistida.
- **Duplicação de CSS (~17 KB) no chunk de `/politica`.** Aceita para ganhar nativo.
- **Fonte oficial indisponível ao vivo.** `stf.jus.br`/`tcu.gov.br` bloquearam o fetch.
  Mitigação: aceitar imprensa de referência **rotulada** (`kind: "press"`, `tier: 2`),
  com regra de duas fontes independentes para qualquer status juridicamente carregador.
- **"Impacto financeiro" pode ser lido como atribuição a uma pessoa.** Mitigação: cada
  valor declara `measuredBy`, `object` e `status` (`reconhecido`/`estimado`/`suspenso_2024`).
  Nunca somar objetos diferentes.
- **Sem rollback/observabilidade.** Rollback = remover a `<Route>` e o JSON (a página não
  tem outros consumidores). Observabilidade = nenhuma (é estática). Aceito e declarado.

---

## Increment DAG

- **Inc 1 — Esquema + JSON curado + três gates (M)** — depends on: none — unblocks: 2, 3, 4, 5, 6, 7, 8
- **Inc 2 — Consumir e compilar o corpus jurídico (M)** — depends on: 1 — unblocks: 5
- **Inc 3 — Tokens/primitivas + `Politica.css` + rota (S)** — depends on: 1 — unblocks: 4, 5, 6, 7
- **Inc 4 — KPIs, comparador de governos e séries (M)** — depends on: 1, 3 — unblocks: 8
- **Inc 5 — Dossiê de escândalos + impacto financeiro (M)** — depends on: 1, 2, 3 — unblocks: 8
- **Inc 6 — Geografia eleitoral (S)** — depends on: 1, 3 — unblocks: 8
- **Inc 7 — Fontes/links + banner de escopo + acessibilidade (S)** — depends on: 3 — unblocks: 8
- **Inc 8 — Verificação: gates ampliados + revisão adversarial + build + CI (M)** — depends on: 2, 4, 5, 6, 7 — unblocks: none

Caminho crítico: **1 → 2 → 5 → 8**. Inc 3, 4, 6, 7 podem andar em paralelo depois de
1/3.

> **Nota sobre a ordem.** A pesquisa jurídica **já está em disco** em
> `eleicao-2026/escandalos/`. `Inc 2` é o passo único de **adesão + parser** (schema
> valida, `build_data.mjs` lê os TSVs e evidências, gera `cases[]` + `sources[]`). Não
> cria `Yvy/research/*.md` — evita duplicação.

---

## Increments

### Inc 1 — Esquema + JSON curado + três gates (M)
**Status:** ✅ done (2026-10-07)
**Depends on:** none
**Unblocks:** 2, 3, 4, 5, 6, 7, 8
**Done criteria:** `frontend/public/politica/data.json` existe, é commitado e valida contra
`schema.mjs`; `make politica` imprime os **três** gates verdes
(`politica_provenance_rate` = 100.0, `politica_values_rate` = 100.0,
`politica_citation_rate` = 100.0) e sai 0; injetar um número sem `sources`
derruba o Gate 1; alterar um valor numérico no JSON sem alterar o bruto derruba
o Gate 2; alterar uma citação jurídica sem que ela apareça na fonte ao vivo
derruba o Gate 3.

#### Decisão obrigatória sobre o repo irmão
O plano consome dados de `../eleicao-2026/`, que **não faz checkout no CI do Yvy**.
Para builds reproduzíveis em clones limpos, o corpus jurídico é **vendorado**
em `scripts/politica/vendor/escandalos/` (TSV + evidências `.txt` + manifesto). Em
dev, `build_data.mjs` prefere `../eleicao-2026/escandalos/` se existir; em CI/clone
limpo usa o vendor. O `data.json` gerado **é commitado** em
`frontend/public/politica/`, de modo que `npm run build` funcione mesmo sem o repo
irmão. `make politica-data` atualiza `data.json`, o vendor e o lock.

#### Files to touch

##### `frontend/public/politica/data.json` (novo)
- What changes: criado do zero — a fonte única de verdade de todo o conteúdo.
- Data shapes (esquema completo):
  ```jsonc
  {
    "meta": { "vintage":"2026-10-07", "generated_by":"scripts/politica/build_data.mjs",
              "scope_note_pt":"…", "scope_note_en":"…", "series_cap":"últimos 10 anos" },
    "kpis": [{                       // grade de números-herói
      "id":"econ_desoc",             // casa com claims.tsv (many-to-one)
      "label_pt":"Desemprego médio","label_en":"Average unemployment",
      "value":6.72,"unit":"%","direction":"lower_is_better",
      "compare":[{"label_pt":"2023-2026 (Lula 3)","value":6.72},
                 {"label_pt":"2019-2022 (Bolsonaro)","value":12.13},
                 {"label_pt":"2012-2016 (Dilma)","value":8.28}],
      "plain_pt":"Menos gente procurando emprego e não achando.",
      "sources":["bcb_sgs"] }],
    "series": [{                     // gráficos de linha
      "id":"desoc","unit":"%","label_pt":"Desemprego (%)",
      "x":["2012-03","2012-04"],"y":[8.1,8.0],
      "partial_end":false,           // true → marcador "parcial" (ex.: DETER 2026)
      "sources":["bcb_sgs"] }],
    "geo": {
      "uf_losers":[{"uf":"GO","pt_delta_pp":-8.46,"pl_delta_pp":1.44,
                    "note_pt":"~7 pp sem destino conhecido (sem dados de abstenção)."}],
      "municipalities":[{"name":"Humaitá","uf":"AM","pl_delta_pp":13.8,"side":"pl"}],
      "summary":{"pl_majority_2022":1785,"pl_majority_2026":2576,
                 "pt_majority_2022":3058,"pt_majority_2026":2435,
                 "neither_2026":617,"sources":["tse_resultados"]} },
    "cases": [{                      // dossiê
      "id":"lula_mensalao","side":"pt","name_pt":"Mensalão","name_en":"Mensalão",
      "period":"2005-2014",
      "allegation_pt":"Pagamento mensal a deputados (revelado por Roberto Jefferson, 2005).",
      "allegation_en":"Monthly payments to congressmen (revealed by Roberto Jefferson, 2005).",
      "status":"nunca_reu",
      "status_note_pt":"STF rejeitou duas vezes a inclusão de Lula como réu.",
      "status_note_en":"The Supreme Court twice rejected adding Lula as a defendant.",
      "status_citation_pt":"Os ministros do Supremo Tribunal Federal (STF) negaram novamente a inclusão do ex-presidente da República Luiz Inácio Lula da Silva no processo de julgamento do mensalão.",
      "status_citation_en":"The ministers of the Federal Supreme Court (STF) once again denied the inclusion of former president Luiz Inácio Lula da Silva in the trial of the mensalão.",
      "defense_pt":"A defesa de Lula sempre afirmou que ele não era réu no caso.",
      "defense_en":"Lula's defense always maintained he was not a defendant in this case.",
      "financial":[],                  // Mensalão: nenhum valor atribuído a pessoa
      "evidence":[{"artifact_pt":"Delações premiadas","artifact_en":"Plea bargains",
                   "proves_pt":"Sustenta que o STF rejeitou incluir Lula como réu.",
                   "proves_en":"Supports that the STF rejected including Lula as a defendant.",
                   "state":"alegado_na_denuncia",
                   "sources":["congressoemfoco_mensalao"]}],
      "sources":["congressoemfoco_mensalao"] },
      {"id":"lula_lava_jato","side":"pt","name_pt":"Lava Jato / Petrolão","name_en":"Lava Jato / Petrobras scandal",
       "period":"2014-2021",
       "allegation_pt":"Cartel de empreiteiras pagava propina na Petrobras.",
       "allegation_en":"Cartel of contractors paid bribes at Petrobras.",
       "status":"condenado_anulado",
       "status_note_pt":"Fachin anulou as condenações por incompetência da 13ª Vara; Plenário confirmou 8×3.",
       "status_note_en":"Justice Fachin annulled the convictions for lack of jurisdiction; the full court confirmed 8-3.",
       "status_citation_pt":"Por 8 votos a 3, o Supremo Tribunal Federal (STF) decidiu hoje (15) manter a decisão que anulou as condenações do ex-presidente Luiz Inácio Lula da Silva.",
       "status_citation_en":"By 8 votes to 3, the Federal Supreme Court decided today to uphold the decision that annulled the convictions of former president Luiz Inácio Lula da Silva.",
       "defense_pt":"A defesa sustentou a incompetência da 13ª Vara e a suspeição de Moro; o STF acolheu.",
       "defense_en":"The defense argued the 13th Court lacked jurisdiction and Moro was biased; the STF agreed.",
       "financial":[{"measuredBy":"Petrobras","object":"perda da estatal com desvios",
                      "value":6200000000,"currency":"BRL","year":2014,
                      "status":"reconhecido","sources":["agenciabrasil_petrobras"]},
                     {"measuredBy":"MPF","object":"multa do acordo de leniência Odebrecht",
                      "value":8500000000,"currency":"BRL","year":2016,
                      "status":"suspenso_2024","sources":["ebc_odebrecht"]}],
       "evidence":[{"artifact_pt":"Delações de Léo Pinheiro / agentes da OAS",
                    "artifact_en":"Plea bargains by Léo Pinheiro / OAS agents",
                    "proves_pt":"Sustenta as acusações usadas no processo.",
                    "proves_en":"Supports the allegations used in the case.",
                    "state":"usado_no_processo","sources":["g1_moro_2021"]}],
       "sources":["agenciabrasil_stf_2021","stf_464261","g1_moro_2021"]}],
    "sources":[{ "id":"bcb_sgs","publisher":"Banco Central do Brasil","title":"SGS 24369",
                 "url":"https://…","date":"2026-10-07","kind":"official","tier":1 }],
    "labels":{ "lula_mensalao":{"pt":"Mensalão","en":"Mensalão"} }
  }
  ```
- Integration points: consumido por `Politica*.js` (Inc 3-7); validado por
  `schema.mjs` e auditado pelos três gates (Inc 1 e Inc 8).
- Error paths: JSON inválido → `schema.mjs` sai 1 com o caminho do campo.

##### `scripts/politica/schema.mjs` (novo)
- What changes: validação sem dependências externas (o repo não tem `ajv`).
- Functions: `validate(data)` → `{ok, errors[]}`; `ENUM_CASE_STATUS`,
  `ENUM_EVIDENCE_STATE`, `ENUM_KIND`, `ENUM_FIN_STATUS` (arrays exportados — são a
  fonte única dos enums, importada também pelos gates).
- Regras específicas:
  - Todo caso jurídico precisa de `defense_pt`/`defense_en`,
    `allegation_pt`/`allegation_en`, `status_note_pt`/`status_note_en`,
    `status_citation_pt`/`status_citation_en`.
  - Toda evidência precisa de `artifact_pt`/`artifact_en` e `proves_pt`/`proves_en`.
  - Todo `kpi` e todo `financial`/`evidence` precisa de `sources` não-vazio.
- Error paths: `main()` imprime os erros e sai 1.

##### `scripts/politica/build_data.mjs` (novo)
- What changes: gera `data.json` a partir de fontes determinísticas.
- Functions: `main()`, `readClaims(root)` (lê `eleicao-2026/bench/claims.tsv` ou vendor),
  `readSeries(root)` (manifesto `scripts/politica/series_manifest.json` aponta para
  `eleicao-2026/evidence/**/raw/*.json`/`*.csv`), `readGeo(root)` (mesmo manifesto,
  CSVs de `evidence/geografia/`), `readCases(root)` (lê
  `eleicao-2026/escandalos/claims.tsv`, `sources.tsv` e `evidence/{lula,flavio}/*.txt`,
  com fallback para vendor), `assertSchema(data)`, `write(data)`, `updateVendor(data)`.
- Manifesto de brutos: `scripts/politica/series_manifest.json` lista, por série/UF,
  o arquivo bruto e a fórmula de agregação (`mean`, `last`, `sum`, `min`, `max`).
  Exemplo:
  ```jsonc
  {"series": [{"id":"desoc","file":"evidence/economia/raw/bcb_sgs_desoc.json",
                "freq":"monthly","field":"value","agg":"last"}]}
  ```
- Integration points: `make politica-data`.
- Error paths: sem `eleicao-2026` e sem vendor → lança; claim sem `source_id` em
  `sources.tsv` → lança; evidence file sem `CITACAO VERBATIM:` ou
  `POSICAO DA DEFESA:` → lança.

##### `scripts/politica/check_provenance.mjs` (novo) — **Gate 1: presença**
- What changes: varre `data.json`; toda folha com `value`/`unit` **ou** todo objeto
  `kpi`/`financial`/`evidence` precisa de `sources` não-vazio; todo `sourceId` citado
  existe em `sources[]`; toda URL começa com `http`; `data.json` ≤ 500 KB (alerta, não
  fail — séries longas e geografia podem estourar 250 KB legítimo).
- Functions: `walk(node)`, `validateSources(data)`, `validateCrosswalk(data, claimsTsv)`,
  `main()`. `validateCrosswalk` checa **cobertura** (todo `claim_id` das 36 claims está
  em `surfaced[]` ∪ `excluded[]`), **não** bijeção. Os 14 `claim_id` jurídicos devem
  aparecer via `cases[]`.
- **Teste de amostra:** Gate 1 valida que, para 3 `claim_id` sorteados, o valor no
  `data_path` bate com o valor registrado no `claims.tsv` (evita mapeamento errado).
- Output: `METRIC=politica_provenance_rate` + `METRIC=politica_orphan_sources`. Exit 1.
- Nota honesta: este é um teste de **presença**, não de correção. Por isso existem os
  Gates 2 e 3.

##### `scripts/politica/verify_values.mjs` (novo) — **Gate 2: recálculo numérico (independente)**
- What changes: recalcula **apenas os números governamentais** direto dos arquivos
  brutos listados no `series_manifest.json` (BCB SGS JSON, SIDRA JSON, PRODES/DETER CSV,
  ZIP do TSE) e compara com o JSON. Inclui superlativos (mínimo/pico do desemprego,
  mínimo do Gini). Séries/UF cujo bruto não tenha fórmula de agregação no manifesto
  são marcadas como `not_independently_verified`, não como falhas — para não prometer
  verificação inexistente.
- Functions: `recomputeFromRaw(item, root)`, `checkSuperlatives(root)`, `main()`.
- Output: `METRIC=politica_values_rate value=<pct>` + `METRIC=politica_independent_checks
  value=<n>` + `METRIC=politica_not_verified value=<n>`. Exit 1 apenas se algum check
  que deveria ser independente falhar.

##### `scripts/politica/verify_citations.mjs` (novo) — **Gate 3: verificação jurídica ao vivo**
- What changes: para cada caso jurídico, faz fetch das URLs citadas e confirma que a
  `status_citation_pt` aparece no texto servido (mesma lógica do
  `eleicao-2026/escandalos/verify_citations.py`). Como os portais STF são SPA estático,
  o gate passa se **qualquer** fonte do caso contiver a citação (imprensa de
  referência funciona como fallback). Se nenhuma fonte responder com o fragmento, o
  caso vira `nao_confirmado` e o build falha.
- Functions: `fetchAndMatch(source)`, `checkCase(c)`, `main()`.
- Output: `METRIC=politica_citation_rate value=<pct>` + `METRIC=politica_citation_miss
  value=<n>`. Exit 1 se `miss > 0`.
- **Nota honesta:** este gate é a única defesa contra a tautologia de verificar o `.txt`
  contra si mesmo.

##### `scripts/politica/claims_crosswalk.json` (novo)
- What changes: mapa **muitos-para-um** `claim_id` → `data_path`(s) + duas listas.
- Data shape:
  ```jsonc
  { "map": {"econ_desoc":"kpis[econ_desoc]", "econ_desoc_min":"kpis[econ_desoc].compare[0]",
            "lula_mensalao_nunca_reu":"cases[lula_mensalao].evidence[0]"},
    "surfaced":["econ_desoc", "…", "lula_mensalao_nunca_reu"],
    "excluded":[{"claim_id":"econ_massa","reason_pt":"não usado no painel"}] }
  ```
- Integration points: `validateCrosswalk`; exige que `surfaced ∪ excluded` = todas as 36.
- Error paths: claim nem surfaced nem excluded → lista e sai 1.

##### `scripts/politica/vendor/escandalos/` (novo diretório)
- What changes: snapshot commitado de `eleicao-2026/escandalos/claims.tsv`,
  `sources.tsv` e `evidence/{lula,flavio}/*.txt`. Atualizado por `make politica-data`
  quando `../eleicao-2026/` está presente.
- Integration points: fallback em `build_data.mjs`; roda seus próprios gates do
  `eleicao-2026` quando o repo irmão está disponível.

##### `frontend/public/politica/data.json.lock` (novo)
- What changes: manifesto com hash e data da última geração, para detectar se o JSON
  commitado ficou desatualizado em relação ao vendor.
- Integration points: Gate 1 alerta se lock difere do JSON atual.

##### `Makefile` (editar)
- What changes: alvos `politica-data` (gera JSON + lock + vendor), `politica-check`
  (roda schema + Gate 1 + Gate 2 + Gate 3), `politica` (depende de ambos). Em CI,
  `politica-check` valida o JSON commitado sem exigir repo irmão.

#### Edge cases
- Crosswalk é **muitos-para-um** (`econ_desoc*` → 1 indicador); o gate checa cobertura, não 1:1.
- Valores monetários inteiros em BRL; formatados na borda por `formatMoney(v, lang)`.
  Em `en`, a saída é `"BRL 6.2 bi"` (prefixo ISO + escala) em vez de `"R$"`.
- Séries longas: cap em `meta.series_cap` (últimos 10 anos); o corte é registrado.
- `data.json` > 500 KB é alerta, não fail.

#### Verification
- Run: `make politica-check` (deve sair 0 com três 100.0/0 miss) e
  `node scripts/politica/schema.mjs`.
- Negative test A: remover `sources` de um KPI → `politica_provenance_rate` < 100 e exit 1.
- Negative test B: mudar `value` de um KPI numérico no JSON sem tocar no bruto →
  `politica_values_rate` < 100 e exit 1.
- Negative test C: alterar `status_citation_pt` para frase inexistente na fonte →
  `politica_citation_rate` < 100 e exit 1.
- Done: os três gates ficam vermelhos quando o dado mente e verdes quando não.

---

### Inc 2 — Consumir e compilar o corpus jurídico (M)
**Status:** ✅ done (2026-10-07)
**Depends on:** 1
**Unblocks:** 5
**Done criteria:** `build_data.mjs` lê `eleicao-2026/escandalos/claims.tsv`,
`sources.tsv` e `evidence/{lula,flavio}/*.txt` (com fallback para o vendor), agrupa
as 14 claims em 5 casos, emite `cases[]` + `sources[]` no `data.json` e passa nos
três gates. Nenhum caso cai em `nao_confirmado`.

#### Files to touch

##### `scripts/politica/build_data.mjs` (editar)
- What changes: implementar `readCases(root)` — parser dos TSVs e das evidências `.txt`;
  agrupar claims por `grupo` para não duplicar casos; emitir `cases[]` + `sources[]` no
  JSON. Usa `../eleicao-2026/escandalos/` quando disponível, senão o vendor.
- Parser dos arquivos de evidência: extrai `CLAIM:`, `STATUS:/VERDICT:/CONFIANCA:`,
  `AFIRMACAO:`, `CITACAO VERBATIM:`, `O QUE ISSO PROVA:`, `POSICAO DA DEFESA:` e
  `ARQUIVO BRUTO:`.
- Functions: `parseTsv(path)`, `parseEvidenceTxt(path)`, `groupClaimsByGrupo(rows)`,
  `buildCases(groups)`, `mergeSources(sourcesTsv, existingSources)`.
- Integration points: `readCases()` é chamado por `main()` e alimenta `data.json`.
- Error paths: `claim_id` sem `evidence` file → lança; evidence file sem
  `CITACAO VERBATIM:` ou `POSICAO DA DEFESA:` → lança; `source_id` citado e ausente em
  `sources.tsv` → lança; grupo sem `defense_pt` → lança.

##### `scripts/politica/check_sources.mjs` (novo)
- What changes: valida que todo `sourceId` usado em `cases[]` existe em
  `data.json:sources[]`, que as URLs começam com `http` e que nenhum `tier:1` está
  sozinho num caso carregador.
- Functions: `crossCheck(cases, sources)`, `main()`.
- Error paths: URL sem esquema → erro; `sourceId` citado e ausente → erro; caso
  carregador com apenas uma fonte → warn (não fail, mas anota no `ScopeFooter`).

#### Edge cases (herdados do corpus verificado)
- **Não usar**: R$ 2,6 mi e estimativa TCE-RJ (**sem fonte**); rótulo "carteirada" como
  caso autônomo (já removido); "prejuízo de R$ 100 mi do mensalão" (imprensa, não
  oficial).
- Valores "alegados na denúncia" (ex.: R$ 3,7 mi do tríplex) só entram com
  `state: "alegado_na_denuncia"` — nunca como `financial`.
- A ação civil de improbidade de 2026 **não tem Flávio como alvo** — não é caso dele.
- **Status juridicamente carregador exige ≥2 fontes independentes** (o corpus já cumpre:
  Lula Lava Jato tem 2 fontes; Flávio rachadinha tem múltiplas fontes; a fonte STF é
  sempre acompanhada de imprensa de referência exatamente porque `portal.stf.jus.br` é
  SPA estático e falha no fetch).

#### Verification
- Run: `cd eleicao-2026/escandalos && python3 build_claims.py && python3 check_provenance.py
  && python3 verify_citations.py` → ambos devem imprimir 14/14 OK.
- Run: `make politica-data && make politica-check`.
- Done: `data.json` tem `cases.length === 5` (Mensalão, Lava Jato/Petrolão, Tríplex,
  Atibaia, Rachadinha) e `sources.length >= 10`; todo caso tem os 4 blocos + defesa;
  nenhum campo vazio; toda cifra com `measuredBy`.

---

### Inc 3 — Tokens/primitivas + `Politica.css` + rota (S)
**Status:** ✅ done (2026-10-07)
**Depends on:** 1
**Unblocks:** 4, 5, 6, 7
**Done criteria:** `/politica` abre com header, navegação por seções e footer de escopo;
sem link no Navbar; build limpo; `.stat-grid`/`.bar-row` **renderizam estilizados** (o que
prova o import de `Dashboard.css`).

#### Files to touch

##### `frontend/src/App.js` (editar)
- What changes: 1 lazy import + 1 rota.
- Exact edit: após `const RiskIntelligence = React.lazy(...)` adicionar
  `const Politica = React.lazy(() => import('./components/Politica/Politica'));`; após a
  rota `/risk-intelligence` adicionar `<Route path="/politica" element={<Politica />} />`.
- Error paths: nenhum (o C server já faz fallback para SPA).

##### `frontend/src/components/Politica/Politica.css` (novo)
- What changes: layout do painel; header comentado citando o plano e os tokens.
- Classes: `.politica-page` (max-width 1200, padding 32/24/56), `.politica-header`,
  `.politica-kicker`, `.politica-section`, `.politica-section__title`, `.politica-nav`
  (chips de âncora), `.politica-callout`(+`--warn`), `.politica-plain`, `.politica-source`,
  `.politica-status` (+ modifiers por valor do enum), `.politica-card--side-pt|--side-pl`,
  `.politica-big`, `.politica-scope`.
- Integration points: importa-se **depois** de `Dashboard.css` (ordem importa); consome
  tokens de `index.css`; **não** redefine `.stat-grid`/`.bar-*`.
- Error paths: CSS puro. Regra: sem `box-shadow` sobre superfícies de mapa (memória do repo).

##### `frontend/src/components/Politica/Politica.js` (novo)
- What changes: shell da página.
- **Imports obrigatórios (MUST-FIX aplicado):** `import '../Dashboard.css';` **e**
  `import './Politica.css';` — sem o primeiro, as primitivas do Dashboard não existem no
  chunk de `/politica` (verificado: `main.*.css` tem 0 ocorrências de `stat-grid`).
- Functions: `export default function Politica()`, `PoliticaProvider` (contexto com
  `data`, `lang`), `SectionNav`, `ScopeFooter`.
- Data shapes: `data` de `/politica/data.json`; estado `loading|ready|error`.
- Integration points: `useI18n()`; filhos `PoliticaKpis`, `PoliticaCompare`,
  `PoliticaSeries`, `PoliticaDossier`, `PoliticaImpact`, `PoliticaGeo`, `PoliticaSources`.
- Error paths: `fetch` falha → bloco de erro com o path tentado.

##### `frontend/src/i18n.js` (editar)
- What changes: namespace `politica` **em `pt` e `en`** (espelhado) — **só a chrome**:
  títulos de seção, rótulos dos enums de status, "o que isso quer dizer", "fonte",
  banners. A copy de conteúdo de cada KPI/caso vive no `data.json` (`*_pt`/`*_en`).
- Decisão de fonte única (SHOULD-FIX aplicado): **a chrome em `i18n.js`; o conteúdo no
  JSON.** São dois domínios distintos, não duas cópias da mesma string.
- Error paths: chave faltando devolve o path cru — o Inc 8 verifica que nenhuma chave
  `politica.*` aparece crua na tela.

#### Edge cases
- O `main-content` já tem `padding-top:64px`; a página não adiciona de novo.
- A página é pública mas carrega `<meta name="robots" content="noindex">` (Inc 8).

#### Verification
- Run: `cd frontend && npx react-scripts build` (sem `CI=true`) → exit 0.
- Manual: abrir `/politica` direto; confirmar que `.stat-grid` tem bordas (prova o CSS do
  Dashboard); confirmar que o Navbar não tem o link; `/` e `/dashboard` seguem ok.
- Done: página existe, é alcançável, sem regressão de rota, com estilo.

---

### Inc 4 — KPIs, comparador de governos e séries (M)
**Status:** ✅ done (2026-10-07)
**Depends on:** 1, 3
**Unblocks:** 8
**Done criteria:** KPIs com número-herói + frase didática + fonte clicável; comparador
alterna 2012-2016 / 2019-2022 / 2023-2026; séries recharts renderizam; nenhuma string
i18n crua.

#### Files to touch

##### `frontend/src/components/Politica/PoliticaKpis.js` (novo)
- What changes: grade de números-herói, um por `kpi`, com `plain_pt` e a linha de fonte.
- Functions: `KpiTile({ kpi })`, default `PoliticaKpis()`. Consome o contexto (sem fetch).
- Integration points: `formatInt`/`formatPct`/`formatKm2` de `utils/format.js`;
  `.stat-grid` + `.stat-card__value`.
- Error paths: `value` não-finito → `—` (os formatadores já tratam NaN).

##### `frontend/src/components/Politica/PoliticaCompare.js` (novo)
- What changes: comparador didático de médias por governo — três cartões de período e
  uma barra proporcional por período.
- Functions: `PeriodCard({ label, value, best })`, `DeltaBar({ a, b })`, default.
- Integration points: `.bar-row`/`.bar-fill`; `formatDelta`/`formatDeltaPct`.
- Error paths: `compare` ausente → não renderiza (sem zero inventado).

##### `frontend/src/components/Politica/PoliticaSeries.js` e `PoliticaCharts.js` (novos)
- What changes: gráficos recharts das séries + a linha "o que isso quer dizer".
- **Decisão (CONSIDER resolvido):** `TICK_STYLE` e `AXIS_LINE` **são** extraídos para
  `PoliticaCharts.js` (não "se duplicados 2×"): são usados por ≥3 gráficos; um critério
  condicional não é verificável.
- Functions: `SeriesChart({ series, annotation })`, `markPartialEnd(series)`.
- Integration points: recharts `LineChart`/`AreaChart` + `ResponsiveContainer` height 260.
- Error paths: série de 1 ponto → ponto + aviso; `partial_end` → marcador "parcial".

#### Edge cases
- **Nunca** sobrepor séries de tamanhos diferentes: DETER 2026 tem 9 meses → `partial_end`
  + ressalva de denominador visível.
- Ordem temporal crescente; o Gate 1 valida monotonicidade de `x`.
- `SeriesChart` define explicitamente as classes `.dash-tooltip*` (hoje inexistentes).

#### Verification
- Run: build limpo; alternar todos os períodos; redimensionar (ResponsiveContainer).
- Manual: cada gráfico tem rótulo em texto (não só cor).
- Done: cada KPI exibe número + frase leiga + fonte.

---

### Inc 5 — Dossiê de escândalos + impacto financeiro (M)
**Status:** ✅ done (2026-10-07)
**Depends on:** 1, 2b, 3
**Unblocks:** 8
**Done criteria:** casos de Lula e de Flávio lado a lado; cada um com os 4 blocos fixos e
o **status do enum em destaque**; cada valor financeiro com órgão + a quem se refere +
natureza; toda prova é artefato nomeado com estado.

#### Files to touch

##### `frontend/src/components/Politica/PoliticaDossier.js` (novo)
- What changes: a comparação. Uma linha por caso, com a coluna de status sempre visível.
  Cada `CaseCard` é didaticamente redundante para o público de baixo capital político:
  **ícone + cor + frase curta** no topo; o status nunca é só texto. Botão "entenda em
  1 minuto" expande a citação verbatim, a posição da defesa e o link para a fonte.
- Functions: `CaseCard({ c, lang })`, `StatusPill({ status })`, `MoneyRow({ f })`,
  `EvidenceRow({ e })`, default.
- Integration points: `formatMoney` (Inc 5, `utils/format.js`); `.politica-card--side-pt|pl`.
- Error paths: `status === "nao_confirmado"` → aviso "não usável"; o Inc 8 falha o build
  (não pode chegar em produção).

##### `frontend/src/components/Politica/PoliticaImpact.js` (novo)
- What changes: bloco de impacto financeiro — barras proporcionais **com rótulo do
  objeto** (Petrobras, Odebrecht, conta de Queiroz) e **disclaimer de incomparabilidade**
  em destaque. O visual impede a leitura errada "Lula roubou X" ou "Flávio roubou Y".
- Functions: `ImpactBars({ cases })`, `MoneyNote({ f })`, default.
- Error paths: valores de objetos diferentes → agrupar por `object` e rotular; nunca somar
  tudo numa barra "total" sem o rótulo do escopo.

##### `frontend/src/utils/format.js` (editar)
- **What changes:** **apenas** `formatMoney(v, lang)` → `"R$ 6,2 bi"` / `"R$ 1,7 mi"`
  em `pt`, `"BRL 6.2 bi"` / `"BRL 1.7 mi"` em `en` (prefixo ISO + escala). **Não**
  adicionar `formatPP` — `formatDeltaPct` já existe e cobre `+7,5%` (SHOULD-FIX
  aplicado).
- Error paths: escala "bi"/"tri"; zero → `"R$ 0"` / `"BRL 0"`; valores acima de 1e12
  → "tri".

#### Edge cases
- **`absolvido` (mérito) ≠ `denunciado_arquivado` (vício processual)** — o enum separa.
- Lula no mensalão = `nunca_reu`; sem pill de acusação.
- Ordem dentro de cada lado é cronológica; não ordenar por gravidade (seria editorial).

#### Verification
- Run: `make politica-check` (cobre `cases[].financial[].sources`) e build.
- Manual: abrir cada link de documento oficial.
- Done: nenhum caso sem `status`; toda cifra com `measuredBy` e `object`.

---

### Inc 6 — Geografia eleitoral (S)
**Status:** ✅ done (2026-10-07)
**Depends on:** 1, 3
**Unblocks:** 8
**Done criteria:** mostra o mapa virou (municípios PL/PT), as UFs onde o PT caiu (com a
exceção de GO) e os municípios-pivô; cada barra com valor em texto.

#### Files to touch

##### `frontend/src/components/Politica/PoliticaGeo.js` (novo)
- What changes: barras horizontais para UFs (GO destacada + nota dos ~7 pp) e tabela de
  municípios (`geo_mun_pl`/`geo_mun_pt`).
- Functions: `UfDeltaBars()`, `MunicipalityTable()`, default.
- Integration points: `.bar-row`; `formatDeltaPct`.
- Error paths: UF sem par 2022/2026 → pular e registrar em `meta`.

#### Edge cases
- A ressalva de comparabilidade (PL muda de candidato 2022→2026; PT não) **precede** os
  números — não pode ser rodapé.
- Contagem de municípios não é ponderada por eleitorado: dizer onde aparece.

#### Verification
- Run: build; manual no mobile (a tabela vira cartões ou scroll).
- Done: a ressalva está acima dos números, não abaixo.

---

### Inc 7 — Fontes/links + banner de escopo + acessibilidade (S)
**Status:** ✅ done (2026-10-07)
**Depends on:** 3
**Unblocks:** 8
**Done criteria:** fontes reunidas no fim; cada número linka para a sua; o banner de
escopo declara o que é e não é verificado **e a data de coleta, acima da dobra**; a
página passa um passe de acessibilidade (headings, contraste, alt, foco).

#### Files to touch

##### `frontend/src/components/Politica/PoliticaSources.js` (novo)
- What changes: lista de fontes agrupada por `kind` (oficial × imprensa), com data e link;
  e o banner de escopo. O banner exibe **os três gates** do painel (schema,
  provenance, values) **e** o resultado dos gates do `eleicao-2026/escandalos/`
  (`sourced_claims_rate` 14/14, `citation_support_rate` 14/14) para que o leitor
  desconfiado veja que as citações foram verificadas ao vivo.
- Functions: `SourceList({ sources })`, `ScopeBanner({ meta })`, `SourceLink({ id })`,
  `GateBlock({ rates })`.
- Integration points: `safeHttpUrl()` (padrão de `HistoricalTrend.js:36-43`).
- Error paths: URL sem `http` → mostra publisher sem link.

##### `frontend/src/components/Politica/Politica.css` (editar)
- What changes: foco visível nos chips/links; contraste dos pills de status; nada de
  `--ink-faint` em texto que o leitor precisa ler; o banner de escopo **acima da dobra**.

#### Edge cases
- `lang` do documento é pt-BR; em `en` os acentos não quebram.
- DESIGN.md: `--signal` é para ativo/selecionado e `data-large` tem **uso único** para o
  número-herói — garantir que o acento da seção ativa e o herói não disputem o mesmo papel
  no mesmo viewport.

#### Verification
- Run: build; headings h1→h2→h3 sem pular nível; tab pelos chips.
- Done: cada número clicável; banner com a data no topo; foco visível.

---

### Inc 8 — Verificação: gates ampliados + revisão adversarial + build + CI (M)
**Status:** ✅ done (2026-10-07)
**Depends on:** 2, 4, 5, 6, 7
**Unblocks:** none
**Done criteria:** `make politica` verde (os **três** gates) cobrindo todos os números
verificáveis; subagente de revisão (cego ao plano) não encontra erro factual nem de
status; build limpo; nenhum `nao_confirmado`; nenhuma string i18n crua; job de CI criado;
rota `/politica` com `<meta name="robots" content="noindex">`.

#### Files to touch

##### `scripts/politica/verify_render.mjs` (novo) — **Gate 4: snapshot do DOM renderizado**
- What changes: em vez de regex em JSX (falsos positivos massivos: `height={260}`,
  `strokeWidth={2}`, índices, lógica), renderiza a página com `ReactDOMServer.renderToStaticMarkup`
  usando um `data.json` de teste conhecido e extrai todo texto visível. Depois varre o
  texto procurando literais numéricos que **não** estejam no JSON de teste. Qualquer
  número renderizado que não venha do JSON é falha.
- Functions: `renderToText()`, `findHardcodedNumbers(renderedText, data)`, `main()`.
- Error paths: número no texto não presente no JSON de teste → `arquivo:linha` e exit 1.
- Decisão: este gate cobre o risco de "número hard-coded na view"; os Gates 1–3 já
  cobrem provenance, recálculo numérico e citações jurídicas.

##### `frontend/src/components/Politica/Politica.js` (editar)
- What changes: adicionar `<Helmet>` / `<meta name="robots" content="noindex">` (ou
  equivalente puro se o projeto não usar react-helmet). Rota oculta + conteúdo
  jurídico-político → decisão de não indexar.

##### `scripts/politica/review_prompt.md` (novo)
- What changes: prompt do revisor adversarial, com postura de **status processual**:
  reverifica cada status jurídico contra uma fonte e reprova caso a palavra escrita não
  bata com o enum; confere que `status_citation` sustenta o status; verifica se o visual
  (pictograma/cor) não contradiz o status.

##### `.github/workflows/ci.yml` (editar) — **SHOULD-FIX aplicado**
- What changes: novo job `politica-check` (roda em `ubuntu-latest`, node 20, `npm ci`
  desnecessário): executa `node scripts/politica/schema.mjs && node
  scripts/politica/check_provenance.mjs && node scripts/politica/verify_values.mjs &&
  node scripts/politica/verify_citations.mjs`. Sem `needs:` (paralelo aos demais), como o
  `frontend-build`. O Gate 4 (`verify_render.mjs`) roda dentro do `frontend-build` ou
  como step adicional após `npm run build`.

#### Edge cases
- Se o revisor não confirmar um status, o caso vai para `nao_confirmado` **e o build
  falha** — preferir não publicar a publicar errado.
- Gate 4 precisa de `data.json` de teste estável; não pode depender de dados ao vivo.

#### Verification
- Run: `make politica` **e** `cd frontend && npx react-scripts build` **e** `node
  scripts/politica/verify_render.mjs` **e** `make test-lua` (garantir que o backend não
  regrediu) **e** confirmar o job no CI.
- Manual: caminhada cross-cutting abaixo.
- Done: quatro gates verdes + revisor sem MUST-FIX + build limpo + CI verde + noindex.

---

## Cross-cutting verification

Depois de Inc 8, a caminhada manual (o painel é para leigo; a medida é o entendimento):

1. Abrir `https://<host>/politica` direto (URL, sem link) no celular e no desktop.
2. Confirmar que o Navbar **não** mostra o link e que `/`, `/dashboard`,
   `/risk-intelligence` continuam funcionando.
3. Ler **só** os números-herói e as frases `plain_*`: dá para entender sem ler o resto?
   (Teste do semi-analfabeto.)
4. Em cada KPI: clicar na fonte e cair numa página real.
5. Na seção de escândalos: para cada caso, o "status hoje" é verdadeiro em out/2026?
   Nenhum caso anulado aparece como condenação atual?
6. Cada valor financeiro mostra órgão + a que objeto se refere?
7. Em `en`, nenhuma string crua, nenhum acento quebrado.
8. Rodar `make politica && make test-lua` do zero num clone limpo.

---

## Standards / common-mistakes referenciados

- `.agents/DESIGN.md` — aplica a: toda a camada visual (`--signal` só em ativo/selecionado;
  `data-large` de uso único; sem drop-shadow sobre mapa; tabular numerals).
- `.agents/AGENTS.md` — aplica a: o build do front é servido pelo C server; `/api` é proxy.
- `.agents/common-mistakes/common-mistakes.md` §11 ("uma fonte de verdade por dimensão") —
  aplica a: o número do KPI e o do comparador vêm do **mesmo campo** do JSON, nunca
  recalculados na view.
- Memória `research-provenance.md` — **central**: o gate de presença é tautológico → por
  isso há o **Gate 2** (recálculo do bruto); o "superlative trap" → aqui o análogo é o
  **status processual** (ninguém reverifica "foi anulado"); declarar quantos checks são
  independentes (`politica_independent_checks`).
- `.plans/dashboard-enhancement/plan.md` — precedente de tom e granularidade.

---

## Open questions (CONSIDER from review)

- **Indexabilidade.** RESOLVIDO: página `/politica` carrega `<meta name="robots"
  content="noindex">` (Inc 8). Rota oculta + conteúdo jurídico-político → não indexar.
- **Escopo jurídico / mensalão.** RESOLVIDO: manter com status `nunca_reu` explícito;
  omitir o caso notório pareceria edição.
- **Idioma.** RESOLVIDO: manter `en` espelhado. O schema exige `*_pt`/`*_en` para
  caso, evidência, notas e citações. `formatMoney(v, lang)` retorna `"R$ 6,2 bi"` em
  `pt` e `"BRL 6.2 bi"` em `en`.
- **Vintage congelado.** RESOLVIDO: Gate 1 emite warning se `hoje - vintage > 6 meses`,
  forçando revisão dos status jurídicos. O banner sempre mostra a data de coleta.
- **Tier de fontes na seção jurídica.** RESOLVIDO: o corpus `eleicao-2026/escandalos/`
  já aplica a regra informalmente. O Gate 1 emite warn se um caso carregador tiver só
  uma fonte.
- **CI e clone limpo.** RESOLVIDO: vendor snapshot em `scripts/politica/vendor/escandalos/`
  + `data.json` commitado. `make politica-check` valida o JSON sem exigir repo irmão.

---

## Out of scope

- **Não é um produto do Yvy.** É uma rota emprestada ("aproveitar a infra existente"),
  sem link no Navbar, sem promoção, sem chancela do produto.
- **Sem backend novo.** Nenhuma rota Lua, nenhuma tabela, nenhum ingest.
- **Sem projeção de 2º turno** (o briefing já se recusa a projetar).
- **Sem juízo editorial** sobre culpa, inocência ou "quem é pior" — só status e fonte.
- **Sem causalidade** ("o governo X causou a queda Y").
- **Sem atualização automática.** O dado é um recorte datado; atualizar é um commit
  manual (`make politica-data`).
- **Sem dados de abstenção/nulos** (a lacuna de GO continua declarada, herdada).
- **Sem reconciliação PRODES camada × manchete** (herdada, declarada como ressalva).
