// A JSON Schema (2020-12) validator for exactly the keywords
// snapshot.schema.json uses, so the tests need nothing from npm but Playwright.
//
// FAILS CLOSED: a keyword it does not implement is an error, never a pass. If
// the schema grows a keyword, this refuses until someone teaches it that
// keyword, rather than silently validating less than the schema says.

const ANNOTATIONS = new Set(["$schema", "$id", "title", "description", "$defs", "$comment"]);
const IMPLEMENTED = new Set([
  "$ref", "type", "enum", "const", "required", "properties", "additionalProperties",
  "items", "minItems", "maxItems", "minimum", "maximum", "anyOf", "allOf", "if", "then", "else",
]);

function typeOf(v) {
  if (v === null) return "null";
  if (Array.isArray(v)) return "array";
  if (typeof v === "number") return Number.isInteger(v) ? "integer" : "number";
  return typeof v;
}

function typeMatches(v, t) {
  const actual = typeOf(v);
  if (t === "number") return actual === "number" || actual === "integer";
  return actual === t;
}

function equal(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

export function validate(root, value) {
  const errors = [];

  function resolve(ref) {
    if (!ref.startsWith("#/")) throw new Error(`validate.mjs: only local $ref is supported, got ${ref}`);
    let node = root;
    for (const part of ref.slice(2).split("/")) {
      node = node[part];
      if (node === undefined) throw new Error(`validate.mjs: unresolvable $ref ${ref}`);
    }
    return node;
  }

  // Returns true when `v` satisfies `s`. `out` collects messages; pass null to
  // test without recording (anyOf branches, if-conditions).
  function check(s, v, path, out) {
    for (const k of Object.keys(s)) {
      if (!ANNOTATIONS.has(k) && !IMPLEMENTED.has(k)) {
        throw new Error(`validate.mjs: unsupported keyword "${k}" at schema for ${path}`);
      }
    }
    let ok = true;
    const fail = (msg) => { ok = false; if (out) out.push(`${path}: ${msg}`); };

    if (s.$ref) ok = check(resolve(s.$ref), v, path, out) && ok;
    if (s.type !== undefined) {
      const types = Array.isArray(s.type) ? s.type : [s.type];
      if (!types.some((t) => typeMatches(v, t))) fail(`expected ${types.join("|")}, got ${typeOf(v)}`);
    }
    if (s.enum !== undefined && !s.enum.some((e) => equal(e, v))) fail(`${JSON.stringify(v)} not in ${JSON.stringify(s.enum)}`);
    if (s.const !== undefined && !equal(s.const, v)) fail(`expected ${JSON.stringify(s.const)}, got ${JSON.stringify(v)}`);
    if (typeof v === "number") {
      if (s.minimum !== undefined && v < s.minimum) fail(`${v} < minimum ${s.minimum}`);
      if (s.maximum !== undefined && v > s.maximum) fail(`${v} > maximum ${s.maximum}`);
    }
    if (Array.isArray(v)) {
      if (s.minItems !== undefined && v.length < s.minItems) fail(`fewer than ${s.minItems} items`);
      if (s.maxItems !== undefined && v.length > s.maxItems) fail(`more than ${s.maxItems} items`);
      if (s.items) v.forEach((item, i) => { ok = check(s.items, item, `${path}[${i}]`, out) && ok; });
    }
    if (v && typeof v === "object" && !Array.isArray(v)) {
      for (const r of s.required || []) if (!(r in v)) fail(`missing required "${r}"`);
      const props = s.properties || {};
      for (const [k, sub] of Object.entries(props)) {
        if (k in v) ok = check(sub, v[k], `${path}.${k}`, out) && ok;
      }
      if (s.additionalProperties === false) {
        for (const k of Object.keys(v)) if (!(k in props)) fail(`unexpected property "${k}"`);
      } else if (s.additionalProperties !== undefined && s.additionalProperties !== true) {
        throw new Error("validate.mjs: additionalProperties must be true or false");
      }
    }
    if (s.anyOf) {
      if (!s.anyOf.some((sub) => check(sub, v, path, null))) {
        const detail = [];
        s.anyOf.forEach((sub) => check(sub, v, path, detail));
        fail(`matches no anyOf branch (${detail.join("; ")})`);
      }
    }
    if (s.allOf) s.allOf.forEach((sub) => { ok = check(sub, v, path, out) && ok; });
    if (s.if) {
      if (check(s.if, v, path, null)) {
        if (s.then) ok = check(s.then, v, path, out) && ok;
      } else if (s.else) {
        ok = check(s.else, v, path, out) && ok;
      }
    }
    return ok;
  }

  check(root, value, "$", errors);
  return errors;
}
