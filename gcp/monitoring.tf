# Converge heartbeat → log-based metric → absence alert.
# The filter matches the `logger -t devbox-converge` line emitted on full
# converge success. The Ops Agent's syslog pipeline may land that line in
# either textPayload or jsonPayload.message depending on parsing, so match
# both fields — keying on textPayload alone silently never increments the
# metric and the absence alert never arms. Absence conditions only ARM once
# a series has a datapoint — the bootstrap's boot-time converge starts the
# series, and the canary checklist verifies the first heartbeat landed.
locals {
  converge_instance_filter = join(" OR ", [
    for instance in values(google_compute_instance.devbox) :
    "resource.label.instance_id = \"${instance.instance_id}\""
  ])
}

resource "google_logging_metric" "converge_success" {
  name   = "devbox-converge-success"
  filter = "resource.type=\"gce_instance\" AND (textPayload:\"devbox-converge-success\" OR jsonPayload.message:\"devbox-converge-success\")"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_monitoring_notification_channel" "devbox_email" {
  count = var.devbox_alert_email == "" ? 0 : 1

  display_name = "devbox-alerts"
  type         = "email"
  labels = {
    email_address = var.devbox_alert_email
  }
}

# 23h (82800s): Cloud Monitoring's absence-window ceiling is 23.5h. Paired
# with the 8h timer: one missed cycle (~16h gap) stays quiet, two alert.
resource "google_monitoring_alert_policy" "converge_stale" {
  count = var.devbox_alert_email == "" || length(local.machines) == 0 ? 0 : 1

  display_name = "devbox converge stale (>23h without success)"
  combiner     = "OR"

  conditions {
    display_name = "no converge_success in 23h (per machine)"
    condition_absent {
      filter   = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.converge_success.name}\" AND (${local.converge_instance_filter})"
      duration = "82800s"
    }
  }

  notification_channels = [google_monitoring_notification_channel.devbox_email[0].id]

  documentation {
    content = "A devbox has not converged in >23h (timer runs every 8h). Check: `systemctl status devbox-converge.timer devbox-converge.service` over Tailscale SSH; journald tag devbox-converge; GCS manifest reachability. Runbook: docs/admin-runbook.md, Routine operations → Roll out a runtime change."
  }
}

# Fleet investigation dashboard: per-machine host metrics. Per-process
# detail lives in each VM's Observability tab (Ops Agent processes
# receiver, Task 6) and Metrics Explorer under agent.googleapis.com/processes/*.
resource "google_monitoring_dashboard" "devbox_fleet" {
  dashboard_json = jsonencode({
    displayName = "Devbox Fleet"
    mosaicLayout = {
      columns = 12
      tiles = [
        for idx, spec in [
          { title = "CPU utilization", metric = "compute.googleapis.com/instance/cpu/utilization" },
          { title = "Memory used %", metric = "agent.googleapis.com/memory/percent_used" },
          { title = "Swap used %", metric = "agent.googleapis.com/swap/percent_used" },
          { title = "Disk used %", metric = "agent.googleapis.com/disk/percent_used" },
          ] : merge({
            width  = 6
            height = 4
            widget = {
              title = spec.title
              xyChart = {
                dataSets = [{
                  # The API fills these two defaults on write and echoes them
                  # back on read. Declaring them keeps config == API response.
                  plotType   = "LINE"
                  targetAxis = "Y1"
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = "resource.type = \"gce_instance\" AND metric.type = \"${spec.metric}\""
                      aggregation = {
                        alignmentPeriod    = "60s"
                        perSeriesAligner   = "ALIGN_MEAN"
                        crossSeriesReducer = "REDUCE_MEAN"
                        groupByFields      = ["resource.label.instance_id"]
                      }
                    }
                  }
                }]
              }
            }
          },
          # The API omits zero-valued tile positions from its response, so
          # emitting explicit zeros produced a permanent no-op plan diff.
          # Filtering them keeps config byte-equal to what the API returns.
        { for k, v in { xPos = (idx % 2) * 6, yPos = floor(idx / 2) * 4 } : k => v if v != 0 })
      ]
    }
  })
}
