-- Requires jsonschema_tle to be installed. Runs in one transaction that is rolled back,
-- uses temp tables and "jsonschema_test." schema ids, and leaves nothing behind.
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = warning;
\pset tuples_only on
\pset format unaligned

begin;

create function pg_temp.expect_error(stmt text, want_sqlstate text, want_message_like text default '%')
returns void language plpgsql as $$
declare got_state text; got_msg text;
begin
  begin
    execute stmt;
  exception when others then
    get stacked diagnostics got_state = returned_sqlstate, got_msg = message_text;
    if got_state <> want_sqlstate or got_msg not like want_message_like then
      raise exception 'FAIL: % -> % "%", wanted % "%"', stmt, got_state, got_msg, want_sqlstate, want_message_like;
    end if;
    return;
  end;
  raise exception 'FAIL: expected error % from: %', want_sqlstate, stmt;
end
$$;

create function pg_temp.check(ok boolean, label text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'FAIL: %', label; end if;
end
$$;

select pg_temp.check(
  exists (select 1 from pg_extension where extname = 'jsonschema_tle'),
  'jsonschema_tle is not installed in this database');

-- schema registration
insert into jsonschema.schemas (id, version, schema) values
  ('jsonschema_test.order', 1, '{
     "$schema": "https://json-schema.org/draft/2020-12/schema",
     "$id": "https://example.com/order",
     "type": "object",
     "required": ["sku", "qty"],
     "properties": {
       "sku": {"type": "string", "minLength": 1},
       "qty": {"type": "integer", "minimum": 1},
       "tags": {"type": "array", "items": {"$ref": "#/$defs/tag"}}
     },
     "$defs": {"tag": {"type": "string", "pattern": "^[a-z]+$"}},
     "unevaluatedProperties": false
   }'),
  ('jsonschema_test.order', 2, '{
     "$id": "https://example.com/order",
     "type": "object",
     "required": ["sku"],
     "properties": {"sku": {"type": "string"}}
   }'),
  ('jsonschema_test.point', 1, '{"type": "array", "prefixItems": [{"type": "number"}, {"type": "number"}], "items": false}');

select pg_temp.check(
  (select count(*) = 3 and bool_and(created_at = transaction_timestamp())
   from jsonschema.schemas where id like 'jsonschema\_test.%'),
  'schemas registered with created_at stamped');

select pg_temp.expect_error(
  $q$insert into jsonschema.schemas (id, version, schema) values ('jsonschema_test.bad', 1, '{"type": "nope"}')$q$,
  '23514', 'jsonschema: invalid schema "jsonschema_test.bad" version 1');
select pg_temp.expect_error(
  $q$insert into jsonschema.schemas (id, version, schema) values ('jsonschema_test.bad', 1, '{"$schema": "http://json-schema.org/draft-07/schema#"}')$q$,
  '23514');
select pg_temp.expect_error(
  $q$insert into jsonschema.schemas (id, version, schema) values ('jsonschema_test.bad', 0, '{}')$q$, '23514');

-- append-only
select pg_temp.expect_error(
  $q$update jsonschema.schemas set schema = '{}' where id = 'jsonschema_test.order'$q$, '0A000');
select pg_temp.expect_error(
  $q$delete from jsonschema.schemas where id = 'jsonschema_test.order'$q$, '0A000');
select pg_temp.expect_error($q$truncate jsonschema.schemas$q$, '0A000');

-- is_valid / validation_errors
select pg_temp.check(jsonschema.is_valid('jsonschema_test.order', 1, '{"sku": "a", "qty": 2, "tags": ["x"]}'), 'valid order v1');
select pg_temp.check(not jsonschema.is_valid('jsonschema_test.order', 1, '{"sku": "a"}'), 'missing qty');
select pg_temp.check(not jsonschema.is_valid('jsonschema_test.order', 1, '{"sku": "a", "qty": 0}'), 'qty minimum');
select pg_temp.check(not jsonschema.is_valid('jsonschema_test.order', 1, '{"sku": "a", "qty": 1, "extra": 1}'), 'unevaluatedProperties');
select pg_temp.check(not jsonschema.is_valid('jsonschema_test.order', 1, '{"sku": "a", "qty": 1, "tags": ["X"]}'), '$ref into $defs');
select pg_temp.check(jsonschema.is_valid('jsonschema_test.order', 2, '{"sku": "a"}'), 'v2 with same $id coexists');
select pg_temp.check(jsonschema.is_valid('jsonschema_test.point', 1, '[1, 2]'), 'prefixItems ok');
select pg_temp.check(not jsonschema.is_valid('jsonschema_test.point', 1, '[1, 2, 3]'), 'items false');
select pg_temp.check(not jsonschema.is_valid('jsonschema_test.order', 1, 'null'), 'json null is not an object');
select pg_temp.check(jsonschema.is_valid('jsonschema_test.order', 1, null) is null, 'sql null -> null');
select pg_temp.check(
  jsonschema.validation_errors('jsonschema_test.order', 1, '{"sku": "a", "qty": "x"}') = array['/qty: must be integer'],
  'validation_errors message');
select pg_temp.check(
  jsonschema.validation_errors('jsonschema_test.order', 1, '{"sku": "a", "qty": 1}') = '{}', 'no errors when valid');
select pg_temp.expect_error(
  $q$select jsonschema.is_valid('jsonschema_test.nope', 1, '{}')$q$,
  'XX000', '%no schema "jsonschema_test.nope" version 1%');

-- trigger
create temp table jsonschema_test_orders (id serial primary key, payload jsonb);
create trigger validate_payload before insert or update of payload on jsonschema_test_orders
  for each row execute function jsonschema.validate('payload', 'jsonschema_test.order', '1');

insert into jsonschema_test_orders (payload) values ('{"sku": "a", "qty": 1}');
insert into jsonschema_test_orders (payload) values (null);
select pg_temp.expect_error(
  $q$insert into jsonschema_test_orders (payload) values ('{"sku": "a", "qty": -1}')$q$,
  '23514', 'jsonschema_test_orders.payload does not match schema "jsonschema_test.order" version 1');
select pg_temp.expect_error(
  $q$update jsonschema_test_orders set payload = '{"sku": ""}' where payload is not null$q$, '23514');
select pg_temp.check((select count(*) = 2 from jsonschema_test_orders), 'only valid rows stored');

do $$
declare d text;
begin
  insert into jsonschema_test_orders (payload) values ('{"sku": "a", "qty": 1.5}');
exception when check_violation then
  get stacked diagnostics d = pg_exception_detail;
  perform pg_temp.check(d = '/qty: must be integer', 'error detail carries path: ' || d);
end $$;

create temp table jsonschema_test_misconfigured (body jsonb);
create trigger v before insert on jsonschema_test_misconfigured
  for each row execute function jsonschema.validate('payload', 'jsonschema_test.order', '1');
select pg_temp.expect_error(
  $q$insert into jsonschema_test_misconfigured values ('{}')$q$, '42703', '%column "payload" not found%');

-- a schema whose insert is rolled back must not stay cached
savepoint flip;
insert into jsonschema.schemas (id, version, schema) values ('jsonschema_test.flip', 1, '{"type": "string"}');
select pg_temp.check(jsonschema.is_valid('jsonschema_test.flip', 1, '"s"'), 'flip v1 as string');
rollback to savepoint flip;
insert into jsonschema.schemas (id, version, schema) values ('jsonschema_test.flip', 1, '{"type": "number"}');
select pg_temp.check(not jsonschema.is_valid('jsonschema_test.flip', 1, '"s"'), 'flip v1 reloaded after rollback');
select pg_temp.check(jsonschema.is_valid('jsonschema_test.flip', 1, '1'), 'flip v1 is number');

rollback;

\echo all tests passed
