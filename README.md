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

## Test and benchmark

Both need `jsonschema_tle` installed and nothing else.

```bash
psql "$DATABASE_URL" -f test/test.sql
psql "$DATABASE_URL" -v rows=50000 -f bench/bench.sql
```

- `test/test.sql` runs in one transaction that is rolled back, using temp tables and
  `jsonschema_test.*` schema ids. It leaves nothing behind.
- `bench/bench.sql` creates schema `jsonschema_bench` (failing if it already exists) and drops
  it at the end. It registers one schema as `jsonschema_bench.order`, reused across runs; the
  registry is append-only, so that row stays.

## Results

Local: `supabase/postgres:15.19.0.004` (plv8 3.1.10, the version on Aurora 17.7), Apple Silicon,
Docker. 50k-row `insert ... select`, median of 3. `pg_jsonschema` 0.3.3 (Rust) shown for reference;
it was measured with an earlier revision of `bench/bench.sql`, which no longer depends on it.

| payload | none | jsonschema_tle | pg_jsonschema 0.3.3 |
|---|---|---|---|
| ~150 B  | 644k rows/s | 50k rows/s (≈19 µs/row) | 24k rows/s (≈40 µs/row) |
| ~5 KB   | 217k rows/s | 9.2k rows/s (≈104 µs/row) | 10k rows/s (≈95 µs/row) |

Single-row insert transactions, 1 connection, `synchronous_commit=off` (pgbench, 10 s):
none ≈20k tps, jsonschema_tle ≈13k tps, pg_jsonschema ≈10k tps. Run-to-run noise on this
laptop is large (the "none" case ranged 20k–42k tps across runs).

Cold start per new connection ≈115–175 ms (V8 init, runtime load, first schema compile).
Use long-lived pooled connections.
