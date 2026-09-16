variable "project" {
  description = "Short project name, used as the prefix for every resource name."
  type        = string
  default     = "helios"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,11}$", var.project))
    error_message = "project must be 3-12 lowercase alphanumeric characters starting with a letter."
  }
}

variable "location" {
  description = "Azure region. Keep every resource in one region; cross-region traffic is billed."
  type        = string
  default     = "centralindia"
}

variable "environment" {
  description = "Name for this instance of the infrastructure, not the app environments inside it."
  type        = string
  default     = "shared"
}

variable "kubernetes_version" {
  description = "AKS control plane version. Null takes the region default, which is what you want unless a specific version is being tested."
  type        = string
  default     = null
}

variable "node_size" {
  description = "VM size for the cluster node pool. B-series is burstable and the cheapest option that will run this workload."
  type        = string
  default     = "Standard_B2s"
}

variable "node_min_count" {
  description = "Floor for the cluster autoscaler. One node is enough at rest."
  type        = number
  default     = 1

  validation {
    condition     = var.node_min_count >= 1
    error_message = "node_min_count must be at least 1; AKS cannot schedule system pods on zero nodes."
  }
}

variable "node_max_count" {
  description = "Ceiling for the cluster autoscaler. Each B2s is 2 vCPUs, so this is bounded by the subscription's regional vCPU quota."
  type        = number

  # 2, not 3, because this subscription is an Azure free trial: a hard cap of
  # 4 regional vCPUs that Microsoft does not raise on request. Two B2s nodes
  # is exactly 4. Raise this to 3 or more only after upgrading to
  # pay-as-you-go and being granted a higher quota.
  #
  #   az vm list-usage --location centralindia --output table
  default = 2

  validation {
    condition     = var.node_max_count >= var.node_min_count
    error_message = "node_max_count must be greater than or equal to node_min_count."
  }
}

variable "log_retention_days" {
  description = "Log Analytics retention. 30 days sits inside the free allowance."
  type        = number
  default     = 30
}

variable "vnet_cidr" {
  description = "Address space for the virtual network."
  type        = string
  default     = "10.0.0.0/16"
}

variable "aks_subnet_cidr" {
  description = "Subnet for cluster nodes and pods. With Azure CNI every pod takes an address from here, so size it for node_max_count * max_pods."
  type        = string
  default     = "10.0.1.0/24"
}

variable "service_cidr" {
  description = "Kubernetes Service address range. Must not overlap vnet_cidr."
  type        = string
  default     = "10.1.0.0/16"
}

variable "dns_service_ip" {
  description = "Cluster DNS address. Must sit inside service_cidr."
  type        = string
  default     = "10.1.0.10"
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}
