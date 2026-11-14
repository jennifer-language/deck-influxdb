<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# influxdb cheatsheet

Every export of `@jennifer/influxdb`. The guide is [the introduction](index.md).

```jennifer
import "@jennifer/influxdb/" as influxdb;
```

## Functions

| Function | Returns | Does |
|---|---|---|
| `influxdb.client(url as string, db as string)` | `Client` | Open a client to a database with no authentication |
| `influxdb.clientWith(url as string, db as string, user as string, password as string)` | `Client` | Open a 1.x client with HTTP Basic-auth credentials |
| `influxdb.client2(url as string, org as string, bucket as string, token as string)` | `Client` | Open an InfluxDB 2.x client |
| `influxdb.point(measurement as string)` | `Point` | Start a point for a measurement (no tags or fields yet) |
| `influxdb.tag(p as Point, key as string, value as string)` | `Point` | Add a tag (indexed string metadata) |
| `influxdb.field(p as Point, key as string, value as float)` | `Point` | Add a float field |
| `influxdb.intField(p as Point, key as string, value as int)` | `Point` | Add an integer field (rendered with the line-protocol `i` suffix) |
| `influxdb.stringField(p as Point, key as string, value as string)` | `Point` | Add a string field (double-quoted, escaped) |
| `influxdb.boolField(p as Point, key as string, value as bool)` | `Point` | Add a boolean field |
| `influxdb.at(p as Point, unixNanos as int)` | `Point` | Set an explicit timestamp in nanoseconds since the Unix epoch |
| `influxdb.atTime(p as Point, t as time.Time)` | `Point` | Set the timestamp from a `time.Time` |
| `influxdb.line(p as Point)` | `string` | Render a point to one line-protocol line |
| `influxdb.write(c as Client, points as list of Point)` |  | Write points to the client's target (line protocol, nanosecond precision) |
| `influxdb.query(c as Client, influxql as string)` | `Result` | Run an InfluxQL statement against a 1.x client's database and parse the result |
| `influxdb.queryFlux(c as Client, flux as string)` | `string` | Run a Flux query against a 2.x client's organization and return the raw response body |

## Types

### `Client`

A client for either API generation.

| Field | Meaning |
|---|---|
| `url as string` | the base URL (e.g. "http://localhost:8086") |
| `version as Version` | the API generation (V1 or V2) |
| `db as string` | the 1.x database name ("" for a 2.x client) |
| `user as string` | the 1.x Basic-auth username ("" for no auth) |
| `password as string` | the 1.x Basic-auth password |
| `org as string` | the 2.x organization ("" for a 1.x client) |
| `bucket as string` | the 2.x bucket ("" for a 1.x client) |
| `token as string` | the 2.x API token ("" for a 1.x client) |

### `Point`

A line-protocol point under construction.

| Field | Meaning |
|---|---|
| `measurement as string` | the measurement name |
| `tags as list of string` | escaped `key=value` tag fragments |
| `fields as list of string` | rendered `key=value` field fragments |
| `timestamp as int` | the timestamp in nanoseconds (when `timed`) |
| `timed as bool` | whether an explicit timestamp is set |

### `Series`

One result series.

| Field | Meaning |
|---|---|
| `name as string` | the measurement name |
| `tags as map of string to string` | the series tag set ({} if none) |
| `columns as list of string` | the column names (e.g. ["time", "value"]) |
| `values as list of list of string` | the rows, one stringified cell per column |

### `Result`

A parsed query result.

| Field | Meaning |
|---|---|
| `series as list of Series` | the result series |

### `InfluxdbError`

Every error of kind `"influxdb"`.

| Field | Meaning |
|---|---|
| `kind as string` | always `"influxdb"` |
| `message as string` | `influxdb: ` and the server's error, the token redacted |
| `status as int` | the HTTP status of the answer; 0 when there was none |
| `code as string` | a 2.x error's `code` (`unauthorized`, `not found`, ...); "" when none |

### `Version`

The API generation a `Client` targets.

| Variant | Meaning |
|---|---|
| `V1` | InfluxDB 1.x: `/write?db=...`, InfluxQL, optional Basic auth |
| `V2` | InfluxDB 2.x: `/api/v2/write?org=...&bucket=...`, Flux, token auth (3.x takes the writes) |
