terraform {
    backend "local" {
    }
}

provider "azurerm" {
  alias  = "production"

  features {}

  subscription_id = var.subscription_production

  version = "~>2.21.0"
}

provider "azurerm" {
    #alias = "target"

    features {}

    subscription_id = var.environment == "production" ? var.subscription_production : var.subscription_test

    version = "~>2.21.0"
}

provider "azuread" {
  version = "=0.11.0"

  subscription_id = var.environment == "production" ? var.subscription_production : var.subscription_test
}


#
# LOCALS
#

locals {
  location_map = {
    australiacentral = "auc",
    australiacentral2 = "auc2",
    australiaeast = "aue",
    australiasoutheast = "ause",
    brazilsouth = "brs",
    canadacentral = "cac",
    canadaeast = "cae",
    centralindia = "inc",
    centralus = "usc",
    eastasia = "ase",
    eastus = "use",
    eastus2 = "use2",
    francecentral = "frc",
    francesouth = "frs",
    germanynorth = "den",
    germanywestcentral = "dewc",
    japaneast = "jpe",
    japanwest = "jpw",
    koreacentral = "krc",
    koreasouth = "kre",
    northcentralus = "usnc",
    northeurope = "eun",
    norwayeast = "noe",
    norwaywest = "now",
    southafricanorth = "zan",
    southafricawest = "zaw",
    southcentralus = "ussc",
    southeastasia = "asse",
    southindia = "ins",
    switzerlandnorth = "chn",
    switzerlandwest = "chw",
    uaecentral = "aec",
    uaenorth = "aen",
    uksouth = "uks",
    ukwest = "ukw",
    westcentralus = "uswc",
    westeurope = "euw",
    westindia = "inw",
    westus = "usw",
    westus2 = "usw2",
  }
}

locals {
  environment_short = substr(var.environment, 0, 1)
  location_short = lookup(local.location_map, var.location, "aue")
}

# Name prefixes
locals {
  name_prefix = "${local.environment_short}-${local.location_short}"
  name_prefix_tf = "${local.name_prefix}-tf-${var.category}-${var.spoke_id}"
}

locals {
  common_tags = {
    category    = "${var.category}"
    environment = "${var.environment}"
    image_version = "${var.resource_version}"
    location    = "${var.location}"
    source      = "${var.meta_source}"
    version     = "${var.meta_version}"
  }

  extra_tags = {
  }
}

locals {
  admin_username = "thebigkahuna"
}

data "azurerm_client_config" "current" {}

locals {
  spoke_base_name = "t-aue-tf-nwk-spoke-${var.spoke_id}"
  spoke_resource_group = "${local.spoke_base_name}-rg"
  spoke_vnet = "${local.spoke_base_name}-vn"
}

data "azurerm_log_analytics_workspace" "log_analytics_workspace" {
  name = "p-aue-tf-analytics-law-logs"
  provider = azurerm.production
  resource_group_name = "p-aue-tf-analytics-rg"
}

data "azurerm_subnet" "sn" {
  name = "${local.spoke_base_name}-sn"
  virtual_network_name = local.spoke_vnet
  resource_group_name = local.spoke_resource_group
}

data "azuread_group" "consul_server_discovery" {
  name = "${local.spoke_base_name}-adg-consul-cloud-join"
}


#
# RESOURCE GROUP
#

resource "azurerm_resource_group" "rg" {
    name = "${local.name_prefix_tf}-rg"
    location = var.location

    tags = merge( local.common_tags, local.extra_tags, var.tags )
}

#
# ROLES
#

resource "azurerm_role_definition" "consul_server_discovery" {
    description = "A custom role that allows Consul nodes to discover the server nodes in their environment."
    name = "${local.name_prefix_tf}-rd-consul-cloud-join"
    scope = azurerm_resource_group.rg.id

    permissions {
        actions = [
            "Microsoft.Network/networkInterfaces/read"
        ]
        not_actions = []
    }

    assignable_scopes = [
        azurerm_resource_group.rg.id
    ]
}

resource "azurerm_role_assignment" "consul_server_discovery" {
    principal_id  = data.azuread_group.consul_server_discovery.id
    role_definition_id = azurerm_role_definition.consul_server_discovery.id
    scope = azurerm_resource_group.rg.id
}


#
# CONSUL SERVER
#

locals {
    name_consul_server = "consul-server"
}

# Locate the existing consul image
data "azurerm_image" "search_consul_server" {
    name = "resource-hashi-server-${var.resource_version}"
    resource_group_name = "t-aue-artefacts-rg"
}

resource "azurerm_network_interface" "nic_consul_server" {
    count = var.cluster_size

    ip_configuration {
        name = "${local.name_prefix_tf}-nicconf-consul-server-${count.index}"
        subnet_id = data.azurerm_subnet.sn.id
        private_ip_address_allocation = "dynamic"
    }

    location = var.location
    name = "${local.name_prefix_tf}-nic-consul-server-${count.index}"
    resource_group_name = azurerm_resource_group.rg.name

    tags = merge(
        local.common_tags,
        local.extra_tags,
        var.tags,
        {
            "consul_server_id" = local.name_prefix_tf
            "datacenter" = var.datacenter
        } )
}

resource "azurerm_network_interface_security_group_association" "nic_nsg_consul_server" {
    count = var.cluster_size
    network_interface_id = element(azurerm_network_interface.nic_consul_server.*.id, count.index)
    network_security_group_id = data.azurerm_subnet.sn.network_security_group_id
}

resource "azurerm_linux_virtual_machine" "vm_consul_server" {
    admin_password = var.admin_password
    admin_username = local.admin_username

    computer_name = "${local.name_prefix_tf}-${local.name_consul_server}-${count.index}"

    count = var.cluster_size

    custom_data = base64encode(templatefile(
        "${abspath(path.root)}/cloud_init_server.yaml",
        {
            cluster_size = var.cluster_size,
            datacenter = var.datacenter,
            domain = var.domain_consul,
            encrypt = var.encrypt_consul,
            environment_id = local.name_prefix_tf,
            subscription = var.environment == "production" ? var.subscription_production : var.subscription_test,
            vnet_forward_ip = cidrhost(data.azurerm_subnet.sn.address_prefixes[0], 1)
        }))

    disable_password_authentication = false

    identity {
        type = "SystemAssigned"
    }

    location = var.location

    name = "${local.name_prefix_tf}-vm-${local.name_consul_server}-${count.index}"

    network_interface_ids = ["${element(azurerm_network_interface.nic_consul_server.*.id,count.index)}"]

    os_disk {
        caching = "ReadWrite"
        name = "${local.name_prefix_tf}-vm-disk-${local.name_consul_server}-${count.index}-os"
        storage_account_type = "Premium_LRS"
    }

    resource_group_name = azurerm_resource_group.rg.name

    size = "Standard_DS1_v2"

    source_image_id = data.azurerm_image.search_consul_server.id

    tags = merge(
        local.common_tags,
        local.extra_tags,
        var.tags,
        {
            "datacenter" = var.datacenter
        } )
}

resource "azuread_group_member" "consul_server_cluster_discovery" {
    count = var.cluster_size

    group_object_id = data.azuread_group.consul_server_discovery.id
    member_object_id  = azurerm_linux_virtual_machine.vm_consul_server[count.index].identity.0.principal_id
}


#
# Consul UI
#

locals {
    name_consul_ui = "consul-ui"
}

# Locate the existing consul image
data "azurerm_image" "search_consul_ui" {
    name = "resource-hashi-ui-${var.resource_version}"
    provider = azurerm.production
    resource_group_name = "p-aue-artefacts-rg"
}

resource "azurerm_network_interface" "nic_consul_ui" {
    ip_configuration {
        name = "${local.name_prefix_tf}-nicconf-consul-ui"
        subnet_id = data.azurerm_subnet.sn.id
        private_ip_address_allocation = "dynamic"
    }

    location = var.location
    name = "${local.name_prefix_tf}-nic-consul-ui"
    resource_group_name = azurerm_resource_group.rg.name

    tags = merge( local.common_tags, local.extra_tags, var.tags )
}

resource "azurerm_network_interface_security_group_association" "nic_nsg_consul_ui" {
    network_interface_id = azurerm_network_interface.nic_consul_ui.id
    network_security_group_id = data.azurerm_subnet.sn.network_security_group_id
}

resource "azurerm_linux_virtual_machine" "vm_consul_ui" {
    # The machines can deal with SSH certificates, but they are obtained via Vault
    admin_password = var.admin_password
    admin_username = local.admin_username

    computer_name = "${local.name_prefix_tf}-${local.name_consul_ui}"

    custom_data = base64encode(templatefile(
        "${abspath(path.root)}/cloud_init_client.yaml",
        {
            category = var.category,
            datacenter = var.datacenter,
            domain = var.domain_consul,
            encrypt = var.encrypt_consul,
            environment_id = local.name_prefix_tf,
            vnet_forward_ip = cidrhost(data.azurerm_subnet.sn.address_prefixes[0], 1)
        }))

    disable_password_authentication = false

    identity {
        type = "SystemAssigned"
    }

    location = var.location

    name = "${local.name_prefix_tf}-vm-${local.name_consul_ui}"

    network_interface_ids = ["${azurerm_network_interface.nic_consul_ui.id}"]

    os_disk {
        caching = "ReadWrite"
        name = "${local.name_prefix_tf}-vm-disk-${local.name_consul_ui}-os"
        storage_account_type = "Premium_LRS"
    }

    resource_group_name = azurerm_resource_group.rg.name

    size = "Standard_DS1_v2"

    source_image_id = data.azurerm_image.search_consul_ui.id

    tags = merge(
        local.common_tags,
        local.extra_tags,
        var.tags,
        {
            "datacenter" = var.datacenter
        } )
}

resource "azuread_group_member" "consul_ui_cluster_discovery" {
    group_object_id = data.azuread_group.consul_server_discovery.id
    member_object_id  = azurerm_linux_virtual_machine.vm_consul_ui.identity.0.principal_id
}
