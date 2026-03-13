from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path


WINDOWS_OPENSSH_DIR = r"C:\Windows\System32\OpenSSH"


def resolve_windows_openssh_binary(binary_name: str, *fallback_names: str) -> str | None:
    candidate = os.path.join(WINDOWS_OPENSSH_DIR, binary_name)
    if os.path.exists(candidate):
        return candidate

    for fallback_name in fallback_names:
        resolved = shutil.which(fallback_name)
        if resolved:
            return resolved

    return None


SSH_EXE = resolve_windows_openssh_binary("ssh.exe", "ssh.exe", "ssh")
SSH_KEYGEN_EXE = resolve_windows_openssh_binary("ssh-keygen.exe", "ssh-keygen.exe", "ssh-keygen")
SSHD_EXE = resolve_windows_openssh_binary("sshd.exe")


def run_command(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=check, text=True, capture_output=True)


def wsl_bash(command: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return run_command(["wsl.exe", "-d", "Ubuntu", "--", "bash", "-lc", command], check=check)


def tmux_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        return int(sock.getsockname()[1])


def create_keypair(path: Path) -> None:
    if not SSH_KEYGEN_EXE:
        raise RuntimeError("ssh-keygen.exe not found.")
    run_command([SSH_KEYGEN_EXE, "-q", "-t", "ed25519", "-N", "", "-f", str(path)])


class InteractiveSsh:
    def __init__(self, port: int, key_path: Path, known_hosts_path: Path) -> None:
        if not SSH_EXE:
            raise RuntimeError("ssh.exe not found.")

        self.process = subprocess.Popen(
            [
                SSH_EXE,
                "-tt",
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=10",
                "-o",
                "StrictHostKeyChecking=no",
                "-o",
                f"UserKnownHostsFile={known_hosts_path}",
                "-i",
                str(key_path),
                "-p",
                str(port),
                "Origin@127.0.0.1",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        self._stdout_chunks: list[str] = []
        self._stderr_chunks: list[str] = []
        self._lock = threading.Lock()
        self._stdout_thread = threading.Thread(target=self._reader, args=(self.process.stdout, self._stdout_chunks), daemon=True)
        self._stderr_thread = threading.Thread(target=self._reader, args=(self.process.stderr, self._stderr_chunks), daemon=True)
        self._stdout_thread.start()
        self._stderr_thread.start()

    def _reader(self, stream, chunks: list[str]) -> None:
        try:
            while True:
                data = stream.read(1)
                if not data:
                    break
                with self._lock:
                    chunks.append(data.decode("utf-8", errors="ignore"))
        finally:
            try:
                stream.close()
            except OSError:
                pass

    def output(self) -> str:
        with self._lock:
            return "".join(self._stdout_chunks) + "".join(self._stderr_chunks)

    def wait_for(self, needle: str, timeout_seconds: float) -> str:
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            combined = self.output()
            if needle in combined:
                return combined
            if self.process.poll() is not None:
                time.sleep(0.2)
                raise RuntimeError(f"SSH process exited before '{needle}' appeared.\nOutput:\n{self.output()}")
            time.sleep(0.05)
        raise RuntimeError(f"Timed out waiting for '{needle}'.\nOutput tail:\n{self.output()[-4000:]}")

    def send(self, text: str) -> None:
        if not self.process.stdin:
            raise RuntimeError("SSH stdin is unavailable.")
        self.process.stdin.write(text.encode("utf-8"))
        self.process.stdin.flush()

    def close(self) -> str:
        if self.process.stdin:
            try:
                self.process.stdin.close()
            except OSError:
                pass
        self.process.wait(timeout=20)
        self._stdout_thread.join(timeout=2)
        self._stderr_thread.join(timeout=2)
        return self.output()


class TemporarySshd:
    def __init__(self) -> None:
        self.temp_dir = Path(tempfile.mkdtemp(prefix="ghws-mobile-sshd-"))
        self.port = find_free_port()
        self.user_key_path = self.temp_dir / "client_ed25519"
        self.host_key_path = self.temp_dir / "host_ed25519"
        self.authorized_keys_path = self.temp_dir / "authorized_keys"
        self.known_hosts_path = self.temp_dir / "known_hosts"
        self.config_path = self.temp_dir / "sshd_config"
        self.process: subprocess.Popen[bytes] | None = None

    def start(self) -> None:
        if not SSHD_EXE:
            raise RuntimeError("Windows sshd.exe not found.")
        create_keypair(self.user_key_path)
        create_keypair(self.host_key_path)

        public_key = self.user_key_path.with_suffix(".pub").read_text(encoding="utf-8").strip()
        self.authorized_keys_path.write_text(public_key + "\n", encoding="utf-8")

        config = "\n".join(
            [
                f"Port {self.port}",
                "ListenAddress 127.0.0.1",
                f"PidFile {str(self.temp_dir / 'sshd.pid').replace('\\', '/')}",
                f"AuthorizedKeysFile {str(self.authorized_keys_path).replace('\\', '/')}",
                f"HostKey {str(self.host_key_path).replace('\\', '/')}",
                "PubkeyAuthentication yes",
                "PasswordAuthentication no",
                "KbdInteractiveAuthentication no",
                "StrictModes no",
                "LogLevel VERBOSE",
                "Subsystem sftp sftp-server.exe",
                "",
            ]
        )
        self.config_path.write_text(config, encoding="utf-8")

        run_command([SSHD_EXE, "-t", "-f", str(self.config_path)])
        self.process = subprocess.Popen(
            [SSHD_EXE, "-D", "-e", "-f", str(self.config_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
        )
        self._wait_until_listening()

    def _wait_until_listening(self) -> None:
        deadline = time.time() + 15
        while time.time() < deadline:
            if self.process and self.process.poll() is not None:
                stderr = self.process.stderr.read().decode("utf-8", errors="ignore") if self.process.stderr else ""
                stdout = self.process.stdout.read().decode("utf-8", errors="ignore") if self.process.stdout else ""
                raise RuntimeError(f"Temporary sshd exited early.\nSTDOUT:\n{stdout}\nSTDERR:\n{stderr}")
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
                sock.settimeout(0.2)
                if sock.connect_ex(("127.0.0.1", self.port)) == 0:
                    return
            time.sleep(0.1)
        raise RuntimeError(f"Temporary sshd did not start listening on port {self.port}.")

    def stop(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        shutil.rmtree(self.temp_dir, ignore_errors=True)


def ensure_tmux_session(session_name: str, working_directory: str) -> None:
    wsl_bash(
        f"tmux kill-session -t {tmux_quote(session_name)} >/dev/null 2>&1 || true; "
        f"tmux new-session -d -s {tmux_quote(session_name)} -c {tmux_quote(working_directory)}"
    )


def kill_tmux_session(session_name: str) -> None:
    wsl_bash(f"tmux kill-session -t {tmux_quote(session_name)} >/dev/null 2>&1 || true", check=False)


def assert_resume_flow(sshd: TemporarySshd, cleanup_sessions: set[str]) -> None:
    resume_suffix = uuid.uuid4().hex[:10]
    session_name = f"shell-ssh-resume-check-{resume_suffix}"
    cleanup_sessions.add(session_name)
    ensure_tmux_session(session_name, "/mnt/d/ghws")

    ssh = InteractiveSsh(sshd.port, sshd.user_key_path, sshd.known_hosts_path)
    try:
        ssh.wait_for("AI session mobile menu", 15)
        ssh.send("2\n")
        ssh.wait_for(f"ssh-resume-check-{resume_suffix}", 15)
        ssh.send("1\n")
        ssh.wait_for("/mnt/d/ghws", 15)
        ssh.send("\x02d")
        ssh.wait_for("AI session mobile menu", 15)
        ssh.send("5\n")
        output = ssh.close()
    finally:
        if ssh.process.poll() is None:
            try:
                ssh.send("5\n")
            except Exception:
                pass
            ssh.close()

    if f"ssh-resume-check-{resume_suffix}" not in output:
        raise RuntimeError("Resume flow did not render the expected session label.")


def main() -> None:
    cleanup_sessions: set[str] = set()
    sshd = TemporarySshd()
    try:
        sshd.start()
        assert_resume_flow(sshd, cleanup_sessions)
        print("PASS")
    finally:
        for session_name in cleanup_sessions:
            kill_tmux_session(session_name)
        sshd.stop()


if __name__ == "__main__":
    main()
