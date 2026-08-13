
# Análise de Gaps — Onde o Yvy Pode Competir (e Vencer)

> Baseado em: MapBiomas Coleção 11 (ago/2026), Agrotools, Serasa Experian, SeloVerde, EUDR, SAFE/MAPA

---

## 1. Matriz de Cobertura Competitiva

| Capacidade | MapBiomas | Agrotools | Serasa | SeloVerde | Yvy Hoje | **Gap Yvy** |
|------------|:---------:|:---------:|:------:|:---------:|:--------:|:-----------:|
| Dados de desmatamento (alertas) | ✅ Grátis | ✅ | ✅ | ✅ | ✅ | — |
| Imagens de alta resolução | ✅ Grátis | ✅ | ✅ | ❌ | ❓ | — |
| Cruzamento com CAR/UC/TI/embargo | ✅ Grátis | ✅ | ✅ | ✅ | ❓ | — |
| API aberta | ✅ Grátis | ✅ Paga | ✅ Paga | ❌ | ❓ | — |
| **Score de risco proprietário** | ❌ | ✅ (scoring ESG) | ✅ (scoring) | ❌ | ❌ | **🔥 PRINCIPAL** |
| **Recomendação de ação** | ❌ | ⚠️ Limitado | ⚠️ Limitado | ❌ | ❌ | **🔥 PRINCIPAL** |
| **Workflow de due diligence** | ❌ | ✅ (enterprise) | ✅ (enterprise) | ❌ | ❌ | **🔥 PRINCIPAL** |
| **Laudo para compliance empresarial** | ⚠️ Técnico | ✅ | ✅ | ❌ | ❌ | **🔥 PRINCIPAL** |
| Monitoramento contínuo de fornecedores | ❌ | ✅ | ✅ | ❌ | ❌ | **🔥 ALTO** |
| **Upload de lista de fornecedores (CSV)** | ⚠️ Meu MapBiomas | ✅ | ✅ | ❌ | ❌ | **🔥 ALTO** |
| Alerta em tempo real para cadeia | ❌ | ✅ | ✅ | ❌ | ❌ | **🔥 ALTO** |
| **PDF profissional para auditoria** | ⚠️ Técnico | ✅ | ✅ | ❌ | ❌ | **🔥 ALTO** |
| Chatbot/IA para análise | ✅ RAG | ❌ | ❌ | ❌ | ❌ | — |
| Plataforma white-label | ✅ Meu MapBiomas | ❌ | ❌ | ❌ | ❌ | — |
| Estatísticas em tempo real | ✅ | ✅ | ✅ | ✅ | ❌ | — |
| Rastreabilidade EUDR | ⚠️ Dados | ✅ | ✅ | ❌ | ❌ | **🔥 MÉDIO** |
| Análise de crédito rural | ❌ | ✅ | ✅ | ❌ | ❌ | — |
| Integração ERP/CRM | ❌ | ✅ | ✅ | ❌ | ❌ | **🔥 MÉDIO** |
| Precificação acessível (SME) | ✅ Grátis | ❌ Enterprise | ❌ Enterprise | ✅ Grátis | ❓ | **🔥 ALTO** |

**Legenda:** ✅ Cobre bem | ⚠️ Cobre parcialmente | ❌ Não cobre | 🔥 Gap viável para Yvy

---

## 2. Os 5 Gaps Viáveis para o Yvy (Priorizados)

### GAP #1 — Score de Risco Proprietário + Recomendação de Ação
**Quem não cobre:** MapBiomas (dados brutos), SeloVerde (dados públicos)
**Quem cobre mal:** Agrotools e Serasa (scoring genérico ESG, não calibrado por caso de uso)

**O que é:**
Um algoritmo que transforma dados brutos (desmatamento, incêndio, UC, TI, embargo, histórico) em um **número único de 0–100** com interpretação clara.

**Por que é defensável:**
- MapBiomas nunca vai criar um "score de risco para frigoríficos" — é um projeto de ciência, não de negócio
- Agrotools e Serasa têm scoring genérico; não é calibrado por persona (frigorífico vs. banco vs. trading)
- Com o tempo, o Yvy calibra o peso das variáveis com base em decisões reais dos clientes

**Como monetizar:**
- Cada propriedade analisada gera um score
- O score é o "motor" do laudo
- Clientes pagam por propriedade monitorada, não por acesso a dados

**MVP:** Tabela de regras simples (if/then) com pesos ajustáveis por ICP

---

### GAP #2 — Workflow de Due Diligence (Upload → Análise → Laudo → Decisão)
**Quem não cobre:** MapBiomas, SeloVerde
**Quem cobre:** Agrotools e Serasa (mas apenas no enterprise, com implantação de meses)

**O que é:**
Um fluxo linear de 4 passos que transforma uma lista de fornecedores/propriedades em um relatório de decisão:

```
Upload CSV (CNPJ + coordenadas)
    ↓
Análise em lote (score + recomendação por propriedade)
    ↓
Revisão humana (cliente ajusta notas e classificação)
    ↓
Relatório consolidado em PDF (para due diligence / EUDR / auditoria)
```

**Por que é defensável:**
- MapBiomas oferece "Meu MapBiomas" (visualização), mas não workflow de decisão
- Agrotools/Serasa exigem contrato enterprise, integração, treinamento — ciclo de 3–6 meses
- Yvy pode entregar valor em **3 minutos** (upload → laudo)

**Como monetizar:**
- R$ 49–149 por propriedade (modelo avulso)
- R$ 299–1.990/mês (SaaS com monitoramento contínuo)

**MVP:** 5 telas (dashboard, upload, score, alerta, report)

---

### GAP #3 — Laudo Profissional para Compliance/Auditoria Empresarial
**Quem não cobre:** MapBiomas (laudo é técnico/ambiental), SeloVerde
**Quem cobre:** Agrotools e Serasa (mas integrado em plataformas enterprise caras)

**O que é:**
Um PDF que não é "laudo técnico de desmatamento", mas **"documento de evidência para due diligence"**.

**Diferença entre laudo MapBiomas e laudo Yvy:**

| Aspecto | Laudo MapBiomas | Laudo Yvy (gap) |
|---------|-----------------|-----------------|
| Público-alvo | Fiscal ambiental, pesquisador | Compliance, jurídico, conselho, auditor |
| Linguagem | Técnica (DETER, SIGTAP, ha) | De negócio (risco, recomendação, EUDR) |
| Recomendação | Nenhuma | "Rejeitar fornecedor", "Aprovar com ressalvas" |
| Formato | Técnico, imagens de satélite | Profissional, branding do cliente, assinatura digital |
| Uso | Fiscalização | Due diligence, auditoria externa, apresentação ao board |
| Valor jurídico | Evidência técnica | Evidência + recomendação + audit trail |

**Por que é defensável:**
- MapBiomas nunca vai gerar um PDF que diz "rejeite este fornecedor" — vai contra o princípio de neutralidade deles
- O laudo do Yvy é o **artefato que justifica a decisão de negócio**

**Como monetizar:**
- Incluído em todos os planos pagos
- Diferencial chave na venda ("nosso laudo é aceito em auditoria EUDR")

---

### GAP #4 — Monitoramento Contínuo de Fornecedores com Alerta Direcionado
**Quem não cobre:** MapBiomas (alertas são territoriais, não vinculados a cadeia), SeloVerde
**Quem cobre:** Agrotools e Serasa (enterprise, caro)

**O que é:**
O cliente sobe uma lista de 1.800 fornecedores. O Yvy monitora cada propriedade continuamente. Quando há novo evento, o cliente recebe:

```
Assunto: [ALERTA YVY] Novo desmatamento em Fazenda São João (Fornecedor #847)

Fornecedor: Fazenda São João (CNPJ: 12.345.678/0001-99)
Commodity: Soja
Contrato: #2026-0847

🟢 Status anterior: Baixo risco
🔴 Status atual: Alto risco

Evento detectado:
• Desmatamento de 12 ha em 10/08/2026
• Proximidade a UC: 2,1 km
• Embargo: não detectado

Recomendação: SUSPENDER compras até laudo complementar

[Ver evidência] [Gerar laudo atualizado] [Escalar para compliance]
```

**Por que é defensável:**
- MapBiomas publica alertas territoriais. Não sabe que "Fazenda São João" é fornecedor do seu cliente
- O valor está no **contexto da cadeia produtiva**, não no alerta isolado
- Cria lock-in: quando o compliance do frigorífico depende dos alertas do Yvy, trocar é caro

**Como monetizar:**
- Plano Business (R$ 1.990/mês): até 2.000 propriedades monitoradas
- Plano Enterprise: volume ilimitado + SLA + webhooks

---

### GAP #5 — Precificação Acessível para SME (Consultorias e Pequenos Tradings)
**Quem não cobre:** Agrotools e Serasa (enterprise only, preço não público, implantação longa)
**Quem cobre de graça:** MapBiomas, SeloVerde (mas sem workflow de decisão)

**O que é:**
Um produto que uma consultoria ambiental de 10 pessoas ou um trading de café de 50 funcionários pode comprar **hoje**, com cartão de crédito, sem call de vendas, sem implantação.

**O mercado esquecido:**
| Segmento | Tamanho estimado | Dor | Poder de pagamento |
|----------|------------------|-----|-------------------|
| Consultorias ambientais (5–50 pessoas) | 2.000+ empresas | Due diligence manual, lenta | R$ 300–800/mês |
| Pequenos tradings/cooperativas | 500+ empresas | Não sabem risco dos fornecedores | R$ 800–2.000/mês |
| Escritórios de advocacia ambiental | 300+ escritórios | Precisam de evidências rápidas | R$ 300–500/mês |
| Fundos de investimento (PE/VC) | 100+ fundos | Due diligence de ativos rurais | R$ 1.000–3.000/mês |

**Por que é defensável:**
- Agrotools e Serasa não vendem para SME — o CAC (custo de aquisição) não fecha para eles
- O Yvy pode vender online, sem time comercial, com trial de 7 dias
- "Meu MapBiomas" é gratuito, mas exige que o usuário SEJA o analista. O Yvy vende "decisão pronta"

**Como monetizar:**
- Free: 5 análises/mês (aquisição)
- Analyst: R$ 299/mês (100 análises)
- Professional: R$ 799/mês (500 propriedades + monitoramento)
- Business: R$ 1.990/mês (2.000 propriedades + API)
- Report avulso: R$ 49–149/propriedade (porta de entrada)

---

## 3. Gaps que o Yvy NÃO Deve Cobrir (Armadilhas)

| Gap | Por que não | Risco |
|-----|-------------|-------|
| Visualização de mapas customizada | "Meu MapBiomas" já faz isso de graça | Compete com gratuito e melhor |
| Chatbot/IA generica para análise ambiental | MapBiomas RAG é mais confiável (dados próprios) | Menor qualidade, maior custo |
| Dados de desmatamento em tempo real | DETER/SAD são mais rápidos; MapBiomas já consolida | Yvy nunca terá dados mais rápidos que o INPE |
| Plataforma white-label | "Meu MapBiomas" é white-label gratuito | Sem diferenciação |
| Análise de crédito rural | Agrotools e Serasa dominam; requer dados financeiros | Mercado maduro, barreira alta |
| Certificação EUDR completa | Requer competência jurídica/técnica que o Yvy não tem | Risco legal, responsabilidade |

---

## 4. O Gap Único: "Environmental Risk Intelligence"

Se eu tivesse que resumir em uma frase o gap que o Yvy pode dominar:

> **O MapBiomas te diz O QUE aconteceu no território. O Yvy deve dizer O QUE fazer com isso no seu negócio.**

Isso se traduz em 3 capacidades que NENHUM concorrente cobre bem para SME:

1. **Análise em lote de fornecedores** (upload CSV → score → laudo → decisão)
2. **Monitoramento contínuo com alerta contextualizado** ("seu fornecedor #847 está em risco")
3. **Laudo empresarial auditável** (PDF que o compliance anexa à due diligence)

---

## 5. Prioridade de Execução (Próximos 30 Dias)

| Semana | Ação | Gap coberto | Entregável |
|--------|------|-------------|------------|
| 1 | Definir fórmula do Risk Score v1 | Gap #1 | Tabela de regras com pesos por ICP |
| 1–2 | Desenvolver gerador de PDF de laudo | Gap #3 | Template de laudo profissional |
| 2 | Criar fluxo de upload CSV → análise em lote | Gap #2 | Wizard de 4 passos |
| 2–3 | Implementar alertas por email/webhook | Gap #4 | Notificação de novo evento em fornecedor |
| 3 | Landing page + checkout online | Gap #5 | Página de preços com trial de 7 dias |
| 3–4 | 10 demos com consultorias reais | Todos | Provar valor com propriedades reais |

---

## 6. Síntese: O Yvy como "Camada de Decisão"

```
┌─────────────────────────────────────────────────────────────┐
│                    MAPBIOMAS ALERTA                         │
│  (dados brutos, alertas validados, laudos técnicos, API)    │
│                    ↓ GRATUITO                               │
├─────────────────────────────────────────────────────────────┤
│              AGROTOOLS / SERASA EXPERIAN                    │
│  (scoring ESG, enterprise, crédito rural, integração ERP)  │
│              ↓ CARO, ENTERPRISE, 3–6 MESES                   │
├─────────────────────────────────────────────────────────────┤
│                      YVY RISK INTELLIGENCE                    │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐   │
│  │  ANALYZE    │  │  MONITOR    │  │      REPORT         │   │
│  │ Upload CSV  │  │ Alertas de  │  │  Laudo PDF para     │   │
│  │ Score 0-100 │  │ fornecedores│  │  compliance/EUDR    │   │
│  │ Recomendação│  │ Webhooks    │  │  Audit trail        │   │
│  └─────────────┘  └─────────────┘  └─────────────────────┘   │
│                    ↓ R$ 299–1.990/mês                         │
└─────────────────────────────────────────────────────────────┘
```

> **A única posição defensável para o Yvy é ser a ponte entre os dados gratuitos do MapBiomas e a decisão empresarial que custa R$ 2.000/mês.**
