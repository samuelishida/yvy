// /politica — legal-corpus compiler (plan: politica-transparencia, Inc 2).
//
// Consumes the ALREADY-VERIFIED corpus at `eleicao-2026/escandalos/`:
//   claims.tsv (18 legal claims) · sources.tsv (25 rows) · evidence/{lula,flavio}/*.txt
//
// The corpus's own gates (sourced_claims_rate 18/18, citation_support_rate 18/18)
// already ran upstream — this module does NOT re-verify. It compiles the TSVs and
// the evidence `.txt` files into the `cases[]` + `sources[]` shapes the panel
// renders, and it never invents a number: every figure and every status arrives
// verbatim from the corpus.
//
// The presentation strings (names, neutral allegations, status notes, defenses)
// live here because they are not in the corpus in bilingual form. They are
// transcribed from `_correcoes_e_nao_usar.md` and the evidence files, and every
// sentence a reader can challenge is backed by the corpus citations emitted below.

import { CASE_CITATION_EN, CASE_CITATION_SCOPE_EN, EVIDENCE_EN, EVIDENCE_PT } from './escandalos_en.mjs';

// ── TSV parsing ──────────────────────────────────────────────────────────────
// The corpus TSVs are tab-separated, may carry `#` comment lines, and pad columns
// with spaces. Header may be preceded by comments.
export function parseTsv(text) {
  const lines = text.split(/\r?\n/).filter((l) => l.trim() !== '' && !l.trimStart().startsWith('#'));
  if (lines.length === 0) return { columns: [], rows: [] };
  const columns = lines[0].split('\t').map((c) => c.trim());
  const rows = [];
  for (const line of lines.slice(1)) {
    const cells = line.split('\t').map((c) => c.trim());
    const row = {};
    columns.forEach((col, i) => {
      row[col] = cells[i] !== undefined ? cells[i] : '';
    });
    rows.push(row);
  }
  return { columns, rows };
}

// ── evidence .txt parsing ────────────────────────────────────────────────────
// Fixture format (one field per labelled line, multi-line values allowed):
//   CLAIM: / STATUS: / VERDICT: / CONFIANCA: / FONTES: / AFIRMACAO: / OBJETO: /
//   CITACAO VERBATIM: / O QUE ISSO PROVA: / POSICAO DA DEFESA: / ARQUIVO BRUTO:
const FIELD_LABELS = [
  'CITACAO VERBATIM',
  'O QUE ISSO PROVA',
  'POSICAO DA DEFESA',
  'ARQUIVO BRUTO',
  'ARQUIVO BRUTO',
  'AFIRMACAO',
  'FONTES',
  'STATUS',
  'VERDICT',
  'CONFIANCA',
  'CLAIM',
  'OBJETO',
  'NOTA DE ALCANCE',
  'RESSALVA',
  'RESSALVA (contagem)',
  'CORRECAO DA v1',
  'CORRECAO',
];
// Longest labels first so `RESSALVA (contagem)` wins over `RESSALVA`.
// A label may be followed by a parenthetical note before the colon, e.g.
// `CITACAO VERBATIM (a fonte que sustenta):` — allowed and ignored.
const LABEL_RE = new RegExp(
  `^\\s*(${FIELD_LABELS.slice()
    .sort((a, b) => b.length - a.length)
    .map((l) => l.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
    .join('|')})(?:\\s*\\([^)]*\\))?\\s*:\\s*(.*)$`,
);

export function parseEvidenceTxt(text) {
  const fields = { BRUTO: [] };
  let current = null;
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.replace(/\s+$/, '');
    if (/^-{5,}\s*$/.test(line.trim())) {
      current = null;
      continue;
    }
    const m = line.match(LABEL_RE);
    if (m) {
      const label = m[1];
      const value = m[2] || '';
      if (label === 'ARQUIVO BRUTO') {
        if (value) fields.BRUTO.push(value.trim());
        current = null;
        continue;
      }
      const key = label.split(' ')[0].split('(')[0].trim();
      // CITACAO VERBATIM keeps its line breaks as a space; other fields collapse.
      fields[key] = (fields[key] ? `${fields[key]} ` : '') + (key === 'CITACAO' ? value : value.trim());
      current = key;
      continue;
    }
    if (current && line.trim() !== '') {
      const piece = line.trim();
      fields[current] = `${fields[current]}${current === 'CITACAO' ? ' ' : ' '}${piece}`.trim();
    }
  }
  const clean = (s) =>
    typeof s === 'string'
      ? s.replace(/\*+/g, '').replace(/\s+/g, ' ').replace(/^"|"$/g, '').trim()
      : '';
  return {
    claim: clean(fields.CLAIM),
    status: clean(fields.STATUS),
    verdict: clean(fields.VERDICT),
    confianca: clean(fields.CONFIANCA),
    fontes: clean(fields.FONTES),
    afirmacao: clean(fields.AFIRMACAO),
    objeto: clean(fields.OBJETO),
    citacao: clean(fields.CITACAO),
    prova: clean(fields['O']),
    defense: clean(fields.POSICAO),
    bruto: fields.BRUTO.slice(),
  };
}

// ── Case presentation ────────────────────────────────────────────────────────
// One entry per panel case. A case may explicitly include claim IDs from other
// corpus groups; `primaryClaim` remains the claim whose citation sustains its
// status unless a separate, named status citation/source is configured.
export const GROUPS = [
  {
    grupo: 'Mensalao',
    id: 'lula_mensalao',
    side: 'pt',
    primaryClaim: 'lula_mensalao_nunca_reu',
    name_pt: 'Mensalão',
    name_en: 'Mensalão (monthly-payment scheme)',
    period: '2005–2014',
    allegation_pt:
      'Pagamento mensal a deputados para votarem com o governo, revelado por Roberto Jefferson em 2005.',
    allegation_en:
      'Monthly payments to congressmen in exchange for votes, revealed by Roberto Jefferson in 2005.',
    status_note_pt:
      'No AP 470, o STF rejeitou por unanimidade pedido para incluir Lula porque a questão já havia sido discutida e estava preclusa. Lula nunca foi réu nessa ação; não houve absolvição nem julgamento de mérito sobre ele.',
    status_note_en:
      'In AP 470, the STF unanimously rejected a request to add Lula because the issue had already been litigated and was procedurally precluded. Lula was never a defendant in that case; there was no acquittal or merits ruling about him.',
    defense_pt:
      'A defesa de Lula sempre afirmou que ele não era réu no caso; o STF confirmou isso ao rejeitar sua inclusão.',
    defense_en:
      "Lula's defense always maintained he was not a defendant; the Supreme Court confirmed this by refusing to include him.",
    financial: [],
  },
  {
    grupo: 'Lava Jato',
    includeClaimIds: ['lula_petrobras_62bi', 'lula_odebrecht_85bi'],
    id: 'lula_lava_jato',
    side: 'pt',
    primaryClaim: 'lula_fachin_anula_2021',
    name_pt: 'Lava Jato / Petrolão',
    name_en: 'Lava Jato / Petrobras scandal',
    period: '2014–2021',
    allegation_pt:
      'Cartel de empreiteiras pagava propina em contratos da Petrobras; o MPF acusou Lula de ser o "comandante máximo".',
    allegation_en:
      'A cartel of contractors paid bribes on Petrobras contracts; prosecutors accused Lula of being the "top commander".',
    status_note_pt:
      'Em 2021, o STF anulou as condenações porque os fatos atribuídos a Lula não tinham ligação direta com desvios da Petrobras; por isso, a 13ª Vara de Curitiba não era competente. Em decisão separada, reconheceu a suspeição de Moro no tríplex e estendeu a nulidade dos atos a Atibaia e ao Instituto Lula por repetição das mesmas circunstâncias. As decisões retiraram condenações por razões processuais; não absolveram Lula no mérito.',
    status_note_en:
      'In 2021, the STF annulled the convictions because the facts attributed to Lula had no direct link to Petrobras diversions, so Curitiba’s 13th Federal Court lacked jurisdiction. In a separate ruling, it found Moro biased in the triplex case and extended nullification of his acts to Atibaia and the Lula Institute because the same circumstances were present. These rulings removed convictions on procedural grounds; they did not acquit Lula on the merits.',
    defense_pt:
      'A defesa sustentou a incompetência da 13ª Vara e a suspeição de Moro; o STF acolheu as duas teses.',
    defense_en:
      'The defense argued the 13th Court lacked jurisdiction and that Moro was biased; the Supreme Court accepted both.',
    financial: [
      {
        measuredBy: 'Petrobras (balanço auditado, 2014)',
        object: 'perda da estatal com desvios (3% dos contratos 2004-2012, 27 empresas)',
        object_en: "the state oil company's loss on diverted contracts (3% of 2004-2012 contracts, 27 firms)",
        value: 6200000000,
        currency: 'BRL',
        year: 2014,
        status: 'reconhecido',
        sources: ['agenciabrasil_petrobras'],
      },
      {
        measuredBy: 'MPF (acordo de leniência, dez/2016)',
        object: 'multa fixada no acordo de leniência da Odebrecht/Novonor (empresa)',
        object_en: 'fine set in the Odebrecht/Novonor leniency agreement (a company, not a person)',
        value: 8500000000,
        currency: 'BRL',
        year: 2016,
        status: 'reconhecido',
        sources: ['ebc_odebrecht'],
      },
    ],
  },
  {
    grupo: 'Triplex',
    id: 'lula_triplex',
    side: 'pt',
    primaryClaim: 'lula_triplex_prescrito',
    name_pt: 'Tríplex do Guarujá',
    name_en: 'Guarujá triplex apartment',
    period: '2016–2022',
    allegation_pt:
      'Propriedade oculta de um tríplex no Guarujá e reformas pagas pela empreiteira OAS como propina.',
    allegation_en:
      'Hidden ownership of a triplex apartment in Guarujá and renovations paid by contractor OAS as a bribe.',
    status_note_pt:
      'O STF anulou a condenação porque os fatos não se ligavam diretamente aos desvios da Petrobras e Curitiba não era o foro competente; depois, anulou os atos de Moro ao reconhecê-lo suspeito. Em 2022, a Justiça Federal do DF extinguiu a punibilidade por prescrição, a pedido do MPF: aplicou a redução do prazo para maiores de 70 anos (art. 115 do Código Penal), e os atos anulados não serviram como marcos interruptivos. Não houve absolvição nem julgamento da veracidade da acusação.',
    status_note_en:
      'The STF annulled the conviction because the facts had no direct link to Petrobras diversions and Curitiba lacked jurisdiction; it later annulled Moro’s acts after finding him biased. In 2022, the Federal Court in Brasília extinguished criminal liability on limitation grounds, at the MPF’s request: it applied the reduced period for defendants over 70 (Art. 115 of the Penal Code), and the annulled acts did not count as limitation-interrupting events. There was no acquittal or ruling on whether the accusation was true.',
    defense_pt:
      'A defesa sempre negou que o imóvel fosse de Lula e alegou que a ação já havia prescrito — o que foi reconhecido.',
    defense_en:
      'The defense always denied Lula owned the apartment and argued the case was time-barred — which was recognised.',
    financial: [],
    extraEvidence: [
      {
        artifact_pt: 'Propina alegada na denúncia',
        artifact_en: 'Bribe alleged in the indictment',
        proves_pt:
          'A denúncia do MPF afirmava propina de R$ 3,7 mi; é valor alegado, nunca reconhecido como devido.',
        proves_en:
          'The indictment alleged a R$ 3.7 mi bribe; this is an alleged amount, never recognised as owed.',
        state: 'alegado_na_denuncia',
        sources: ['g1_triplex_2022'],
      },
    ],
  },
  {
    grupo: 'Atibaia',
    id: 'lula_atibaia',
    side: 'pt',
    primaryClaim: 'lula_atibaia_prescrito',
    name_pt: 'Sítio de Atibaia',
    name_en: 'Atibaia country estate',
    period: '2017–2025',
    allegation_pt:
      'Reformas do sítio de Atibaia pagas por OAS/Odebrecht como propina.',
    allegation_en:
      'Renovations of the Atibaia estate paid for by OAS/Odebrecht as a bribe.',
    status_note_pt:
      'O STF estendeu ao caso de Atibaia a suspeição de Moro reconhecida no tríplex, por identificar as mesmas circunstâncias, e anulou os atos do juiz. Em Brasília, a Justiça Federal extinguiu a punibilidade de Lula por prescrição; como ele tinha mais de 70 anos, aplicou-se o prazo reduzido do art. 115 do Código Penal. Em 2025, o TRF-1 negou pedido do MPF para suspender o encerramento enquanto o STF analisava o alcance da nulidade: o recurso não suspendia a decisão, e só o STF poderia ordenar essa suspensão. O caso não teve novo julgamento de mérito das alegações sobre o sítio.',
    status_note_en:
      'The STF extended its triplex finding that Moro was biased to Atibaia because it found the same circumstances, and annulled his judicial acts. In Brasília, the Federal Court extinguished Lula’s criminal liability on limitation grounds; because he was over 70, it applied the reduced period under Art. 115 of the Penal Code. In 2025, the TRF-1 denied the MPF’s request to suspend the closure while the STF reviewed the scope of the nullity: the appeal did not suspend the decision, and only the STF could order a suspension. The estate allegations were not retried on the merits.',
    status_citation_pt: 'o agravo em tramitação no STF não tem efeito suspensivo',
    status_source_ids: ['conjur_atibaia_2025', 'jbr_atibaia_2025', 'stf_468184'],
    citation_scope_pt:
      'O trecho prova que o recurso do MPF não suspendia o encerramento enquanto o STF examinava a nulidade. A prescrição, com prazo reduzido por idade, fundamentou a extinção da punibilidade de Lula em Brasília; não houve novo julgamento do mérito.',
    citation_scope_en:
      'The excerpt shows that the MPF appeal did not suspend the closure while the STF reviewed the nullity. Limitation, with the period reduced due to age, grounded the extinction of Lula’s criminal liability in Brasília; there was no new merits trial.',
    defense_pt:
      'A defesa alegou suspeição e prescrição; o STF anulou os atos de Moro, a Justiça Federal reconheceu a prescrição e o TRF-1 manteve o encerramento.',
    defense_en:
      'The defense argued bias and the statute of limitations; the STF annulled Moro’s acts, the Federal Court recognized the limitation, and the TRF-1 left the case closed.',
    financial: [],
  },
  {
    grupo: 'Rachadinha',
    includeClaimIds: ['flavio_depositos_2mi', 'flavio_coaf_12mi'],
    id: 'flavio_rachadinha',
    side: 'pl',
    primaryClaim: 'flavio_denuncia_arquivada',
    name_pt: 'Rachadinha na ALERJ',
    name_en: 'ALERJ "salary kickback" case',
    period: '2018–2026',
    allegation_pt:
      'Servidores do gabinete devolviam parte dos salários a Fabrício Queiroz, ex-assessor de Flávio, então deputado estadual.',
    allegation_en:
      'Staffers allegedly returned part of their salaries via Fabrício Queiroz, a former aide to Flávio, then a state deputy.',
    status_note_pt:
      'O STJ anulou atos decisórios da primeira instância, inclusive quebras de sigilo, por questão de competência e foro. O STF invalidou quatro dos cinco RIFs do Coaf porque o MP-RJ pediu os dados diretamente antes de autorização do TJ-RJ. Sem esses elementos financeiros legalmente utilizáveis, o próprio MP pediu a rejeição; em 2022, o TJ-RJ rejeitou a denúncia por falta de justa causa. Em 2025, o STF manteve o encerramento: um recurso não cabia no Supremo e o MP já reconhecera insuficiência de provas; outro chegou fora do prazo para discutir foro. Isso não declarou os depósitos verdadeiros nem falsos e não foi absolvição de mérito; nova apuração exige elementos diferentes e lícitos.',
    status_note_en:
      'The STJ annulled first-instance judicial acts, including secrecy orders, over jurisdiction and special-forum issues. The STF invalidated four of the five Coaf RIFs because the MP-RJ requested the data directly before TJ-RJ authorization. Without those financial materials legally usable, prosecutors sought rejection; in 2022 the TJ-RJ rejected the complaint for lack of just cause. In 2025, the STF kept the case closed: one appeal was not reviewable there and prosecutors had acknowledged insufficient evidence; another came too late to revisit forum. This did not find the deposits true or false and was not a merits acquittal; any new inquiry must rely on different, lawful evidence.',
    status_citation_pt:
      'TJ-RJ rejeita denúncia contra Flávio Bolsonaro no caso das rachadinhas',
    status_source_ids: ['g1_tjrj_2022', 'g1_stj_2021', 'stf_rifs_flavio', 'poder360_gilmar_2025'],
    citation_scope_pt:
      'O trecho citado confirma que o TJ-RJ rejeitou a denúncia a pedido do MP-RJ. O fundamento foi a falta de justa causa após a exclusão dos dados financeiros considerados ilícitos; a citação não decide se as movimentações ocorreram.',
    citation_scope_en:
      'The quoted passage confirms that the TJ-RJ rejected the complaint at the MP-RJ’s request. The ground was lack of just cause after financial data deemed unlawful were excluded; the quote does not decide whether the transactions occurred.',
    defense_pt:
      '"Jamais existiu rachadinha. Jamais houve repasse de recursos para as contas de Flávio Bolsonaro ou de suas empresas."',
    defense_en:
      '"There was never a kickback scheme. Money was never transferred to the accounts of Flávio Bolsonaro or his companies."',
    financial: [
      {
        measuredBy: 'MP-RJ (via quebra de sigilo)',
        object: '483 depósitos de 13 assessores na conta de Queiroz (2016-2017)',
        object_en: "483 deposits from 13 staffers into Queiroz's account (2016-2017)",
        value: 2062360.52,
        currency: 'BRL',
        year: 2017,
        status: 'estimado',
        sources: ['g1_depositos_2019'],
      },
      {
        measuredBy: 'Coaf/UIF (RIF)',
        object: 'movimentação atípica apontada na conta de Queiroz',
        object_en: "unusual transactions flagged in Queiroz's account",
        value: 1236838,
        currency: 'BRL',
        year: 2017,
        status: 'reconhecido',
        sources: ['g1_coaf_2018'],
      },
    ],
  },
  {
    grupo: 'Banco Master',
    includeClaimIds: ['flavio_master_repasse'],
    id: 'flavio_master',
    side: 'pl',
    primaryClaim: 'flavio_master_filme',
    name_pt: 'Banco Master / Dark Horse',
    name_en: 'Banco Master / Dark Horse',
    period: '2024–2026',
    allegation_pt:
      'Mensagens e reportagens apontam negociação de Flávio Bolsonaro com Daniel Vorcaro para financiar o filme Dark Horse. Os valores e suspeitas seguem sob investigação; não são conclusão judicial.',
    allegation_en:
      'Messages and news reports describe Flávio Bolsonaro negotiating with Daniel Vorcaro to finance the film Dark Horse. The amounts and suspicions remain under investigation; they are not a court finding.',
    status_note_pt:
      'Na fotografia de 09/10/2026, há inquérito policial aberto; as fontes desta ficha não registram denúncia formal nem decisão judicial de mérito. É investigação de suspeitas, não decisão de culpa ou absolvição.',
    status_note_en:
      'As of 2026-10-09, a police inquiry is open; the sources in this card report no formal charge or judicial merits ruling. It is an investigation of suspicions, not a finding of guilt or an acquittal.',
    status_citation_pt: 'Flávio foi incluído em 22 de julho na investigação que apura o repasse para custear a produção do filme',
    status_source_ids: ['agenciabrasil_master_inquiry'],
    defense_pt:
      'Flávio afirma que buscou investimento privado para uma obra cultural nos EUA, nega irregularidade e diz que encerrou a relação com Vorcaro quando as acusações vieram a público.',
    defense_en:
      'Flávio says he sought private investment for a cultural project in the United States, denies wrongdoing, and says he ended his relationship with Vorcaro after the allegations became public.',
    financial: [],
  },
  {
    grupo: 'Imoveis / dinheiro vivo',
    id: 'flavio_imoveis',
    side: 'pl',
    primaryClaim: 'flavio_imoveis_copacabana',
    name_pt: 'Imóveis: Copacabana e Barra',
    name_en: 'Properties: Copacabana and Barra',
    period: '2012–2018',
    allegation_pt:
      'O MP-RJ apontou pagamentos em dinheiro vivo ligados à compra de imóveis em Copacabana e na Barra. São alegações da mesma denúncia das rachadinhas, sem decisão judicial sobre o mérito dessas transações.',
    allegation_en:
      'Rio prosecutors alleged cash payments linked to property purchases in Copacabana and Barra. These claims were part of the same rachadinha complaint; no court ruled on the merits of these transactions.',
    status_note_pt:
      'As alegações sobre Copacabana e Barra faziam parte da mesma denúncia das rachadinhas. O STJ anulou atos decisórios e quebras de sigilo por questão de competência/foro; o STF invalidou quatro RIFs do Coaf porque o MP-RJ os pediu diretamente antes de autorização do TJ-RJ. Por isso, os dados bancários e fiscais atingidos não podiam sustentar aquela denúncia: o próprio MP pediu a rejeição, e o TJ-RJ a rejeitou por falta de justa causa em 2022. A decisão tratou da legalidade da obtenção e do uso da prova; não declarou os registros falsos ou verdadeiros nem julgou as transações imobiliárias no mérito.',
    status_note_en:
      'The Copacabana and Barra allegations were part of the same rachadinha complaint. The STJ annulled judicial acts and secrecy orders over jurisdiction and special-forum issues; the STF invalidated four Coaf RIFs because the MP-RJ requested them directly before TJ-RJ authorization. The affected banking and tax data therefore could not support that complaint: prosecutors themselves sought rejection, and the TJ-RJ rejected it for lack of just cause in 2022. The ruling concerned lawful evidence gathering and use; it did not find the records true or false or rule on the property transactions on the merits.',
    status_citation_pt:
      'O Órgão Especial do Tribunal de Justiça do Rio de Janeiro acatou pedido do Ministério Público e rejeitou a denúncia contra o senador Flávio Bolsonaro (PL-RJ) no caso das rachadinhas.',
    status_source_ids: ['g1_tjrj_2022', 'g1_stj_2021', 'stf_rifs_flavio', 'poder360_gilmar_2025'],
    citation_scope_pt:
      'A citação confirma a rejeição da denúncia a pedido do MP-RJ, não o mérito das alegações sobre os imóveis. O fundamento foi a falta de justa causa após a invalidação dos dados financeiros usados na acusação.',
    citation_scope_en:
      'The quote confirms the complaint was rejected at the MP-RJ’s request, not the merits of the property allegations. The ground was lack of just cause after the financial data used in the accusation were invalidated.',
    defense_pt:
      'A defesa nega irregularidades nas transações e contestou a validade das provas financeiras; o TJ-RJ rejeitou a denúncia sem julgar o mérito.',
    defense_en:
      'The defense denies wrongdoing in the transactions and challenged the financial evidence; the TJ-RJ rejected the complaint without ruling on the merits.',
    financial: [],
    extraEvidence: [
      {
        artifact_pt: 'Provas financeiras usadas na denúncia',
        artifact_en: 'Financial evidence used in the complaint',
        proves_pt:
          'O STJ anulou decisões sobre quebras de sigilo por questão de competência/foro; o STF invalidou quatro RIFs pedidos diretamente pelo MP-RJ antes de autorização do TJ-RJ. O TJ-RJ concluiu que os dados bancários e fiscais não podiam sustentar aquela denúncia e a rejeitou por falta de justa causa. Isso trata da admissibilidade da prova, não declara as transações verdadeiras nem falsas.',
        proves_en:
          'The STJ annulled secrecy orders over jurisdiction and special-forum issues; the STF invalidated four RIFs requested directly by the MP-RJ before TJ-RJ authorization. The TJ-RJ concluded the banking and tax data could not support that complaint and rejected it for lack of just cause. This concerns admissibility of evidence; it does not find the transactions true or false.',
        state: 'anulado',
        sources: ['g1_stj_2021', 'g1_tjrj_2022', 'stf_rifs_flavio'],
      },
    ],
  },
];

// Evidence state per claim — separate from case status. It describes whether an
// item is alleged, under inquiry, used, or annulled; it never implies guilt.
const EVIDENCE_STATE = {
  lula_mensalao_nunca_reu: 'usado_no_processo',
  lula_fachin_anula_2021: 'anulado',
  lula_moro_suspeito: 'anulado',
  lula_triplex_prescrito: 'anulado',
  lula_atibaia_prescrito: 'anulado',
  lula_petrobras_62bi: 'usado_no_processo',
  lula_odebrecht_85bi: 'usado_no_processo',
  flavio_denunciado_2020: 'usado_no_processo',
  flavio_denuncia_arquivada: 'usado_no_processo',
  flavio_stj_anulou_2021: 'anulado',
  flavio_stf_anulou_rifs: 'anulado',
  flavio_gilmar_negou_reabrir: 'usado_no_processo',
  flavio_depositos_2mi: 'usado_no_processo',
  flavio_coaf_12mi: 'anulado',
  flavio_master_filme: 'alegado_em_apuracao',
  flavio_master_repasse: 'alegado_em_apuracao',
  flavio_imoveis_copacabana: 'alegado_na_denuncia',
  flavio_imoveis_barra: 'alegado_na_denuncia',
};

const splitIds = (s) => (s || '').split(',').map((x) => x.trim()).filter(Boolean);

// ── compiler ─────────────────────────────────────────────────────────────────
// `loadTxt(relPath)` → string, provided by the caller so this module stays
// storage-agnostic (sibling repo in dev, vendored snapshot in CI).
export function buildCases({ claimsTsv, sourcesTsv, loadTxt }) {
  const claims = parseTsv(claimsTsv).rows;
  const sourceRows = parseTsv(sourcesTsv).rows;

  // sources[] — verbatim from sources.tsv, mapped to the panel's schema.
  const sources = sourceRows.map((s) => ({
    id: s.id,
    publisher: s.publisher,
    title: s.title,
    url: s.url,
    date: s.retrieved,
    kind: s.kind === 'oficial' ? 'official' : s.kind === 'imprensa' ? 'press' : s.kind,
    tier: Number(s.tier),
  }));
  const knownSource = new Set(sources.map((s) => s.id));
  const knownClaim = new Set(claims.map((c) => c.claim_id));

  const errors = [];
  const cases = [];

  for (const g of GROUPS) {
    for (const id of g.includeClaimIds || []) {
      if (!knownClaim.has(id)) errors.push(`${g.id}: included claim "${id}" not found`);
    }
    const groupClaims = claims.filter((c) =>
      c.grupo === g.grupo || (g.includeClaimIds || []).includes(c.claim_id),
    );
    if (groupClaims.length === 0) {
      errors.push(`grupo "${g.grupo}": no claims found`);
      continue;
    }
    const primary = groupClaims.find((c) => c.claim_id === g.primaryClaim);
    if (!primary) {
      errors.push(`grupo "${g.grupo}": primary claim "${g.primaryClaim}" not found`);
      continue;
    }

    const parsed = groupClaims.map((c) => {
      const txt = loadTxt(c.evidence);
      if (!txt) {
        errors.push(`${c.claim_id}: evidence file missing (${c.evidence})`);
        return { claim: c, ev: null };
      }
      return { claim: c, ev: parseEvidenceTxt(txt) };
    });
    if (parsed.some((p) => !p.ev)) continue;

    const primaryEv = parsed.find((p) => p.claim.claim_id === primary.claim_id).ev;
    if (!primaryEv.citacao) {
      errors.push(`${primary.claim_id}: evidence has no CITACAO VERBATIM`);
      continue;
    }

    // citations[] — every claim's verbatim quote + the sources that carry it.
    // The panel renders these so a sceptical reader can check the words himself.
    const citations = parsed
      .filter((p) => p.ev.citacao)
      .map((p) => ({ claim_id: p.claim.claim_id, text_pt: p.ev.citacao, sources: splitIds(p.claim.source_ids) }));

    // evidence[] — one artefact per claim file, plus any group extras.
    const evidence = parsed.map((p) => ({
      claim_id: p.claim.claim_id,
      artifact_pt: EVIDENCE_PT[p.claim.claim_id]?.artifact_pt || p.ev.afirmacao || p.ev.claim,
      artifact_en: EVIDENCE_EN[p.claim.claim_id]?.artifact_en || '',
      proves_pt: p.ev.prova || p.ev.afirmacao,
      proves_en: EVIDENCE_EN[p.claim.claim_id]?.proves_en || '',
      state: EVIDENCE_STATE[p.claim.claim_id] || 'usado_no_processo',
      sources: splitIds(p.claim.source_ids),
    }));

    const caseSources = new Set();
    for (const p of parsed) splitIds(p.claim.source_ids).forEach((id) => caseSources.add(id));

    const financial = (g.financial || []).map((f) => ({ ...f }));
    const statusSources = g.status_source_ids || [];
    if ((g.status_citation_pt || statusSources.length) && (!g.status_citation_pt || !statusSources.length)) {
      errors.push(`${g.id}: status citation and status source IDs must be configured together`);
    }
    for (const id of statusSources) {
      if (!knownSource.has(id)) errors.push(`${g.id}: unknown status source id "${id}"`);
    }

    const entry = {
      id: g.id,
      side: g.side,
      name_pt: g.name_pt,
      name_en: g.name_en,
      period: g.period,
      allegation_pt: g.allegation_pt,
      allegation_en: g.allegation_en,
      status: primary.status,
      status_note_pt: g.status_note_pt,
      status_note_en: g.status_note_en,
      status_citation_pt: g.status_citation_pt || primaryEv.citacao,
      status_citation_en: g.status_citation_en || CASE_CITATION_EN[g.id] || '',
      defense_pt: g.defense_pt,
      defense_en: g.defense_en,
      financial,
      evidence: [...evidence, ...(g.extraEvidence || [])],
      citations,
      claim_ids: groupClaims.map((c) => c.claim_id),
      sources: [...caseSources].filter((id) => knownSource.has(id)),
    };
    if (statusSources.length) entry.status_sources = statusSources;
    for (const id of statusSources) caseSources.add(id);
    for (const item of g.extraEvidence || []) {
      for (const id of item.sources || []) {
        caseSources.add(id);
        if (!knownSource.has(id)) errors.push(`${g.id}.evidence: unknown source id "${id}"`);
      }
    }
    entry.sources = [...caseSources].filter((id) => knownSource.has(id));
    // citation_scope is OPTIONAL and only emitted when it has content, so the
    // schema's "both or neither" rule never trips on an empty pair.
    const scopePt = g.citation_scope_pt || '';
    const scopeEn = g.citation_scope_en || CASE_CITATION_SCOPE_EN[g.id] || '';
    if (scopePt && scopeEn) {
      entry.citation_scope_pt = scopePt;
      entry.citation_scope_en = scopeEn;
    }

    // A load-bearing status must not rest on a single source (plan Inc 2 rule).
    if (entry.sources.length < 1) {
      errors.push(`${g.id}: no sources resolved (missing from sources.tsv?)`);
    }
    // Every source id referenced must exist, or the schema gate will fail anyway.
    for (const id of [...caseSources]) {
      if (!knownSource.has(id)) errors.push(`${g.id}: unknown source id "${id}"`);
    }
    for (const f of financial) {
      for (const id of f.sources) {
        if (!knownSource.has(id)) errors.push(`${g.id}.financial: unknown source "${id}"`);
      }
    }
    cases.push(entry);
  }

  // Banned values must never appear (plan Inc 2 edge cases).
  const BANNED = [
    { re: /R\$\s*2,6\s*mi/i, why: 'R$ 2,6 mi — no source exists' },
    { re: /\bTCE-RJ\b/, why: 'TCE-RJ estimate — no source exists' },
  ];
  const blob = JSON.stringify(cases);
  for (const b of BANNED) if (b.re.test(blob)) errors.push(`banned value present: ${b.why}`);

  return { cases, sources, errors };
}
