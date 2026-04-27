# Grafana dashboards

Three dashboards, intentionally simple. All built around the Prometheus / Loki
/ Tempo stack provisioned by `k8s/infrastructure/base/observability/` and the
alerts defined in `kube-prometheus-stack/values.yaml`
(`additionalPrometheusRulesMap.openpanel-alerts`).

```
grafana-dashboards/
├── cluster.json        # Cluster summary + per-node detail + active alerts
├── openpanel.json      # OpenPanel pods/resources + Databases
└── logs-traces.json    # Loki logs (top) and Tempo traces (bottom)
```

## What goes where

**Cluster (`cluster.json`)** — top row is the cluster at a glance (nodes ready,
pods running, CPU, memory). Below that is the most important node-level
detail: per-node CPU, memory, root-filesystem fill, network I/O, pod restarts.
The bottom panel is an `alertlist` filtered to every cluster/node alert
(`KubeNode*`, `KubePod*`, `NodeFilesystem*`, `NodeMemory*`, `KubeletDown`,
`HighMemoryUsage`, etc.) so you can see what's firing without leaving the
dashboard.

**OpenPanel (`openpanel.json`)** — top section covers the application: pods
running / not ready, API up?, recent restarts, per-pod CPU and memory (vs
limit), and the API RED metrics (rate / errors / duration). Bottom section
covers the databases: Postgres / Redis / ClickHouse up?, PVC fill, Postgres
connections, Redis memory. Each `up?` stat falls back to `vector(0)` (DOWN)
when the scrape target is missing, so a missing exporter shows up as a clear
red tile rather than an empty panel. Active OpenPanel alerts live on the
cluster dashboard's alertlist and in Alertmanager — they were intentionally
removed from this dashboard to keep it focused on signals, not state.

**Logs & Traces (`logs-traces.json`)** — one dashboard, three sections.
Overview: three stat tiles (log ingest rate, error rate, warning rate) coloured
red/orange whenever they go above zero, so the dashboard is readable at a
glance. Logs: a stacked log-volume timeseries with explicit per-level colours
(error=red, warn=orange, info=blue, debug=grey) and a live tail filtered to
`error|warn|fatal|panic` for the chosen namespace. Traces: recent traces and
a separate panel filtered to `duration > 1s`. The Tempo panels filter on
`resource.service.namespace` (the OTel attribute the apps actually emit, set
via `OTEL_RESOURCE_ATTRIBUTES` in each overlay) — not `k8s.namespace.name`,
which the SDK does not populate. The Loki datasource has a `derivedField`
that turns any `traceID=…` token into a clickable link into Tempo, so you
can pivot from a log line straight to the trace.

## Variables

| Dashboard      | Variable    | What it does                                       |
|----------------|-------------|----------------------------------------------------|
| Cluster        | `ds_prom`   | Prometheus datasource                              |
| Cluster        | `node`      | Filter the per-node panels to one or more nodes    |
| OpenPanel      | `ds_prom`   | Prometheus datasource                              |
| Logs & Traces  | `ds_loki`   | Loki datasource                                    |
| Logs & Traces  | `ds_tempo`  | Tempo datasource                                   |
| Logs & Traces  | `namespace` | Namespace to scope logs and traces to              |
| Logs & Traces  | `logfilter` | Free-text regex applied to the live log tail       |
| Logs & Traces  | `service`   | Regex applied to `resource.service.name` in TraceQL (default `.*`) |

## How they get into Grafana

GitOps — the dashboards are wrapped in ConfigMaps by the kustomization at
`k8s/infrastructure/overlays/<env>/observability/grafana/`. Each ConfigMap
carries the label `grafana_dashboard: "1"` and a `grafana_folder` annotation,
so the Grafana sidecar (configured in
`k8s/infrastructure/base/observability/grafana/values.yaml`) picks them up
without a Grafana restart.

To render and apply by hand:

```sh
kustomize build --enable-helm \
  k8s/infrastructure/overlays/staging/observability/grafana \
  | kubectl apply -f -
```

To import a single dashboard into a local Grafana for editing,
**Dashboards → New → Import** and upload the JSON file.

## Editing

Each panel has a `description` that explains what it shows and why it matters.
If you change a panel, update its `description` so the next person reading
the dashboard does not have to guess. If you add or remove a custom alert in
`kube-prometheus-stack/values.yaml`, also update the `alertInstanceLabelFilter`
on the matching `alertlist` panel.
