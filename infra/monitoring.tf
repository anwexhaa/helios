# Azure Monitor alerting.
#
# These deliberately do NOT overlap with the Prometheus rules. Prometheus
# measures the service and runs inside the cluster, which means it cannot tell
# you about a cluster that has gone away. Everything here is about the
# platform underneath the service, and it keeps working when the cluster does
# not.
#
# Delivery for the whole project goes through one action group, so there is a
# single place to change the address.

resource "azurerm_monitor_action_group" "ops" {
  name                = "ag-${local.name}"
  resource_group_name = azurerm_resource_group.this.name
  short_name          = "helios"

  email_receiver {
    name                    = "owner"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# A node has stopped being Ready.
#
# Prometheus is running on that node. This is the canonical example of an
# alert that has to live outside the thing it watches.
# ---------------------------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "node_not_ready" {
  name                = "helios-node-not-ready"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  scopes               = [azurerm_log_analytics_workspace.this.id]
  severity             = 1
  evaluation_frequency = "PT5M"
  window_duration      = "PT15M"

  criteria {
    query                   = <<-KQL
      KubeNodeInventory
      | where TimeGenerated > ago(15m)
      | summarize arg_max(TimeGenerated, Status) by Computer
      | where Status !has "Ready"
    KQL
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  # Resolve on its own once the node recovers. An alert that has to be closed
  # by hand ends up permanently open, and then it is furniture.
  auto_mitigation_enabled = true
  description             = "A cluster node has not reported Ready for 15 minutes."

  action {
    action_groups = [azurerm_monitor_action_group.ops.id]
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# A container is crash-looping.
#
# Deliberately scoped to repeated restarts rather than any restart. A single
# restart is the platform doing its job; a pod restarting five times in
# fifteen minutes is not recovering on its own.
# ---------------------------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "crashloop" {
  name                = "helios-crashloop"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  scopes               = [azurerm_log_analytics_workspace.this.id]
  severity             = 2
  evaluation_frequency = "PT5M"
  window_duration      = "PT15M"

  criteria {
    query                   = <<-KQL
      KubePodInventory
      | where TimeGenerated > ago(15m)
      | where Namespace startswith "helios-"
      | summarize Restarts = max(PodRestartCount) - min(PodRestartCount) by Name, Namespace
      | where Restarts >= 5
    KQL
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  auto_mitigation_enabled = true
  description             = "A pod restarted 5 or more times in 15 minutes."

  action {
    action_groups = [azurerm_monitor_action_group.ops.id]
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Disk pressure on a node.
#
# On this cluster the node hosts Prometheus, and Prometheus fills disks. If
# this fires, the monitoring system is about to become the outage.
# ---------------------------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "disk_pressure" {
  name                = "helios-disk-pressure"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  scopes               = [azurerm_log_analytics_workspace.this.id]
  severity             = 2
  evaluation_frequency = "PT10M"
  window_duration      = "PT30M"

  criteria {
    query                   = <<-KQL
      InsightsMetrics
      | where TimeGenerated > ago(30m)
      | where Namespace == "container.azm.ms/disk"
      | where Name == "used_percent"
      | summarize UsedPercent = avg(Val) by Computer
      | where UsedPercent > 80
    KQL
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  auto_mitigation_enabled = true
  description             = "Node disk is above 80% used."

  action {
    action_groups = [azurerm_monitor_action_group.ops.id]
  }

  tags = local.tags
}
