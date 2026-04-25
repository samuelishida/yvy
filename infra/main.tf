# ---------------------------------------------------------------------------
# Dados
# ---------------------------------------------------------------------------
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = "VM.Standard.E2.1.Micro"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# ---------------------------------------------------------------------------
# VCN e Networking
# ---------------------------------------------------------------------------
resource "oci_core_vcn" "yvy_vcn" {
  compartment_id = var.compartment_ocid
  cidr_block     = "10.0.0.0/16"
  display_name   = "${var.project_name}-vcn"
  dns_label      = var.project_name
}

resource "oci_core_internet_gateway" "yvy_igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.yvy_vcn.id
  display_name   = "${var.project_name}-igw"
}

resource "oci_core_route_table" "yvy_public_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.yvy_vcn.id
  display_name   = "${var.project_name}-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.yvy_igw.id
  }
}

resource "oci_core_subnet" "yvy_public_subnet" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.yvy_vcn.id
  cidr_block        = "10.0.0.0/24"
  display_name      = "${var.project_name}-public-subnet"
  dns_label         = "public"
  route_table_id    = oci_core_route_table.yvy_public_rt.id
  security_list_ids = [oci_core_security_list.yvy_security_list.id]
}

# ---------------------------------------------------------------------------
# Security List (Firewall da nuvem)
# ---------------------------------------------------------------------------
resource "oci_core_security_list" "yvy_security_list" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.yvy_vcn.id
  display_name   = "${var.project_name}-security-list"

  # SSH
  ingress_security_rules {
    protocol  = "6" # TCP
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Yvy Frontend
  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 5001
      max = 5001
    }
  }

  # HTTP (para redirect/Cloudflare)
  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 80
      max = 80
    }
  }

  # HTTPS (para SSL futuro)
  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 443
      max = 443
    }
  }

  # ICMP (para ping/debug)
  ingress_security_rules {
    protocol  = "1" # ICMP
    source    = "0.0.0.0/0"
    stateless = false
    icmp_options {
      type = 8
      code = 0
    }
  }

  # Egress livre
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    stateless   = false
  }
}

# ---------------------------------------------------------------------------
# VM Always Free — Micro (VM.Standard.E2.1.Micro)
# Fallback: tenta AD-2 se AD-1 estiver sem capacidade
# ---------------------------------------------------------------------------
locals {
  ad_name = length(data.oci_identity_availability_domains.ads.availability_domains) > 1 ? data.oci_identity_availability_domains.ads.availability_domains[1].name : data.oci_identity_availability_domains.ads.availability_domains[0].name
}

resource "oci_core_instance" "yvy_server" {
  compartment_id      = var.compartment_ocid
  availability_domain = local.ad_name
  display_name        = "${var.project_name}-server"
  shape               = "VM.Standard.E2.1.Micro"

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = 50
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.yvy_public_subnet.id
    assign_public_ip = true
    display_name     = "${var.project_name}-vnic"
  }

  metadata = {
    ssh_authorized_keys = file(var.ssh_public_key_path)
    user_data           = base64encode(templatefile("${path.module}/cloud-init.yml", {}))
  }

  preserve_boot_volume = false

  freeform_tags = {
    Project     = var.project_name
    Environment = var.environment
    Runtime     = var.deploy_runtime
    ManagedBy   = "terraform"
  }
}
