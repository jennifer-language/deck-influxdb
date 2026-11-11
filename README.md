# @jennifer/influxdb

[![test](https://github.com/jennifer-language/deck-influxdb/actions/workflows/test.yml/badge.svg)](https://github.com/jennifer-language/deck-influxdb/actions/workflows/test.yml)
[![Documentation](https://img.shields.io/badge/docs-github%20pages-blue)](https://jennifer-language.github.io/deck-influxdb/)
[![release](https://img.shields.io/github/v/release/jennifer-language/deck-influxdb)](https://github.com/jennifer-language/deck-influxdb/releases/latest)

A [Jennifer](https://jennifer-lang.dev/) deck for
[InfluxDB](https://www.influxdata.com/): build line-protocol points, write
them, and query them back: InfluxDB 1.x with InfluxQL, 2.x with token auth
and Flux, and 3.x with 2.x writes and InfluxQL queries.

It was Jennifer's bundled `influxdb.j` module until 0.27; the surface is the same,
so moving over changes only the import:

```jennifer
import "@jennifer/influxdb/" as influxdb;   # was: import "influxdb.j" as influxdb;
```

**[Documentation](https://jennifer-language.github.io/deck-influxdb/)**

## Install

```sh
jvc add @jennifer/influxdb
```

This vendors the deck to `vendor/<scope>/influxdb/`. Without `jvc`, unpack the
`src/` subtree of a release archive (`<scope>-influxdb-<version>.tar.gz`) there.

## Usage

```jennifer
import "@jennifer/influxdb/" as influxdb;

def c as influxdb.Client init influxdb.clientWith("http://localhost:8086", "metrics", "user", "pass");
def p as influxdb.Point init influxdb.field(influxdb.tag(influxdb.point("cpu"), "host", "srv1"), "value", 0.64);
influxdb.write($c, [$p]);
```

## Requirements

Jennifer 0.26.0 or newer, the default `jennifer` binary (`net`), not
`jennifer-tiny`.

## Development

```sh
tools/check-all.sh                   # the full gate, as CI runs it
jennifer test src/influxdb_test.j      # the test overlay
tools/check-docs.sh                  # docs against the code
tools/pack.sh dist                   # build the release archive
```

## Licence

LGPL-3.0-only, see [LICENSE](LICENSE). Copyright (C) 2026 mplx &lt;mplx@jennifer-lang.dev&gt;.

`tools/check-headers.sh` checks every source file's SPDX header against
`deck.toml`.
