-- Local HTTP-to-CGI development server (`daat serve`); dispatches requests to the daat binary.
-- Development use only (no TLS); use a reverse proxy with CGI in production.

const config = require("config")
const external_tool = require("external_tool")
const lfs = require("lfs")
const paths = require("paths")

const serve = {}

const PYTHON_CGI_BRIDGE = """
import http.server, os, subprocess, sys, urllib.parse

BIN = os.environ["DAAT_SERVE_BIN"]
ROOT = os.environ["DAAT_SERVE_ROOT"]
HOST = os.environ["DAAT_SERVE_HOST"]
PORT = int(os.environ["DAAT_SERVE_PORT"])
ONCE = os.environ.get("DAAT_SERVE_ONCE") == "1"

class DaatCGIHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("[daat serve] %s - %s\\n" % (self.address_string(), fmt % args))

    def _dispatch_cgi(self):
        parsed = urllib.parse.urlsplit(self.path)
        path_info = urllib.parse.unquote(parsed.path or "/")
        query_string = parsed.query or ""

        length_hdr = self.headers.get("Content-Length")
        body = b""
        if length_hdr:
            body = self.rfile.read(int(length_hdr))

        env = dict(os.environ)
        env["GATEWAY_INTERFACE"] = "CGI/1.1"
        env["DOCUMENT_ROOT"] = ROOT
        env["REQUEST_METHOD"] = self.command
        env["PATH_INFO"] = path_info
        env["QUERY_STRING"] = query_string
        if self.headers.get("Content-Type"):
            env["CONTENT_TYPE"] = self.headers.get("Content-Type")
        if length_hdr:
            env["CONTENT_LENGTH"] = length_hdr
        if self.headers.get("Cookie"):
            env["HTTP_COOKIE"] = self.headers.get("Cookie")
        if self.headers.get("X-CSRF-Token"):
            env["HTTP_X_CSRF_TOKEN"] = self.headers.get("X-CSRF-Token")
        if self.headers.get("X-API-Key"):
            env["HTTP_X_API_KEY"] = self.headers.get("X-API-Key")

        proc = subprocess.run(
            [BIN],
            input=body,
            stdout=subprocess.PIPE,
            stderr=sys.stderr,
            cwd=ROOT,
            env=env,
        )
        raw = proc.stdout
        sep = b"\\r\\n\\r\\n"
        idx = raw.find(sep)
        if idx < 0:
            sep = b"\\n\\n"
            idx = raw.find(sep)
        if idx < 0:
            self.send_response(500)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"Invalid CGI response from daat binary")
            return

        hdr_bytes = raw[:idx].decode("iso-8859-1")
        payload = raw[idx + len(sep):]

        status_code = 200
        status_msg = "OK"
        out_headers = []
        for line in hdr_bytes.splitlines():
            if ":" not in line:
                continue
            k, v = line.split(":", 1)
            k = k.strip()
            v = v.strip()
            if k.lower() == "status":
                parts = v.split(" ", 1)
                status_code = int(parts[0])
                status_msg = parts[1] if len(parts) > 1 else ""
            else:
                out_headers.append((k, v))

        self.send_response(status_code, status_msg)
        has_len = False
        for k, v in out_headers:
            if k.lower() == "content-length":
                has_len = True
            self.send_header(k, v)
        if not has_len:
            self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def do_GET(self):
        self._dispatch_cgi()

    def do_POST(self):
        self._dispatch_cgi()

    def do_HEAD(self):
        self._dispatch_cgi()

    def do_PUT(self):
        self._dispatch_cgi()

    def do_PATCH(self):
        self._dispatch_cgi()

    def do_DELETE(self):
        self._dispatch_cgi()

    def do_OPTIONS(self):
        self._dispatch_cgi()

class SyncReusableHTTPServer(http.server.HTTPServer):
    allow_reuse_address = True

class ReusableHTTPServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True

ServerCls = SyncReusableHTTPServer if ONCE else ReusableHTTPServer
httpd = ServerCls((HOST, PORT), DaatCGIHandler)
actual_port = httpd.server_address[1]
print(f"Serving Daat at http://{HOST}:{actual_port} (root: {ROOT})", flush=True)
print("Local development server only -- use TLS + Apache/nginx CGI in production.", flush=True)
try:
    if ONCE:
        httpd.handle_request()
    else:
        httpd.serve_forever()
except KeyboardInterrupt:
    pass
"""

function resolve_self_binary()
    -- On Linux, /proc/self/exe points directly to the compiled daat binary.
    exe = lfs.symlinkattributes("/proc/self/exe", "target")
    if type(exe) == "string" and exe != "" and string.find(exe, "luam", 1, true) == nil then
        return exe
    end
    if paths.file_exists("./bin/daat") then
        return lfs.currentdir() .. "/bin/daat"
    end
    found, _ = external_tool.capture("command -v daat 2>/dev/null")
    if found != nil then
        return string.gsub(found, "%s+$", "")
    end
    return nil
end

function serve.do_serve(cmd_args, root)
    if root == nil or root == "." then
        root = lfs.currentdir()
    end
    host = "127.0.0.1"
    port = 8000
    once = false

    i = 1
    while i <= #cmd_args do
        a = cmd_args[i]
        if a == "-h" or a == "--help" then
            print("Usage: daat serve [--port 8000] [--host 127.0.0.1] [--once]")
            print("Starts a local HTTP-to-CGI development server for the current store.")
            return 0
        elseif a == "--port" then
            p = tonumber(cmd_args[i + 1])
            if p == nil or p < 0 or p > 65535 then
                print("Error: --port must be between 0 and 65535")
                return 1
            end
            port = math.floor(p)
            i = i + 2
        elseif a == "--host" then
            h = cmd_args[i + 1]
            if h == nil or h == "" then
                print("Error: --host requires an address")
                return 1
            end
            host = h
            i = i + 2
        elseif a == "--once" then
            once = true
            i = i + 1
        else
            print("Usage: daat serve [--port 8000] [--host 127.0.0.1] [--once]")
            return 1
        end
    end

    if config.is_initialized(root) == false then
        print("Not initialized. Run 'daat init' first.")
        return 1
    end

    if not external_tool.available("python3") then
        print("Error: python3 is required on PATH to run 'daat serve'.")
        return 1
    end

    bin_path = resolve_self_binary()
    if bin_path == nil then
        print("Error: could not locate compiled 'daat' binary.")
        return 1
    end

    vendor_dir = os.getenv("DAAT_VENDOR_DIR")
    if vendor_dir == nil or vendor_dir == "" then
        repo_guess = string.match(bin_path, "^(.*)/[^/]+/[^/]+$")
        if repo_guess != nil and paths.is_dir(repo_guess .. "/vnd") then
            vendor_dir = repo_guess .. "/vnd"
        else
            vendor_dir = "./vnd"
        end
    end

    once_flag = "0"
    if once then
        once_flag = "1"
    end

    cmd = string.format(
        "DAAT_SERVE_BIN=%s DAAT_SERVE_ROOT=%s DAAT_SERVE_HOST=%s DAAT_SERVE_PORT=%d DAAT_SERVE_ONCE=%s DAAT_VENDOR_DIR=%s python3 -c %s",
        external_tool.shell_quote(bin_path),
        external_tool.shell_quote(root),
        external_tool.shell_quote(host),
        port,
        once_flag,
        external_tool.shell_quote(vendor_dir),
        external_tool.shell_quote(PYTHON_CGI_BRIDGE)
    )
    ok = external_tool.run(cmd)
    if ok == true or ok == 0 then
        return 0
    end
    return 1
end

return serve
