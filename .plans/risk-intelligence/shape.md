# Shaping decisions — Risk Intelligence

## Alternatives considered (rejected)

### PDF: client-side (jspdf) vs server-side (reportlab)
- **Rejected client-side**: o audit trail ficaria client-side, quebrando o
  requisito de evidência para compliance/EUDR. O backend é Lua baremetal sem
  Node; jspdf exigiria manter o PDF no browser e reenviar.
- **Chosen server-side (reportlab subprocess)**: Python já está no stack de
  deploy (`scripts/data/*.py`); o PDF é gerado a partir do score persistido
  (`risk_precompute`), então o audit trail é server-side e reproduzível.

### Tenancy: single-tenant vs multi-tenant
- **Rejected multi-tenant agora**: a app não tem auth (só API key
  compartilhada). Adicionar tenant/workspace exigiria auth, isolamento de
  dados e migração — escopo grande sem base.
- **Chosen single-tenant (v1)**: uma lista de fornecedores por deployment.
  Multi-tenant é fase 2, com a tabela `suppliers` já preparada para uma coluna
  `tenant_id`.

### MapBiomas: GraphQL V2 vs bulk download
- **Rejected GraphQL V2**: requer conta/token Bearer (moving part), e a
  plataforma não tem service account. O bulk download (shapefile/CSV) espelha
  exatamente o padrão `download_sinaflor_auth.py` (CKAN → DB dedicado → scp →
  prod), sem token.
- **Chosen bulk download**: mesmo pipeline de ingestão já provado no repo.

### Alert delivery: email vs webhook vs in-app
- **Rejected email SMTP**: não há infra SMTP; `socket/smtp.lua` está presente
  mas nunca usado. Config de SMTP é moving part novo.
- **Rejected in-app only**: não entrega valor B2B (compliance precisa ser
  notificado).
- **Chosen webhook + in-app (v1)**: webhook é a integração B2B padrão; in-app
  dá visibilidade. Retry durável é fase 2.

## Prototype-first de-risking

- **Inc 1 (ingestion)** é o maior risco de schema: prototipar o download de
  um shapefile real e normalizar antes de escrever o resto. Se o schema do
  MapBiomas mudar, só o import precisa mudar.
- **Inc 2 (score)** é o coração do produto: prototipar `risk_score.lua` puro
  (sem I/O) primeiro — é testável isoladamente e define o contrato de dados
  para batch, PDF e monitor.

## Why this order

- Inc 1 antes de 2/6 porque o score e o monitor dependem dos dados MapBiomas.
- Inc 2 antes de 3/4/6 porque batch, PDF e monitor consomem o score.
- Inc 3 e 4 em paralelo (ambos dependem só de 2) — PDF não depende do batch
  API, só do score.
- Inc 6 (monitor) depende só de 1 e 2, então pode rodar em paralelo com 3/4.
- Inc 5 (frontend) por último porque consome batch API + PDF + a aba de
  alertas do monitor (Inc 6).

## Correções da revisão (plan-reviewer + review-plan)

- **POST já existe** em `main.lua` (`/api/fires/sync`, `/api/admin/*`,
  `/api/news/refresh`); o trabalho novo é parsing CSV raw, não "adicionar
  POST" nem multipart.
- **O gate real de upload em produção é o nginx** (`ansible/templates/
  yvy-nginx.conf.j2`): `/api/*` vai direto ao Lua :5000, bypassando o C
  server. O nginx não configura `client_max_body_size` → default 1MB →
  rejeita body >1MB. Precisa setar em `yvy-nginx.conf.j2`. O proxy C
  `yvy-server.c` só é gate em dev/local (sem nginx).
- **Upload é CSV raw, não FormData multipart**: frontend envia
  `Content-Type: text/csv` + body raw; backend passa `ctx.req.body` direto ao
  `utils.parse_csv`. Evita adicionar parsing multipart ao core server.
- **`risk_scores` usa `property_id` surrogate** (cod_imovel | cnpj | lat:lon)
  em DB dedicado `risk.db`, reconciliando as chaves de entrada de batch e
  monitor. `resolve_property_id` é função pura em `risk_score.lua`.
- **Gotcha de subprocesso**: fechar/redirecionar o fd do socket herdado nos
  jobs `nohup` e no renderer de PDF para a resposta retornar cedo.
- **DAG**: Inc 5 agora depende de 3, 4, 6 (inclui a aba de alertas).
