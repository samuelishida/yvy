output "instance_public_ip" {
  description = "IP público da VM Yvy"
  value       = oci_core_instance.yvy_server.public_ip
}

output "instance_private_ip" {
  description = "IP privado da VM Yvy"
  value       = oci_core_instance.yvy_server.private_ip
}

output "instance_ocid" {
  description = "OCID da instância"
  value       = oci_core_instance.yvy_server.id
}

output "ssh_command" {
  description = "Comando SSH para acessar a VM"
  value       = "ssh -i <sua_chave_privada> ubuntu@${oci_core_instance.yvy_server.public_ip}"
}

output "app_url" {
  description = "URL da aplicação"
  value       = "http://${oci_core_instance.yvy_server.public_ip}:5001"
}
