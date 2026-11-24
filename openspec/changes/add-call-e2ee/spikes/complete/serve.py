import http.server,sys,json
class Server(http.server.SimpleHTTPRequestHandler):
 def end_headers(self):
  self.send_header('Referrer-Policy','no-referrer')
  self.send_header('Content-Security-Policy',"default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self' blob:; connect-src 'self' https://127.0.0.1:* https://localhost:*; style-src 'self' 'unsafe-inline'; img-src 'self' data:")
  super().end_headers()
 def do_POST(self):
  b=self.rfile.read(int(self.headers.get('Content-Length','0')))
  print(json.dumps({'method':'POST','path':self.path,'body':b.decode()}),flush=True)
  self.send_response(204);self.end_headers()
http.server.ThreadingHTTPServer(('127.0.0.1',8124),lambda *a,**k:Server(*a,directory=sys.argv[1],**k)).serve_forever()
