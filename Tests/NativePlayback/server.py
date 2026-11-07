import http.server, time, datetime, json, ssl, os, socketserver
from pathlib import Path
from urllib.parse import urlparse
root = Path(__file__).parent / 'media'
started = {}
fetched = {}
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path=urlparse(self.path).path
        if path=='/health':
            data=b'OK'; kind='text/plain'
        elif path=='/stats':
            data=json.dumps(fetched).encode(); kind='application/json'
        elif path.endswith('.m3u8'):
            fixture=Path(path).stem
            mode=fixture.split("-")[0]
            now=started.setdefault(fixture,time.time())
            elapsed=time.time()-now
            count=10 if mode=='control' else min(30,3+int(elapsed/2))
            if mode=='preroll':
                count=min(count,4) if elapsed<8 else count
                ad_start,ad_end=0,8
            elif mode=='midroll':
                ad_start,ad_end=6,12
            elif mode=='title':
                ad_start,ad_end=6,22
            else:
                ad_start=ad_end=0
            def stamp(offset):
                return datetime.datetime.fromtimestamp(now+offset,datetime.timezone.utc).isoformat().replace('+00:00','Z')
            first=max(0,count-3) if mode=='title' else 0
            lines=['#EXTM3U','#EXT-X-VERSION:3','#EXT-X-TARGETDURATION:2',f'#EXT-X-MEDIA-SEQUENCE:{first}']
            if mode!='title': lines.append('#EXT-X-PLAYLIST-TYPE:EVENT')
            if mode not in ('control','title'):
                lines.append(f'#EXT-X-DATERANGE:ID="stitched-ad-test",CLASS="twitch-stitched-ad",START-DATE="{stamp(ad_start)}",DURATION={ad_end-ad_start}')
            for i in range(first,count):
                if mode=='midroll' and i in (3,6): lines.append('#EXT-X-DISCONTINUITY')
                title='Amazon' if mode=='title' and ad_start<=i*2<ad_end else ''
                lines += [f'#EXT-X-PROGRAM-DATE-TIME:{stamp(i*2)}',f'#EXTINF:2,{title}',f'https://127.0.0.1:8765/{fixture}/segment{i:03}.ts']
            if mode=='control': lines.append('#EXT-X-ENDLIST')
            data=('\n'.join(lines)+'\n').encode();kind='application/vnd.apple.mpegurl'
        elif path.endswith('.ts'):
            mode=path.split('/')[1]; name=Path(path).name
            fetched.setdefault(mode,[]).append(name)
            data=(root/name).read_bytes();kind='video/mp2t'
        else:
            self.send_error(404);return
        self.send_response(200);self.send_header('Content-Type',kind)
        self.send_header('Content-Length',str(len(data)));self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(data)
    def log_message(self, fmt, *args): print(f"HTTP {self.command} {self.path}: {fmt % args}", flush=True)
class LoopbackServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # The fixture has a known name; avoid reverse DNS during HTTPServer init.
        socketserver.TCPServer.server_bind(self)
        self.server_name = 'localhost'
        self.server_port = self.server_address[1]

if __name__ == '__main__':
    server = LoopbackServer(('127.0.0.1', 8765), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(os.environ['FIXTURE_CERT'], os.environ['FIXTURE_KEY'])
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print('Fixture listening on https://127.0.0.1:8765', flush=True)
    server.serve_forever()
