terraform {
  required_version = ">= 1.2.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 5.0.0"
    }
  }
}

provider "oci" {
  region = var.region
}

locals {
  shape = "VM.Standard.A1.Flex"

  # Ports open to admin_cidr only.
  admin_ports = [22, 8443]

  # Ports open to client_cidr.
  client_ports = concat([8089], var.open_enrolment_port ? [8446] : [])

  setup_env = <<-EOT
    TAK_ZIP_URL='${var.tak_zip_url}'
    SERVER_HOSTNAME='${var.server_hostname}'
    CERT_COUNTRY='${var.cert_country}'
    CERT_STATE='${var.cert_state}'
    CERT_CITY='${var.cert_city}'
    CERT_ORG='${var.cert_org}'
    CERT_ORG_UNIT='${var.cert_org_unit}'
    OPEN_ENROLMENT_PORT='${var.open_enrolment_port}'
  EOT

  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    setup_env_b64      = base64encode(local.setup_env)
    setup_script_b64   = base64encode(file("${path.module}/scripts/tak-setup.sh"))
    add_user_b64       = base64encode(file("${path.module}/scripts/tak-add-user.sh"))
    open_ports_b64     = base64encode(file("${path.module}/scripts/open-host-firewall.sh"))
  })
}

# --- Lookups -----------------------------------------------------------------

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# Latest Canonical Ubuntu image for ARM (A1) in this region.
data "oci_core_images" "ubuntu_arm" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = var.ubuntu_version
  shape                    = local.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# --- Network -----------------------------------------------------------------

resource "oci_core_vcn" "tak" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.instance_name}-vcn"
  dns_label      = "takvcn"
}

resource "oci_core_internet_gateway" "tak" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.tak.id
  display_name   = "${var.instance_name}-igw"
  enabled        = true
}

resource "oci_core_route_table" "tak" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.tak.id
  display_name   = "${var.instance_name}-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.tak.id
  }
}

resource "oci_core_security_list" "tak" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.tak.id
  display_name   = "${var.instance_name}-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  dynamic "ingress_security_rules" {
    for_each = local.admin_ports
    content {
      protocol    = "6" # TCP
      source      = var.admin_cidr
      description = "Admin access on ${ingress_security_rules.value}"
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }

  dynamic "ingress_security_rules" {
    for_each = local.client_ports
    content {
      protocol    = "6" # TCP
      source      = var.client_cidr
      description = "TAK client access on ${ingress_security_rules.value}"
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }

  # Path MTU discovery (Oracle's default security list includes this).
  ingress_security_rules {
    protocol = "1" # ICMP
    source   = "0.0.0.0/0"
    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "tak" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.tak.id
  cidr_block                 = var.subnet_cidr
  display_name               = "${var.instance_name}-subnet"
  dns_label                  = "taksubnet"
  route_table_id             = oci_core_route_table.tak.id
  security_list_ids          = [oci_core_security_list.tak.id]
  prohibit_public_ip_on_vnic = false
}

# --- Server ------------------------------------------------------------------

resource "oci_core_instance" "tak" {
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_index].name
  display_name        = var.instance_name
  shape               = local.shape

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_gb
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_arm.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.tak.id
    assign_public_ip = true
    hostname_label   = "takserver"
  }

  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(local.cloud_init)
  }

  lifecycle {
    # A newer Ubuntu image or edited setup scripts should not rebuild a running server.
    ignore_changes = [source_details[0].source_id, metadata]
  }
}
