# 🔐 Secrets do GitHub Actions para OCI Deploy

Para habilitar o deploy automático na OCI, configure os seguintes secrets no repositório:

## Como adicionar

1. Acesse: `https://github.com/samuelishida/yvy/settings/secrets/actions`
2. Clique em **"New repository secret"**
3. Adicione cada secret abaixo

---

## Lista de Secrets

### `OCI_TENANCY_OCID`
**Valor:** OCID da sua tenancy OCI
**Como obter:** Console OCI → Profile (canto superior direito) → Tenancy: `<nome>` → OCID

### `OCI_USER_OCID`
**Valor:** OCID do seu usuário
**Como obter:** Console OCI → Identity → Users → seu usuário → OCID

### `OCI_FINGERPRINT`
**Valor:** Fingerprint da API Key
**Como obter:** Console OCI → Identity → Users → seu usuário → API Keys → copiar o fingerprint

### `OCI_PRIVATE_KEY`
**Valor:** Conteúdo completo do arquivo `~/.oci/oci_api_key.pem`
**Como obter:**
```bash
cat ~/.oci/oci_api_key.pem
```
Cole o conteúdo inteiro, incluindo as linhas `-----BEGIN PRIVATE KEY-----` e `-----END PRIVATE KEY-----`.

### `OCI_REGION`
**Valor:** `sa-saopaulo-1` (ou sua região)
**Como obter:** Console OCI → região selecionada no canto superior direito

### `OCI_COMPARTMENT_OCID`
**Valor:** OCID do compartment onde a VM será criada
**Como obter:** Console OCI → Identity → Compartments → compartment desejado → OCID
**Dica:** Use o mesmo valor de `OCI_TENANCY_OCID` para criar no root compartment.

### `OCI_SSH_PUBLIC_KEY`
**Valor:** Conteúdo de `~/.ssh/oci_yvy.pub`
**Como obter:**
```bash
cat ~/.ssh/oci_yvy.pub
```

### `OCI_SSH_PRIVATE_KEY`
**Valor:** Conteúdo de `~/.ssh/oci_yvy` (sem `.pub`)
**Como obter:**
```bash
cat ~/.ssh/oci_yvy
```
Cole o conteúdo inteiro, incluindo `-----BEGIN OPENSSH PRIVATE KEY-----`.

---

## ⚠️ Segurança

- **NUNCA** commite esses valores no repositório
- **NUNCA** compartilhe a chave privada OCI ou SSH
- As chaves privadas no GitHub Actions são criptografadas e só disponíveis nos workflows
- Rotacione as chaves periodicamente (a cada 6 meses)

---

## Verificação

Após configurar todos os secrets, teste com um deploy manual:

1. Acesse: `https://github.com/samuelishida/yvy/actions`
2. Clique em **"Deploy to OCI"**
3. Clique em **"Run workflow"** → selecione a branch `main` → **"Run workflow"**

O workflow deve executar com sucesso e exibir a URL da aplicação no final.
