# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * An InfluxDB client over `http` for both major API generations: write
 * measurements as line-protocol points and run queries, getting back a parsed
 * result. The push counterpart to a scrape.
 *
 * Two selectable backends under one `Client` (stance 1: one module, one
 * version discriminator). A **1.x** client (`client` / `clientWith`) writes to
 * `/write?db=...` with optional Basic auth and queries InfluxQL over `/query`
 * (`query`). A **2.x** client (`client2`) writes to
 * `/api/v2/write?org=...&bucket=...` with `Authorization: Token <token>` auth
 * and queries Flux over `/api/v2/query` (`queryFlux`); InfluxDB 3.x takes its
 * writes but has no Flux (query 3.x with InfluxQL through a 1.x client). `write` dispatches on the
 * client's `version`, so the same call serves both; the line protocol is
 * identical across versions, so `line` is reused verbatim.
 *
 * A `Point` is built with value-semantic builders (`point` / `tag` / `field` /
 * `intField` / `stringField` / `boolField` / `at`), each returning a fresh
 * `Point`, then rendered to a line-protocol line by `line` (or sent by
 * `write`). Field types are carried as pre-rendered fragments, so one point can
 * mix float / int / string / bool fields despite Jennifer's homogeneous maps.
 * Needs the default `jennifer` binary (`http` over `net`); a failed request
 * throws `Error{kind: "influxdb"}` (a 2.x client's token is redacted from it).
 * @module influxdb
 * @example
 * import "@jennifer/influxdb/" as influxdb;
 * def db as influxdb.Client init influxdb.client("http://localhost:8086", "metrics");
 * def p as influxdb.Point init influxdb.field(
 *     influxdb.tag(influxdb.point("cpu"), "host", "server01"), "value", 0.64);
 * influxdb.write($db, [$p]);
 * def r as influxdb.Result init influxdb.query($db, "SELECT last(\"value\") FROM cpu");
 * # or a 2.x client:
 * def db2 as influxdb.Client init influxdb.client2("http://localhost:8086", "myorg", "mybucket", "mytoken");
 * influxdb.write($db2, [$p]);
 * def csv as string init influxdb.queryFlux($db2, "from(bucket:\"mybucket\") |> range(start:-1h)");
 */
use json;
use strings;
use convert;
use time;
use encoding;
use regex;
use maps;
import "http.j" as http;
import "uri.j" as uri;

# The default InfluxDB HTTP endpoint (shared by 1.x and 2.x).
def const DEFAULT_URL as string init "http://localhost:8086";

/**
 * The API generation a `Client` targets: `influxdb.Version.V1` (InfluxDB 1.x -
 * `/write?db=...` + InfluxQL, optional Basic auth) or `influxdb.Version.V2`
 * (InfluxDB 2.x - `/api/v2/write?org=...&bucket=...` + Flux, token auth; 3.x
 * takes these writes but has no Flux).
 * The backend selector `write` dispatches on; the zero value is `V1`.
 */
export def enum Version {
    V1,
    V2
};

/**
 * A client for either API generation. A 1.x client carries `db` and optional
 * Basic-auth `user` / `password`; a 2.x client carries `org` / `bucket` and a
 * `token`. `version` selects which set is used (unused fields stay "").
 * @field url {string} the base URL (e.g. "http://localhost:8086")
 * @field version {Version} the API generation (V1 or V2)
 * @field db {string} the 1.x database name ("" for a 2.x client)
 * @field user {string} the 1.x Basic-auth username ("" for no auth)
 * @field password {string} the 1.x Basic-auth password
 * @field org {string} the 2.x organization ("" for a 1.x client)
 * @field bucket {string} the 2.x bucket ("" for a 1.x client)
 * @field token {string} the 2.x API token ("" for a 1.x client)
 */
export def struct Client {
    url as string,
    version as Version,
    db as string,
    user as string,
    password as string,
    org as string,
    bucket as string,
    token as string
};

/**
 * A line-protocol point under construction. Tags and fields are held as
 * pre-rendered, escaped `key=value` fragments so a point can mix field types.
 * @field measurement {string} the measurement name
 * @field tags {list of string} escaped `key=value` tag fragments
 * @field fields {list of string} rendered `key=value` field fragments
 * @field timestamp {int} the timestamp in nanoseconds (when `timed`)
 * @field timed {bool} whether an explicit timestamp is set
 */
export def struct Point {
    measurement as string,
    tags as list of string,
    fields as list of string,
    timestamp as int,
    timed as bool
};

/**
 * One result series: its measurement name, its GROUP BY tag set, the column
 * names, and the rows (each cell stringified).
 * @field name {string} the measurement name
 * @field tags {map of string to string} the series tag set ({} if none)
 * @field columns {list of string} the column names (e.g. ["time", "value"])
 * @field values {list of list of string} the rows, one stringified cell per column
 */
export def struct Series {
    name as string,
    tags as map of string to string,
    columns as list of string,
    values as list of list of string
};

/**
 * A parsed query result: the flattened series across every statement.
 * @field series {list of Series} the result series
 */
export def struct Result {
    series as list of Series
};

func fail(msg as string) {
    throw Error{kind: "influxdb", message: "influxdb: " + $msg};
}

# --- clients (exported) -----------------------------------------------------

/**
 * Open a client to a database with no authentication.
 * @param url {string} the base URL (e.g. "http://localhost:8086")
 * @param db {string} the database name
 * @return {Client} a ready client
 */
export func client(url as string, db as string) {
    return clientWith($url, $db, "", "");
}

/**
 * Open a 1.x client with HTTP Basic-auth credentials.
 * @param url {string} the base URL
 * @param db {string} the database name
 * @param user {string} the username
 * @param password {string} the password
 * @return {Client} a ready client
 */
export func clientWith(url as string, db as string, user as string, password as string) {
    return Client{
        url: $url,
        version: Version.V1,
        db: $db,
        user: $user,
        password: $password,
        org: "",
        bucket: "",
        token: ""
    };
}

/**
 * Open an InfluxDB 2.x client: token auth, addressing data by organization +
 * bucket. `write` posts to `/api/v2/write` and `queryFlux` runs Flux over
 * `/api/v2/query`. InfluxDB 3.x accepts the writes but has no Flux.
 * @param url {string} the base URL (e.g. "http://localhost:8086")
 * @param org {string} the organization
 * @param bucket {string} the target bucket
 * @param token {string} the API token (sent as `Authorization: Token <token>`)
 * @return {Client} a ready 2.x client
 */
export func client2(url as string, org as string, bucket as string, token as string) {
    return Client{
        url: $url,
        version: Version.V2,
        db: "",
        user: "",
        password: "",
        org: $org,
        bucket: $bucket,
        token: $token
    };
}

# --- line-protocol escaping (private) ---------------------------------------

# escapeChars backslash-escapes every character of `s` that appears in
# `specials`. A backslash in `specials` is always escaped (string fields). One
# that is not is doubled only where it would otherwise pair with what follows:
# before a special character, another backslash, or the end of the component
# (where the next character is the separator). So a value can neither undo
# the escaping (`a\` then `,role=admin`) nor change a lone backslash, which
# InfluxDB 1.x keeps literally where 2.x would unescape `\\`. Most components
# need no escaping, so they return unchanged without a pass over the
# characters; the rest collect and join once (`+` per char is O(N^2)).
func escapeChars(s as string, specials as string) {
    if (not regex.matches("[\\\\" + regex.escape($specials) + "]", $s)) {
        return $s;
    }
    def always as bool init strings.contains($specials, "\\");
    def out as list of string init [];
    def cs as list of string init strings.chars($s);
    def n as int init len($cs);
    def i as int init 0;
    while ($i < $n) {
        def ch as string init $cs[$i];
        if ($ch == "\\" and not $always) {
            if ($i + 1 == $n or $cs[$i + 1] == "\\" or strings.contains($specials, $cs[$i + 1])) {
                $out[] = "\\\\";
            } else {
                $out[] = "\\";
            }
        } elseif (strings.contains($specials, $ch)) {
            $out[] = "\\" + $ch;
        } else {
            $out[] = $ch;
        }
        $i = $i + 1;
    }
    return strings.join($out, "");
}

# escapeMeasurement escapes a measurement name (comma and space, not equals).
func escapeMeasurement(s as string) {
    return escapeChars($s, ", ");
}

# escapeKey escapes a tag key / tag value / field key (comma, space, equals).
func escapeKey(s as string) {
    return escapeChars($s, ", =");
}

# escapeStringField renders a string field value: double-quoted, with `"` and
# `\` backslash-escaped.
func escapeStringField(s as string) {
    return "\"" + escapeChars($s, "\"\\") + "\"";
}

# fieldKey escapes a field key, refusing an empty one: `m =1.0` is not line
# protocol, and the server rejects the whole batch.
func fieldKey(key as string) {
    if ($key == "") {
        fail("a field key must not be empty");
    }
    return escapeKey($key);
}

# --- point builders (exported) ----------------------------------------------

/**
 * Start a point for a measurement (no tags or fields yet).
 * @param measurement {string} the measurement name
 * @return {Point} a fresh point
 */
export func point(measurement as string) {
    def tags as list of string init [];
    def fields as list of string init [];
    return Point{
        measurement: $measurement,
        tags: $tags,
        fields: $fields,
        timestamp: 0,
        timed: false
    };
}

/**
 * Add a tag (indexed string metadata). Returns a fresh point.
 * @param p {Point} the point
 * @param key {string} the tag key
 * @param value {string} the tag value
 * @return {Point} a point with the tag added
 */
export func tag(p as Point, key as string, value as string) {
    if ($key == "") {
        fail("a tag key must not be empty");
    }
    # An empty tag value is not line protocol; like the official clients, the
    # tag is left out.
    if ($value == "") {
        return $p;
    }
    def out as Point init $p;
    $out.tags[] = escapeKey($key) + "=" + escapeKey($value);
    return $out;
}

/**
 * Add a float field. Returns a fresh point.
 * @param p {Point} the point
 * @param key {string} the field key
 * @param value {float} the field value
 * @return {Point} a point with the field added
 */
export func field(p as Point, key as string, value as float) {
    def out as Point init $p;
    $out.fields[] = fieldKey($key) + "={$value}";
    return $out;
}

/**
 * Add an integer field (rendered with the line-protocol `i` suffix). Returns a
 * fresh point.
 * @param p {Point} the point
 * @param key {string} the field key
 * @param value {int} the field value
 * @return {Point} a point with the field added
 */
export func intField(p as Point, key as string, value as int) {
    def out as Point init $p;
    $out.fields[] = fieldKey($key) + "={$value}i";
    return $out;
}

/**
 * Add a string field (double-quoted, escaped). Returns a fresh point.
 * @param p {Point} the point
 * @param key {string} the field key
 * @param value {string} the field value
 * @return {Point} a point with the field added
 */
export func stringField(p as Point, key as string, value as string) {
    def out as Point init $p;
    $out.fields[] = fieldKey($key) + "=" + escapeStringField($value);
    return $out;
}

/**
 * Add a boolean field. Returns a fresh point.
 * @param p {Point} the point
 * @param key {string} the field key
 * @param value {bool} the field value
 * @return {Point} a point with the field added
 */
export func boolField(p as Point, key as string, value as bool) {
    def out as Point init $p;
    def rendered as string init "false";
    if ($value) {
        $rendered = "true";
    }
    $out.fields[] = fieldKey($key) + "=" + $rendered;
    return $out;
}

/**
 * Set an explicit timestamp in nanoseconds since the Unix epoch. Returns a
 * fresh point.
 * @param p {Point} the point
 * @param unixNanos {int} the timestamp in nanoseconds
 * @return {Point} a timestamped point
 */
export func at(p as Point, unixNanos as int) {
    def out as Point init $p;
    $out.timestamp = $unixNanos;
    $out.timed = true;
    return $out;
}

/**
 * Set the timestamp from a `time.Time`. Returns a fresh point.
 * @param p {Point} the point
 * @param t {time.Time} the timestamp
 * @return {Point} a timestamped point
 */
export func atTime(p as Point, t as time.Time) {
    return at($p, time.unixNanos($t));
}

/**
 * Render a point to one line-protocol line.
 * @param p {Point} the point
 * @return {string} the line-protocol line
 * @throws {Error} kind "influxdb" if the point has no fields, its measurement is empty or starts with `#` (a comment line, dropped by the server), or a component holds a newline
 */
export func line(p as Point) {
    if ($p.measurement == "" or strings.startsWith($p.measurement, "#")) {
        fail("a measurement must not be empty or start with #");
    }
    if (len($p.fields) == 0) {
        fail("point \"" + clean($p.measurement) + "\" has no fields");
    }
    def out as string init escapeMeasurement($p.measurement);
    if (len($p.tags) > 0) {
        $out = $out + "," + strings.join($p.tags, ",");
    }
    $out = $out + " " + strings.join($p.fields, ",");
    if ($p.timed) {
        $out = $out + " {$p.timestamp}";
    }
    # A newline anywhere in the rendered point splits its line and corrupts the
    # whole batch (the newline is the point separator, and line protocol has no
    # escape for it). Reject the point so it fails alone instead of silently
    # breaking every point in the write.
    if (strings.contains($out, "\n") or strings.contains($out, "\r")) {
        fail("point \"" + clean($p.measurement) +
            "\" contains a newline in a measurement / tag / field value (not representable in line protocol)");
    }
    return $out;
}

# --- HTTP plumbing (private) ------------------------------------------------

# joinBase joins a base URL and a path with exactly one slash between them.
func joinBase(base as string, path as string) {
    if (strings.endsWith($base, "/")) {
        return $base[..len($base) - 1] + $path;
    }
    return $base + $path;
}

# A built HTTP request: the URL, the Content-Type, the header map, and the
# body. The pure output of the request builders (buildWrite / buildQuery /
# buildFlux), so a test can assert the endpoint / params / auth / body without a
# live server.
def struct Req {
    url as string,
    contentType as string,
    headers as map of string to string,
    body as string
};

# authHeaders builds the auth header map for a client: Basic auth from
# user/password for a 1.x client (empty when no username), a `Token` header for
# a 2.x client (empty when no token).
func authHeaders(c as Client) {
    def h as map of string to string init {};
    match ($c.version) {
        when V1 {
            if (len($c.user) > 0) {
                def creds as string init $c.user + ":" + $c.password;
                def enc as string init encoding.toText(
                    "base64",
                    convert.bytesFromString("utf-8", $creds));
                $h["Authorization"] = "Basic " + $enc;
            }
        }
        when V2 {
            if (len($c.token) > 0) {
                $h["Authorization"] = "Token " + $c.token;
            }
        }
    }
    return $h;
}

# redact scrubs a client's credentials out of an error message, so a server
# that echoes the request (or its Authorization header) cannot expose them:
# the whole header value (`Token ...`, `Basic ...`) first, then the bare token
# or password when it is long enough not to match unrelated text.
func redact(c as Client, msg as string) {
    def out as string init $msg;
    def h as map of string to string init authHeaders($c);
    if (maps.has($h, "Authorization")) {
        $out = strings.replace($out, $h["Authorization"], "<redacted>");
    }
    for (def secret in [$c.token, $c.password]) {
        if (len($secret) >= 6) {
            $out = strings.replace($out, $secret, "<redacted>");
        }
    }
    return $out;
}

# MAX_ERROR caps how much server text an error message carries.
def const MAX_ERROR as int init 512;

# clean makes server or caller text fit an error message: control characters
# (but tab) become spaces, so it cannot forge log lines or terminal output,
# and it is cut at MAX_ERROR characters.
func clean(text as string) {
    def flat as string init regex.replace('[\x00-\x08\x0A-\x1F\x7F]', $text, " ");
    if (len($flat) > MAX_ERROR) {
        return strings.substring($flat, 0, MAX_ERROR) + "...";
    }
    return $flat;
}

# send posts a request, turning a transport failure (refused, timed out, bad
# URL) into an `influxdb` error like the server's own, credentials redacted.
func send(c as Client, req as Req) {
    try {
        return http.post($req.url, $req.contentType, $req.body, $req.headers);
    } catch (e) {
        fail(redact($c, clean($e.message)));
    }
}

# buildWrite builds the write request for a client and a rendered line-protocol
# body: `/write?db=...` for a 1.x client, `/api/v2/write?org=...&bucket=...` for
# a 2.x client, both at nanosecond precision.
func buildWrite(c as Client, body as string) {
    def ct as string init "text/plain; charset=utf-8";
    match ($c.version) {
        when V1 {
            def url as string init joinBase($c.url, "/write") + "?db=" +
                uri.encode($c.db) + "&precision=ns";
            return Req{url: $url, contentType: $ct, headers: authHeaders($c), body: $body};
        }
        when V2 {
            def url as string init joinBase($c.url, "/api/v2/write") + "?org=" +
                uri.encode($c.org) + "&bucket=" + uri.encode($c.bucket) + "&precision=ns";
            return Req{url: $url, contentType: $ct, headers: authHeaders($c), body: $body};
        }
    }
}

# buildQuery builds the 1.x InfluxQL request: `/query?db=...` with the
# statement as a form body (`q=...`), so it stays out of proxy and access logs
# (a `CREATE USER ... WITH PASSWORD` would otherwise be logged) and URL limits.
func buildQuery(c as Client, influxql as string) {
    def url as string init joinBase($c.url, "/query") + "?db=" + uri.encode($c.db);
    return Req{
        url: $url,
        contentType: "application/x-www-form-urlencoded",
        headers: authHeaders($c),
        body: "q=" + uri.encodeForm($influxql)
    };
}

# buildFlux builds the 2.x Flux request (`/api/v2/query?org=...`, the Flux
# script as the body under `application/vnd.flux`).
func buildFlux(c as Client, flux as string) {
    def url as string init joinBase($c.url, "/api/v2/query") + "?org=" + uri.encode($c.org);
    return Req{
        url: $url,
        contentType: "application/vnd.flux",
        headers: authHeaders($c),
        body: $flux
    };
}

# errorFrom extracts a server error message from a failed response: 1.x's
# `{"error": ...}`, 2.x's `{"code": ..., "message": ...}`, else the status
# alone. The text is cleaned and capped; the status leads.
func errorFrom(resp as http.Response) {
    def status as string init "HTTP {$resp.status}";
    if (len($resp.body) > 0) {
        try {
            def n as json.Value init json.decode($resp.body);
            for (def ptr in ["/error", "/message"]) {
                if (json.has($n, $ptr) and json.typeOf($n, $ptr) == "string") {
                    return $status + ": " + clean(json.asString($n, $ptr));
                }
            }
        } catch (e) { # lint-disable: L103
            # Intentionally empty: a non-JSON error body falls through to the
            # status message below. Bound to keep the swallow deliberate.
        }
    }
    return "request failed with " + $status;
}

# --- write (exported) -------------------------------------------------------

/**
 * Write points to the client's target (line protocol, nanosecond precision).
 * Dispatches on the client's `version`: a 1.x client posts to `/write?db=...`,
 * a 2.x client to `/api/v2/write?org=...&bucket=...`.
 * @param c {Client} the client
 * @param points {list of Point} the points to write
 * @throws {Error} kind "influxdb" on a non-2xx response (2.x token redacted)
 */
export func write(c as Client, points as list of Point) {
    if (len($points) == 0) {
        return null;
    }
    # Collect the lines and join once: an accumulating `+` over the batch would
    # be O(N^2) in the body size, and batch writes are the hot path.
    def lines as list of string init [];
    for (def p in $points) {
        $lines[] = line($p);
    }
    def body as string init strings.join($lines, "\n");
    def req as Req init buildWrite($c, $body);
    def resp as http.Response init send($c, $req);
    if ($resp.status >= 300) {
        fail(redact($c, errorFrom($resp)));
    }
    return null;
}

# --- query (exported) -------------------------------------------------------

# cellString stringifies one JSON scalar cell (null -> "").
func cellString(node as json.Value, ptr as string) {
    def t as string init json.typeOf($node, $ptr);
    match ($t) {
        when "string" { return json.asString($node, $ptr); }
        when "bool" { if (json.asBool($node, $ptr)) {
            return "true";
        }
        return "false"; }
        when "int" { return convert.toString(json.asInt($node, $ptr)); }
        when "float" { return convert.toString(json.asFloat($node, $ptr)); }
        else { return ""; } # null and anything else -> ""
    }
}

# parseSeries reads one series object at `base` into a Series.
func parseSeries(node as json.Value, base as string) {
    def name as string init "";
    if (json.has($node, $base + "/name")) {
        $name = json.asString($node, $base + "/name");
    }
    def tags as map of string to string init {};
    if (json.has($node, $base + "/tags")) {
        def keys as list of string init json.keys($node, $base + "/tags");
        for (def k in $keys) {
            # A key is a pointer segment: "~" and "/" escaped (RFC 6901), so
            # a tag key such as `kubernetes.io/hostname` reads back.
            def seg as string init strings.replace(strings.replace($k, "~", "~0"), "/", "~1");
            $tags[$k] = cellString($node, $base + "/tags/" + $seg);
        }
    }
    def columns as list of string init [];
    if (json.has($node, $base + "/columns")) {
        def nc as int init json.length($node, $base + "/columns");
        def c as int init 0;
        while ($c < $nc) {
            $columns[] = json.asString($node, $base + "/columns/{$c}");
            $c = $c + 1;
        }
    }
    def values as list of list of string init [];
    if (json.has($node, $base + "/values")) {
        def nrows as int init json.length($node, $base + "/values");
        def r as int init 0;
        while ($r < $nrows) {
            def rowptr as string init $base + "/values/{$r}";
            def ncols as int init json.length($node, $rowptr);
            def row as list of string init [];
            def cc as int init 0;
            while ($cc < $ncols) {
                $row[] = cellString($node, $rowptr + "/{$cc}");
                $cc = $cc + 1;
            }
            $values[] = $row;
            $r = $r + 1;
        }
    }
    return Series{name: $name, tags: $tags, columns: $columns, values: $values};
}

# parseQuery turns a decoded `/query` response into a Result, throwing on a
# per-statement error.
func parseQuery(node as json.Value) {
    def series as list of Series init [];
    if (json.has($node, "/error")) {
        fail(clean(cellString($node, "/error")));
    }
    if (not json.has($node, "/results")) {
        return Result{series: $series};
    }
    def nres as int init json.length($node, "/results");
    def i as int init 0;
    while ($i < $nres) {
        def rbase as string init "/results/{$i}";
        if (json.has($node, $rbase + "/error")) {
            fail(clean(cellString($node, $rbase + "/error")));
        }
        if (json.has($node, $rbase + "/series")) {
            def nser as int init json.length($node, $rbase + "/series");
            def j as int init 0;
            while ($j < $nser) {
                $series[] = parseSeries($node, $rbase + "/series/{$j}");
                $j = $j + 1;
            }
        }
        $i = $i + 1;
    }
    return Result{series: $series};
}

/**
 * Run an InfluxQL statement against a 1.x client's database and parse the
 * result. (The 2.x query language is Flux - see `queryFlux`.)
 * @param c {Client} the client
 * @param influxql {string} the InfluxQL statement (e.g. `SELECT * FROM cpu`)
 * @return {Result} the parsed series
 * @throws {Error} kind "influxdb" on a request failure or a query error
 */
export func query(c as Client, influxql as string) {
    def req as Req init buildQuery($c, $influxql);
    def resp as http.Response init send($c, $req);
    if ($resp.status >= 300) {
        fail(redact($c, errorFrom($resp)));
    }
    def node as json.Value;
    try {
        $node = json.decode($resp.body);
    } catch (e) {
        fail(redact($c, "non-JSON response from the query endpoint"));
    }
    return parseQuery($node);
}

/**
 * Run a Flux query against a 2.x client's organization and return the raw
 * response body: InfluxDB answers a Flux query with annotated CSV (RFC 4180
 * with `#datatype` / `#group` / `#default` header rows), not JSON, so this
 * returns it verbatim - parse it with the `csv` module. Posts the script to
 * `/api/v2/query?org=...` under `application/vnd.flux`.
 * @param c {Client} a 2.x client (from `client2`)
 * @param flux {string} the Flux script
 * @return {string} the annotated-CSV response body
 * @throws {Error} kind "influxdb" on a non-2xx response (token redacted)
 */
export func queryFlux(c as Client, flux as string) {
    def req as Req init buildFlux($c, $flux);
    def resp as http.Response init send($c, $req);
    if ($resp.status >= 300) {
        fail(redact($c, errorFrom($resp)));
    }
    return $resp.body;
}
