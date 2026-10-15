create schema jsonschema;

create table jsonschema.schemas (
  id text not null,
  version int not null check (version > 0),
  schema jsonb not null,
  created_at timestamptz not null,
  primary key (id, version)
);

select pg_catalog.pg_extension_config_dump('jsonschema.schemas', '');

create function jsonschema._load_runtime() returns void
language plv8 as $jsonschema_runtime$
{{RUNTIME}}
$jsonschema_runtime$;

-- plv8 converts jsonb arguments to JS values far slower than V8 parses JSON text,
-- so every plv8 entry point takes jsonb as text.

create function jsonschema._schema_errors(schema text) returns text[]
language plv8 immutable strict as $$
  if (!globalThis.__jsonschema) plv8.find_function("jsonschema._load_runtime")();
  return __jsonschema.schemaErrors(JSON.parse(schema));
$$;

create function jsonschema._errors(schema_id text, schema_version int, instance text) returns text[]
language plv8 stable strict as $$
  if (!globalThis.__jsonschema) plv8.find_function("jsonschema._load_runtime")();
  const validate = __jsonschema.load(schema_id, schema_version);
  return validate(JSON.parse(instance)) ? null : __jsonschema.formatErrors(validate.errors);
$$;

create function jsonschema._before_schema_insert() returns trigger
language plpgsql as $$
declare
  errors text[] := jsonschema._schema_errors(new.schema::text);
begin
  if errors is not null then
    raise exception using
      errcode = 'check_violation',
      message = format('jsonschema: invalid schema "%s" version %s', new.id, new.version),
      detail = array_to_string(errors, E'\n');
  end if;
  new.created_at := transaction_timestamp();
  return new;
end
$$;

create trigger before_insert before insert on jsonschema.schemas
  for each row execute function jsonschema._before_schema_insert();

create function jsonschema._forbid_mutation() returns trigger
language plpgsql as $$
begin
  raise exception 'jsonschema.schemas is append-only; insert a new version instead'
    using errcode = 'feature_not_supported';
end
$$;

create trigger forbid_update_delete before update or delete on jsonschema.schemas
  for each row execute function jsonschema._forbid_mutation();

create trigger forbid_truncate before truncate on jsonschema.schemas
  for each statement execute function jsonschema._forbid_mutation();

create function jsonschema.is_valid(schema_id text, schema_version int, instance jsonb)
returns boolean
language sql stable strict as $$
  select jsonschema._errors(schema_id, schema_version, instance::text) is null
$$;

create function jsonschema.validation_errors(schema_id text, schema_version int, instance jsonb)
returns text[]
language sql stable strict as $$
  select coalesce(jsonschema._errors(schema_id, schema_version, instance::text), '{}')
$$;

-- Usage: create trigger ... before insert or update of <column> on <table>
--   for each row execute function jsonschema.validate('<column>', '<schema id>', '<version>');
create function jsonschema.validate() returns trigger
language plpgsql as $$
declare
  value jsonb;
  errors text[];
begin
  if tg_nargs <> 3 then
    raise exception 'jsonschema.validate(column, schema_id, version) takes exactly 3 arguments';
  end if;
  execute format('select ($1).%I', tg_argv[0]) into value using new;
  if value is null then
    return new;
  end if;
  errors := jsonschema._errors(tg_argv[1], tg_argv[2]::int, value::text);
  if errors is not null then
    raise exception using
      errcode = 'check_violation',
      message = format('%s.%s does not match schema "%s" version %s',
                       tg_table_name, tg_argv[0], tg_argv[1], tg_argv[2]),
      detail = array_to_string(errors, E'\n');
  end if;
  return new;
end
$$;
