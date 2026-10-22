#!/usr/bin/env python3
"""Serve only the public project CA and setup instructions on a trusted LAN."""

import argparse
import hashlib
from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import ssl


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ca", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8088)
    parser.add_argument("--app-url", default="https://work123.local:8443")
    args = parser.parse_args()
    certificate = args.ca.read_bytes()
    digest = hashlib.sha256(ssl.PEM_cert_to_DER_cert(certificate.decode("ascii"))).hexdigest().upper()
    fingerprint = ":".join(digest[i:i + 2] for i in range(0, len(digest), 2))
    page = f"""<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>归处 · iPad 首次设置</title>
<style>body{{font:17px/1.8 system-ui;margin:40px auto;padding:0 24px;max-width:680px;color:#203b32;background:#f5f6f2}}
a{{color:#315c48}}li{{margin:18px 0}}code{{overflow-wrap:anywhere;font-size:12px}}.button{{display:inline-block;background:#315c48;color:white;padding:10px 18px;border-radius:8px;text-decoration:none}}</style>
<h1>归处 · iPad 首次设置</h1><p>此页面仅用于安装项目的公开证书。请在与树莓派相同网络的 iPad 上用 Safari 打开。</p>
<ol><li><a class="button" href="/ca.crt">下载项目证书</a><br>允许下载描述文件。若以文件形式保存，请打开证书以安装。</li>
<li>在“设置 → 通用 → VPN 与设备管理”（或“已下载描述文件”）安装 <b>Lost Found Box Local Demo CA</b>。</li>
<li>在“设置 → 通用 → 关于本机 → 证书信任设置”中，为此项目证书开启完全信任。</li>
<li><a class="button" href="{escape(args.app_url, quote=True)}">打开照片登记</a><br>点击“打开相机”并允许访问。若仍有证书警告，请返回检查信任设置。</li></ol>
<p>这是课堂原型的本地证书，只在确认连接到项目树莓派后安装。受管理设备可能需要管理员操作；菜单随系统版本略有不同。项目结束后可移除该描述文件。</p>
<p>证书 SHA-256 指纹（可与部署记录核对）：<br><code>{fingerprint}</code></p></html>""".encode("utf-8")

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = self.path.partition("?")[0]
            if path == "/":
                body, mime, status = page, "text/html; charset=utf-8", 200
            elif path == "/ca.crt":
                body, mime, status = certificate, "application/x-x509-ca-cert", 200
            else:
                body, mime, status = b"Not found", "text/plain", 404
            self.send_response(status)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
