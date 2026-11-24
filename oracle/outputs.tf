output "public_ip" {
  description = "Server public IP. Stays the same across stop/start; changes if the server is destroyed and rebuilt."
  value       = oci_core_instance.tak.public_ip
}

output "ssh_command" {
  value = "ssh ubuntu@${oci_core_instance.tak.public_ip}"
}

output "setup_log" {
  description = "Watch the install (takes 10-20 minutes)."
  value       = "ssh ubuntu@${oci_core_instance.tak.public_ip} 'sudo tail -f /var/log/tak-setup.log'"
}

output "admin_url" {
  description = "Admin web UI. Import admin.p12 into your browser first."
  value       = "https://${var.server_hostname != "" ? var.server_hostname : oci_core_instance.tak.public_ip}:8443"
}

output "client_endpoint" {
  value = "${var.server_hostname != "" ? var.server_hostname : oci_core_instance.tak.public_ip}:8089 (TLS)"
}

output "ubuntu_image" {
  description = "Ubuntu image the server was built from."
  value       = data.oci_core_images.ubuntu_arm.images[0].display_name
}
