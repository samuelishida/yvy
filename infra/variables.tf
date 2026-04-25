variable "tenancy_ocid" {
  description = "OCID da tenancy OCI"
  type        = string
}

variable "user_ocid" {
  description = "OCID do usuário OCI"
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint da API Key"
  type        = string
}

variable "private_key_path" {
  description = "Caminho para a chave privada da API Key"
  type        = string
}

variable "region" {
  description = "Região OCI"
  type        = string
  default     = "sa-saopaulo-1"
}

variable "compartment_ocid" {
  description = "OCID do compartment (use tenancy_ocid para root)"
  type        = string
}

variable "ssh_public_key_path" {
  description = "Caminho para a chave pública SSH"
  type        = string
}

variable "project_name" {
  description = "Nome do projeto"
  type        = string
  default     = "yvy"
}

variable "environment" {
  description = "Ambiente"
  type        = string
  default     = "production"
}

variable "deploy_runtime" {
  description = "Runtime da aplicacao na VM OCI"
  type        = string
  default     = "baremetal"
}
