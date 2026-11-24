# Resource Manager fills tenancy_ocid, compartment_ocid and region automatically.

variable "tenancy_ocid" {
  type        = string
  description = "Tenancy OCID (filled in automatically by Resource Manager)."
}

variable "compartment_ocid" {
  type        = string
  description = "Compartment to build everything in."
}

variable "region" {
  type        = string
  default     = "ap-sydney-1"
  description = "Must be your tenancy's home region for Always Free compute."
}

variable "ssh_public_key" {
  type        = string
  description = "Contents of your SSH public key (e.g. ~/.ssh/id_ed25519.pub). Used to log in as 'ubuntu'."
}

variable "admin_cidr" {
  type        = string
  description = "Who may reach SSH (22) and the admin web UI (8443). One or more CIDRs, comma-separated, e.g. 203.0.113.10/32 or 203.0.113.10/32,198.51.100.7/32."

  validation {
    condition = alltrue([
      for c in split(",", var.admin_cidr) :
      can(cidrhost(trimspace(c), 0)) && trimspace(c) != "0.0.0.0/0"
    ])
    error_message = "admin_cidr must be one or more valid CIDRs (comma-separated), and must not include 0.0.0.0/0."
  }
}

variable "client_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = "Who may reach the TAK client port (8089). Phones on mobile data have changing IPs, so this is usually 0.0.0.0/0; every connection still needs a client certificate."

  validation {
    condition     = can(cidrhost(var.client_cidr, 0))
    error_message = "client_cidr must be a valid CIDR."
  }
}

variable "open_enrolment_port" {
  type        = bool
  default     = false
  description = "Open 8446 (username/password certificate enrolment) to client_cidr. Leave off unless you have configured enrolment in CoreConfig.xml."
}

variable "tak_zip_url" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional. Pre-authenticated request (PAR) URL for the takserver-docker-*.zip in Object Storage. Leave blank to copy the zip up by hand after the server boots."

  validation {
    condition     = var.tak_zip_url == "" || can(regex("^https://[^'\"\\s]+$", var.tak_zip_url))
    error_message = "Must be an https:// URL with no quotes or spaces, or blank."
  }
}

variable "server_hostname" {
  type        = string
  default     = ""
  description = "Optional DNS name you will point at the server (e.g. tak.example.org.au). If blank, certificates and data packages use the public IP."

  validation {
    condition     = var.server_hostname == "" || can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.server_hostname))
    error_message = "Use a lower-case DNS name such as tak.example.org.au, or leave blank."
  }
}

variable "cert_country" {
  type        = string
  default     = "AU"
  description = "Two-letter country code for certificates."

  validation {
    condition     = can(regex("^[A-Z]{2}$", var.cert_country))
    error_message = "Use a two-letter code in capitals, e.g. AU."
  }
}

variable "cert_state" {
  type        = string
  default     = "NSW"
  description = "State for certificates."

  validation {
    condition     = can(regex("^[A-Za-z0-9 .,&()-]{1,64}$", var.cert_state))
    error_message = "Use letters, numbers, spaces and . , & ( ) - only."
  }
}

variable "cert_city" {
  type        = string
  default     = "Newcastle"
  description = "City for certificates."

  validation {
    condition     = can(regex("^[A-Za-z0-9 .,&()-]{1,64}$", var.cert_city))
    error_message = "Use letters, numbers, spaces and . , & ( ) - only."
  }
}

variable "cert_org" {
  type        = string
  default     = "TAK"
  description = "Organisation name for certificates."

  validation {
    condition     = can(regex("^[A-Za-z0-9 .,&()-]{1,64}$", var.cert_org))
    error_message = "Use letters, numbers, spaces and . , & ( ) - only."
  }
}

variable "cert_org_unit" {
  type        = string
  default     = "TAK"
  description = "Organisational unit for certificates."

  validation {
    condition     = can(regex("^[A-Za-z0-9 .,&()-]{1,64}$", var.cert_org_unit))
    error_message = "Use letters, numbers, spaces and . , & ( ) - only."
  }
}

variable "instance_name" {
  type    = string
  default = "tak-server"
}

# Always Free allowance for Ampere A1 is 4 OCPUs and 24 GB RAM in total.
variable "ocpus" {
  type    = number
  default = 4
}

variable "memory_gb" {
  type    = number
  default = 24
}

# Always Free allowance is 200 GB of block storage in total (boot + block volumes).
variable "boot_volume_gb" {
  type    = number
  default = 100
}

variable "ubuntu_version" {
  type    = string
  default = "24.04"
}

variable "availability_domain_index" {
  type        = number
  default     = 0
  description = "Sydney has one availability domain, so leave at 0."
}

variable "vcn_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.42.1.0/24"
}
