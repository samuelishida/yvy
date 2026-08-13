# MapBiomas Alerta — Especificação Técnica Completa

> **Versão:** 2026.08  
> **Fonte oficial:** https://alerta.mapbiomas.org / https://plataforma.alerta.mapbiomas.org  
> **Uso:** Inserir no agente como contexto de concorrência/benchmark de dados abertos

---

## 1. Visão Geral

O **MapBiomas Alerta** é um sistema de **validação e refinamento de alertas de desmatamento** com imagens de satélite de alta resolução. Não é um sistema de detecção original — ele consolida, valida, refina e publica alertas provenientes de diversos sistemas de monitoramento já existentes no Brasil.

**Propósito:** Revelar transformações do território brasileiro com precisão, agilidade e qualidade, tornando acessível o conhecimento sobre cobertura e uso da terra.

**Posicionamento chave:** Publica **toda e qualquer perda de vegetação nativa**, **sem avaliação de legalidade, regularidade ou responsabilidade** sobre a supressão.

**Lançamento:** 07 de junho de 2019.  
**Cobertura temporal:** Alertas desde janeiro de 2019 (fase pré-operacional: outubro–dezembro de 2018).  
**Atualização:** Semanal (geralmente às terças-feiras).  
**Custo:** 100% gratuito e aberto.

---

## 2. Metodologia — 6 Etapas

### Etapa 1: Compilação
- Coleta mensal de alertas de múltiplos sistemas de detecção
- Criação de código identificador único (ID) para cada alerta
- DETER importado a cada 15 dias; demais fontes, mensalmente

### Etapa 2: Validação e Seleção de Imagens
- **Pré-validação automatizada:** elimina alertas já validados, áreas de reflorestamento/agricultura (MapBiomas anual), falsos positivos conhecidos
- **Inspeção visual:** analistas treinados por bioma avaliam mosaicos mensais Planet (3,7m resolução)
- **Seleção de par de imagens:** uma "antes" (até 12 meses pré-detecção) e uma "depois" (mais próxima do fim do desmatamento)
- **Descarte de falsos positivos:** silvicultura, agricultura, sazonalidade (com registro do motivo)

### Etapa 3: Refinamento
- Delimitação precisa da área desmatada via classificação supervisionada (Random Forest) no Google Earth Engine
- Uso do aplicativo **Workspace** (desenvolvido pelo MapBiomas) para processamento
- Simplificação do polígono para remover excesso de vértices
- Variação de até ±5% na área final devido à generalização
- Identificação do **vetor de pressão:** agropecuária, garimpo, mineração, expansão urbana, eventos climáticos extremos, outros

### Etapa 4: Cruzamento com Bases Territoriais Públicas
Sobreposição espacial com:
- **Cadastro Ambiental Rural (CAR)** — incluindo APP e Reserva Legal declaradas
- **SIGEF** (assentamentos)
- **SNCI** (imóveis certificados)
- **Terras Indígenas (TIs)**
- **Unidades de Conservação (UCs)** — federais, estaduais, municipais
- **Territórios quilombolas**
- **Assentamentos rurais**
- **Áreas embargadas** (IBAMA, órgãos estaduais)
- **Autorizações de supressão** (Sinaflor/IBAMA)
- **Planos de Manejo Florestal Sustentável**
- **Limites geográficos:** municípios, estados, biomas, bacias hidrográficas
- **Territórios especiais:** Amazônia Legal, área Lei Mata Atlântica, MATOPIBA, AMACRO, Reservas da Biosfera

### Etapa 5: Auditoria
- Supervisor técnico de cada bioma revisa cada polígono refinado
- Avalia necessidade de ajustes antes da publicação final

### Etapa 6: Publicação
- Publicação semanal na plataforma web
- Laudos disponibilizados para cada alerta e para cada cruzamento com imóvel CAR/SIGEF/SNCI (>0,3 ha)
- **Retificação/cancelamento pós-publicação:** alertas podem ser retificados ou cancelados mediante solicitação fundamentada. Cancelados são removidos do mapa/estatísticas, mas mantidos na base para consulta individual.

---

## 3. Sistemas de Detecção Fonte (Alertas Brutos)

| Sistema | Fonte | Bioma(s) | Resolução | Frequência |
|---------|-------|----------|-----------|------------|
| **DETER** | INPE | Amazônia, Cerrado, Pantanal | 30–60m | Quinzenal |
| **SAD** | IMAZON | Amazônia | 30m | Mensal |
| **SAD Caatinga** | Geodatin / UEFS | Caatinga | 10m (Sentinel-2) | Mensal |
| **SAD Mata Atlântica** | SOS Mata Atlântica / ArcPlan | Mata Atlântica | 10m (Sentinel-2) | Mensal |
| **SAD Pantanal** | SOS Pantanal / ArcPlan | Pantanal | 10m (Sentinel-2) | Mensal |
| **SAD Pampa** | GeoKarten / UFRGS | Pampa | 10m (Sentinel-2) | Mensal |
| **SAD Cerrado** | IPAM / LAPIG-UFG | Cerrado | 10m (Sentinel-2) | Mensal |
| **SIRAD-X** | ISA / rede Xingu+ | Bacia do Xingu (Amazônia/Cerrado) | Radar Sentinel-1 | Mensal |
| **GLAD** | Universidade de Maryland | Pampa (e outros) | 30m (Landsat) | Mensal |
| **PRODES** | INPE | Amazônia, Cerrado, Pampa, Pantanal | Anual | Anual |

**Nota:** PRODES é incorporado posteriormente para reduzir omissões. Atlas dos Remanescentes Florestais (SOS Mata Atlântica/INPE) também incluído para Mata Atlântica.

---

## 4. Imagens Utilizadas

| Tipo | Satélite | Resolução | Frequência | Uso |
|------|----------|-----------|------------|-----|
| Alta resolução | PlanetScope (constelação 200+ microssatélites) | 3,7m | Diária | Validação, refinamento, laudos |
| Média resolução | Sentinel-2 | 10m | ~5 dias | Validação SAD Cerrado, detecção |
| Média resolução | Landsat | 30m | 16 dias | Histórico de cobertura e uso da terra |

---

## 5. Laudo Técnico — Conteúdo Completo

Para cada alerta publicado, o MapBiomas Alerta gera um **laudo técnico automatizado** em PDF. Quando o alerta cruza com um imóvel CAR/SIGEF/SNCI (>0,3 ha), gera laudo específico do cruzamento.

### Conteúdo do Laudo:
1. **Código do alerta** (ID único)
2. **Fonte original** do alerta (DETER, SAD, GLAD, etc.)
3. **Bioma, Estado e Município**
4. **Área do desmatamento** (hectares)
5. **Área do desmatamento que cruza com o imóvel**
6. **Código do imóvel** (CAR, SIGEF, SNCI)
7. **Imagens de alta resolução:**
   - Imagem "antes" do desmatamento (data)
   - Imagem "depois" do desmatamento (data)
8. **Sobreposições territoriais:**
   - APP (Área de Preservação Permanente)
   - Reserva Legal (RL)
   - Nascentes
   - Terras Indígenas
   - Unidades de Conservação
   - Plano de Manejo Florestal Sustentável
   - Áreas embargadas
   - Autorizações de supressão
9. **Histórico da cobertura e uso da terra** (MapBiomas, 2012–atual)
10. **Histórico de imagens Landsat** na área avaliada
11. **Memorial descritivo** com coordenadas geográficas dos vértices do polígono
12. **Fontes de dados** utilizadas nos cruzamentos
13. **Vetor de pressão** identificado

### Limitações do Laudo:
- Dados gerados automaticamente — pode haver erros no processamento de imagens históricas
- Requer atualização anual das bases de uso e ocupação do solo
- Não avalia legalidade ou regularidade do desmatamento

---

## 6. Plataforma Web — Funcionalidades

URL: https://plataforma.alerta.mapbiomas.org

### Mapa Interativo
- Visualização de todos os alertas validados desde 2019
- Imagens de alta resolução "antes" e "depois"
- Camadas de sobreposição territorial

### Filtros de Busca
- Data de detecção ou data de publicação
- Período
- Tipo de território
- Território específico
- Cruzamentos (APP, RL, UC, TI, embargo, etc.)
- Tamanho do alerta (área mínima/máxima)
- Autorização de supressão
- Área embargada

### Territórios de Interesse
- Permite seleção de territórios geográficos personalizados
- Busca e consulta de alertas dentro do território definido

### Consulta por CAR
- Busca direta pelo código do CAR
- Visualização de alertas que cruzam com o imóvel

### Laudos
- Geração e download de laudos em PDF
- Laudo do alerta + laudo do cruzamento com imóvel

### Downloads (requer conta gratuita)
- **Shapefile (.shp):** todos os alertas georreferenciados (polígonos)
- **CSV/Excel (.xls):** dados tabulares consolidados por ano, com informações do CAR
- **PDF:** laudos individuais
- **Plugin QGIS:** acesso direto aos alertas no QGIS

---

## 7. API GraphQL V2

### Endpoint
```
https://plataforma.alerta.mapbiomas.org/api/v2/graphql
```

### Autenticação
- **Tipo:** Bearer Token
- **Obtido via:** mutation `SignIn` com login da plataforma
- **Registro:** https://plataforma.alerta.mapbiomas.org/sign-up
- **Token incluído no header:** `Authorization: Bearer <TOKEN>`
- **Custo:** Gratuito (requer atribuição)
- **Sem acesso por conta de serviço** (service account)

### Queries Principais

#### `alerts` — Lista de alertas com filtros
Retorna alertas com recortes temporais ou espaciais. Substitui a antiga `publishedAlerts` da V1.

**Parâmetros típicos:**
- `start_date` / `end_date`
- `sources` (DETER, SAD, GLAD, etc.)
- `bbox` (bounding box: min_lon, min_lat, max_lon, max_lat)
- Filtros territoriais

**Colunas retornadas (exemplo):**
| Campo | Tipo | Descrição |
|-------|------|-----------|
| `alert_code` | String | Código único do alerta |
| `area_ha` | Float | Área em hectares |
| `data_deteccao` | DateTime | Data de detecção |
| `data_publicacao` | DateTime | Data de publicação |
| `status` | String | Status do alerta |
| `fonte` | String | Fonte original (DETER, SAD, etc.) |
| `lat` | Float | Latitude |
| `lon` | Float | Longitude |
| `geometry` | Polygon (WKT) | Geometria do polígono (em queries geo) |

#### `alert` — Detalhe completo de um alerta
Retorna todos os dados do alerta + informações do laudo. Substitui `publishedAlert` + `alertReport` da V1.

**Inclui:**
- Dados básicos do alerta
- Cruzamentos territoriais completos
- Dados do CAR (imóveis rurais cruzados)
- APP, Reserva Legal, nascentes
- Terras Indígenas, UCs, quilombos, assentamentos
- Embargos, autorizações, planos de manejo
- Histórico de cobertura e uso da terra

#### `alertSummary` — Estatísticas agregadas
Retorna informações estatísticas que aparecem no dashboard da plataforma (contagens, áreas totais, etc.).

### API V1 (Deprecated)
- Endpoint: `https://plataforma.alerta.mapbiomas.org/api/v1/graphql`
- Status: Descontinuada, sem novas queries
- **Removida em:** 30/11/2023

### Performance V2
- Até **10x mais rápida** que a V1
- Foco em estabilidade e novos cruzamentos

### Clientes e Bibliotecas
- Clientes desktop: Insomnia, Postman, etc.
- Bibliotecas GraphQL disponíveis para diversas linguagens
- Sandbox integrada na documentação da API

### Exemplo de Uso (Python/agrobr)
```python
import asyncio
from agrobr import mapbiomas_alerta

async def main():
    # Tabular alerts
    df = await mapbiomas_alerta.alertas(
        token="seu-token",
        start_date="2024-01-01",
        end_date="2024-06-30",
    )

    # Filter by source
    df = await mapbiomas_alerta.alertas(
        sources=["DETER", "SAD"],
        start_date="2024-01-01",
    )

    # Bounding box
    df = await mapbiomas_alerta.alertas(
        bbox=(-56, -16, -54, -14),
    )

    # With geometry
    gdf = await mapbiomas_alerta.alertas_geo(
        start_date="2024-01-01",
        end_date="2024-03-31",
    )

    # Info
    info = await mapbiomas_alerta.alerta_info()

asyncio.run(main())
```

---

## 8. Dados Abertos — Downloads

### Relatório Anual do Desmatamento (RAD)
- Publicado anualmente com panorama completo
- RAD2025 (mais recente em 2026)
- Disponível em: https://alerta.mapbiomas.org/relatorio/

### Formatos de Download
| Formato | Conteúdo | URL |
|---------|----------|-----|
| **Shapefile (.shp)** | Polígonos georreferenciados de todos os alertas | Página de downloads da plataforma |
| **Excel (.xls)** | Dados tabulares consolidados por ano, com CAR | Página de downloads da plataforma |
| **PDF** | Laudos individuais | Por alerta na plataforma |
| **CSV** | Dados tabulares | API GraphQL ou página de downloads |

### Colunas do Shapefile/Excel
- `alert_code`: código único do alerta
- `source`: fonte original do alerta
- `area_ha`: área em hectares
- `biome`: bioma predominante
- `state`: estado predominante
- `city`: município predominante
- `ano_det`: ano de detecção

**Nota:** Quando o alerta cruza mais de um bioma/estado/município, o shapefile atribui o valor predominante (maior área). O relatório anual calcula por interseção.

---

## 9. Limitações Conhecidas

1. **Tempo de processamento:** 30–90 dias entre detecção pelo sistema fonte e publicação no MapBiomas Alerta. Não serve para fiscalização de flagrante (use DETER/SAD diretamente).

2. **Omissões:** Depende da detecção dos sistemas fonte. Áreas mínimas de detecção variam (ex: DETER Amazônia ignora <3 ha; DETER Cerrado ignora <1 ha).

3. **Velocidade subestimada:** Intervalo entre imagens "antes" e "depois" pode ser de meses devido a nuvens, afetando cálculo de velocidade média.

4. **Vegetação não lenhosa:** Sistemas de detecção focam em vegetação florestal. Vegetação campestre é subestimada (exceção: SAD Cerrado detecta savânicas e campestres).

5. **Dados do ano corrente:** Sempre parciais e sujeitos a alteração devido ao tempo de processamento.

6. **Sem avaliação de legalidade:** Todo desmatamento detectado é publicado como alerta, independente de regularidade ou autorização.

7. **Falsos positivos:** Pequena fração é descartada (silvicultura, agricultura, sazonalidade), mas alguns podem passar.

8. **Imagens históricas:** Podem apresentar erros de processamento no laudo automático.

---

## 10. Licença e Atribuição

- **Licença:** Dados públicos e gratuitos (Creative Commons — atribuição obrigatória)
- **Requisito:** Citar MapBiomas Alerta como fonte em qualquer uso dos dados
- **Restrição:** Não pode ser vendido como produto próprio sem transformação significativa

---

## 11. Estatísticas de Cobertura (referência)

| Bioma | Alertas (2019–2021) | Área Desmatada (ha) | Velocidade Média (ha/dia) |
|-------|---------------------|---------------------|---------------------------|
| Amazônia | 106.411 | 1.708.879 | 2.163 |
| Cerrado | 14.934 | 843.932 | 1.067 |
| Mata Atlântica | 4.873 | 38.179 | 48 |
| Caatinga | 4.436 | 73.191 | 93 |
| Pantanal | 458 | 44.157 | 56 |
| Pampa | 157 | 1.761 | 2 |
| **Brasil** | **131.269** | **2.710.099** | **3.429** |

---

## 12. Novidades da Coleção 11 (Lançamento — agosto/2026)

O evento de lançamento da Coleção 11 do MapBiomas (agosto/2026) marcou um salto significativo na democratização e no avanço do monitoramento ambiental brasileiro. Abaixo, as novidades operacionais que impactam diretamente concorrentes e parceiros do ecossistema.

---

### 12.1 Evolução do Mapeamento — Novas Classes de Uso e Cobertura

A Coleção 11 amplia o detalhamento do território brasileiro com **três classes inéditas**:

| Classe | Descrição | Relevância |
|--------|-----------|------------|
| **Marismas** | Áreas de transição costeira | Fundamentais para biodiversidade costeira e zoneamento |
| **Savanas alagadas** | Ecossistemas úmidos sazonais | Novos dados para compreender regimes hídricos e carbono azul |
| **Empreendimentos eólicos** | Infraestrutura de energia renovável | Monitoramento da expansão eólica no território brasileiro |

**Implicação:** O MapBiomas deixa de ser apenas "floresta vs. desmatamento" e passa a cobrir **infraestrutura energética** e **zonas úmidas costeiras**. Isso amplia o escopo de análise para setores como energia, planejamento territorial e zoneamento ambiental.

---

### 12.2 "Meu MapBiomas" — Plataforma Personalizada

Considerado o **"próximo salto"** da plataforma. Permite que qualquer instituição ou usuário crie seu **próprio sistema de inteligência territorial** em minutos.

**Funcionalidades demonstradas ao vivo:**

| Recurso | Descrição |
|---------|-----------|
| **Criação de plataforma personalizada** | Em poucos minutos, o usuário configura uma instância própria do MapBiomas |
| **Upload de dados próprios** | Shapefiles e camadas geoespaciais customizadas podem ser carregados |
| **Cruzamento com acervo MapBiomas** | Dados próprios são cruzados automaticamente com as 30+ camadas do MapBiomas |
| **Visualização dinâmica** | Mapas interativos com as camadas do usuário + camadas MapBiomas |
| **Geração de estatísticas em tempo real** | Contagens, áreas, percentuais calculados automaticamente sobre o território customizado |

**Implicação estratégica:** O "Meu MapBiomas" é uma **ferramenta de white-label/self-service** que permite que ONGs, consultorias, empresas e órgãos públicos criem suas próprias plataformas de monitoramento sem desenvolver do zero. Isso reduz a barreira de entrada para quem quer monitorar territórios específicos.

> **Para o Yvy:** O "Meu MapBiomas" compete diretamente com a camada de "visualização de dados" e "dashboard customizado". Se o Yvy continuar vendendo "mapa interativo", está competindo com uma ferramenta gratuita e mais madura. A diferenciação por "visualização" morreu neste lançamento.

---

### 12.3 Integração com Inteligência Artificial (IA)

A IA passou a ser um pilar central na experiência do usuário do MapBiomas.

#### 12.3.1 Chatbot com RAG (Recuperação Aumentada de Argumentos)
- **Técnica:** RAG sobre relatórios técnicos do MapBiomas
- **Fontes:** Relatórios anuais de fogo, relatórios de desmatamento, metodologias, estatísticas
- **Capacidades:**
  - Responde perguntas em linguagem natural sobre dados do MapBiomas
  - Fornece **links diretos** para tabelas, gráficos e fontes originais
  - Traduz termos técnicos para linguagem acessível
  - Gera estatísticas em tempo real sobre o território consultado

#### 12.3.2 Automação de Processos
- **Tradução automática** de campos e labels técnicos
- **Geração de estatísticas** em tempo real sobre áreas selecionadas
- **Visualização dinâmica** de mapas com base em consultas em linguagem natural
- **Auxílio à análise técnica** — sugere camadas relevantes, compara períodos, identifica tendências

**Implicação:** O MapBiomas agora tem um **assistente de análise ambiental** que democratiza o acesso a dados complexos. Um jornalista ou gestor público pode fazer perguntas como *"Qual foi a evolução do desmatamento no Pará entre 2019 e 2025?"* e receber resposta com mapa, gráfico e fonte.

> **Para o Yvy:** O chatbot do MapBiomas compete com a ideia de "IA generativa para análise ambiental" que o Yvy poderia considerar. A diferença é que o MapBiomas usa RAG sobre dados próprios consolidados, não sobre dados genéricos. Isso torna o chatbot dele mais confiável para análise territorial pura.

---

### 12.4 Casos de Uso e Aplicação Prática (Parceiros)

Diversos parceiros apresentaram aplicações reais durante o evento:

| Parceiro | Aplicação | Relevância para Yvy |
|----------|-----------|---------------------|
| **ICMBio** | Manejo integrado do fogo e proteção de áreas | Confirma que dados MapBiomas são usados em fiscalização federal |
| **EPE (Empresa de Pesquisa Energética)** | Estudos socioambientais e planejamento de empreendimentos lineares (transmissão de energia) | **Novo mercado:** setor energético precisa de dados ambientais para licenciamento |
| **WWF** | Monitoramento de espécies sensíveis (ex: boto) | Dados de uso da terra para conservação de fauna |
| **Imaflora** | Certificação agrícola e rastreabilidade | **Diretamente relevante:** Imaflora é referência em certificação e due diligence ambiental no agronegócio |

**Implicação:** O MapBiomas está sendo adotado por **instituições de peso** no licenciamento ambiental, certificação e planejamento energético. Isso eleva o padrão de expectativa do mercado sobre o que uma plataforma de dados ambientais deve entregar.

---

### 12.5 Melhorias na Experiência do Usuário (UX)

- **Site oficial reorganizado:** dados de downloads melhor organizados, com introduções didáticas para públicos diversos (jornalistas, acadêmicos, gestores públicos, setor privado)
- **Navegação simplificada:** acesso mais intuitivo a coleções, downloads, relatórios e ferramentas
- **Conteúdo educativo:** tutoriais e guias para diferentes perfis de usuário

---

### 12.6 Síntese das Novidades — Matriz de Ameaça ao Yvy

| Novidade MapBiomas | Ameaça ao Yvy | Nível | Justificativa |
|--------------------|---------------|-------|---------------|
| Meu MapBiomas (plataforma personalizada) | Dashboard/visualização customizada | 🔴 **Alta** | Gratuito, self-service, cruza dados próprios com acervo MapBiomas |
| Chatbot com RAG | IA generativa para análise ambiental | 🟠 **Média/Alta** | RAG sobre dados próprios é mais confiável que LLM genérico; democratiza análise |
| Novas classes (eólica, marismas) | Análise de infraestrutura energética | 🟡 **Média** | Amplia escopo do MapBiomas para setor energético, antes não coberto |
| Estatísticas em tempo real | Relatórios automáticos | 🟠 **Média/Alta** | Gera estatísticas e visualizações dinâmicas sobre território customizado |
| Upload de shapefiles próprios | Integração de dados do cliente | 🟠 **Média/Alta** | Cliente pode subir seus polígonos e cruzar com MapBiomas sem pagar |
| Parceria Imaflora | Certificação e due diligence | 🟡 **Média** | Imaflora é referência; se usa MapBiomas, eleva o floor de expectativa |

> **Conclusão atualizada:** O lançamento da Coleção 11 reforça a tese central: **o Yvy não pode competir na camada de visualização, dashboard ou análise territorial genérica.** O MapBiomas agora oferece isso de graça, com IA, com personalização e com o acervo mais completo do Brasil. A única trincheira viável para o Yvy continua sendo a **camada de decisão empresarial**: score de risco, recomendação de ação, workflow de due diligence, laudo para compliance e monitoramento contínuo de fornecedores.

---

## 13. Implicações para o Yvy (Nota do Agente)

> **O MapBiomas Alerta é o FLOOR, não o teto.**

O que ele oferece (e o Yvy **não deve tentar replicar**):
- Dados de desmatamento validados e gratuitos
- Laudos técnicos com imagens de alta resolução
- API aberta para consulta
- Cruzamentos com CAR, UC, TI, embargo

O que ele **NÃO oferece** (e é onde o Yvy compete):
- **Score de risco proprietário** — MapBiomas não classifica "risco alto/médio/baixo"
- **Recomendação de ação** — não diz "rejeite este fornecedor"
- **Workflow de due diligence** — não automatiza o processo de análise de 1.800 propriedades
- **Laudo para compliance empresarial** — o laudo dele é técnico/ambiental, não jurídico/comercial
- **Monitoramento contínuo de fornecedores** — não alerta quando um fornecedor da sua cadeia tem novo desmatamento
- **Integração com ERP/CRM** — API é para consulta pontual, não para pipeline de dados empresarial
- **PDF profissional para auditoria** — o laudo dele serve para fiscalização, não para apresentar ao conselho

> **Tese:** O Yvy não compete com o MapBiomas Alerta. O Yvy **usa** o MapBiomas Alerta como uma de suas fontes de dados e adiciona a camada de decisão empresarial por cima.

---

## 14. Links Oficiais

| Recurso | URL |
|---------|-----|
| Site oficial | https://alerta.mapbiomas.org |
| Plataforma | https://plataforma.alerta.mapbiomas.org |
| API GraphQL V2 | https://plataforma.alerta.mapbiomas.org/api/v2/graphql |
| Documentação API | https://plataforma.alerta.mapbiomas.org/api |
| Downloads | https://plataforma.alerta.mapbiomas.org/downloads |
| Método | https://alerta.mapbiomas.org/metodo-mapbiomas-alerta/ |
| FAQ | https://alerta.mapbiomas.org/perguntas-frequentes/ |
| Tutoriais | https://alerta.mapbiomas.org/tutoriais/ |
| Relatórios anuais | https://alerta.mapbiomas.org/relatorio/ |
| Guia de boas práticas | https://alerta.mapbiomas.org/en/faq/e-possivel-acessar-os-alertas-validados-e-os-laudos-atraves-de-outros-servicos-de-dados/ |
