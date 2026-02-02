import http.server
import socketserver
import os

PORT = 8000
DIRECTORY = "/home/pi/photos"

# Ensure directory exists
os.makedirs(DIRECTORY, exist_ok=True)

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)
    
    def do_GET(self):
        if self.path == '/' or self.path == '/index.html':
            # Serve custom gallery page
            try:
                with open('/home/pi/gallery.html', 'rb') as f:
                    content = f.read()
                self.send_response(200)
                self.send_header('Content-type', 'text/html; charset=utf-8')
                self.send_header('Content-length', len(content))
                self.end_headers()
                self.wfile.write(content)
            except FileNotFoundError:
                # Fallback to default behavior if gallery.html doesn't exist
                super().do_GET()
        elif self.path == '/api/photos':
            # Return JSON list of photos
            try:
                files = [f for f in os.listdir(DIRECTORY) if f.lower().endswith(('.jpg', '.jpeg', '.png'))]
                files.sort(key=lambda x: os.path.getmtime(os.path.join(DIRECTORY, x)), reverse=True)
                
                import json
                self.send_response(200)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(files).encode('utf-8'))
            except Exception as e:
                self.send_error(500, str(e))
        else:
            # Serve photos and other files normally
            super().do_GET()

class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True

print(f"Starting Photo Server on port {PORT} serving {DIRECTORY}")
with ReusableTCPServer(("", PORT), Handler) as httpd:
    httpd.serve_forever()
