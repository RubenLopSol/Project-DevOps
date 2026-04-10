# Exploración del Stack Local — Docker Compose

Verificación manual de todos los servicios del stack OpenPanel corriendo en local.

---

## 1. Levantar el stack

```bash
docker compose up -d
```

**Resultado:**
```
✔ postgres    Healthy
✔ redis       Healthy
✔ clickhouse  Healthy
✔ loki        Healthy
✔ prometheus  Started
✔ grafana     Started
✔ promtail    Started
✔ migrate     Exited (correcto — job de migraciones, corre y termina)
✔ api         Healthy
✔ worker      Started
✔ dashboard   Started
```

> **Nota:** El servicio `migrate` aparece como `Exited` — es correcto. Es un Job que ejecuta las migraciones de Prisma y termina. La API y el Worker solo arrancan después de que este Job termina con éxito.

---

## 2. API Healthcheck

```bash
curl http://localhost:3333/healthcheck
```

**Resultado:**
```json
{
  "ready": true,
  "redis": true,
  "db": true,
  "ch": true
}
```

La API confirma que tiene conectividad con Redis, PostgreSQL y ClickHouse.

---

## 3. Crear usuario via API

```bash
curl -X POST http://localhost:3333/trpc/auth.signUpEmail \
  -H "Content-Type: application/json" \
  -d '{"json":{"firstName":"Ruben","lastName":"Lopez","email":"ruben@test.com","password":"Test1234!","confirmPassword":"Test1234!"}}' | jq
```

**Resultado:**
```json
{
  "result": {
    "data": {
      "json": {
        "id": "b5ffed75700fbc4850aad4387aa3681b13bfa3075736a03f5e52b7a16547e11c",
        "userId": "user_xCeWCdGh3Ivw1W4bZH",
        "expiresAt": "2026-05-10T12:06:42.037Z",
        "createdAt": "2026-04-10T12:06:42.037Z",
        "updatedAt": "2026-04-10T12:06:42.037Z"
      }
    }
  }
}
```

- `userId` — ID del usuario creado en PostgreSQL
- `id` — token de sesión
- `expiresAt` — la sesión expira en 30 días

---

## 4. PostgreSQL — Verificar tablas (Prisma migrations)

```bash
docker compose exec postgres psql -U openpanel -d openpanel -c "\dt"
```

**Resultado:** 31 tablas creadas por Prisma migrations:

```
accounts, chats, clients, dashboards, email_unsubscribes, event_meta,
imports, insight_events, integrations, invites, members, notification_rules,
notifications, organizations, project_access, project_insights, projects,
references, report_layouts, reports, reset_password, salts, sessions,
share_dashboards, share_reports, share_widgets, shares, users, ...
```

---

## 5. PostgreSQL — Verificar usuario creado

```bash
docker compose exec postgres psql -U openpanel -d openpanel -t \
  -c "SELECT json_agg(row_to_json(t)) FROM (SELECT id, email, \"firstName\", \"lastName\", \"createdAt\" FROM users) t;" | jq
```

**Resultado:**
```json
[
  {
    "id": "user_xCeWCdGh3Ivw1W4bZH",
    "email": "ruben@test.com",
    "firstName": "Ruben",
    "lastName": "Lopez",
    "createdAt": "2026-04-10T12:06:42.031"
  }
]
```

---

## 6. PostgreSQL — Verificar sesión

Las sesiones se guardan en **PostgreSQL**, no en Redis.

```bash
docker compose exec postgres psql -U openpanel -d openpanel -t \
  -c "SELECT json_agg(row_to_json(t)) FROM (SELECT id, \"userId\", \"expiresAt\", \"createdAt\" FROM sessions) t;" | jq
```

**Resultado:**
```json
[
  {
    "id": "b5ffed75700fbc4850aad4387aa3681b13bfa3075736a03f5e52b7a16547e11c",
    "userId": "user_xCeWCdGh3Ivw1W4bZH",
    "expiresAt": "2026-05-10T12:06:42.037",
    "createdAt": "2026-04-10T12:06:42.037"
  }
]
```

---

## 7. Redis — Colas BullMQ

Redis no almacena sesiones — almacena las **colas de procesamiento** (BullMQ).

```bash
docker compose exec redis redis-cli KEYS "*"
```

**Claves principales encontradas:**
```
bull:cron:repeat:flushEvents     — procesa eventos analytics en batches → ClickHouse
bull:cron:repeat:flushSessions   — procesa sesiones de usuario
bull:cron:repeat:flushProfiles   — procesa perfiles
bull:cron:repeat:salt            — rotación de salts de contraseñas
bull:cron:repeat:insightsDaily   — cálculo diario de insights
bull:cron:repeat:deleteProjects  — limpieza de proyectos eliminados
event_buffer:total_count         — contador de eventos pendientes en buffer
session:buffer:count             — contador de sesiones en buffer
```

**Flujo de datos:**
```
API recibe evento → buffer en Redis → Worker procesa en batch → ClickHouse
```

---

## 8. ClickHouse — Migraciones de tablas

Las tablas de ClickHouse **no las crea Prisma** — las crea un script de migraciones propio del proyecto (`packages/db/code-migrations/`). El servicio `migrate` del docker-compose solo ejecuta Prisma (PostgreSQL). Hay que ejecutar las migraciones de ClickHouse manualmente:

```bash
docker compose exec api sh -c "cd /app/packages/db && node_modules/.bin/jiti ./code-migrations/migrate.ts --self-hosting"
```

**Resultado:** 9 migraciones ejecutadas correctamente. Tablas creadas:

```
events, events_bots, events_imports, sessions, profiles, profile_aliases,
self_hosting, dau_mv, cohort_events_mv, distinct_event_names_mv,
event_property_values_mv
```

---

## 9. Enviar evento de tracking

```bash
curl -X POST http://localhost:3333/track \
  -H "Content-Type: application/json" \
  -H "openpanel-client-id: be404107-8839-4266-8cca-49fc0d804721" \
  -H "openpanel-client-secret: sec_0d1514fbfb5434e95cf6" \
  -d '{"type":"track","payload":{"name":"page_view","properties":{"url":"http://localhost:3000","path":"/","title":"Home"}}}'
```

**Resultado:** La API recibe el evento, lo mete en Redis y el Worker lo procesa hacia ClickHouse.

---

## 10. Verificar evento en ClickHouse

```bash
docker compose exec clickhouse clickhouse-client \
  --user default --password clickhouse_local \
  --query "SELECT name, project_id, path, created_at FROM openpanel.events"
```

**Resultado:**
```
page_view    mi-web    /    2026-04-10 12:29:04.390
```

Flujo completo verificado: `API → Redis → Worker → ClickHouse ✓`

---

## Resumen del flujo de datos

```
Browser/SDK
    │
    ▼
API (Fastify :3333)
    ├── Usuarios, sesiones, proyectos → PostgreSQL
    └── Eventos analytics → Redis (buffer)
                                │
                                ▼
                           Worker (BullMQ)
                                │
                                ▼
                           ClickHouse (analytics OLAP)
```

**PostgreSQL** — metadatos: usuarios, organizaciones, proyectos, sesiones, configuración  
**Redis** — colas BullMQ: buffer de eventos, perfiles, sesiones analytics  
**ClickHouse** — datos de analytics de alto volumen (eventos, pageviews, funnels)
