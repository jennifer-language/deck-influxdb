# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.25.0
#
# influxdb_test.j - white-box tests for influxdb.j. Run with:
#
#     jennifer test src/influxdb_test.j
#
# These exercise the pure line-protocol rendering / escaping and the query-JSON
# parsing with no network; the live write / query over http runs against an
# `httpd` server on a loopback port standing in for InfluxDB
# (testWriteAndQueryAgainstAServer). influxdb.j already `use`s json / strings /
# convert / time / encoding / regex / maps, so the overlay adds testing, httpd and task.
use testing;
use httpd;
use task;

func testLineBasic() {
    def p as Point init field(point("cpu"), "value", 0.5);
    testing.assertEqual(line($p), "cpu value=0.5");
}

# A newline in a tag value (or any component) must be rejected: it would split
# the point's line and corrupt the whole batch.
func lineWithNewlineTag() {
    def p as Point init field(tag(point("cpu"), "host", "a\nb"), "value", 1.0);
    line($p);
}
func testLineRejectsNewline() {
    testing.assertThrows("lineWithNewlineTag", "influxdb");
}

func testLineWithOneTag() {
    def p as Point init point("cpu");
    $p = tag($p, "host", "a");
    $p = field($p, "value", 1.0);
    testing.assertEqual(line($p), "cpu,host=a value=1.0");
}

func testLineFieldTypes() {
    def p as Point init point("m");
    $p = intField($p, "n", 5);
    $p = boolField($p, "up", true);
    $p = boolField($p, "down", false);
    $p = stringField($p, "s", "hi");
    testing.assertEqual(line($p), "m n=5i,up=true,down=false,s=\"hi\"");
}

func testLineTimestamp() {
    def p as Point init at(field(point("m"), "v", 2.0), 1434055562000000000);
    testing.assertEqual(line($p), "m v=2.0 1434055562000000000");
}

func testLineEscaping() {
    def p as Point init point("cpu load");
    $p = tag($p, "region", "us west");
    $p = tag($p, "host", "srv,1");
    $p = field($p, "a=b", 1.0);
    testing.assertEqual(line($p), "cpu\\ load,region=us\\ west,host=srv\\,1 a\\=b=1.0");
}

func testStringFieldEscaping() {
    def p as Point init stringField(point("m"), "note", "he said \"hi\"\\done");
    testing.assertEqual(line($p), "m note=\"he said \\\"hi\\\"\\\\done\"");
}

func testLineNoFieldsThrows() {
    def threw as bool init false;
    try {
        line(point("m"));
    } catch (e) {
        $threw = true;
        testing.assertEqual($e.kind, "influxdb");
    }
    testing.assertTrue($threw);
}

func testEscapeHelpers() {
    testing.assertEqual(escapeMeasurement("a b,c"), "a\\ b\\,c");
    testing.assertEqual(escapeKey("a b,c=d"), "a\\ b\\,c\\=d");
    testing.assertEqual(escapeStringField("x"), "\"x\"");
}

func testCellString() {
    def n as json.Value init json.decode('{"s":"txt","i":42,"f":3.5,"b":true,"z":null}');
    testing.assertEqual(cellString($n, "/s"), "txt");
    testing.assertEqual(cellString($n, "/i"), "42");
    testing.assertEqual(cellString($n, "/f"), "3.5");
    testing.assertEqual(cellString($n, "/b"), "true");
    testing.assertEqual(cellString($n, "/z"), "");
}

func testParseQuery() {
    def body as string init '{"results":[{"statement_id":0,"series":[{"name":"cpu","tags":{"host":"a"},"columns":["time","value"],"values":[["2021-01-01T00:00:00Z",0.5],["2021-01-01T00:01:00Z",0.7]]}]}]}';
    def r as Result init parseQuery(json.decode($body));
    testing.assertEqual(len($r.series), 1);
    testing.assertEqual($r.series[0].name, "cpu");
    testing.assertEqual($r.series[0].tags["host"], "a");
    testing.assertEqual(len($r.series[0].columns), 2);
    testing.assertEqual($r.series[0].columns[1], "value");
    testing.assertEqual(len($r.series[0].values), 2);
    testing.assertEqual($r.series[0].values[0][0], "2021-01-01T00:00:00Z");
    testing.assertEqual($r.series[0].values[1][1], "0.7");
}

func testParseQueryError() {
    def body as string init '{"results":[{"statement_id":0,"error":"database not found: nope"}]}';
    def threw as bool init false;
    try {
        parseQuery(json.decode($body));
    } catch (e) {
        $threw = true;
        testing.assertEqual($e.kind, "influxdb");
    }
    testing.assertTrue($threw);
}

func testParseQueryEmpty() {
    # a statement with no series (e.g. a write-style statement) yields no series
    def r as Result init parseQuery(json.decode('{"results":[{"statement_id":0}]}'));
    testing.assertEqual(len($r.series), 0);
}

# --- 2.x / 3.x backend: request building (no network) -----------------------

func testClient2Fields() {
    def c as Client init client2("http://localhost:8086", "myorg", "mybucket", "mytoken");
    testing.assertEqual($c.org, "myorg");
    testing.assertEqual($c.bucket, "mybucket");
    testing.assertEqual($c.token, "mytoken");
    testing.assertEqual($c.db, "");
    match ($c.version) {
        when V1 { testing.assertTrue(false); }
        when V2 { testing.assertTrue(true); }
    }
}

func testClientDefaultsV1() {
    def c as Client init client("http://localhost:8086", "metrics");
    match ($c.version) {
        when V1 { testing.assertTrue(true); }
        when V2 { testing.assertTrue(false); }
    }
}

# The pinned v2 write request: endpoint /api/v2/write with org + bucket +
# precision, a `Token` Authorization header, and the line-protocol body.
func testBuildWriteV2() {
    def c as Client init client2("http://localhost:8086", "myorg", "mybucket", "mytoken");
    def p as Point init field(tag(point("cpu"), "host", "server01"), "value", 0.64);
    def req as Req init buildWrite($c, line($p));
    testing.assertEqual(
        $req.url,
        "http://localhost:8086/api/v2/write?org=myorg&bucket=mybucket&precision=ns");
    testing.assertEqual($req.contentType, "text/plain; charset=utf-8");
    testing.assertEqual($req.headers["Authorization"], "Token mytoken");
    testing.assertEqual($req.body, "cpu,host=server01 value=0.64");
}

# A 1.x write stays byte-identical: /write?db=... and no auth header when
# unauthenticated.
func testBuildWriteV1() {
    def c as Client init client("http://localhost:8086", "metrics");
    def p as Point init field(point("cpu"), "value", 0.5);
    def req as Req init buildWrite($c, line($p));
    testing.assertEqual($req.url, "http://localhost:8086/write?db=metrics&precision=ns");
    testing.assertEqual($req.contentType, "text/plain; charset=utf-8");
    testing.assertEqual($req.body, "cpu value=0.5");
    testing.assertEqual(len($req.headers), 0);
}

func testBuildWriteV1BasicAuth() {
    def c as Client init clientWith("http://localhost:8086", "metrics", "user", "pass");
    def req as Req init buildWrite($c, "cpu value=1.0");
    # base64("user:pass") == "dXNlcjpwYXNz"
    testing.assertEqual($req.headers["Authorization"], "Basic dXNlcjpwYXNz");
}

# The pinned Flux query request: /api/v2/query?org=... under vnd.flux with the
# Flux script as the body.
func testBuildFluxV2() {
    def c as Client init client2("http://localhost:8086", "myorg", "mybucket", "mytoken");
    def req as Req init buildFlux($c, "from(bucket:\"mybucket\") |> range(start:-1h)");
    testing.assertEqual($req.url, "http://localhost:8086/api/v2/query?org=myorg");
    testing.assertEqual($req.contentType, "application/vnd.flux");
    testing.assertEqual($req.headers["Authorization"], "Token mytoken");
    testing.assertEqual($req.body, "from(bucket:\"mybucket\") |> range(start:-1h)");
}

func testBuildQueryV1() {
    def c as Client init client("http://localhost:8086", "metrics");
    def req as Req init buildQuery($c, "SELECT * FROM cpu");
    # The statement goes in the form body, not the URL (it would be logged).
    testing.assertEqual($req.url, "http://localhost:8086/query?db=metrics");
    testing.assertEqual($req.contentType, "application/x-www-form-urlencoded");
    testing.assertEqual($req.body, "q=SELECT+%2A+FROM+cpu");
}

# The token is scrubbed from any error a 2.x request surfaces; a client with
# no credentials leaves the message untouched.
func testRedactToken() {
    def c as Client init client2("http://h", "o", "b", "sekrettoken");
    testing.assertEqual(redact($c, "boom sekrettoken here"), "boom <redacted> here");
    def c1 as Client init client("http://h", "db");
    testing.assertEqual(redact($c1, "unchanged"), "unchanged");
}

# --- write and query, against an httpd server on a loopback port ------------

# Answer a write and a query as InfluxDB 1.x would, checking what a client
# must send; a wrong request is a 400 that fails the client call.
func fakeInflux(srv as httpd.Server) {
    def wantAuth as string init "Basic dXNlcjpwYXNz";
    for (def i in 0..2) {
        def req as httpd.Request init httpd.accept($srv);
        if (httpd.path($req) == "/write") {
            def body as string init convert.stringFromBytes(httpd.body($req), "utf-8");
            if (httpd.method($req) == "POST" and
                httpd.header($req, "Authorization") == $wantAuth and
                httpd.query($req, "db") == "metrics" and httpd.query($req, "precision") == "ns" and
                $body == "cpu,host=srv1 value=0.64") {
                httpd.respond($req, 204, "");
            } else {
                httpd.respond($req, 400, '{"error":"bad write request"}');
            }
        } elseif (httpd.path($req) == "/query" and
            uri.parseQuery(convert.stringFromBytes(httpd.body($req), "utf-8"))["q"] ==
            "SELECT value FROM cpu") {
            httpd.setHeader($req, "Content-Type", "application/json");
            httpd.respond(
                $req,
                200,
                '{"results":[{"statement_id":0,"series":[{"name":"cpu","columns":["time","value"],"values":[["2021-01-01T00:00:00Z",0.64]]}]}]}');
        } else {
            httpd.respond($req, 400, '{"error":"bad query"}');
        }
    }
}

func testWriteAndQueryAgainstAServer() {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def t as task of null init spawn {
        fakeInflux($srv);
    };
    def c as Client init clientWith("http://" + httpd.address($srv), "metrics", "user", "pass");
    write($c, [field(tag(point("cpu"), "host", "srv1"), "value", 0.64)]);
    def r as Result init query($c, "SELECT value FROM cpu");
    task.wait($t);
    httpd.shutdown($srv);
    testing.assertEqual(len($r.series), 1);
    testing.assertEqual($r.series[0].name, "cpu");
    testing.assertEqual($r.series[0].values[0][0], "2021-01-01T00:00:00Z");
    testing.assertEqual($r.series[0].values[0][1], "0.64");
}

# atTime timestamps a point from a time.Time, in nanoseconds.
func testAtTime() {
    def p as Point init atTime(
        field(point("cpu"), "value", 1.0),
        time.fromIso("2021-01-01T00:00:00Z"));
    testing.assertEqual(line($p), "cpu value=1.0 1609459200000000000");
}

# Answer one Flux query as InfluxDB 2.x would: annotated CSV for a request
# with the token and the Flux media type, a 401 otherwise.
func fakeFlux(srv as httpd.Server) {
    def seen as list of string init [];
    for (def i in 0..2) {
        def req as httpd.Request init httpd.accept($srv);
        def body as string init convert.stringFromBytes(httpd.body($req), "utf-8");
        $seen[] = httpd.method($req) + " " + httpd.path($req) + " org=" + httpd.query($req, "org") +
            " " +
            httpd.header($req, "Content-Type") + " " + $body;
        if (httpd.header($req, "Authorization") == "Token s3cr3t") {
            httpd.setHeader($req, "Content-Type", "text/csv");
            httpd.respond($req, 200, "#datatype,string,long\r\n,result,table\r\n,_result,0\r\n");
        } else {
            httpd.setHeader($req, "Content-Type", "application/json");
            httpd.respond($req, 401, '{"code":"unauthorized","message":"unauthorized access"}');
        }
    }
    return $seen;
}

func testQueryFluxAgainstAServer() {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def t as task of list of string init spawn {
        return fakeFlux($srv);
    };
    def url as string init "http://" + httpd.address($srv);
    def flux as string init 'from(bucket: "metrics") |> range(start: -1h)';
    testing.assertEqual(
        queryFlux(client2($url, "acme", "metrics", "s3cr3t"), $flux),
        "#datatype,string,long\r\n,result,table\r\n,_result,0\r\n");
    def refused as string init "";
    try {
        queryFlux(client2($url, "acme", "metrics", "wrong-token"), $flux);
    } catch (e) {
        $refused = $e.kind + ": " + $e.message;
    }
    def seen as list of string init task.wait($t);
    httpd.shutdown($srv);
    testing.assertTrue(strings.startsWith($refused, "influxdb: "));
    testing.assertFalse(strings.contains($refused, "wrong-token"));
    testing.assertEqual($seen[0], "POST /api/v2/query org=acme application/vnd.flux " + $flux);
}

# --- the review's fixes ------------------------------------------------------

# A backslash before an escaped character, another backslash or the end of a
# component is doubled, so a value cannot undo the escaping; a lone one stays.
func testBackslashCannotUndoEscaping() {
    testing.assertEqual(
        line(field(tag(tag(point("m"), "host", 'a\'), "role", "admin"), "v", 1.0)),
        'm,host=a\\,role=admin v=1.0');
    testing.assertEqual(line(field(point('cpu\'), "v", 1.0)), 'cpu\\ v=1.0');
    testing.assertEqual(
        line(field(tag(point("m"), "path", 'C:\x'), "v", 1.0)),
        'm,path=C:\x v=1.0');
    testing.assertEqual(escapeKey('x\,k\=v'), 'x\\\,k\\\=v');
    testing.assertEqual(escapeKey("plain"), "plain");
    testing.assertEqual(escapeStringField('say "hi" \o/'), '"say \"hi\" \\o/"');
}

func emptyTagKey() {
    tag(point("m"), "", "v");
}

func emptyFieldKey() {
    field(point("m"), "", 1.0);
}

func emptyMeasurement() {
    line(field(point(""), "v", 1.0));
}

func commentMeasurement() {
    line(field(point("#cpu"), "v", 1.0));
}

func testInvalidLinesRefused() {
    for (def f in ["emptyTagKey", "emptyFieldKey", "emptyMeasurement", "commentMeasurement"]) {
        testing.assertThrows($f, "influxdb");
    }
    # an empty tag value is left out, as the official clients do
    testing.assertEqual(line(field(tag(point("m"), "host", ""), "v", 1.0)), "m v=1.0");
}

func testErrorText() {
    def two as http.Response init http.Response{
        status: 400,
        statusText: "Bad Request",
        headers: {},
        body: '{"code":"invalid","message":"unable to parse line"}'
    };
    testing.assertEqual(errorFrom($two), "HTTP 400: unable to parse line");
    def one as http.Response init http.Response{
        status: 404,
        statusText: "",
        headers: {},
        body: '{"error":"database not found"}'
    };
    testing.assertEqual(errorFrom($one), "HTTP 404: database not found");
    def evil as http.Response init http.Response{
        status: 500,
        statusText: "",
        headers: {},
        body: '{"error":"evil\u001b[2J\r\nFAKE LOG LINE"}'
    };
    testing.assertFalse(regex.matches('[\x00-\x08\x0A-\x1F]', errorFrom($evil)));
    def long as http.Response init http.Response{
        status: 500,
        statusText: "",
        headers: {},
        body: '{"error":"' + strings.repeat("A", 5000) + '"}'
    };
    testing.assertTrue(len(errorFrom($long)) < MAX_ERROR + 20);
    testing.assertEqual(
        errorFrom(http.Response{status: 502, statusText: "", headers: {}, body: "<html>"}),
        "request failed with HTTP 502");
}

func testRedactsBasicAndShortSecrets() {
    def c as Client init clientWith("http://h", "db", "admin", "hunter2");
    def msg as string init "rejected Basic YWRtaW46aHVudGVyMg== for admin with hunter2";
    testing.assertEqual(redact($c, $msg), "rejected <redacted> for admin with <redacted>");
    def short as Client init client2("http://h", "o", "b", "4");
    testing.assertEqual(redact($short, "status 401 Token 4"), "status 401 <redacted>");
}

func refusedConnection() {
    write(client("http://127.0.0.1:1", "db"), [field(point("m"), "v", 1.0)]);
}

func testTransportErrorsAreInfluxdb() {
    testing.assertThrows("refusedConnection", "influxdb");
}

func topLevelError() {
    parseQuery(json.decode('{"error":"error parsing query"}'));
}

func testQueryParsing() {
    def r as Result init parseQuery(json.decode(
        '{"results":[{"series":[{"name":"cpu","tags":{"kubernetes.io/hostname":"n1","a~b":"x"},"columns":["time","v"],"values":[["t",1]]}]}]}'));
    testing.assertEqual($r.series[0].tags["kubernetes.io/hostname"], "n1");
    testing.assertEqual($r.series[0].tags["a~b"], "x");
    testing.assertThrows("topLevelError", "influxdb");
}
