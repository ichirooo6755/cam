import http.server
import socketserver
import os
import mimetypes
import re
import html

PORT = 8000
DIRECTORY = "/home/pi/photos"

SAFE_FILENAME_RE = re.compile(r'^[A-Za-z0-9._-]+$')

# Ensure directory exists
os.makedirs(DIRECTORY, exist_ok=True)

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)
    
    def do_GET(self):
        if self.path == '/' or self.path == '/index.html':
            # Serve custom gallery page
            try:
                with open('/home/pi/gallery.html', 'r', encoding='utf-8') as f:
                    template = f.read()

                files = [
                    f for f in os.listdir(DIRECTORY)
                    if f.lower().endswith(('.jpg', '.jpeg', '.png')) and SAFE_FILENAME_RE.match(f)
                ]
                files.sort(key=lambda x: os.path.getmtime(os.path.join(DIRECTORY, x)), reverse=True)

                items = []
                for index, filename in enumerate(files):
                    safe_name = html.escape(filename)
                    items.append(
                        '<div class="photo-frame">'
                        f'<img src="/api/photo/{index}" alt="{safe_name}" loading="lazy">'
                        f'<div class="photo-caption">{safe_name}</div>'
                        '</div>'
                    )

                content = template.replace('<!--PHOTO_ITEMS-->', '\n'.join(items))
                content_bytes = content.encode('utf-8')
                self.send_response(200)
                self.send_header('Content-type', 'text/html; charset=utf-8')
                self.send_header('Content-length', len(content_bytes))
                self.end_headers()
                self.wfile.write(content_bytes)
            except FileNotFoundError:
                # Fallback to default behavior if gallery.html doesn't exist
                super().do_GET()
        elif self.path == '/api/photos':
            # Return JSON list of photos
            try:
                files = [
                    f for f in os.listdir(DIRECTORY)
                    if f.lower().endswith(('.jpg', '.jpeg', '.png')) and SAFE_FILENAME_RE.match(f)
                ]
                files.sort(key=lambda x: os.path.getmtime(os.path.join(DIRECTORY, x)), reverse=True)
                
                import json
                self.send_response(200)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(files).encode('utf-8'))
            except Exception as e:
                self.send_error(500, str(e))
        elif self.path.startswith('/api/photo/'):
            try:
                index_text = self.path[len('/api/photo/'):]
                if not index_text.isdigit():
                    self.send_error(400, 'Invalid index')
                    return
                index = int(index_text)

                files = [
                    f for f in os.listdir(DIRECTORY)
                    if f.lower().endswith(('.jpg', '.jpeg', '.png')) and SAFE_FILENAME_RE.match(f)
                ]
                files.sort(key=lambda x: os.path.getmtime(os.path.join(DIRECTORY, x)), reverse=True)

                if index < 0 or index >= len(files):
                    self.send_error(404, 'Photo not found')
                    return

                filename = files[index]
                file_path = os.path.join(DIRECTORY, filename)
                real_dir = os.path.realpath(DIRECTORY)
                real_path = os.path.realpath(file_path)
                if not real_path.startswith(real_dir + os.sep):
                    self.send_error(403, 'Access denied')
                    return

                with open(file_path, 'rb') as f:
                    content = f.read()

                mime_type, _ = mimetypes.guess_type(filename)
                self.send_response(200)
                self.send_header('Content-type', mime_type or 'application/octet-stream')
                self.send_header('Content-length', len(content))
                self.end_headers()
                self.wfile.write(content)
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
