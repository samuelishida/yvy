// /politica — English layer for the legal corpus (plan: politica-transparencia, Inc 2).
//
// The corpus at `eleicao-2026/escandalos/` is Portuguese-only. The schema requires
// `*_en` for every case, citation, evidence artefact and status note, so this file
// supplies the English mirror. Keys are the claim ids the corpus already uses —
// nothing here invents a fact, it translates the corpus text.
//
// Status citations are translated so an English reader can read the same sentence
// a Portuguese reader sees. The verbatim Portuguese source text remains the one
// Gate 3 fetches and matches.

export const CASE_CITATION_EN = {
  lula_mensalao:
    'The justices of the Federal Supreme Court (STF) once again denied the inclusion of former president Luiz Inácio Lula da Silva in the mensalão trial.',
  lula_lava_jato:
    'By 8 votes to 3, the Federal Supreme Court (STF) decided today (15) to uphold the ruling that annulled the convictions of former president Luiz Inácio Lula da Silva.',
  lula_triplex:
    'In the ruling, the judge acknowledges that the statute of limitations had expired, since the deadline for defendants over 70 is halved.',
  lula_atibaia:
    'The TRF-1 rejected the MPF’s request to suspend the Atibaia case while the STF reviewed the scope of the nullity; the pending appeal had no suspensive effect.',
  flavio_rachadinha:
    "The Special Panel of the Court of Justice of Rio de Janeiro granted the prosecutors' request and rejected the charges against senator Flávio Bolsonaro (PL-RJ) in the 'rachadinha' case.",
  flavio_master:
    'Flávio was included on July 22 in the investigation into the transfer to fund production of the film.',
  flavio_imoveis:
    'The Special Panel of the Court of Justice of Rio de Janeiro accepted the Public Prosecutor’s request and rejected the complaint against senator Flávio Bolsonaro (PL-RJ) in the rachadinha case.',
};

// evidence claim_id → { artifact_en, proves_en }
export const CASE_CITATION_SCOPE_EN = {
  lula_atibaia:
    'The excerpt shows that the MPF appeal did not suspend the closure while the STF reviewed the nullity. Limitation, with the period reduced due to age, grounded the extinction of Lula’s criminal liability in Brasília; there was no new merits trial.',
};

// Optional PT overrides, for the rare corpus artifact whose wording the panel must
// NOT reproduce verbatim (e.g. an unsupported count). Keyed by claim id.
export const EVIDENCE_PT = {
  lula_mensalao_nunca_reu: {
    artifact_pt:
      'Lula nunca foi réu no Mensalão (AP 470); o STF rejeitou duas vezes sua inclusão. A ação foi encerrada sem que ele fosse réu — o painel não afirma um número de condenados do caso.',
  },
  lula_fachin_anula_2021: {
    artifact_pt:
      'Fachin anulou as decisões da 13ª Vara de Curitiba em 08/03/2021 porque os casos de Lula não tinham ligação direta com desvios da Petrobras e não cabiam naquele juízo; o Plenário confirmou em 15/04/2021 (8×3). A nulidade foi processual, não absolvição de mérito.',
    proves_pt:
      'Sustenta a anulação por incompetência da 13ª Vara, pois os fatos atribuídos a Lula não tinham ligação direta com os desvios da Petrobras; o Plenário confirmou por 8×3.',
  },
  lula_atibaia_prescrito: {
    artifact_pt:
      'Em 2025, o TRF-1 rejeitou o pedido do MPF para suspender o encerramento enquanto o STF analisava o alcance da nulidade; o recurso não tinha efeito suspensivo. Em Brasília, a punibilidade de Lula havia sido extinta por prescrição, com redução do prazo para maiores de 70 anos. Não houve novo julgamento de mérito das alegações sobre o sítio.',
    proves_pt:
      'Sustenta a negativa de suspensão e seus fundamentos; não afirma que o TRF-1 tenha julgado novamente a veracidade das acusações.',
  },
  flavio_denuncia_arquivada: {
    artifact_pt:
      'Em 2022, o TJ-RJ rejeitou a denúncia a pedido do MP-RJ por falta de justa causa: após STJ e STF invalidarem dados bancários, fiscais e RIFs usados na acusação, o MP afirmou que eles não podiam sustentá-la. Foi encerramento processual, sem absolvição ou julgamento de mérito.',
    proves_pt:
      'Sustenta a rejeição por falta de justa causa após a invalidação dos elementos financeiros; não decide se as movimentações ocorreram.',
  },
  flavio_master_filme: {
    artifact_pt:
      'Mensagens e reportagens indicam negociação de R$ 134 milhões (US$ 24 milhões) para financiar o filme; esse é o total negociado, não o valor transferido.',
  },
  flavio_master_repasse: {
    artifact_pt:
      'Segundo a reportagem, Vorcaro transferiu cerca de R$ 61 milhões a um fundo ligado à produção do filme; o valor não é atribuído à conta pessoal de Flávio.',
  },
  flavio_imoveis_copacabana: {
    artifact_pt:
      'O MP-RJ alegou que R$ 638.400 em dinheiro vivo foram depositados na conta de um corretor no dia da compra de dois apartamentos em Copacabana.',
  },
  flavio_imoveis_barra: {
    artifact_pt:
      'O MP-RJ alegou que R$ 295,5 mil em 146 depósitos de origem desconhecida foram usados para pagar parcelas de um apartamento na Barra.',
  },
  flavio_stj_anulou_2021: {
    artifact_pt:
      'Em 09/11/2021, o STJ anulou atos decisórios do juiz de primeira instância por questão de competência e foro de Flávio; a anulação alcançou ordens de quebra de sigilos bancário e fiscal. Isso invalida atos de obtenção/uso das provas atingidas, não demonstra que os registros financeiros eram falsos.',
    proves_pt:
      'Sustenta que a anulação por competência/foro alcançou decisões e quebras de sigilo do caso; não julga a veracidade das movimentações.',
  },
  flavio_stf_anulou_rifs: {
    artifact_pt:
      'Em 30/11/2021, o STF anulou quatro dos cinco RIFs do Coaf usados na investigação. O fundamento foi o pedido direto do MP-RJ ao Coaf antes de autorização do TJ-RJ para investigar o deputado estadual; a decisão tratou da legalidade do compartilhamento, não da veracidade das movimentações.',
    proves_pt:
      'Sustenta a anulação de quatro RIFs por compartilhamento anterior à autorização do TJ-RJ, não uma constatação de que os lançamentos eram falsos.',
  },
  flavio_gilmar_negou_reabrir: {
    artifact_pt:
      'Em fevereiro de 2025, o STF rejeitou dois recursos do MP-RJ: um não cabia no Supremo por discutir lei infraconstitucional e porque o próprio MP reconhecera falta de prova suficiente; o outro foi apresentado fora do prazo sobre o foro. O encerramento da denúncia permaneceu sem julgamento do mérito; nova apuração pode usar elementos diferentes e lícitos.',
    proves_pt:
      'Sustenta os fundamentos processuais das decisões de 2025, não uma conclusão sobre a verdade das acusações.',
  },
};

export const EVIDENCE_EN = {
  lula_mensalao_nunca_reu: {
    artifact_en:
      'Lula was never a defendant in the mensalão (AP 470); the STF twice rejected his inclusion. The case closed without him ever being a defendant — the panel does not assert a count of those convicted.',
    proves_en:
      'Supports that the STF refused to add Lula as a defendant; the refusal was reiterated.',
  },
  lula_fachin_anula_2021: {
    artifact_en:
      'Justice Fachin annulled the decisions from Curitiba’s 13th Federal Court on 2021-03-08 because the cases had no direct link to Petrobras diversions and did not belong in that court; the full STF upheld the ruling on 2021-04-15 (8–3). This was a jurisdiction ruling, not an acquittal on the merits.',
    proves_en:
      'Supports that the convictions were annulled because Curitiba’s 13th Court lacked jurisdiction and that the full court upheld it 8–3.',
  },
  lula_moro_suspeito: {
    artifact_en:
      'The STF declared judge Sergio Moro biased (HC 164.493); the 2nd Panel on 2021-03-23 and the full court on 2021-06-23 (7–4). 2026 developments: the TRE-DF (2026-07-15) invoked Moro’s bias to bar validating the evidence; the CNJ suspended judge Gabriela Hardt for 2 years (2026-08-04).',
    proves_en:
      'Supports that Moro was found biased (HC 164.493), confirmed by the 2nd Panel and the full court (7–4).',
  },
  lula_triplex_prescrito: {
    artifact_en:
      'The triplex case was shelved as time-barred in January 2022 (judge Pollyanna Alves, 12th Federal Criminal Court of Brasília). The ruling acknowledges the limitation and explains that the deadline for defendants over 70 is halved (Art. 115 of the Penal Code). The limitation follows the annulment of Moro’s acts by the STF. There was no acquittal on the merits.',
    proves_en:
      'Supports the limitation and the rule of Art. 115 of the Penal Code (deadline halved after age 70).',
  },
  lula_atibaia_prescrito: {
    artifact_en:
      'In 2025, the TRF-1 rejected the MPF’s request to suspend the closure while the STF reviewed the scope of the nullity; the pending appeal had no suspensive effect. In Brasília, Lula’s criminal liability had been extinguished on limitation grounds, with the period reduced for defendants over 70. The estate allegations were not retried on the merits.',
    proves_en:
      'Supports the refusal to suspend the case closure and its procedural ground; it does not show that the TRF-1 retried the allegations on their merits.',
  },
  lula_petrobras_62bi: {
    artifact_en:
      'Petrobras recognised a loss of R$ 6.2 billion from the Lava Jato diversions in its audited 2014 balance sheet.',
    proves_en:
      'Supports the loss recognised by Petrobras itself (a state company) in its 2014 balance sheet.',
  },
  lula_odebrecht_85bi: {
    artifact_en:
      'The Odebrecht leniency agreement (Dec/2016) set a fine of R$ 8.5 billion.',
    proves_en:
      'Supports that the Odebrecht leniency agreement set a fine of R$ 8.5 billion (Dec/2016).',
  },
  flavio_denunciado_2020: {
    artifact_en:
      'Flávio was FORMALLY CHARGED by the Rio prosecutors (MP-RJ) in November 2020, along with Queiroz and 15 others, for criminal organisation, embezzlement, money laundering and misappropriation.',
    proves_en:
      'Supports the formal 2020 indictment and the crimes charged.',
  },
  flavio_denuncia_arquivada: {
    artifact_en:
      'On 2022-05-16, the TJ-RJ rejected the complaint at the MP-RJ’s request for lack of just cause: after the STJ and STF invalidated financial data used in the accusation, prosecutors said those materials could not support it. This was a procedural closure, not a merits acquittal.',
    proves_en:
      'Supports the rejection for lack of just cause after financial materials used in the accusation were invalidated; it does not decide whether the transactions occurred.',
  },
  flavio_depositos_2mi: {
    artifact_en:
      'The MP-RJ (via a secrecy breach) identified R$ 2,062,360.52 in 483 deposits from 13 staffers into Queiroz’s account.',
    proves_en:
      'Supports the amount and that it originated in Queiroz’s account.',
  },
  flavio_coaf_12mi: {
    artifact_en:
      'Coaf flagged R$ 1,236,838 in unusual transactions in Queiroz’s account between Jan/2016 and Jan/2017.',
    proves_en:
      'Supports the unusual transactions in Queiroz’s account flagged by Coaf.',
  },
  flavio_master_filme: {
    artifact_en:
      'Messages and reports describe a negotiated R$ 134 million (US$ 24 million) film-financing amount; this was the negotiated total, not the amount transferred.',
    proves_en:
      'Supports that messages and audio indicated a financing negotiation for Dark Horse, and distinguishes the negotiated total from the amount transferred.',
  },
  flavio_master_repasse: {
    artifact_en:
      'According to the report, Vorcaro transferred about R$ 61 million to a fund linked to film production; the amount is not attributed to Flávio’s personal account.',
    proves_en:
      'Supports the reported transfer amount and period, while identifying the production fund as recipient.',
  },
  flavio_imoveis_copacabana: {
    artifact_en:
      'Rio prosecutors alleged that R$ 638,400 in cash was deposited into a broker’s account on the day two Copacabana apartments were purchased.',
    proves_en:
      'Supports what Rio prosecutors alleged about the cash deposit and its timing; it is not a court finding about the transaction.',
  },
  flavio_imoveis_barra: {
    artifact_en:
      'Rio prosecutors alleged that R$ 295,500 in 146 deposits of unknown origin was used to pay installments on a Barra apartment.',
    proves_en:
      'Supports what Rio prosecutors alleged about the deposits and apartment payments; it is not a court finding about the transaction.',
  },
  flavio_stj_anulou_2021: {
    artifact_en:
      'On 2021-11-09, the STJ annulled first-instance judicial acts over jurisdiction and Flávio’s special-forum issue; this included banking and tax secrecy orders. That invalidated affected evidence-gathering/use, but did not show that the financial records were false.',
    proves_en:
      'Supports that the jurisdiction/forum ruling reached the secrecy orders; it does not decide whether the transactions occurred.',
  },
  flavio_stf_anulou_rifs: {
    artifact_en:
      'On 2021-11-30, the STF annulled four of the five Coaf RIFs used in the inquiry. The ground was the MP-RJ’s direct request to Coaf before TJ-RJ authorization to investigate the state deputy; this ruled on lawful sharing, not whether the transactions were true.',
    proves_en:
      'Supports the invalidation of four RIFs because they were shared before TJ-RJ authorization; it is not a finding that the entries were false.',
  },
  flavio_gilmar_negou_reabrir: {
    artifact_en:
      'In February 2025, the STF rejected two MP-RJ appeals: one was not reviewable there because it raised statutory rather than constitutional issues and the MP itself had acknowledged insufficient evidence; the other was filed too late to revisit forum. The complaint remained closed without a merits ruling; a new inquiry may rely on different, lawful evidence.',
    proves_en:
      'Supports the procedural grounds for the 2025 rulings, not a conclusion about whether the allegations were true.',
  },
};
