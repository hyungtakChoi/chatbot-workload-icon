provider "azurerm" {
  features {}
}

# Resource group
resource "azurerm_resource_group" "chatbot_rg" {
  name     = "chatbot-resource-group"
  location = "koreacentral"
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Virtual network
resource "azurerm_virtual_network" "chatbot_vnet" {
  name                = "chatbot-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.chatbot_rg.location
  resource_group_name = azurerm_resource_group.chatbot_rg.name
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Subnet
resource "azurerm_subnet" "chatbot_subnet" {
  name                 = "chatbot-subnet"
  resource_group_name  = azurerm_resource_group.chatbot_rg.name
  virtual_network_name = azurerm_virtual_network.chatbot_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Network security group
resource "azurerm_network_security_group" "chatbot_nsg" {
  name                = "chatbot-nsg"
  location            = azurerm_resource_group.chatbot_rg.location
  resource_group_name = azurerm_resource_group.chatbot_rg.name
  
  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "HTTPS"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Public IP
resource "azurerm_public_ip" "chatbot_public_ip" {
  name                = "chatbot-public-ip"
  location            = azurerm_resource_group.chatbot_rg.location
  resource_group_name = azurerm_resource_group.chatbot_rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Network interface
resource "azurerm_network_interface" "chatbot_nic" {
  name                = "chatbot-nic"
  location            = azurerm_resource_group.chatbot_rg.location
  resource_group_name = azurerm_resource_group.chatbot_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.chatbot_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.chatbot_public_ip.id
  }
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Associate NSG with NIC
resource "azurerm_network_interface_security_group_association" "chatbot_nsg_assoc" {
  network_interface_id      = azurerm_network_interface.chatbot_nic.id
  network_security_group_id = azurerm_network_security_group.chatbot_nsg.id
}

# GPU VM - NV6ads_A10_v5 (A10 GPU)
resource "azurerm_linux_virtual_machine" "chatbot_vm" {
  name                  = "chatbot-gpu-vm"
  location              = azurerm_resource_group.chatbot_rg.location
  resource_group_name   = azurerm_resource_group.chatbot_rg.name
  size                  = "Standard_NV6ads_A10_v5"
  admin_username        = "adminuser"
  network_interface_ids = [azurerm_network_interface.chatbot_nic.id]

  admin_ssh_key {
    username   = "adminuser"
    public_key = file("~/.ssh/id_rsa.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Managed disk for model storage
resource "azurerm_managed_disk" "chatbot_data_disk" {
  name                 = "chatbot-data-disk"
  location             = azurerm_resource_group.chatbot_rg.location
  resource_group_name  = azurerm_resource_group.chatbot_rg.name
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = 100
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Attach managed disk to VM
resource "azurerm_virtual_machine_data_disk_attachment" "chatbot_disk_attach" {
  managed_disk_id    = azurerm_managed_disk.chatbot_data_disk.id
  virtual_machine_id = azurerm_linux_virtual_machine.chatbot_vm.id
  lun                = "10"
  caching            = "ReadWrite"
}

# Azure Application Gateway for load balancing
resource "azurerm_application_gateway" "chatbot_appgw" {
  name                = "chatbot-appgateway"
  resource_group_name = azurerm_resource_group.chatbot_rg.name
  location            = azurerm_resource_group.chatbot_rg.location

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "gateway-ip-config"
    subnet_id = azurerm_subnet.chatbot_subnet.id
  }

  frontend_port {
    name = "https-port"
    port = 443
  }

  frontend_ip_configuration {
    name                 = "frontend-ip-config"
    public_ip_address_id = azurerm_public_ip.chatbot_public_ip.id
  }

  backend_address_pool {
    name = "backend-pool"
  }

  backend_http_settings {
    name                  = "http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 60
  }

  http_listener {
    name                           = "https-listener"
    frontend_ip_configuration_name = "frontend-ip-config"
    frontend_port_name             = "https-port"
    protocol                       = "Https"
    ssl_certificate_name           = "ssl-cert"
  }

  request_routing_rule {
    name                       = "routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "https-listener"
    backend_address_pool_name  = "backend-pool"
    backend_http_settings_name = "http-settings"
    priority                   = 1
  }
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Azure Key Vault for secrets management
resource "azurerm_key_vault" "chatbot_kv" {
  name                        = "chatbot-keyvault"
  location                    = azurerm_resource_group.chatbot_rg.location
  resource_group_name         = azurerm_resource_group.chatbot_rg.name
  enabled_for_disk_encryption = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false

  sku_name = "standard"
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Azure Monitor for monitoring
resource "azurerm_log_analytics_workspace" "chatbot_logs" {
  name                = "chatbot-logs-workspace"
  location            = azurerm_resource_group.chatbot_rg.location
  resource_group_name = azurerm_resource_group.chatbot_rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Application Insights for telemetry
resource "azurerm_application_insights" "chatbot_insights" {
  name                = "chatbot-appinsights"
  location            = azurerm_resource_group.chatbot_rg.location
  resource_group_name = azurerm_resource_group.chatbot_rg.name
  workspace_id        = azurerm_log_analytics_workspace.chatbot_logs.id
  application_type    = "web"
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Data source for Azure client configuration
data "azurerm_client_config" "current" {}

# Output public IP
output "chatbot_public_ip" {
  value = azurerm_public_ip.chatbot_public_ip.ip_address
}