\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = warning;
\pset tuples_only on
\pset format unaligned

create extension if not exists pg_jsonschema;

drop table if exists src_small, src_large, bench_results, t_none, t_tle, t_pgjs cascade;

-- ~150 byte payloads
create table src_small as
select jsonb_build_object(
  'sku', 'sku-' || g,
  'qty', 1 + g % 50,
  'price', (g % 1000) / 10.0,
  'currency', (array['EUR','USD','DKK'])[1 + g % 3],
  'tags', jsonb_build_array('alpha', 'beta')
) as payload
from generate_series(1, :rows) g;

-- ~5 KB payloads: 40 line items
create table src_large as
select jsonb_build_object(
  'sku', 'sku-' || g,
  'qty', 1 + g % 50,
  'price', (g % 1000) / 10.0,
  'currency', 'EUR',
  'tags', jsonb_build_array('alpha', 'beta'),
  'lines', (select jsonb_agg(jsonb_build_object(
              'line', i, 'sku', 'part-' || i, 'qty', i, 'price', i * 1.5,
              'note', repeat('x', 40)))
            from generate_series(1, 40) i)
) as payload
from generate_series(1, :rows) g;

\set schema '{"type":"object","required":["sku","qty","price","currency"],"properties":{"sku":{"type":"string","minLength":1},"qty":{"type":"integer","minimum":1},"price":{"type":"number","minimum":0},"currency":{"enum":["EUR","USD","DKK"]},"tags":{"type":"array","items":{"type":"string","pattern":"^[a-z]+$"}},"lines":{"type":"array","items":{"$ref":"#/$defs/line"}}},"$defs":{"line":{"type":"object","required":["line","sku","qty","price"],"properties":{"line":{"type":"integer"},"sku":{"type":"string"},"qty":{"type":"integer","minimum":1},"price":{"type":"number"},"note":{"type":"string","maxLength":200}},"additionalProperties":false}},"additionalProperties":false}'

insert into jsonschema.schemas (id, version, schema)
select 'bench', coalesce(max(version), 0) + 1, :'schema' from jsonschema.schemas where id = 'bench'
returning version as bench_version \gset

create table t_none (payload jsonb);

create table t_tle (payload jsonb);
create trigger v before insert on t_tle
  for each row execute function jsonschema.validate('payload', 'bench', :'bench_version');

create table t_pgjs (payload jsonb check (jsonb_matches_schema(:'schema', payload)));

create table bench_results (method text, size text, run int, ms numeric);

create function pg_temp.run(target text, source text) returns numeric language plpgsql as $$
declare t0 timestamptz;
begin
  execute format('truncate %I', target);
  t0 := clock_timestamp();
  execute format('insert into %I select payload from %I', target, source);
  return extract(epoch from clock_timestamp() - t0) * 1000;
end
$$;

-- warm up: load plv8 runtime and compile the schema in this session
select pg_temp.run('t_tle', 'src_small');

do $$
declare m text; s text; r int;
begin
  for r in 1..3 loop
    foreach s in array array['small', 'large'] loop
      foreach m in array array['none', 'tle', 'pgjs'] loop
        insert into bench_results
        values (m, s, r, pg_temp.run('t_' || m, 'src_' || s));
      end loop;
    end loop;
  end loop;
end $$;

\pset tuples_only off
\pset format aligned
\echo
select
  size,
  method,
  round(percentile_cont(0.5) within group (order by ms)::numeric, 0) as median_ms,
  round(:rows / (percentile_cont(0.5) within group (order by ms)::numeric / 1000)) as rows_per_s,
  round((percentile_cont(0.5) within group (order by ms)::numeric
        - (select percentile_cont(0.5) within group (order by b.ms) from bench_results b
           where b.method = 'none' and b.size = r.size)::numeric) * 1000 / :rows, 2) as validation_us_per_row
from bench_results r
group by size, method
order by size desc, median_ms;
