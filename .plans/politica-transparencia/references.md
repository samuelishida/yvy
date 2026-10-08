# References — insumos para `/politica`

Arquivo de apoio do plano. Contém (1) o corpus numérico herdado e (2) os **achados da
pesquisa jurídica** já materializados em `eleicao-2026/escandalos/`. O plano consome
esses TSVs e evidências diretamente, sem duplicar em `Yvy/research/`.

> **Regra de ouro desta seção.** Em **todos** os casos, as condenações de Lula foram
> **anuladas** e a denúncia de Flávio foi **arquivada sem mérito**. Apresentar qualquer
> uma delas como fato atual é factualmente falso e difamatório.

---

## 1. Corpus numérico herdado (`eleicao-2026`)

- Claims numéricas: `eleicao-2026/bench/claims.tsv` (22 linhas, todas `OK`).
- Fontes numéricas: `eleicao-2026/bench/sources.tsv` (6, todas `official`).
- Claims jurídicas: `eleicao-2026/escandalos/claims.tsv` (14 linhas, todas `CONFIRMADO`).
- Fontes jurídicas: `eleicao-2026/escandalos/sources.tsv` (18, oficial + imprensa).
- Gates numéricos: `sourced_claims_rate` 22/22 · `assertions_verified_rate` 62/62 ·
  `broken_raw_pointers` 0.
- Gates jurídicos: `sourced_claims_rate` 14/14 · `citation_support_rate` 14/14 ·
  `citations_independent` 14.
- Brutos para o Gate 2: `eleicao-2026/evidence/**/raw/` (BCB SGS JSON, SIDRA JSON,
  PRODES/DETER CSV, ZIP do TSE).
- Recorte: pós-1º turno de 04/10/2026 → PL 47,03% (Flávio, n.22) × PT 45,16% (Lula, n.13);
  2022: PT 48,43% × PL 43,20%.
- **Crosswalk é muitos-para-um:** 4 claims de desemprego (`econ_desoc`,
  `econ_desoc_min`, `econ_desoc_pico`, `econ_desoc_dilma`) → 1 indicador de KPI.

---

## 2. Achados jurídicos (pesquisa desta sessão)

### 2.1 Lula (PT)

| Caso | Alegação (neutra) | Status hoje (out/2026) | Enum |
|---|---|---|---|
| Mensalão (AP 470) | Pagamento mensal a deputados (revelado por R. Jefferson, 2005) | **Nunca réu.** STF rejeitou 2× a inclusão. 24 condenados, não Lula. AP encerrada. | `nunca_reu` |
| Petrolão / Lava Jato | Cartel de empreiteiras pagava propina na Petrobras; MPF acusou Lula de "comandante máximo" | **Todas as condenações anuladas.** Fachin 08/03/2021 (incompetência da 13ª Vara), referendado pelo Plenário 15/04/2021; Moro declarado suspeito (HC 164.493, 2ª Turma 23/03/2021, Plenário 23/06/2021 7×4). | `condenado_anulado` |
| Tríplex do Guarujá | Propriedade oculta do tríplex + reformas como propina (OAS) | Moro 12/07/2017 → TRF-4 24/01/2018 → STJ 23/04/2019 → **anulada** (Fachin) → **arquivada por prescrição** 28/01/2022 (12ª Vara Fed. Criminal de Brasília). | `prescrito` |
| Sítio de Atibaia | Reformas do sítio como propina (OAS/Odebrecht) | Hardt 06/02/2019 → TRF-4 27/11/2019 → **anulada** (Gilmar 24/06/2021) → denúncia rejeitada (2021) → **TRF-1 nega reabertura 30/07/2025** (prescrição da pretensão). | `prescrito` |

**Achados vinculantes:**
- Lula **não tem** condenação com trânsito em julgado. **Não houve absolvição de mérito**:
  houve anulação (nulidade) e prescrição. Logo, "condenado" **e** "inocentado" são imprecisos.
- ONU (28/04/2022): Moro foi **parcial** e os direitos políticos de Lula foram violados.
- Toffoli anulou as provas do acordo de leniência da Odebrecht (06/09/2023, sistemas
  Drousys/My Web Day B).

**Impacto financeiro (só o que tem fonte):**
| Valor | Órgão | Objeto | Status | Fonte |
|---|---|---|---|---|
| **R$ 6,2 bi** | Petrobras (balanço auditado 2014) | perda da estatal com a Lava Jato (3% de contratos 2004-2012, 27 empresas) | `reconhecido` | Agência Brasil/EBC |
| **R$ 8,5 bi** | MPF (leniência Odebrecht, dez/2016) | multa do acordo de leniência | `suspenso_2024` (Toffoli, Pet 11.972, 01/02/2024) | Congresso em Foco / Migalhas |
| **até R$ 42,8 bi** | laudo pericial PF (2015) | prejuízo estimado da Petrobras | `estimado` | G1 — **não entra no painel** (estimativa, não consta no corpus `escandalos/`). |
| **R$ 1,7 mi** | TCU (2025) | recolhimento da **DNA Propaganda** (empresa) | `reconhecido`, mas **não atribuído a Lula** | Veja (imprensa) — **não entra no painel** porque não há citação verbatim no corpus e o objeto é empresa, não pessoa. |
| **R$ 2,2 mi** | leilão (2018) | arrematação do tríplex | `reconhecido` | Folha — **não entra no painel** (não consta no corpus `escandalos/`; mantido aqui apenas como registro de pesquisa). |
| **R$ 3,7 mi** | denúncia MPF (tríplex) | propina alegada | `alegado_na_denuncia` | — — **não entra no painel** (valor alegado, não reconhecido). |

**NÃO USAR:** qualquer cifra atribuída **a Lula pessoalmente** — não existe fonte oficial.
"R$ 100 mi de prejuízo do mensalão" é imprensa, não oficial. R$ 650 mi (Marcos Valério,
dívida ativa PGFN) é dívida **dele**, não do mensalão.

**Provas (artefatos):** delações premiadas (Roberto Jefferson, Delúbio, Marcos Valério);
registros bancários do "valerioduto"; depoimentos de Léo Pinheiro e agentes da OAS;
mensagens de texto ("chefe"/"madame"); documentos rasurados sobre o imóvel do Guarujá;
delações de Youssef, Cerveró e Paulo Roberto Costa.
**Estado:** os atos instrutórios da Lava Jato contra Lula foram **anulados**; as provas da
leniência da Odebrecht foram **anuladas** em 2023.

### 2.2 Flávio Bolsonaro (PL)

| Caso | Alegação (neutra) | Status hoje (out/2026) | Enum |
|---|---|---|---|
| "Rachadinha" na ALERJ | Servidores devolviam parte dos salários a Fabrício Queiroz | **Denunciado (MP-RJ, 2020) → denúncia arquivada 16/05/2022** pelo Órgão Especial do TJ-RJ a pedido do próprio MP-RJ, **sem julgamento de mérito**. Reabertura negada (Gilmar, fev/2025). | `denunciado_arquivado` |
| Fabrício Queiroz | Operador financeiro do suposto esquema | Preso 18/06/2020 (Operação Anjo, Atibaia). Denunciado em 2020 no mesmo processo de Flávio; **arquivado em 2022** pelos mesmos vícios. | `denunciado_arquivado` |
| "Carteirada" | — | **NÃO É CASO JURÍDICO AUTÔNOMO** — removido do painel. O termo tem origem editorial/partidária. O que é documentado (uso de foro por prerrogativa) não constitui caso separado no escopo deste painel. | `nao_confirmado` — **não usado** |

**Achados vinculantes:**
- Flávio **foi formalmente denunciado** e **nunca foi julgado no mérito**. Dizer
  "condenado" **ou** "absolvido" está incorreto.
- **STJ (5ª Turma, 09/11/2021):** anulou as decisões do juiz Flávio Itabaiana (incl.
  quebras de sigilo) por foro por prerrogativa.
- **STF (2ª Turma, nov/2021, Gilmar):** anulou **4 dos 5** RIFs do Coaf que embasaram a
  investigação ("investigação disfarçada"). A própria base probatória foi invalidada.
- 29/09/2026: Gilmar manteve quebra de sigilos de Danielle da Nóbrega numa **ação civil de
  improbidade (2023) que NÃO tem Flávio como alvo**.

**Impacto financeiro (só o que tem fonte):**
| Valor | Órgão | Objeto | Status | Fonte |
|---|---|---|---|---|
| **R$ 2.062.360,52** | MP-RJ (via quebra de sigilo) | 483 depósitos de 13 assessores na conta de Queiroz (2016-2017) | `estimado` | G1 — **nunca arredondar para "R$ 2,06 mi"** no painel (evita confusão com a cifra banida de R$ 2,6 mi). |
| **R$ 1.236.838,00** | Coaf/UIF (RIF) | movimentação atípica (01/2016-01/2017) | `reconhecido` | G1 |
| **R$ 324.774** | Coaf/UIF (RIF) | saques em espécie | `reconhecido` | G1 |
| **R$ 41.930** | Coaf/UIF (RIF) | cheques compensados | `reconhecido` | G1 |
| **R$ 24 mil** | Coaf/UIF (RIF) | cheque a Michelle Bolsonaro | `reconhecido` | G1 |

**NÃO USAR:** R$ 2,6 mi e estimativa do TCE-RJ — **nenhuma fonte encontrada**.

**Provas (artefatos):** RIFs do Coaf (**4 de 5 anulados** pelo STF 2021); quebras de sigilo
bancário/fiscal (**anuladas** pelo STJ 2021); contracheques; mensagens de WhatsApp/áudios
(Operação Intocáveis); folha de pagamento da ALERJ.
**Defesa de Flávio:** "Jamais existiu rachadinha. Jamais houve repasse de recursos para as
contas de Flávio Bolsonaro ou de suas empresas."

---

## 3. Tabela de fontes (consumidas diretamente de `eleicao-2026/escandalos/sources.tsv`)

O painel **não duplica** esta tabela. Os `source_id` abaixo são os mesmos do
`eleicao-2026/escandalos/sources.tsv`, validados pelos gates do subprojeto.

| id | Publisher | URL | Tipo | Tier |
|---|---|---|---|:--:|
| congressoemfoco_mensalao | Congresso em Foco | https://www.congressoemfoco.com.br/noticia/59918/stf-rejeita-novamente-inclusao-de-lula-no-mensalao | imprensa | 2 |
| stf_464261 | STF | https://portal.stf.jus.br/noticias/verNoticiaDetalhe.asp?idConteudo=464261 | oficial | 1 |
| agenciabrasil_stf_2021 | Agência Brasil (EBC) | https://agenciabrasil.ebc.com.br/justica/noticia/2021-04/stf-mantem-anulacao-das-condenacoes-de-lula | oficial | 1 |
| g1_moro_2021 | G1 | https://g1.globo.com/politica/noticia/2021/06/23/plenario-do-stf-reconhece-decisao-da-segunda-turma-que-declarou-moro-parcial-ao-condenar-lula.ghtml | imprensa | 2 |
| stf_468184 | STF | https://portal.stf.jus.br/noticias/verNoticiaDetalhe.asp?idConteudo=468184&ori=1 | oficial | 1 |
| g1_triplex_2022 | G1 | https://g1.globo.com/politica/noticia/2022/01/28/justica-do-df-arquiva-caso-do-triplex-do-guaruja-envolvendo-o-ex-presidente-lula.ghtml | imprensa | 2 |
| conjur_atibaia_2025 | ConJur | https://www.conjur.com.br/2025-jul-30/trf-1-nega-pedido-para-reabrir-acao-contra-lula-por-sitio-de-atibaia | imprensa | 2 |
| agenciabrasil_petrobras | Agência Brasil (EBC) | https://agenciabrasil.ebc.com.br/economia/noticia/2015-04/petrobras-teve-prejuizo-de-r-216-bilhoes-no-ano-passado | oficial(estatal) | 1 |
| ebc_odebrecht | Agência Brasil (EBC) | https://agenciabrasil.ebc.com.br/politica/noticia/2016-12/odebrecht-fecha-acordo-de-leniencia-com-eua-e-suica | oficial(estatal) | 1 |
| g1_denuncia_flavio_2020 | G1 | https://g1.globo.com/rj/rio-de-janeiro/noticia/2020/11/04/ministerio-publico-do-rj-denuncia-flavio-bolsonaro-por-organizacao-criminosa-peculato-e-lavagem-de-dinheiro.ghtml | imprensa | 2 |
| g1_tjrj_2022 | G1 | https://g1.globo.com/rj/rio-de-janeiro/noticia/2022/05/16/tj-rj-rejeita-denuncia-contra-flavio-bolsonaro-no-caso-das-rachadinhas.ghtml | imprensa | 2 |
| g1_stj_2021 | G1 | https://g1.globo.com/politica/noticia/2021/11/09/stj-anula-todas-as-decisoes-de-juiz-contra-flavio-bolsonaro-nas-rachadinhas.ghtml | imprensa | 2 |
| stf_rifs_flavio | STF | https://portal.stf.jus.br/noticias/verNoticiaDetalhe.asp?idConteudo=477496 | oficial | 1 |
| g1_jn_rifs | G1 / Jornal Nacional | https://g1.globo.com/jornal-nacional/noticia/2021/11/30/stf-mantem-foro-privilegiado-de-flavio-bolsonaro-e-anula-provas-no-caso-das-rachadinhas.ghtml | imprensa | 2 |
| g1_depositos_2019 | G1 | https://g1.globo.com/rj/rio-de-janeiro/noticia/2019/12/18/queiroz-recebeu-r-2-milhoes-em-483-depositos-de-assessores-ligados-a-flavio-bolsonaro-diz-mp.ghtml | imprensa | 2 |
| g1_coaf_2018 | G1 | https://g1.globo.com/rj/rio-de-janeiro/noticia/2018/12/06/coaf-aponta-que-ex-motorista-de-flavio-bolsonaro-movimentou-mais-de-r-12-milhao-em-operacoes-suspeitas.ghtml | imprensa | 2 |
| poder360_gilmar_2025 | Poder360 | https://www.poder360.com.br/poder-justica/gilmar-nega-pedido-para-reabrir-acao-contra-flavio-por-rachadinha/ | imprensa | 2 |
| g1_flavio_2026 | G1 | https://g1.globo.com/politica/noticia/2026/09/29/gilmar-mantem-quebra-de-sigilos-de-ex-assessora-de-flavio-bolsonaro-em-investigacao-sobre-rachadinha.ghtml | imprensa | 2 |
| bbc_queiroz_prisao | BBC News Brasil | https://www.bbc.com/portuguese/brasil-53093178 | imprensa | 2 |
| bbc_rachadinha_arquivo | BBC News Brasil | https://www.bbc.com/portuguese/brasil-63232593 | imprensa | 2 |
| conjur_arquivamento_2022 | ConJur | https://www.conjur.com.br/2022-mai-16/tj-rj-arquiva-denuncia-flavio-bolsonaro-rachadinha | imprensa | 2 |
| cartacapital_rachadinha_2025 | CartaCapital | https://www.cartacapital.com.br/politica/o-que-aconteceu-com-o-caso-da-rachadinha-de-flavio-bolsonaro-suposto-candidato-em-2026/ | imprensa | 2 |

**Bloqueios conhecidos:** `portal.stf.jus.br/noticias/...` serve SPA com pouco texto
estático (≈8,7 KB, sem o fragmento da citação). Por isso o corpus `eleicao-2026/escandalos/`
sempre **pareia** cada fonte STF com uma fonte imprensa de referência (G1, Agência Brasil,
ConJur), e o Gate 3 (`verify_citations.mjs`) passa se **qualquer** das fontes contiver a
citação.

## 4. Arquivos brutos esperados (`eleicao-2026/evidence/**/raw/`)

O `series_manifest.json` do Inc 1 deve apontar para estes arquivos (lista preliminar,
ajustável após inspeção do corpus):

| Série/KPI | Arquivo(s) bruto(s) | Agregação |
|---|---|---|
| Desemprego (`desoc`) | `evidence/economia/raw/bcb_sgs_desoc.json` | `last` mensal |
| Gini | `evidence/social/raw/ibge_gini.json` ou CSV | `last` anual |
| PIB | `evidence/economia/raw/bcb_sgs_pib.json` | trimestral → anualizado |
| PRODES desmatamento | `evidence/ambiente/raw/prodes_*.csv` | soma anual |
| DETER alertas | `evidence/ambiente/raw/deter_*.csv` | soma acumulada (parcial para 2026) |
| Geografia eleitoral | ZIP do TSE + CSVs `evidence/geografia/*.csv` | contagem de municípios |

> Se algum arquivo não existir no corpus, o manifesto deve declará-lo como
> `not_independently_verified` em vez de inventar valores.

---

## 5. Fontes de navegação (código do Yvy)

- `frontend/src/App.js` — registro de rota (lazy + `<Route>` em `<Suspense>`).
- `frontend/src/components/RiskIntelligence/RiskIntelligence.{js,css}` — melhor template
  de página feature-folder.
- `frontend/src/components/Dashboard.css` — primitivas reusáveis (`.stat-grid`, `.bar-*`).
- `frontend/src/components/Dashboard/CardShell.js` — 5 estados (não usado aqui).
- `frontend/src/utils/format.js` — formatadores existentes.
- `frontend/src/i18n.js` — dicionário `pt`/`en` espelhado.
- `backend-lua/yvy-server.c:252-262` — regra "path sem ponto → index.html".
- `.github/workflows/ci.yml:146-166` — job `frontend-build`.
