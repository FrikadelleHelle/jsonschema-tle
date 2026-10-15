# jsonschema_tle

JSON Schema (2020-12) validation for `jsonb` on Aurora PostgreSQL, packaged as a
[Trusted Language Extension](https://github.com/aws/pg_tle) on plv8, backed by
[Ajv](https://ajv.js.org/).

## Usage

```sql
-- register a schema (append-only; new behaviour = new version)
insert into jsonschema.schemas (id, version, schema)
values ('order', 1, '{"type": "object", "required": ["sku"], "properties": {"sku": {"type": "string"}}}');

-- enforce on a column (rejects with SQLSTATE 23514 check_violation, errors in DETAIL)
create trigger validate_payload before insert or update of payload on orders
  for each row execute function jsonschema.validate('payload', 'order', '1');

-- ad hoc
select jsonschema.is_valid('order', 1, '{"sku": "a"}');
select jsonschema.validation_errors('order', 1, '{"sku": 1}');  -- {"/sku: must be string"}
```

- Schemas are checked against the 2020-12 meta-schema on insert; invalid ones are rejected.
- `jsonschema.schemas` rejects UPDATE, DELETE and TRUNCATE, so a compiled validator cached
  per connection under `(id, version)` can never go stale.
- SQL NULL columns pass; JSON `null` is validated like any other value.
- Validation is a trigger, not a CHECK: a CHECK that reads another table breaks PostgreSQL's
  immutability assumption (no re-check when the schema changes, restore ordering failures).

## Build and install

```bash
npm install && npm run build   # writes dist/install.sql
```

On the database (Aurora: `pg_tle` must be in `shared_preload_libraries`, which needs a reboot):

```sql
create extension if not exists pg_tle;
create extension if not exists plv8;
\i dist/install.sql
create extension jsonschema_tle;
```

## Results

Local: `supabase/postgres:15.19.0.004` (plv8 3.1.10, the version on Aurora 17.7), Apple Silicon,
Docker. 50k-row `insert ... select`, median of 3. `pg_jsonschema` 0.3.3 (Rust) shown for reference.

| payload | none | jsonschema_tle | pg_jsonschema 0.3.3 |
|---|---|---|---|
| ~150 B  | 644k rows/s | 50k rows/s (≈19 µs/row) | 24k rows/s (≈40 µs/row) |
| ~5 KB   | 217k rows/s | 9.2k rows/s (≈104 µs/row) | 10k rows/s (≈95 µs/row) |

Single-row insert transactions, 1 connection, `synchronous_commit=off` (pgbench, 10 s):
none ≈20k tps, jsonschema_tle ≈13k tps, pg_jsonschema ≈10k tps. Run-to-run noise on this
laptop is large (the "none" case ranged 20k–42k tps across runs).

Cold start per new connection ≈115–175 ms (V8 init, runtime load, first schema compile).
Use long-lived pooled connections.

## Caveats

- Numbers are from a laptop on PostgreSQL 15, not Aurora 17.7. Re-measure on staging.
- Ajv compiles validators with `new Function`. This works in plv8 3.1.10 locally; it has not
  been checked on Aurora. Check before installing:
  `do $$ plv8.elog(NOTICE, new Function('return 1')()) $$ language plv8;`
- `pg_jsonschema` releases newer than 0.3.3 add a compiled-schema type that their README
  reports as ~4x faster; that comparison is not made here.
- 2020-12 only. Schemas declaring another `$schema` draft are rejected. No cross-schema `$ref`
  between registry entries. `format` is annotation-only (2020-12 default).
- Restoring a dump re-stamps `jsonschema.schemas.created_at` with the restore time.
