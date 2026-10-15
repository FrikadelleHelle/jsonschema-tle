import Ajv2020 from "ajv/dist/2020.js";

const options = { strict: false, allErrors: false, logger: false, addUsedSchema: false };

// Schemas are checked against the meta-schema once, on insert into jsonschema.schemas;
// compiling the meta-schema dominates cold start, so the validation path skips it.
const ajv = new Ajv2020({ ...options, validateSchema: false });
let registrationAjv;

const validators = new Map();
let lookup;

// A schema row created in the current transaction may still roll back and be
// replaced by a different row with the same (id, version), so it is never cached.
function load(id, version) {
  const key = id + "\u0000" + version;
  const cached = validators.get(key);
  if (cached) return cached;

  lookup ??= plv8.prepare(
    "select schema, created_at = transaction_timestamp() as uncommitted " +
      "from jsonschema.schemas where id = $1 and version = $2",
    ["text", "int4"],
  );
  const rows = lookup.execute([id, version]);
  if (rows.length === 0) {
    throw new Error(`jsonschema: no schema "${id}" version ${version}`);
  }
  const validate = ajv.compile(rows[0].schema);
  if (!rows[0].uncommitted) validators.set(key, validate);
  return validate;
}

function formatErrors(errors) {
  return errors.map((e) => `${e.instancePath || "/"}: ${e.message}`);
}

globalThis.__jsonschema = {
  load,
  formatErrors,

  schemaErrors(schema) {
    try {
      (registrationAjv ??= new Ajv2020(options)).compile(schema);
      return null;
    } catch (e) {
      return [e.message];
    }
  },
};
