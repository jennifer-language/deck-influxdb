<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# @jennifer/influxdb

InfluxDB time-series client.

Add it with `jvc add @jennifer/influxdb` and import it with `import "@jennifer/influxdb/" as influxdb;`. Write measurements as
line-protocol points and query them back as parsed results, against both major
API generations: 1.x (`/write?db=...` + InfluxQL) and 2.x
(`/api/v2/write?org=...&bucket=...` + Flux). InfluxDB 3.x takes the 2.x
writes but has no Flux; query it with InfluxQL through a 1.x client. Built on
the [`http`](https://jennifer-lang.dev/modules/http.html) module, so it needs
the default `jennifer` binary. A failed request, refused, timed out or
answered with an error, throws an `influxdb.InfluxdbError` (kind
`"influxdb"`) with the client's credentials redacted. Its `status` is the HTTP
status of the server's answer (0 when there was none) and `code` a 2.x error's
code (`unauthorized`, `not found`, `invalid`, ...), so a caller branches on
them instead of the message.

```jennifer
import "@jennifer/influxdb/" as influxdb;

# 1.x: database + optional Basic auth, InfluxQL.
def db as influxdb.Client init influxdb.client("http://localhost:8086", "metrics");
def p as influxdb.Point init influxdb.field(
    influxdb.tag(influxdb.point("cpu"), "host", "server01"), "value", 0.64);
influxdb.write($db, [$p]);
def r as influxdb.Result init influxdb.query($db, "SELECT last(\"value\") FROM cpu");

# 2.x: org + bucket + token, Flux (3.x: writes only).
def db2 as influxdb.Client init influxdb.client2("http://localhost:8086", "myorg", "mybucket", "mytoken");
influxdb.write($db2, [$p]);   # same call - dispatches on the client version
def csv as string init influxdb.queryFlux($db2, "from(bucket:\"mybucket\") |> range(start:-1h)");
```

Runnable: [`examples/write.j`](https://github.com/jennifer-language/deck-influxdb/blob/main/examples/write.j).

## Client

One `Client` struct serves both generations, with a `version` discriminator
selecting which fields apply (stance 1: one module, one selectable backend).
A 1.x client carries `db` and optional Basic-auth `user` / `password`; a 2.x
client carries `org` / `bucket` and a `token`. Unused fields stay `""`.

```jennifer
export def enum influxdb.Version { V1, V2 };

def struct influxdb.Client {
    url as string,          # base URL, e.g. "http://localhost:8086"
    version as Version,     # V1 (InfluxDB 1.x) or V2 (InfluxDB 2.x; 3.x writes)
    db as string,           # 1.x database name ("" for a 2.x client)
    user as string,         # 1.x Basic-auth username ("" for no auth)
    password as string,     # 1.x Basic-auth password
    org as string,          # 2.x organization ("" for a 1.x client)
    bucket as string,       # 2.x bucket ("" for a 1.x client)
    token as string         # 2.x API token ("" for a 1.x client)
};
```

| Call | Returns | |
| ---- | ------- | - |
| `influxdb.client(url, db)` | `Client` | 1.x: connect to a database, no authentication |
| `influxdb.clientWith(url, db, user, password)` | `Client` | 1.x: with HTTP Basic-auth credentials |
| `influxdb.client2(url, org, bucket, token)` | `Client` | 2.x (and 3.x writes): token auth, addressed by org + bucket |

## Writing points

A `Point` is built with value-semantic builders; each returns a fresh `Point`. Field types are carried as pre-rendered line-protocol fragments,
so one point can mix float, integer, string, and boolean fields (Jennifer maps
are homogeneous, so a single typed map could not).

| Call | Returns | |
| ---- | ------- | - |
| `influxdb.point(measurement)` | `Point` | start a point (no tags/fields yet) |
| `influxdb.tag(p, key, value)` | `Point` | add an indexed string tag |
| `influxdb.field(p, key, value)` | `Point` | add a **float** field |
| `influxdb.intField(p, key, value)` | `Point` | add an **int** field (line-protocol `i` suffix) |
| `influxdb.stringField(p, key, value)` | `Point` | add a **string** field (quoted, escaped) |
| `influxdb.boolField(p, key, value)` | `Point` | add a **bool** field |
| `influxdb.at(p, unixNanos)` | `Point` | set an explicit timestamp (nanoseconds) |
| `influxdb.atTime(p, t)` | `Point` | set the timestamp from a `time.Time` |
| `influxdb.line(p)` | `string` | render one line-protocol line (throws if no fields) |
| `influxdb.write(c, points)` | | write a `list of Point` to the database |

Line-protocol escaping is automatic: measurement names escape space and comma;
tag keys/values and field keys escape space, comma, and `=`; string field
values are double-quoted with `"` and `\` escaped. A backslash before one of
those characters, before another backslash or at the end of a name or tag is
doubled, so a value cannot undo the escaping; any other backslash is kept as
is (InfluxDB 1.x stores `\\` literally). Some points are not line protocol,
so the builders, `line` and `write` throw `influxdb` for them: no fields, an
empty measurement or one starting with `#` (a comment line the server would
drop), an empty tag or field key, or a newline anywhere. A tag with an empty
value is left out, as the official clients do. The line protocol is identical
across API generations, so `line` is version-agnostic.

`write` dispatches on the client's `version`: a 1.x client posts to
`/write?db=...&precision=ns` with optional Basic auth; a 2.x client posts to
`/api/v2/write?org=...&bucket=...&precision=ns` with an `Authorization: Token
<token>` header. Either throws on a non-2xx response with the status and the
server's message (1.x `{"error": ...}`, 2.x `{"message": ...}`), cut to 512
characters, control characters replaced, and the token or password redacted.

```jennifer
def p as influxdb.Point init influxdb.point("cpu");
$p = influxdb.tag($p, "host", "server01");
$p = influxdb.field($p, "value", 0.64);
$p = influxdb.intField($p, "cores", 8);
influxdb.line($p);   # cpu,host=server01 value=0.64,cores=8i
```

## Querying

```jennifer
def struct influxdb.Series {
    name as string,                       # measurement name
    tags as map of string to string,      # GROUP BY tag set ({} if none)
    columns as list of string,            # column names, e.g. ["time", "value"]
    values as list of list of string      # rows, one stringified cell per column
};
def struct influxdb.Result {
    series as list of Series              # flattened across every statement
};
```

`influxdb.query(client, influxql)` runs an InfluxQL statement against `/query`
and parses the tabular JSON into `Series` (the same read-a-parsed-result shape
as [`prometheus`](https://jennifer-language.github.io/deck-prometheus/)'s retrieval half). Every cell is
stringified: `time` comes back as its RFC 3339 string, numbers via their
shortest form, booleans as `"true"` / `"false"`, and JSON `null` as `""` - so a
homogeneous `list of list of string` can hold a row of otherwise mixed-type
columns. Convert a cell you know is numeric with `convert.toFloat`. A
per-statement or top-level `error` in the response throws
an `InfluxdbError` with `status` 0 (the server answered 200 and reported the
error in the result). The statement goes in the POST body (`q=...`), not
the URL, so it stays out of proxy and access logs. A result the server cut at
its row limit (`"partial": true`) comes back as far as it goes, without a
flag: page with `LIMIT` / `OFFSET` for large results.

```jennifer
def r as influxdb.Result init influxdb.query($db, "SELECT value FROM cpu");
for (def s in $r.series) {
    for (def row in $s.values) {
        # row[0] = time (string), row[1] = value (stringified number)
    }
}
```

### Flux (2.x)

`influxdb.queryFlux(client2, flux)` runs a Flux script against a 2.x client's
organization (`POST /api/v2/query?org=...` under `application/vnd.flux`).
InfluxDB answers a Flux query with annotated CSV (RFC 4180 with
`#datatype` / `#group` / `#default` header rows), not JSON, so `queryFlux`
returns the response body verbatim as a `string`; parse it with the
[`csv`](https://jennifer-lang.dev/modules/csv.html) module. (The JSON-parsing `query` / `Series` / `Result` shape
is the 1.x InfluxQL path.)

```jennifer
def db2 as influxdb.Client init influxdb.client2("http://localhost:8086", "myorg", "mybucket", "mytoken");
def csv as string init influxdb.queryFlux($db2,
    "from(bucket:\"mybucket\") |> range(start:-1h) |> filter(fn:(r) => r._measurement == \"cpu\")");
```

## Scope

- **Both API generations.** 1.x line protocol + InfluxQL (`client` /
  `clientWith`, `query`) and 2.x org/bucket writes + Flux (`client2`,
  `queryFlux`), sharing the line protocol and `Point` builders. InfluxDB 3.x
  takes `client2` writes; it has no Flux, so query it through `client` with
  InfluxQL.
- **Nanosecond write precision** (`precision=ns`); a point's timestamp is an
  integer nanosecond value (or a `time.Time` via `atTime`).
- **1.x query cells are stringified.** The `Result` keeps rows homogeneous
  (`list of list of string`) rather than exposing a typed cell union; convert
  numeric columns yourself.
- **Flux returns raw annotated CSV.** `queryFlux` returns the response body as a
  `string` for the `csv` module to parse, rather than a bespoke Flux-CSV
  decoder.
- **Auth: 1.x Basic auth, 2.x token.** Credentials ride in the `Authorization`
  header and are redacted from any raised error. TLS client certs are not wired;
  use a reverse proxy for those.

## See also

- [http.md](https://jennifer-lang.dev/modules/http.html) - the HTTP client this module builds on.
- [prometheus.md](https://jennifer-language.github.io/deck-prometheus/) - the pull-based metrics sibling; its retrieval
  half shares this parsed-result shape.
- [modules/index.md](https://jennifer-lang.dev/modules/index.html) - the module catalog and import rules.
