# Yvy Implementation Plan

## Objetivo
Criar um plano de implementação para fortalecer a aplicação Yvy em três áreas principais:

- segurança e produção
- qualidade do código e observabilidade
- infraestrutura de desenvolvimento e implantação

## Escopo
O plano foca em mudanças de curto e médio prazo que são compatíveis com a arquitetura atual:

- backend Flask em `backend/`
- frontend Flask em `frontend/`
- MongoDB via Docker Compose
- ingestão de dados TerraBrasilis com `backend/ingest.py`

## Prioridades
1. Corrigir problemas críticos de Docker e imagem
2. Proteger o backend com validação e limites
3. Adicionar logs e sinalização de término
4. Criar pipeline de CI/CD básica
5. Estabelecer paridade de ambiente e configuração
6. Sempre testar apos code changes

## 1. Docker e imagens seguras

### 1.1 Atualizar bases de imagem
- Substituir `python:3.9-slim` por `python:3.12-slim` ou `python:3.13-slim`.
- Garantir imagem compatível com dependências atuais.

### 1.2 Reduzir superfície de ataque
- Remover `build-essential` e `wget` das imagens de produção.
- Instalar apenas o necessário para runtime.

### 1.3 Adicionar `.dockerignore`
- Excluir `.env`, `.venv`, `mongo_data/`, `__pycache__/`, `*.pyc`, `*.pyo` e arquivos temporários.

### 1.4 Rodar como usuário não-root
- Criar usuário não-root nas Dockerfiles do backend e frontend.

## 2. Validação e segurança do backend

### 2.1 Validar parâmetros do endpoint `/data`
- Verificar `ne_lat`, `ne_lng`, `sw_lat`, `sw_lng`.
- Validar tipos numéricos.
- Validar intervalo geográfico: `ne_lat > sw_lat` e `ne_lng > sw_lng`.
- Responder com 400 quando estiver incorreto.

### 2.2 Limitar taxa e volume
- Adicionar proteção contra requisições abusivas no endpoint `/data`.
- Implementar cache leve ou rate limiting no backend.

### 2.3 Revisar credenciais e variáveis de ambiente
- Garantir `MONGO_ROOT_PASSWORD` nunca em repositório.
- Usar `.env.example` apenas como template.

## 3. Observabilidade e logs

### 3.1 Remover `print()` de produção
- Substituir saídas por `logging` do Python.
- Usar formato estruturado ou simples com timestamp.

### 3.2 Configurar log configuration
- Definir logger no `backend` e `frontend`.
- Registrar nível default, erros e avisos.
- Garantir logs importantes no startup, ingestão e erros de API.

### 3.3 Adicionar monitoramento básico
- Adicionar endpoints de health check se não existirem.

## 4. CI/CD e testes automatizados

### 4.1 Pipeline de CI/CD
- Criar fluxo GitHub Actions ou GitLab CI.
- Executar `pytest` no backend.
- Executar validação de lint se houver configuração.

### 4.2 Garantir execução de testes no container
- Validar comando de teste em `.venv` e em container Docker.
- Documentar o processo no README.

## 5. Ambiente e configuração

### 5.1 Paridade de ambientes
- Documentar `.env.dev` / `.env.prod` se necessário.
- Garantir `DEV=1` habilita modo de desenvolvimento e `DEV=0` modo produção.

### 5.2 Documentação de variáveis
- Atualizar README sobre variáveis de ambiente exigidas.
- Incluir exemplos de configuração para dev e prod.

## 6. Disponibilidade e shutdown

### 6.1 Graceful shutdown
- Adicionar tratamento de `SIGTERM`/`SIGINT` no backend e frontend Flask.
- Configurar gunicorn se usado em produção com `--timeout` e `--graceful-timeout`.

### 6.2 Atualizar Docker Compose
- Garantir reinício e dependências corretas.
- Verificar `healthcheck` para backend e frontend.

## Tarefas detalhadas

### Tarefa A: Dockerfiles e .dockerignore
- Atualizar backend/ Dockerfile
- Atualizar frontend/ Dockerfile
- Criar `.dockerignore`

### Tarefa B: Validação de API
- Implementar validação do `/data` no `backend.py`
- Adicionar testes unitários para entradas válidas e inválidas

### Tarefa C: Logging e monitoração
- Substituir `print()` por `logging`
- Adicionar health check e logs de startup

### Tarefa D: CI/CD
- Criar arquivo de pipeline (`.github/workflows/ci.yml` ou `.gitlab-ci.yml`)
- Incluir etapas: instalar dependências, executar testes, verificar lint

### Tarefa E: Documentação e ambiente
- Atualizar README com comandos corretos e novos requisitos
- Adicionar exemplos para `.env.dev` e `.env.prod` se aplicável

## Riscos e dependências
- Dependências de imagem Docker podem variar com Python 3.12/3.13.
- Ingestão de dados TIF requer arquivos de entrada disponíveis.
- Rate limiting pode precisar de armazenamento compartilhado se for uma implementação distribuída.

## Aproximação recomendada
1. Começar pela correção de Dockerfiles e `.dockerignore`.
2. Implementar validação e testes de API no backend.
3. Adicionar logging e health checks.
4. Criar pipeline de CI/CD.
5. Atualizar documentação e variáveis de ambiente.

## Resultado esperado
Uma aplicação Yvy mais segura, rastreável e confiável, com controle de qualidade automatizado e documentação alinhada ao ambiente de execução.
