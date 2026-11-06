// A stand-in for supabase-js when an edge function is booted locally
// (tool/edge_stub/boot.sh): the ops under test use the REST helper, which
// the stand-in REST server answers; anything that reaches this client fails.
// deno-lint-ignore no-explicit-any
export function createClient(..._a: any[]): any { return null as any; }
