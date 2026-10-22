#!/usr/bin/env python3
"""Create a project-local CA and HTTPS certificate without changing system trust."""

import argparse
import ipaddress
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hostname", action="append", default=[], help="Certificate DNS name; repeatable")
    parser.add_argument("--ip", action="append", default=[], help="Certificate IP address; repeatable")
    parser.add_argument("--out", type=Path, default=Path(__file__).resolve().parents[1] / "certs")
    parser.add_argument("--renew", action="store_true", help="Replace only the server certificate/key; keep the existing CA")
    args = parser.parse_args()
    names = list(dict.fromkeys(["localhost"] + args.hostname))
    for name in names:
        if len(name) > 253 or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", name):
            parser.error("Invalid hostname")
    try:
        addresses = list(dict.fromkeys(["127.0.0.1"] + [str(ipaddress.ip_address(value)) for value in args.ip]))
    except ValueError:
        parser.error("Invalid IP address")
    if not shutil.which("openssl"):
        parser.error("OpenSSL is required. Raspberry Pi OS: sudo apt install openssl")
    os.umask(0o077)
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True)
    ca_key, ca_cert = output / "ca.key", output / "ca.crt"
    server_key, server_cert = output / "server.key", output / "server.crt"
    if ca_key.exists() != ca_cert.exists():
        parser.error("Incomplete existing CA. Restore both ca.key and ca.crt, or use a different --out directory.")
    if (server_key.exists() or server_cert.exists()) and not args.renew:
        parser.error("Server files already exist. Use --renew to replace the server certificate while retaining the CA.")

    def run(*command):
        result = subprocess.run(["openssl", *map(str, command)], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr.strip())
        return result.stdout

    with tempfile.TemporaryDirectory(prefix="tls-", dir=output) as temp:
        work = Path(temp)
        if not ca_key.exists():
            config = work / "ca.cnf"
            config.write_text("""[req]
distinguished_name = dn
x509_extensions = ca
prompt = no
[dn]
CN = Lost Found Box Local Demo CA
[ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
""")
            run("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "365",
                "-keyout", work / "ca.key", "-out", work / "ca.crt", "-config", config)
            shutil.move(str(work / "ca.key"), ca_key)
            shutil.move(str(work / "ca.crt"), ca_cert)
        config = work / "server.cnf"
        sans = "\n".join([f"DNS.{i} = {name}" for i, name in enumerate(names, 1)] +
                         [f"IP.{i} = {address}" for i, address in enumerate(addresses, 1)])
        config.write_text(f"""[req]
distinguished_name = dn
prompt = no
[dn]
CN = {names[-1]}
[server]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @names
[names]
{sans}
""")
        run("req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256", "-keyout", work / "server.key",
            "-out", work / "server.csr", "-config", config)
        run("x509", "-req", "-in", work / "server.csr", "-CA", ca_cert, "-CAkey", ca_key,
            "-set_serial", "0x" + os.urandom(16).hex(), "-days", "90", "-sha256",
            "-extfile", config, "-extensions", "server", "-out", work / "server.crt")
        run("verify", "-CAfile", ca_cert, work / "server.crt")
        shutil.move(str(work / "server.key"), server_key)
        shutil.move(str(work / "server.crt"), server_cert)
    ca_key.chmod(0o600)
    server_key.chmod(0o600)
    ca_cert.chmod(0o644)
    server_cert.chmod(0o644)
    print(f"Created certificate in {output}")
    print("DNS names: " + ", ".join(names))
    print("IP addresses: " + ", ".join(addresses))
    print("Install and explicitly trust ca.crt on the project iPad. Never distribute ca.key.")
    print(run("x509", "-in", ca_cert, "-noout", "-fingerprint", "-sha256").strip())


if __name__ == "__main__":
    main()
