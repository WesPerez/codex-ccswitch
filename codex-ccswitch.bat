@echo off
setlocal EnableExtensions

set "SELF=%~f0"
set "PY_EXE=python"
where python >nul 2>nul
if errorlevel 1 (
    echo [error] Python was not found on PATH.
    echo Install Python 3 or edit this BAT to point PY_EXE at python.exe.
    exit /b 1
)

for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "[IO.Path]::Combine([IO.Path]::GetTempPath(), 'codex-ccswitch-' + [guid]::NewGuid().ToString('N') + '.py')"`) do set "PAYLOAD=%%I"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$raw = Get-Content -LiteralPath $env:SELF -Raw; $marker = '### ' + 'PYTHON_PAYLOAD ###'; $idx = $raw.IndexOf($marker); if ($idx -lt 0) { Write-Error 'Python payload not found.'; exit 2 }; $code = $raw.Substring($idx + $marker.Length).TrimStart(); [IO.File]::WriteAllText($env:PAYLOAD, $code, [Text.UTF8Encoding]::new($false))"
if errorlevel 1 exit /b %ERRORLEVEL%

"%PY_EXE%" "%PAYLOAD%" %*
set "RC=%ERRORLEVEL%"
del "%PAYLOAD%" >nul 2>nul
exit /b %RC%

### PYTHON_PAYLOAD ###
# -*- coding: utf-8 -*-
from __future__ import annotations

import argparse
import csv
import datetime as _dt
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

HOME = Path(os.environ["USERPROFILE"])
CODEX_HOME = HOME / ".codex"
TOOLS_HOME = CODEX_HOME / "tools"
LIVE_CONFIG = CODEX_HOME / "config.toml"
AUTH_JSON = CODEX_HOME / "auth.json"
GLOBAL_STATE = CODEX_HOME / ".codex-global-state.json"
CHROME_NATIVE_HOSTS_V2 = CODEX_HOME / "chrome-native-hosts-v2.json"
CHROME_PLUGIN_CACHE = CODEX_HOME / "plugins" / "cache" / "openai-bundled" / "chrome"
NATIVE_HOST_MANIFEST = HOME / "AppData" / "Local" / "OpenAI" / "extension" / "com.openai.codexextension.json"
CCSWITCH_HOME = HOME / ".cc-switch"
CCSWITCH_DB = CCSWITCH_HOME / "cc-switch.db"
CCSWITCH_SETTINGS = CCSWITCH_HOME / "settings.json"
BACKUP_ROOT = CODEX_HOME / ".tmp"

SETTING_COMMON = "common_config_codex"
SETTING_CANONICAL = "codex_common_config_canonical_v1"
SETTING_OFFICIAL_AUTH = "codex_official_auth_backup_v1"
CCSWITCH_PROCESS_NAME = "cc-switch.exe"
CCSWITCH_APP_DIR = "CC Switch"

SKIP_TOP_LEVEL_KEYS = {"model", "model_provider", "model_reasoning_effort", "notify"}
REMOVE_TOP_LEVEL_KEYS: set[str] = set()
MODEL_PROVIDER_RETRY_KEYS = ("request_max_retries", "stream_max_retries")
SKIP_TABLE_NAMES = {
    "tui.model_availability_nux",
    "mcp_servers.node_repl",
    "mcp_servers.node_repl.env",
}
SKIP_TABLE_PREFIXES = ("model_providers", "projects")

EMBEDDED_PUBLIC_CONFIG = r'''model_reasoning_effort = "ultra"
approval_policy = "never"
sandbox_mode = "danger-full-access"
model_catalog_json = 'C:\Users\Wes\.codex\models-wooai-supported-v0.144.4.json'
disable_response_storage = true

[marketplaces]

[marketplaces.openai-bundled]
last_updated = "2026-06-20T20:17:38Z"
source_type = "local"
source = 'C:\Users\Wes\.codex\plugins\local-marketplaces\openai-bundled'

[marketplaces.openai-primary-runtime]
last_updated = "2026-06-17T02:20:08Z"
source_type = "local"
source = '\\?\C:\Users\Wes\.codex\plugins\cache\openai-primary-runtime'

[marketplaces.ponytail]
source_type = "git"
source = "https://github.com/DietrichGebert/ponytail.git"

[plugins]

[plugins."documents@openai-primary-runtime"]
enabled = true

[plugins."spreadsheets@openai-primary-runtime"]
enabled = true

[plugins."presentations@openai-primary-runtime"]
enabled = true

[plugins."github@openai-curated"]
enabled = true

[plugins."browser@openai-bundled"]
enabled = true

[plugins."computer-use@openai-bundled"]
enabled = true

[plugins."pdf@openai-primary-runtime"]
enabled = true

[plugins."chrome@openai-bundled"]
enabled = true

[plugins."ponytail@ponytail"]
enabled = true

[desktop]
conversationDetailMode = "STEPS_COMMANDS"
ambient-suggestions-enabled = false
followUpQueueMode = "steer"

[features]
apps = false
memories = true

[windows]
sandbox = "elevated"

[projects.'e:\project\common']
trust_level = "trusted"

[memories]
generate_memories = true
use_memories = true

[mcp_servers.openaiDeveloperDocs]
url = "https://developers.openai.com/mcp"
enabled = false
'''


def info(message: str) -> None:
    print(f"[info] {message}")


def warn(message: str) -> None:
    print(f"[warn] {message}")


def error(message: str) -> None:
    print(f"[error] {message}")


def fatal(message: str, code: int = 1) -> None:
    error(message)
    sys.exit(code)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def split_toml_parts(text: str, delimiter: str) -> list[str]:
    parts: list[str] = []
    current: list[str] = []
    quote = ""
    escape = False
    for char in text:
        if escape:
            current.append(char)
            escape = False
            continue
        if quote == '"' and char == "\\":
            current.append(char)
            escape = True
            continue
        if quote:
            current.append(char)
            if char == quote:
                quote = ""
            continue
        if char in ("'", '"'):
            quote = char
            current.append(char)
            continue
        if char == delimiter:
            parts.append("".join(current).strip())
            current = []
            continue
        current.append(char)
    parts.append("".join(current).strip())
    return parts


def strip_toml_comment(line: str) -> str:
    quote = ""
    escape = False
    out: list[str] = []
    for char in line:
        if escape:
            out.append(char)
            escape = False
            continue
        if quote == '"' and char == "\\":
            out.append(char)
            escape = True
            continue
        if quote:
            out.append(char)
            if char == quote:
                quote = ""
            continue
        if char in ("'", '"'):
            quote = char
            out.append(char)
            continue
        if char == "#":
            break
        out.append(char)
    return "".join(out).strip()


def parse_toml_scalar(raw: str) -> Any:
    text = raw.strip()
    if len(text) >= 2 and text[0] == text[-1] == "'":
        return text[1:-1]
    if len(text) >= 2 and text[0] == text[-1] == '"':
        return json.loads(text)
    if text.startswith("[") and text.endswith("]"):
        body = text[1:-1].strip()
        return [] if not body else [parse_toml_scalar(part) for part in split_toml_parts(body, ",")]
    if text.lower() == "true":
        return True
    if text.lower() == "false":
        return False
    if re.fullmatch(r"[+-]?\d+", text):
        return int(text)
    return text


def split_toml_dotted_name(name: str) -> list[str]:
    parts: list[str] = []
    for part in split_toml_parts(name, "."):
        if len(part) >= 2 and part[0] == part[-1] and part[0] in ("'", '"'):
            parts.append(parse_toml_scalar(part))
        else:
            parts.append(part)
    return parts


def load_minimal_toml(text: str) -> dict[str, Any]:
    # ponytail: fallback validates the TOML subset this script writes; install tomli for full TOML on Python <3.11.
    root: dict[str, Any] = {}
    current = root
    for line_no, raw_line in enumerate(text.splitlines(), start=1):
        line = strip_toml_comment(raw_line)
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            current = root
            for part in split_toml_dotted_name(line[1:-1].strip()):
                child = current.setdefault(part, {})
                if not isinstance(child, dict):
                    raise ValueError(f"line {line_no}: table conflicts with value")
                current = child
            continue
        match = re.match(r"^([A-Za-z0-9_-]+)\s*=\s*(.+)$", line)
        if not match:
            raise ValueError(f"line {line_no}: unsupported TOML syntax")
        current[match.group(1)] = parse_toml_scalar(match.group(2))
    return root


def load_toml(text: str, label: str) -> Any:
    parser = None
    try:
        import tomllib
        parser = tomllib
    except ImportError:
        try:
            import tomli  # type: ignore
            parser = tomli
        except ImportError:
            try:
                import toml  # type: ignore
                parser = toml
            except ImportError:
                parser = None
    try:
        return parser.loads(text) if parser else load_minimal_toml(text)
    except Exception as exc:
        fatal(f"{label} is not valid TOML: {exc}")


def parse_toml(text: str, label: str) -> None:
    load_toml(text, label)


def toml_semantically_equal(left: str, right: str) -> bool:
    try:
        return load_toml(left or "", "left TOML") == load_toml(right or "", "right TOML")
    except SystemExit:
        return left == right


def normalize_text(lines: list[str]) -> str:
    text = "\n".join(lines)
    text = re.sub(r"\n{3,}", "\n\n", text).strip() + "\n"
    return text


def strip_blank_edges(lines: list[str]) -> list[str]:
    start = 0
    end = len(lines)
    while start < end and lines[start].strip() == "":
        start += 1
    while end > start and lines[end - 1].strip() == "":
        end -= 1
    return lines[start:end]


def parse_into_blocks(text: str):
    top_keys: list[tuple[str, list[str]]] = []
    pending: list[str] = []
    tables: list[tuple[str, list[str]]] = []
    in_table = False
    table_name = ""
    table_lines: list[str] = []

    for line in text.splitlines():
        stripped = line.strip()
        table_match = re.match(r"^\[(.+?)\]\s*$", stripped)
        if table_match:
            if in_table:
                tables.append((table_name, table_lines))
            in_table = True
            table_name = table_match.group(1).strip()
            table_lines = list(pending) + [line]
            pending = []
            continue

        if in_table:
            table_lines.append(line)
            continue

        kv_match = re.match(r"^([A-Za-z0-9_-]+)\s*=", stripped)
        if kv_match:
            top_keys.append((kv_match.group(1), pending + [line]))
            pending = []
        else:
            pending.append(line)

    if in_table:
        tables.append((table_name, table_lines))
    return top_keys, tables


def parse_table_keys(table_lines: list[str]) -> dict[str, list[str]]:
    result: dict[str, list[str]] = {}
    pending: list[str] = []
    for line in table_lines[1:]:
        stripped = line.strip()
        kv_match = re.match(r"^([A-Za-z0-9_-]+)\s*=", stripped)
        if kv_match:
            key = kv_match.group(1)
            result.setdefault(key, []).extend(pending + [line])
            pending = []
        else:
            pending.append(line)
    return result


def is_skipped_table(name: str) -> bool:
    if name in SKIP_TABLE_NAMES:
        return True
    for prefix in SKIP_TABLE_PREFIXES:
        if name == prefix or name == prefix.rstrip("."):
            return True
        if name.startswith(prefix + ".") or (prefix.endswith(".") and name.startswith(prefix)):
            return True
    return False


def is_model_provider_config_table(name: str) -> bool:
    return name.startswith("model_providers.")


def extract_model_provider_retry_settings(text: str) -> tuple[dict[str, list[str]], str]:
    _top, tables = parse_into_blocks(text)
    provider_tables = [
        (name, lines)
        for name, lines in tables
        if is_model_provider_config_table(name)
    ]
    provider_tables.sort(key=lambda item: 0 if item[0] == "model_providers.custom" else 1)

    for name, lines in provider_tables:
        table_keys = parse_table_keys(lines)
        retry_settings = {
            key: strip_blank_edges(table_keys[key])
            for key in MODEL_PROVIDER_RETRY_KEYS
            if key in table_keys
        }
        if retry_settings:
            return retry_settings, f"[{name}]"

    return {}, ""


def extract_public_config(live_text: str) -> str:
    live_top, live_tables = parse_into_blocks(live_text)
    out: list[str] = []

    for key, lines in live_top:
        if key in SKIP_TOP_LEVEL_KEYS or key in REMOVE_TOP_LEVEL_KEYS:
            continue
        out.extend(strip_blank_edges(lines))

    if out and live_tables:
        out.append("")

    for name, lines in live_tables:
        if is_skipped_table(name):
            continue
        out.extend(strip_blank_edges(lines))
        out.append("")

    return normalize_text(out)


def merge_model_provider_retry_settings(
    target_text: str,
    retry_settings: dict[str, list[str]],
) -> tuple[str, list[str]]:
    if not retry_settings:
        return target_text, []

    target_top, target_tables = parse_into_blocks(target_text)
    changes: list[str] = []
    new_tables: list[tuple[str, list[str]]] = []

    for name, table_lines in target_tables:
        if not is_model_provider_config_table(name):
            new_tables.append((name, table_lines))
            continue

        table_keys = parse_table_keys(table_lines)
        merged: list[str] = []
        replaced: set[str] = set()

        for line in table_lines:
            kv_match = re.match(r"^([A-Za-z0-9_-]+)\s*=", line.strip())
            if kv_match and kv_match.group(1) in retry_settings:
                key = kv_match.group(1)
                if key not in replaced:
                    source_lines = retry_settings[key]
                    if strip_blank_edges(table_keys.get(key, [])) != source_lines:
                        changes.append(f"~ [{name}].{key}")
                    merged.extend(source_lines)
                    replaced.add(key)
                continue

            merged.append(line)

        for key in MODEL_PROVIDER_RETRY_KEYS:
            source_lines = retry_settings.get(key)
            if source_lines is None or key in replaced:
                continue
            merged.extend(source_lines)
            changes.append(f"+ [{name}].{key}")

        new_tables.append((name, merged))

    if not changes:
        return target_text, []

    out: list[str] = []
    for _key, lines in target_top:
        out.extend(strip_blank_edges(lines))
    if target_top and new_tables:
        out.append("")
    for idx, (_name, lines) in enumerate(new_tables):
        out.extend(strip_blank_edges(lines))
        if idx < len(new_tables) - 1:
            out.append("")
    return normalize_text(out), changes


def top_level_toml_value(text: str, key: str) -> str:
    table_match = re.search(r"(?m)^\s*\[", text)
    top_level = text[: table_match.start()] if table_match else text
    return toml_value_from_line(top_level, key)


def set_top_level_toml_string(text: str, key: str, value: str) -> str:
    table_match = re.search(r"(?m)^\s*\[", text)
    split_at = table_match.start() if table_match else len(text)
    top_level = text[:split_at]
    tables = text[split_at:]
    replacement = f"{key} = {json.dumps(value)}"
    pattern = re.compile(rf"(?m)^\s*{re.escape(key)}\s*=.*$")
    if pattern.search(top_level):
        top_level = pattern.sub(replacement, top_level, count=1)
    else:
        model_line = re.search(r"(?m)^\s*model\s*=.*$", top_level)
        if not model_line:
            return text
        insert_at = model_line.end()
        top_level = top_level[:insert_at] + "\n" + replacement + top_level[insert_at:]
    return top_level + tables


def normalize_model_reasoning_effort(text: str) -> tuple[str, list[str]]:
    model = top_level_toml_value(text, "model")
    current = top_level_toml_value(text, "model_reasoning_effort")
    if model in {"gpt-5.6-sol", "gpt-5.6-terra"}:
        desired = "ultra"
    elif model == "grok-4.5" and current not in {"low", "medium", "high"}:
        desired = "high"
    else:
        return text, []
    if current == desired:
        return text, []
    updated = set_top_level_toml_string(text, "model_reasoning_effort", desired)
    parse_toml(updated, f"model-specific config for {model}")
    return updated, [f"~ model_reasoning_effort ({model}: {desired})"]


def merge_public(target_text: str, source_text: str) -> tuple[str, list[str]]:
    target_top, target_tables = parse_into_blocks(target_text)
    source_top, source_tables = parse_into_blocks(source_text)
    changes = [] if toml_semantically_equal(extract_public_config(target_text), source_text) else ["~ public mirror"]

    new_top = [(key, lines) for key, lines in target_top if key in SKIP_TOP_LEVEL_KEYS]
    new_top.extend((key, lines) for key, lines in source_top if key not in SKIP_TOP_LEVEL_KEYS)

    new_tables = [(name, lines) for name, lines in source_tables if not is_skipped_table(name)]
    new_tables.extend((name, lines) for name, lines in target_tables if is_skipped_table(name))

    out: list[str] = []
    for _key, lines in new_top:
        out.extend(strip_blank_edges(lines))
    if new_top and new_tables:
        out.append("")
    for idx, (_name, lines) in enumerate(new_tables):
        out.extend(strip_blank_edges(lines))
        if idx < len(new_tables) - 1:
            out.append("")
    return normalize_text(out), changes


def is_local_shared_table(name: str) -> bool:
    return name == "projects" or name.startswith("projects.")


def render_tables(tables: list[tuple[str, list[str]]]) -> str:
    out: list[str] = []
    for idx, (_name, lines) in enumerate(tables):
        out.extend(strip_blank_edges(lines))
        if idx < len(tables) - 1:
            out.append("")
    return normalize_text(out) if out else ""


def merge_local_shared_tables(target_text: str, source_text: str) -> tuple[str, list[str]]:
    source_top, source_tables = parse_into_blocks(source_text)
    source_local = [(name, lines) for name, lines in source_tables if is_local_shared_table(name)]
    if not source_local:
        return target_text, []

    target_top, target_tables = parse_into_blocks(target_text)
    target_local = [(name, lines) for name, lines in target_tables if is_local_shared_table(name)]
    if toml_semantically_equal(render_tables(target_local), render_tables(source_local)):
        return target_text, []

    new_tables = [(name, lines) for name, lines in target_tables if not is_local_shared_table(name)]
    new_tables.extend(source_local)
    out: list[str] = []
    for _key, lines in target_top:
        out.extend(strip_blank_edges(lines))
    if target_top and new_tables:
        out.append("")
    for idx, (_name, lines) in enumerate(new_tables):
        out.extend(strip_blank_edges(lines))
        if idx < len(new_tables) - 1:
            out.append("")
    return normalize_text(out), ["~ local shared tables (projects)"]


def is_windows_admin() -> bool:
    if os.name != "nt":
        return False
    try:
        import ctypes

        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def normalize_path_text(value: Any) -> str:
    text = str(value or "").strip().strip('"')
    if text.startswith("\\\\?\\"):
        text = text[4:]
    return text


def unique_paths(paths: list[Path]) -> list[Path]:
    result: list[Path] = []
    seen: set[str] = set()
    for path in paths:
        try:
            candidate = path.resolve()
        except Exception:
            candidate = path
        key = str(candidate).lower()
        if key in seen or not candidate.exists():
            continue
        seen.add(key)
        result.append(candidate)
    return result


def query_process_image_path(pid: int) -> Path | None:
    if os.name != "nt":
        return None
    try:
        import ctypes
        from ctypes import wintypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        process_query_limited_information = 0x1000
        handle = kernel32.OpenProcess(process_query_limited_information, False, int(pid))
        if not handle:
            return None
        try:
            size = wintypes.DWORD(32768)
            buffer = ctypes.create_unicode_buffer(size.value)
            ok = kernel32.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size))
            if not ok:
                return None
            text = normalize_path_text(buffer.value)
            return Path(text) if text else None
        finally:
            kernel32.CloseHandle(handle)
    except Exception:
        return None


def can_terminate_process(pid: int) -> tuple[bool, int]:
    if os.name != "nt":
        return False, 0
    try:
        import ctypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        process_terminate = 0x0001
        handle = kernel32.OpenProcess(process_terminate, False, int(pid))
        if not handle:
            return False, ctypes.get_last_error()
        kernel32.CloseHandle(handle)
        return True, 0
    except Exception:
        return False, 0


def terminate_process(pid: int) -> tuple[bool, str]:
    if os.name != "nt":
        return False, "TerminateProcess fallback is only available on Windows."
    try:
        import ctypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        process_terminate = 0x0001
        handle = kernel32.OpenProcess(process_terminate, False, int(pid))
        if not handle:
            return False, f"OpenProcess(PROCESS_TERMINATE) failed with Win32 error {ctypes.get_last_error()}"
        try:
            ok = kernel32.TerminateProcess(handle, 1)
            if not ok:
                return False, f"TerminateProcess failed with Win32 error {ctypes.get_last_error()}"
            return True, "TerminateProcess succeeded"
        finally:
            kernel32.CloseHandle(handle)
    except Exception as exc:
        return False, f"TerminateProcess fallback failed: {exc}"


def tasklist_cc_switch_processes() -> list[dict[str, Any]]:
    try:
        result = subprocess.run(
            ["tasklist", "/FI", f"IMAGENAME eq {CCSWITCH_PROCESS_NAME}", "/FO", "CSV", "/NH"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except Exception:
        return []

    rows: list[dict[str, Any]] = []
    for record in csv.reader((result.stdout or "").splitlines()):
        if len(record) < 2:
            continue
        if record[0].lower() != CCSWITCH_PROCESS_NAME:
            continue
        try:
            pid = int(record[1])
        except ValueError:
            continue
        rows.append({"ProcessId": pid, "Name": CCSWITCH_PROCESS_NAME})
    return rows


def cc_switch_processes() -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    try:
        result = subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                (
                    "Get-CimInstance Win32_Process -Filter \"name = 'cc-switch.exe'\" | "
                    "Select-Object ProcessId,Name,ExecutablePath,CommandLine | ConvertTo-Json -Compress"
                ),
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        raw = (result.stdout or "").strip()
        if raw:
            value = json.loads(raw)
            rows = value if isinstance(value, list) else [value]
    except Exception:
        rows = []

    if not rows:
        rows = tasklist_cc_switch_processes()

    normalized: list[dict[str, Any]] = []
    seen_pids: set[int] = set()
    for row in rows:
        if not isinstance(row, dict):
            continue
        try:
            pid = int(row.get("ProcessId"))
        except Exception:
            continue
        if pid in seen_pids:
            continue
        seen_pids.add(pid)
        row["ProcessId"] = pid
        image_path = query_process_image_path(pid)
        if image_path:
            row["ImagePath"] = str(image_path)
            if not normalize_path_text(row.get("ExecutablePath")):
                row["ExecutablePath"] = str(image_path)
        can_terminate, terminate_error = can_terminate_process(pid)
        row["CanTerminate"] = can_terminate
        row["TerminateError"] = terminate_error
        normalized.append(row)
    return normalized


def cc_switch_pids() -> list[int]:
    pids: list[int] = []
    for row in cc_switch_processes():
        pid = row.get("ProcessId")
        if isinstance(pid, int):
            pids.append(pid)
    return pids


def known_cc_switch_exe_paths() -> list[Path]:
    paths: list[Path] = []
    for value in (
        os.environ.get("LOCALAPPDATA"),
        os.environ.get("APPDATA"),
        str(HOME / "AppData" / "Local"),
        str(Path.home() / "AppData" / "Local"),
    ):
        if not value:
            continue
        base = Path(normalize_path_text(value))
        paths.append(base / "Programs" / CCSWITCH_APP_DIR / CCSWITCH_PROCESS_NAME)

    found = shutil.which(CCSWITCH_PROCESS_NAME)
    if found:
        paths.append(Path(found))
    return unique_paths(paths)


def cc_switch_restart_paths(processes: list[dict[str, Any]] | None = None) -> list[Path]:
    paths: list[Path] = []
    for row in processes or []:
        for key in ("ExecutablePath", "ImagePath"):
            text = normalize_path_text(row.get(key))
            if text:
                paths.append(Path(text))
    paths.extend(known_cc_switch_exe_paths())
    return unique_paths(paths)


def format_process(row: dict[str, Any]) -> str:
    pid = row.get("ProcessId")
    path = normalize_path_text(row.get("ExecutablePath")) or normalize_path_text(row.get("ImagePath")) or "(path unavailable)"
    can_terminate = "yes" if row.get("CanTerminate") else f"no/error={row.get('TerminateError')}"
    return f"pid={pid}, path={path}, canTerminate={can_terminate}"


def wait_until_cc_switch_exits(timeout_seconds: float) -> bool:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if not cc_switch_pids():
            return True
        time.sleep(0.5)
    return not cc_switch_pids()


def run_taskkill(pid: int, force: bool = False) -> bool:
    cmd = ["taskkill", "/PID", str(pid), "/T"]
    if force:
        cmd.append("/F")
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    except Exception as exc:
        warn(f"{' '.join(cmd)} failed to start: {exc}")
        return False

    output = " ".join(
        part.strip()
        for part in (result.stdout, result.stderr)
        if part and part.strip()
    )
    label = "forced taskkill" if force else "graceful taskkill"
    if result.returncode == 0:
        info(f"{label} pid={pid} succeeded: {output or '(no output)'}")
        return True
    warn(f"{label} pid={pid} failed with exit {result.returncode}: {output or '(no output)'}")
    return False


def stop_cc_switch_for_write(allow_running: bool = False) -> list[Path]:
    processes = cc_switch_processes()
    if not processes:
        return []

    restart_paths = cc_switch_restart_paths(processes)

    pids = [int(row["ProcessId"]) for row in processes if isinstance(row.get("ProcessId"), int)]
    if not pids:
        return restart_paths

    info("Stopping cc-switch.exe before writing its database/config templates.")
    for row in processes:
        info(f"CC-Switch process: {format_process(row)}")
    for pid in pids:
        run_taskkill(pid, force=False)

    if wait_until_cc_switch_exits(10):
        return restart_paths

    warn("cc-switch.exe did not exit cleanly; forcing shutdown before write.")
    for pid in cc_switch_pids():
        run_taskkill(pid, force=True)

    if wait_until_cc_switch_exits(5):
        return restart_paths

    warn("taskkill did not stop cc-switch.exe; trying Windows TerminateProcess fallback.")
    for pid in cc_switch_pids():
        ok, detail = terminate_process(pid)
        if ok:
            info(f"TerminateProcess pid={pid}: {detail}")
        else:
            warn(f"TerminateProcess pid={pid}: {detail}")

    if wait_until_cc_switch_exits(5):
        return restart_paths

    remaining = ", ".join(str(pid) for pid in cc_switch_pids())
    message = (
        "cc-switch.exe is still running"
        + (f" (pids={remaining})" if remaining else "")
        + "; refusing to write while it may overwrite the same state."
    )
    if allow_running:
        warn(
            message
            + " Continuing with best-effort auth repair because the official auth backup is available."
        )
        return []
    fatal(message)
    return restart_paths


def restart_cc_switch(paths: list[Path]) -> None:
    if cc_switch_pids():
        info("CC-Switch is already running; restart is not needed.")
        return
    if not paths:
        paths = known_cc_switch_exe_paths()
    if not paths:
        warn("Could not restart CC-Switch automatically; no executable path was found.")
        return
    path = paths[0]
    if not path.exists():
        warn(f"Could not restart CC-Switch; executable no longer exists: {path}")
        return
    try:
        creationflags = 0
        for flag_name in ("DETACHED_PROCESS", "CREATE_NEW_PROCESS_GROUP", "CREATE_NO_WINDOW"):
            creationflags |= int(getattr(subprocess, flag_name, 0))
        subprocess.Popen(
            [str(path)],
            cwd=str(path.parent),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=creationflags,
        )
        time.sleep(2)
        info(f"Restarted CC-Switch: {path}")
    except Exception as exc:
        warn(f"Could not restart CC-Switch automatically: {exc}")


def connect_db() -> sqlite3.Connection:
    if not CCSWITCH_DB.exists():
        fatal(f"cc-switch database not found: {CCSWITCH_DB}")
    conn = sqlite3.connect(CCSWITCH_DB, timeout=15)
    conn.row_factory = sqlite3.Row
    return conn


def get_setting(conn: sqlite3.Connection, key: str) -> str:
    row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    return "" if row is None or row["value"] is None else str(row["value"])


def set_setting(conn: sqlite3.Connection, key: str, value: str) -> None:
    exists = conn.execute("SELECT 1 FROM settings WHERE key = ?", (key,)).fetchone()
    if exists:
        conn.execute("UPDATE settings SET value = ? WHERE key = ?", (value, key))
    else:
        conn.execute("INSERT INTO settings(key, value) VALUES(?, ?)", (key, value))


def read_json_object(text: str | None, label: str) -> dict[str, Any]:
    if not text:
        return {}
    try:
        value = json.loads(text)
    except json.JSONDecodeError as exc:
        warn(f"Could not parse JSON for {label}: {exc}")
        return {}
    if not isinstance(value, dict):
        warn(f"Expected JSON object for {label}; got {type(value).__name__}.")
        return {}
    return value


def embedded_public_config() -> str:
    return EMBEDDED_PUBLIC_CONFIG.replace(r"C:\Users\Wes", str(HOME))


def backup_before_write(label: str) -> Path:
    stamp = _dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    target = BACKUP_ROOT / f"codex-ccswitch-{label}-{stamp}"
    target.mkdir(parents=True, exist_ok=True)

    if CCSWITCH_DB.exists():
        src = sqlite3.connect(CCSWITCH_DB, timeout=15)
        dst = sqlite3.connect(target / "cc-switch.db.bak")
        try:
            src.backup(dst)
        finally:
            dst.close()
            src.close()

    for src_path, name in [
        (CCSWITCH_SETTINGS, "cc-switch.settings.json.bak"),
        (LIVE_CONFIG, "config.toml.live"),
        (AUTH_JSON, "auth.json.bak"),
        (GLOBAL_STATE, ".codex-global-state.json.bak"),
    ]:
        if src_path.exists():
            shutil.copy2(src_path, target / name)
    return target


def toml_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def looks_like_windows_path(value: str) -> bool:
    return bool(re.match(r"^[A-Za-z]:\\", value))


def node_repl_bundle_regex() -> str:
    return (
        r"(?ms)^\[mcp_servers\.node_repl\]\s*.*?"
        r"(?=^\[(?!mcp_servers\.node_repl\.env\])|\Z)"
        r"(?:^\[mcp_servers\.node_repl\.env\]\s*.*?(?=^\[|\Z))?"
    )


def extract_node_repl_bundle(text: str) -> str:
    match = re.search(node_repl_bundle_regex(), text)
    return match.group(0).strip() + "\n" if match else ""


def replace_node_repl_bundle(text: str, bundle: str) -> tuple[str, bool]:
    if not bundle:
        return text, False
    top, tables = parse_into_blocks(text)
    removed = False
    out: list[str] = []
    for _key, lines in top:
        out.extend(strip_blank_edges(lines))
    kept_tables: list[tuple[str, list[str]]] = []
    for name, lines in tables:
        if name in {"mcp_servers.node_repl", "mcp_servers.node_repl.env"}:
            removed = True
            continue
        kept_tables.append((name, lines))
    if out and (kept_tables or bundle.strip()):
        out.append("")
    for _name, lines in kept_tables:
        out.extend(strip_blank_edges(lines))
        out.append("")
    out.extend(bundle.strip().splitlines())
    new_text = normalize_text(out)
    return new_text, removed or new_text != text


def runtime_paths_complete(paths: dict[str, str]) -> bool:
    return all(paths.values()) and all(Path(value).exists() for value in paths.values())


def runtime_paths_from_registry_entry(entry: dict[str, Any]) -> dict[str, str]:
    paths = entry.get("paths") if isinstance(entry.get("paths"), dict) else {}
    modules = paths.get("nodeModuleDirs") if isinstance(paths.get("nodeModuleDirs"), list) else []
    return {
        "codexCliPath": normalize_path_text(paths.get("codexCliPath")),
        "nodePath": normalize_path_text(paths.get("nodePath")),
        "nodeReplPath": normalize_path_text(paths.get("nodeReplPath")),
        "nodeModuleDirs": normalize_path_text(modules[0] if modules else ""),
    }


def newest_codex_cli_path(preferred: str = "") -> str:
    candidates: list[Path] = []
    if preferred:
        candidates.append(Path(preferred))
    plugin_cli = CODEX_HOME / "plugins" / ".plugin-appserver" / "codex.exe"
    candidates.append(plugin_cli)
    bin_root = HOME / "AppData" / "Local" / "OpenAI" / "Codex" / "bin"
    if bin_root.exists():
        candidates.extend(sorted(bin_root.glob("*/codex.exe"), key=lambda path: path.stat().st_mtime, reverse=True))
    paths = unique_paths(candidates)
    return str(paths[0]) if paths else ""


def toml_value_from_line(text: str, key: str) -> str:
    match = re.search(rf"(?m)^\s*{re.escape(key)}\s*=\s*(.+?)\s*$", text)
    if not match:
        return ""
    value = match.group(1).strip()
    quote = value[:1]
    if quote in {"'", '"'}:
        end = value.find(quote, 1)
        if end >= 0:
            return normalize_path_text(value[1:end])
    return normalize_path_text(value.split("#", 1)[0])


def runtime_paths_from_live_config() -> dict[str, str]:
    if not LIVE_CONFIG.exists():
        return {}
    bundle = extract_node_repl_bundle(read_text(LIVE_CONFIG))
    if not bundle.strip():
        return {}
    return {
        "codexCliPath": newest_codex_cli_path(toml_value_from_line(bundle, "CODEX_CLI_PATH")),
        "nodePath": toml_value_from_line(bundle, "NODE_REPL_NODE_PATH"),
        "nodeReplPath": toml_value_from_line(bundle, "command"),
        "nodeModuleDirs": toml_value_from_line(bundle, "NODE_REPL_NODE_MODULE_DIRS"),
    }


def runtime_paths_from_disk() -> dict[str, str]:
    codex_cli_path = newest_codex_cli_path()
    runtime_root = HOME / "AppData" / "Local" / "OpenAI" / "Codex" / "runtimes" / "cua_node"
    if not runtime_root.exists():
        return {}
    bins = sorted((path / "bin" for path in runtime_root.iterdir() if path.is_dir()), key=lambda path: path.parent.stat().st_mtime, reverse=True)
    for bin_dir in bins:
        result = {
            "codexCliPath": codex_cli_path,
            "nodePath": str(bin_dir / "node.exe"),
            "nodeReplPath": str(bin_dir / "node_repl.exe"),
            "nodeModuleDirs": str(bin_dir / "node_modules"),
        }
        if runtime_paths_complete(result):
            return result
    return {}


def load_runtime_paths() -> dict[str, str]:
    if CHROME_NATIVE_HOSTS_V2.exists():
        data = json.loads(read_text(CHROME_NATIVE_HOSTS_V2))
        entries = data.get("entries") if isinstance(data, dict) else []
        if isinstance(entries, list):
            candidates = sorted(
                (entry for entry in entries if isinstance(entry, dict)),
                key=lambda entry: str(entry.get("updatedAt") or ""),
                reverse=True,
            )
            for entry in candidates:
                result = runtime_paths_from_registry_entry(entry)
                if runtime_paths_complete(result):
                    return result
        else:
            warn(f"Runtime registry has no entries: {CHROME_NATIVE_HOSTS_V2}")
    else:
        warn(f"Runtime registry not found: {CHROME_NATIVE_HOSTS_V2}")

    for result in (runtime_paths_from_live_config(), runtime_paths_from_disk()):
        if runtime_paths_complete(result):
            return result
    fatal("No complete existing node_repl runtime paths found in registry, live config, or Codex runtime directory")


def build_node_repl_bundle(old_bundle: str, runtime: dict[str, str]) -> str:
    old = load_toml(old_bundle, "existing node_repl block") if old_bundle.strip() else {}
    server = ((old.get("mcp_servers") or {}).get("node_repl") or {}) if isinstance(old, dict) else {}
    env = dict(server.get("env") or {}) if isinstance(server, dict) else {}
    for key in list(env):
        if key.startswith("SKY_CUA_"):
            env.pop(key, None)
    codex_cli_path = runtime["codexCliPath"]
    env.update(
        {
            "CODEX_CLI_PATH": codex_cli_path,
            "NODE_REPL_NODE_MODULE_DIRS": runtime["nodeModuleDirs"],
            "NODE_REPL_NODE_PATH": runtime["nodePath"],
        }
    )
    env.setdefault("BROWSER_USE_AVAILABLE_BACKENDS", "chrome,iab")
    env.setdefault("BROWSER_USE_CODEX_APP_BUILD_FLAVOR", "prod")
    env.setdefault("CODEX_HOME", str(CODEX_HOME))
    env.setdefault("NODE_REPL_INSTRUCTIONS_USE_CASE_BROWSER", "Control the in-app browser in conjunction with the Browser Plugin.")
    env.setdefault(
        "NODE_REPL_INSTRUCTIONS_USE_CASE_CHROME",
        "Control the Chrome browser in conjunction with the Chrome Plugin. Prefer this method of controlling Chrome over alternatives (such as Computer Use) unless the user explicitly mentions an alternative.",
    )
    env.setdefault("NODE_REPL_NATIVE_PIPE_CONNECT_TIMEOUT_MS", "1000")
    env.setdefault("NODE_REPL_TRUSTED_CODE_PATHS", str(CODEX_HOME))

    lines = [
        "[mcp_servers.node_repl]",
        'type = "stdio"',
        f"command = {toml_quote(runtime['nodeReplPath'])}",
        "startup_timeout_sec = 120",
        "",
        "[mcp_servers.node_repl.env]",
    ]
    for key in sorted(env):
        value = str(env[key])
        if key.endswith("_PATH") or key.endswith("_PATHS") or key.endswith("_DIRS") or key in {"CODEX_CLI_PATH", "CODEX_HOME"} or "\\" in value or looks_like_windows_path(value):
            lines.append(f"{key} = {toml_quote(value)}")
        else:
            lines.append(f'{key} = "{value.replace(chr(34), chr(92) + chr(34))}"')
    return "\n".join(lines).strip() + "\n"


def repair_chrome_latest(dry_run: bool = False) -> list[str]:
    latest = CHROME_PLUGIN_CACHE / "latest"
    browser_client = latest / "scripts" / "browser-client.mjs"
    if browser_client.exists():
        return []
    candidates = sorted(
        [
            path
            for path in CHROME_PLUGIN_CACHE.iterdir()
            if path.is_dir() and path.name != "latest" and (path / "scripts" / "browser-client.mjs").exists()
        ],
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        return ["! chrome latest missing and no complete chrome plugin version found"]
    target = candidates[0]
    changes = [f"~ chrome latest -> {target}"]
    if dry_run:
        return changes
    if latest.exists():
        latest_resolved = latest.resolve()
        cache_resolved = CHROME_PLUGIN_CACHE.resolve()
        if not str(latest_resolved).lower().startswith(str(cache_resolved).lower()):
            fatal(f"Refusing to remove chrome latest outside cache: {latest_resolved}")
        os.rmdir(latest)
    result = subprocess.run(["cmd", "/c", "mklink", "/J", str(latest), str(target)], capture_output=True, text=True)
    if result.returncode != 0:
        fatal((result.stderr or result.stdout or "mklink failed").strip())
    return changes


def edge_codex_extension_installed() -> bool:
    edge_root = HOME / "AppData" / "Local" / "Microsoft" / "Edge" / "User Data"
    if not edge_root.exists():
        return False
    return any(edge_root.glob("*/Extensions/hehggadaopoacecdllhhajmbjkdcmajg"))


def edge_native_host_registered() -> bool:
    if os.name != "nt":
        return True
    try:
        result = subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-Command",
                "(Get-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Edge\\NativeMessagingHosts\\com.openai.codexextension' -ErrorAction SilentlyContinue).'(default)'",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except Exception:
        return False
    return normalize_path_text(result.stdout.strip()).lower() == str(NATIVE_HOST_MANIFEST).lower()


def repair_edge_native_host(dry_run: bool = False) -> list[str]:
    if os.name != "nt" or not edge_codex_extension_installed() or edge_native_host_registered():
        return []
    if not NATIVE_HOST_MANIFEST.exists():
        return [f"! Edge native host manifest missing: {NATIVE_HOST_MANIFEST}"]
    changes = ["~ Edge NativeMessagingHosts com.openai.codexextension"]
    if dry_run:
        return changes
    result = subprocess.run(
        [
            "powershell",
            "-NoProfile",
            "-Command",
            (
                "$key='HKCU:\\Software\\Microsoft\\Edge\\NativeMessagingHosts\\com.openai.codexextension';"
                f"$manifest='{str(NATIVE_HOST_MANIFEST)}';"
                "New-Item -Path $key -Force | Out-Null;"
                "Set-ItemProperty -Path $key -Name '(default)' -Value $manifest"
            ),
        ],
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode != 0:
        fatal((result.stderr or result.stdout or "Edge native host registry write failed").strip())
    return changes


def repair_runtime(dry_run: bool = False) -> int:
    if not LIVE_CONFIG.exists():
        fatal(f"Live config not found: {LIVE_CONFIG}")
    live_text = read_text(LIVE_CONFIG)
    runtime = load_runtime_paths()
    old_bundle = extract_node_repl_bundle(live_text)
    new_bundle = build_node_repl_bundle(old_bundle, runtime)
    live_new, live_changed = replace_node_repl_bundle(live_text, new_bundle)
    parse_toml(live_new, "runtime-repaired live config")
    live_changed = live_changed and not toml_semantically_equal(live_text, live_new)

    changes: list[str] = []
    if live_changed:
        changes.append("~ live [mcp_servers.node_repl]")
    changes.extend(repair_chrome_latest(dry_run=True))
    changes.extend(repair_edge_native_host(dry_run=True))

    conn = connect_db()
    provider_updates: list[tuple[str, str, str, list[str]]] = []
    proxy_update = None
    try:
        for row in conn.execute("SELECT id, name, settings_config FROM providers WHERE app_type='codex'"):
            settings_config = read_json_object(row["settings_config"], f"provider:{row['id']}:settings_config")
            config = settings_config.get("config") if isinstance(settings_config.get("config"), str) else ""
            repaired, changed = replace_node_repl_bundle(config, new_bundle)
            changed = changed and not toml_semantically_equal(config, repaired)
            if changed:
                parse_toml(repaired, f"provider {row['name']} ({row['id']}) config")
                settings_config["config"] = repaired
                provider_updates.append(
                    (
                        row["id"],
                        row["name"],
                        json.dumps(settings_config, ensure_ascii=False, separators=(",", ":")),
                        ["~ [mcp_servers.node_repl]"],
                    )
                )

        row = conn.execute("SELECT original_config FROM proxy_live_backup WHERE app_type='codex'").fetchone()
        if row:
            original_config = read_json_object(row["original_config"], "proxy_live_backup:codex")
            config = original_config.get("config") if isinstance(original_config.get("config"), str) else ""
            repaired, changed = replace_node_repl_bundle(config, new_bundle)
            changed = changed and not toml_semantically_equal(config, repaired)
            if changed:
                parse_toml(repaired, "proxy_live_backup codex config")
                original_config["config"] = repaired
                proxy_update = json.dumps(original_config, ensure_ascii=False, separators=(",", ":"))
    finally:
        conn.close()

    for _provider_id, provider_name, _settings, provider_changes in provider_updates:
        summarize_changes(f"provider {provider_name}", provider_changes)
    if proxy_update is not None:
        summarize_changes("proxy_live_backup codex", ["~ [mcp_servers.node_repl]"])
    summarize_changes("runtime", changes)

    has_changes = bool(changes or provider_updates or proxy_update is not None)
    if not has_changes:
        info("Runtime paths already healthy.")
        return 0
    if dry_run:
        info("Dry-run only; runtime paths were not written.")
        return 0

    backup_dir = backup_before_write("repair-runtime")
    info(f"Backup: {backup_dir}")
    if live_changed:
        write_text(LIVE_CONFIG, live_new)
    repair_chrome_latest(dry_run=False)
    repair_edge_native_host(dry_run=False)
    conn = connect_db()
    try:
        for provider_id, _provider_name, settings, _changes in provider_updates:
            conn.execute(
                "UPDATE providers SET settings_config = ? WHERE id = ? AND app_type = 'codex'",
                (settings, provider_id),
            )
        if proxy_update is not None:
            conn.execute(
                "UPDATE proxy_live_backup SET original_config = ?, backed_up_at = ? WHERE app_type = 'codex'",
                (proxy_update, _dt.datetime.now(_dt.timezone.utc).isoformat()),
            )
        conn.commit()
    finally:
        conn.close()
    info("Runtime repair complete.")
    return 0


def choose_public_source(conn: sqlite3.Connection, source: str) -> tuple[str, str]:
    if source == "embedded":
        text = embedded_public_config()
        return text, "embedded BAT defaults"
    if source == "live":
        if not LIVE_CONFIG.exists():
            fatal(f"Live config not found: {LIVE_CONFIG}")
        text = extract_public_config(read_text(LIVE_CONFIG))
        return text, "current live config"

    if LIVE_CONFIG.exists():
        live_text = read_text(LIVE_CONFIG)
        live_looks_healthy = all(
            marker in live_text
            for marker in (
                'approval_policy = "never"',
                'sandbox_mode = "danger-full-access"',
                "[memories]",
                'followUpQueueMode = "steer"',
                '[plugins."browser@openai-bundled"]',
                '[plugins."chrome@openai-bundled"]',
                '[plugins."computer-use@openai-bundled"]',
                '[plugins."ponytail@ponytail"]',
            )
        )
        if live_looks_healthy:
            return extract_public_config(live_text), "current healthy live config"

    canonical = get_setting(conn, SETTING_CANONICAL)
    if canonical.strip():
        return canonical, f"cc-switch setting {SETTING_CANONICAL}"

    common = get_setting(conn, SETTING_COMMON)
    if common.strip() and "approval_policy" in common and "sandbox_mode" in common:
        return common, f"cc-switch setting {SETTING_COMMON}"

    return embedded_public_config(), "embedded BAT defaults"


def collect_template_repairs(
    conn: sqlite3.Connection,
    source_text: str,
    local_shared_text: str,
    retry_settings: dict[str, list[str]],
):
    provider_updates = []
    backup_update = None

    rows = conn.execute(
        """
        SELECT id, name, settings_config, meta
        FROM providers
        WHERE app_type = 'codex'
        ORDER BY sort_index, created_at
        """
    ).fetchall()

    for row in rows:
        settings_config = read_json_object(row["settings_config"], f"provider:{row['id']}:settings_config")
        meta = read_json_object(row["meta"], f"provider:{row['id']}:meta")
        changes: list[str] = []

        old_config = settings_config.get("config") or ""
        if not isinstance(old_config, str):
            old_config = ""
        new_config, merge_changes = merge_public(old_config, source_text)
        new_config, local_changes = merge_local_shared_tables(new_config, local_shared_text)
        new_config, retry_changes = merge_model_provider_retry_settings(new_config, retry_settings)
        new_config, reasoning_changes = normalize_model_reasoning_effort(new_config)
        if new_config != old_config:
            parse_toml(new_config, f"provider {row['name']} ({row['id']}) config")
            settings_config["config"] = new_config
            changes.extend(merge_changes)
            changes.extend(local_changes)
            changes.extend(retry_changes)
            changes.extend(reasoning_changes)

        if meta.get("commonConfigEnabled") is not True:
            meta["commonConfigEnabled"] = True
            changes.append("~ meta.commonConfigEnabled")

        if changes:
            provider_updates.append(
                (
                    row["id"],
                    row["name"],
                    json.dumps(settings_config, ensure_ascii=False, separators=(",", ":")),
                    json.dumps(meta, ensure_ascii=False, separators=(",", ":")),
                    changes,
                )
            )

    row = conn.execute("SELECT original_config FROM proxy_live_backup WHERE app_type = 'codex'").fetchone()
    if row:
        original_config = read_json_object(row["original_config"], "proxy_live_backup:codex")
        old_config = original_config.get("config") or ""
        if not isinstance(old_config, str):
            old_config = ""
        new_config, changes = merge_public(old_config, source_text)
        new_config, local_changes = merge_local_shared_tables(new_config, local_shared_text)
        new_config, retry_changes = merge_model_provider_retry_settings(new_config, retry_settings)
        new_config, reasoning_changes = normalize_model_reasoning_effort(new_config)
        changes.extend(local_changes)
        changes.extend(retry_changes)
        changes.extend(reasoning_changes)
        if new_config != old_config:
            parse_toml(new_config, "proxy_live_backup codex config")
            original_config["config"] = new_config
            backup_update = (
                json.dumps(original_config, ensure_ascii=False, separators=(",", ":")),
                changes,
            )

    return provider_updates, backup_update


def summarize_changes(label: str, changes: list[str]) -> None:
    if not changes:
        return
    shown = ", ".join(changes[:5])
    if len(changes) > 5:
        shown += f", ... +{len(changes) - 5} more"
    print(f"[change] {label}: {shown}")


def sync_public_config(source: str, dry_run: bool = False) -> int:
    if cc_switch_pids():
        info("cc-switch.exe is running; it will be stopped and restarted automatically if writes are needed.")

    conn = connect_db()
    try:
        source_text, source_label = choose_public_source(conn, source)
        source_text = extract_public_config(source_text)
        parse_toml(source_text, source_label)

        live_text = read_text(LIVE_CONFIG) if LIVE_CONFIG.exists() else ""
        retry_settings, retry_source_label = extract_model_provider_retry_settings(live_text)
        live_new, live_changes = merge_public(live_text, source_text)
        live_new, live_retry_changes = merge_model_provider_retry_settings(live_new, retry_settings)
        live_new, live_reasoning_changes = normalize_model_reasoning_effort(live_new)
        live_changes.extend(live_retry_changes)
        live_changes.extend(live_reasoning_changes)
        parse_toml(live_new, "merged live config")

        common_old = get_setting(conn, SETTING_COMMON)
        canonical_old = get_setting(conn, SETTING_CANONICAL)
        common_changed = not toml_semantically_equal(common_old, source_text)
        canonical_changed = not toml_semantically_equal(canonical_old, source_text)
        provider_updates, proxy_backup_update = collect_template_repairs(
            conn,
            source_text,
            live_text,
            retry_settings,
        )

        info(f"Public config source: {source_label}")
        if retry_settings:
            keys = ", ".join(retry_settings)
            info(f"Model provider retry source: {retry_source_label} ({keys})")
        else:
            info("Model provider retry source: none found in live config")
        if live_text != live_new and not live_changes:
            info(
                "Live config: semantic merge unchanged "
                f"({len(live_text)} bytes; normalized candidate {len(live_new)} bytes)"
            )
        else:
            info(f"Live config: {len(live_text)} -> {len(live_new)} bytes")
        info(f"DB {SETTING_COMMON}: {len(common_old)} -> {len(source_text)} bytes")
        info(f"DB {SETTING_CANONICAL}: {len(canonical_old)} -> {len(source_text)} bytes")

        if common_changed:
            print(f"[change] replace DB setting {SETTING_COMMON}")
        if canonical_changed:
            print(f"[change] replace DB setting {SETTING_CANONICAL}")
        summarize_changes("live config", live_changes)
        for provider_id, provider_name, _settings, _meta, changes in provider_updates:
            summarize_changes(f"provider {provider_name} ({provider_id})", changes)
        if proxy_backup_update is not None:
            summarize_changes("proxy_live_backup codex", proxy_backup_update[1])

        has_changes = (
            common_changed
            or canonical_changed
            or live_changes
            or provider_updates
            or proxy_backup_update is not None
        )
        if not has_changes:
            info("Nothing to change.")
            return 0
        if dry_run:
            info("Dry-run only; no files or database rows were written.")
            return 0

        restart_paths = stop_cc_switch_for_write()
        try:
            backup_dir = backup_before_write("sync")
            info(f"Backup: {backup_dir}")

            set_setting(conn, SETTING_COMMON, source_text)
            set_setting(conn, SETTING_CANONICAL, source_text)
            for provider_id, _provider_name, settings_config, meta, _changes in provider_updates:
                conn.execute(
                    """
                    UPDATE providers
                    SET settings_config = ?, meta = ?
                    WHERE id = ? AND app_type = 'codex'
                    """,
                    (settings_config, meta, provider_id),
                )
            if proxy_backup_update is not None:
                conn.execute(
                    "UPDATE proxy_live_backup SET original_config = ? WHERE app_type = 'codex'",
                    (proxy_backup_update[0],),
                )
            conn.commit()
            write_text(LIVE_CONFIG, live_new)
        finally:
            restart_cc_switch(restart_paths)
        info("Public config repaired in live config, common config, provider templates, and proxy backup.")
        return 0
    finally:
        conn.close()


TOKEN_MARKERS = ("access_token", "refresh_token", "id_token", "account_id", "chatgpt", "tokens")


def contains_token_shape(value: Any) -> bool:
    if isinstance(value, dict):
        for key, child in value.items():
            lowered = str(key).lower()
            if any(marker in lowered for marker in TOKEN_MARKERS):
                return True
            if contains_token_shape(child):
                return True
    elif isinstance(value, list):
        return any(contains_token_shape(item) for item in value)
    return False


def read_auth_file(path: Path = AUTH_JSON) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fatal(f"{path} is not valid JSON: {exc}")
    if not isinstance(value, dict):
        fatal(f"{path} must contain a JSON object.")
    return value


def classify_auth_json(data: dict[str, Any]) -> str:
    if not data:
        return "missing"
    has_official = contains_token_shape(data)
    has_api_key = "OPENAI_API_KEY" in data
    if has_official and has_api_key:
        return "official+api_key"
    if has_official:
        return "official"
    if has_api_key:
        return "api_key"
    return "unknown"


def describe_auth_file(path: Path = AUTH_JSON) -> str:
    if not path.exists():
        return "missing"
    stat = path.stat()
    timestamp = _dt.datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M:%S")
    return f"{classify_auth_json(read_auth_file(path))} | {stat.st_size} bytes | modified {timestamp}"


def classify_auth_text(text: str) -> str:
    if not text.strip():
        return "missing"
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        return "invalid"
    if not isinstance(value, dict):
        return "invalid"
    return classify_auth_json(value)


def strip_api_key_from_official_auth_text(text: str) -> str:
    data = json.loads(text)
    if not isinstance(data, dict):
        fatal("Official auth backup must be a JSON object.")
    data.pop("OPENAI_API_KEY", None)
    if classify_auth_json(data) != "official":
        fatal("Official auth becomes invalid after removing OPENAI_API_KEY; refusing to capture.")
    return json.dumps(data, ensure_ascii=False, indent=2) + "\n"


def normalize_official_auth_text(text: str) -> str:
    mode = classify_auth_text(text)
    if mode not in ("official", "official+api_key"):
        fatal(f"Official auth backup is not usable (detected: {mode}).")
    return strip_api_key_from_official_auth_text(text)


def repair_official_auth_references(
    conn: sqlite3.Connection,
    official_text: str,
    dry_run: bool = False,
) -> list[str]:
    normalized_text = normalize_official_auth_text(official_text)
    official_auth = json.loads(normalized_text)
    changes: list[str] = []

    old_setting = get_setting(conn, SETTING_OFFICIAL_AUTH)
    if old_setting != normalized_text:
        changes.append(f"~ DB setting {SETTING_OFFICIAL_AUTH}")
        if not dry_run:
            set_setting(conn, SETTING_OFFICIAL_AUTH, normalized_text)

    official_provider = conn.execute(
        """
        SELECT id, settings_config
        FROM providers
        WHERE id = 'codex-official' AND app_type = 'codex'
        """
    ).fetchone()
    if official_provider:
        settings_config = read_json_object(
            official_provider["settings_config"],
            "provider:codex-official:settings_config",
        )
        old_auth = settings_config.get("auth") if isinstance(settings_config.get("auth"), dict) else {}
        if old_auth != official_auth:
            changes.append("~ provider codex-official auth")
            if not dry_run:
                settings_config["auth"] = official_auth
                conn.execute(
                    """
                    UPDATE providers
                    SET settings_config = ?
                    WHERE id = 'codex-official' AND app_type = 'codex'
                    """,
                    (json.dumps(settings_config, ensure_ascii=False, separators=(",", ":")),),
                )
    else:
        changes.append("+ provider codex-official auth")
        if not dry_run:
            provider_config = extract_public_config(read_text(LIVE_CONFIG)) if LIVE_CONFIG.exists() else embedded_public_config()
            parse_toml(provider_config, "provider codex-official config")
            settings_config = {
                "auth": official_auth,
                "config": provider_config,
            }
            conn.execute(
                """
                INSERT INTO providers(
                    id, app_type, name, settings_config, created_at, sort_index, meta, is_current
                )
                VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    "codex-official",
                    "codex",
                    "OpenAI Official",
                    json.dumps(settings_config, ensure_ascii=False, separators=(",", ":")),
                    int(time.time() * 1000),
                    0,
                    json.dumps({"commonConfigEnabled": True}, separators=(",", ":")),
                    0,
                ),
            )

    row = conn.execute(
        "SELECT original_config FROM proxy_live_backup WHERE app_type = 'codex'"
    ).fetchone()
    if row:
        original_config = read_json_object(row["original_config"], "proxy_live_backup:codex")
        old_auth = original_config.get("auth") if isinstance(original_config.get("auth"), dict) else {}
        if old_auth != official_auth:
            changes.append("~ proxy_live_backup codex auth")
            if not dry_run:
                original_config["auth"] = official_auth
                conn.execute(
                    """
                    UPDATE proxy_live_backup
                    SET original_config = ?, backed_up_at = ?
                    WHERE app_type = 'codex'
                    """,
                    (
                        json.dumps(original_config, ensure_ascii=False, separators=(",", ":")),
                        _dt.datetime.now(_dt.timezone.utc).isoformat(),
                    ),
                )
    else:
        changes.append("+ proxy_live_backup codex")
        if not dry_run:
            original_config = {
                "auth": official_auth,
                "config": read_text(LIVE_CONFIG) if LIVE_CONFIG.exists() else "",
            }
            conn.execute(
                """
                INSERT INTO proxy_live_backup(app_type, original_config, backed_up_at)
                VALUES(?, ?, ?)
                """,
                (
                    "codex",
                    json.dumps(original_config, ensure_ascii=False, separators=(",", ":")),
                    _dt.datetime.now(_dt.timezone.utc).isoformat(),
                ),
            )

    return changes


def verify_official_auth_references(official_text: str, verify_live: bool = False) -> bool:
    expected_auth = json.loads(normalize_official_auth_text(official_text))
    issues: list[str] = []

    if verify_live:
        live_auth = read_auth_file()
        live_auth.pop("OPENAI_API_KEY", None)
        if live_auth != expected_auth:
            issues.append("live auth.json")

    conn = connect_db()
    try:
        issues.extend(repair_official_auth_references(conn, official_text, dry_run=True))
    finally:
        conn.close()

    if issues:
        warn("Official auth verification still has drift: " + ", ".join(issues))
        return False
    info("Official auth verification passed.")
    return True


def run_codex_login_status() -> str:
    try:
        result = subprocess.run(
            ["cmd", "/c", "codex", "login", "status"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        output = (result.stdout or result.stderr or "").strip()
        return output or f"codex login status exited with {result.returncode}"
    except Exception as exc:
        return f"could not run codex login status: {exc}"


def capture_official_auth(dry_run: bool = False) -> int:
    data = read_auth_file()
    mode = classify_auth_json(data)
    if mode not in ("official", "official+api_key"):
        fatal(
            "Current auth.json is not official ChatGPT auth "
            f"(detected: {mode}). Sign in with ChatGPT first, then run: codex-ccswitch.bat capture-auth"
        )

    text = normalize_official_auth_text(AUTH_JSON.read_text(encoding="utf-8"))
    conn = connect_db()
    try:
        old_text = get_setting(conn, SETTING_OFFICIAL_AUTH)
        old_mode = classify_auth_text(old_text)
        changes = repair_official_auth_references(conn, text, dry_run=True)
        info(f"Live auth: {describe_auth_file()}")
        info(f"DB official auth backup: {old_mode}")
        if not changes:
            info("Official auth backup and CC-Switch official restore references already match live auth.")
            return 0
        if dry_run:
            summarize_changes("official auth references", changes)
            info("Dry-run only; no auth backup was written.")
            return 0
        if cc_switch_pids():
            info("cc-switch.exe is running; auth-only capture will write DB backup without restarting it.")
        backup_dir = backup_before_write("capture-auth")
        info(f"Backup: {backup_dir}")
        changes = repair_official_auth_references(conn, text)
        conn.commit()
        summarize_changes("official auth references", changes)
        verify_official_auth_references(text)
        info("Captured official auth into DB and CC-Switch official restore references.")
        return 0
    finally:
        conn.close()


def restore_official_auth(dry_run: bool = False) -> int:
    conn = connect_db()
    try:
        backup_text = get_setting(conn, SETTING_OFFICIAL_AUTH)
    finally:
        conn.close()

    backup_mode = classify_auth_text(backup_text)
    live_mode = classify_auth_json(read_auth_file())
    official_text = normalize_official_auth_text(backup_text) if backup_mode in ("official", "official+api_key") else ""
    info(f"Live auth: {describe_auth_file()}")
    info(f"DB official auth backup: {backup_mode}")

    if backup_mode not in ("official", "official+api_key"):
        fatal(
            "No official ChatGPT auth backup exists in CC-Switch DB yet. "
            "Sign in with ChatGPT until quota/account info appears, then run: codex-ccswitch.bat capture-auth"
        )
    conn = connect_db()
    try:
        reference_changes = repair_official_auth_references(conn, official_text, dry_run=True)
    finally:
        conn.close()
    live_needs_restore = live_mode not in ("official", "official+api_key")

    if not live_needs_restore and not reference_changes:
        info("Live auth and CC-Switch official restore references are already official; nothing to restore.")
        return 0
    if dry_run:
        changes = list(reference_changes)
        if live_needs_restore:
            changes.append("~ live auth.json")
        summarize_changes("official auth restore", changes)
        info("Dry-run only; auth.json was not written.")
        return 0

    if cc_switch_pids():
        info("cc-switch.exe is running; auth-only restore will write auth refs and verify without restarting it.")
    backup_dir = backup_before_write("restore-auth")
    info(f"Backup: {backup_dir}")
    conn = connect_db()
    try:
        reference_changes = repair_official_auth_references(conn, official_text)
        conn.commit()
    finally:
        conn.close()
    if live_needs_restore:
        write_text(AUTH_JSON, official_text)
    summarize_changes("official auth references", reference_changes)
    if live_needs_restore:
        info("Restored official ChatGPT auth.json from CC-Switch DB backup.")
    verify_official_auth_references(official_text, verify_live=True)
    return 0


def get_current_codex_provider_summary(conn: sqlite3.Connection) -> dict[str, Any]:
    settings_path = CCSWITCH_SETTINGS
    current = ""
    if settings_path.exists():
        try:
            settings = json.loads(settings_path.read_text(encoding="utf-8"))
            if isinstance(settings, dict):
                current = str(settings.get("currentProviderCodex") or "")
        except Exception:
            current = ""
    if not current:
        row = conn.execute(
            "SELECT id FROM providers WHERE app_type='codex' AND is_current=1 LIMIT 1"
        ).fetchone()
        current = row["id"] if row else ""
    if not current:
        return {}
    row = conn.execute(
        "SELECT id, name, settings_config, meta FROM providers WHERE id=? AND app_type='codex'",
        (current,),
    ).fetchone()
    if not row:
        return {"id": current, "missing": True}
    settings_config = read_json_object(row["settings_config"], f"provider:{current}:settings_config")
    meta = read_json_object(row["meta"], f"provider:{current}:meta")
    auth = settings_config.get("auth") if isinstance(settings_config.get("auth"), dict) else {}
    config = settings_config.get("config") if isinstance(settings_config.get("config"), str) else ""
    return {
        "id": row["id"],
        "name": row["name"],
        "commonConfigEnabled": meta.get("commonConfigEnabled"),
        "apiFormat": meta.get("apiFormat"),
        "authMode": classify_auth_json(auth),
        "authKeys": sorted(auth.keys()),
        "hasPublicSettings": all(
            marker in config
            for marker in ("approval_policy", "sandbox_mode", "memories", "followUpQueueMode")
        ),
        "hasProxyEnv": has_proxy_env(config),
        "hasOpenAIDocsMcp": has_openai_docs_mcp(config),
    }


def has_proxy_env(config: str) -> bool:
    return all(
        marker in config
        for marker in (
            "[shell_environment_policy]",
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "NO_PROXY",
        )
    )


def has_openai_docs_mcp(config: str) -> bool:
    match = re.search(r"(?ms)^\[mcp_servers\.openaiDeveloperDocs\]\s*(.*?)(?=^\[|\Z)", config)
    return bool(match and re.search(r"(?m)^\s*enabled\s*=\s*true\s*$", match.group(1)))


def read_ccswitch_settings() -> dict[str, Any]:
    if not CCSWITCH_SETTINGS.exists():
        return {}
    try:
        value = json.loads(CCSWITCH_SETTINGS.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return value if isinstance(value, dict) else {}


def auth_summary_from_object(value: Any) -> str:
    auth = value if isinstance(value, dict) else {}
    keys = ",".join(sorted(auth.keys())) or "(none)"
    return f"{classify_auth_json(auth)} keys={keys}"


def status() -> int:
    print("== Codex auth ==")
    print(f"live auth: {describe_auth_file()}")
    conn = connect_db()
    try:
        official_backup = get_setting(conn, SETTING_OFFICIAL_AUTH)
        backup_mode = classify_auth_text(official_backup)
        print(f"DB official auth backup: {backup_mode}")

        official_provider = conn.execute(
            "SELECT settings_config FROM providers WHERE id='codex-official' AND app_type='codex'"
        ).fetchone()
        if official_provider:
            provider_config = read_json_object(
                official_provider["settings_config"],
                "provider:codex-official:settings_config",
            )
            print(f"codex-official provider auth: {auth_summary_from_object(provider_config.get('auth'))}")
        else:
            print("codex-official provider auth: missing provider")

        proxy_backup = conn.execute(
            "SELECT original_config FROM proxy_live_backup WHERE app_type='codex'"
        ).fetchone()
        if proxy_backup:
            proxy_config = read_json_object(proxy_backup["original_config"], "proxy_live_backup:codex")
            print(f"proxy_live_backup auth: {auth_summary_from_object(proxy_config.get('auth'))}")
        else:
            print("proxy_live_backup auth: missing")

        if backup_mode in ("official", "official+api_key"):
            drift = repair_official_auth_references(conn, official_backup, dry_run=True)
            print(f"official auth references: {'ok' if not drift else 'needs repair: ' + ', '.join(drift)}")
    finally:
        conn.close()
    print(f"codex login status: {run_codex_login_status()}")

    print("\n== Codex config ==")
    live_text = read_text(LIVE_CONFIG) if LIVE_CONFIG.exists() else ""
    for marker in (
        'approval_policy = "never"',
        'sandbox_mode = "danger-full-access"',
        "[memories]",
        'followUpQueueMode = "steer"',
        '[plugins."browser@openai-bundled"]',
        '[plugins."chrome@openai-bundled"]',
        '[plugins."computer-use@openai-bundled"]',
        '[plugins."ponytail@ponytail"]',
        "[hooks.state]",
    ):
        print(f"{marker}: {'yes' if marker in live_text else 'no'}")
    print(f"[tui.model_availability_nux]: {'yes' if '[tui.model_availability_nux]' in live_text else 'no'} (ignored)")
    print(f"proxy env: {'yes' if has_proxy_env(live_text) else 'no'}")
    print(f"OpenAI Docs MCP: {'yes' if has_openai_docs_mcp(live_text) else 'no'}")

    print("\n== CC-Switch ==")
    print(f"script elevated: {'yes' if is_windows_admin() else 'no'}")
    settings = read_ccswitch_settings()
    for key in (
        "showInTray",
        "minimizeToTrayOnClose",
        "launchOnStartup",
        "enableLocalProxy",
        "preserveCodexOfficialAuthOnSwitch",
        "currentProviderCodex",
    ):
        if key in settings:
            print(f"settings.{key}: {settings.get(key)}")
    processes = cc_switch_processes()
    if processes:
        print("cc-switch.exe: running")
        for row in processes:
            print(f"  {format_process(row)}")
    else:
        print("cc-switch.exe: not running")
    restart_paths = cc_switch_restart_paths(processes)
    print(f"restart candidates: {', '.join(str(path) for path in restart_paths) if restart_paths else '(none)'}")
    conn = connect_db()
    try:
        common = get_setting(conn, SETTING_COMMON)
        canonical = get_setting(conn, SETTING_CANONICAL)
        print(f"{SETTING_COMMON}: {len(common)} bytes, approval={'approval_policy' in common}, memories={'memories' in common}")
        print(f"{SETTING_CANONICAL}: {len(canonical)} bytes, approval={'approval_policy' in canonical}, memories={'memories' in canonical}")
        summary = get_current_codex_provider_summary(conn)
        if summary:
            print("current provider:")
            print(f"  id: {summary.get('id')}")
            print(f"  name: {summary.get('name')}")
            print(f"  commonConfigEnabled: {summary.get('commonConfigEnabled')}")
            print(f"  apiFormat: {summary.get('apiFormat')}")
            print(f"  authMode: {summary.get('authMode')}")
            print(f"  authKeys: {','.join(summary.get('authKeys', []))}")
            print(f"  hasPublicSettings: {summary.get('hasPublicSettings')}")
            print(f"  hasProxyEnv: {summary.get('hasProxyEnv')}")
            print(f"  hasOpenAIDocsMcp: {summary.get('hasOpenAIDocsMcp')}")
        row = conn.execute("SELECT original_config FROM proxy_live_backup WHERE app_type='codex'").fetchone()
        if row:
            obj = read_json_object(row["original_config"], "proxy_live_backup:codex")
            auth = obj.get("auth") if isinstance(obj.get("auth"), dict) else {}
            config = obj.get("config") if isinstance(obj.get("config"), str) else ""
            print(
                "proxy_live_backup: "
                f"authKeys={','.join(sorted(auth.keys()))}, "
                f"hasPublicSettings={all(m in config for m in ('approval_policy','sandbox_mode','memories'))}, "
                f"hasProxyEnv={has_proxy_env(config)}, "
                f"hasOpenAIDocsMcp={has_openai_docs_mcp(config)}"
            )
        else:
            print("proxy_live_backup: missing")
    finally:
        conn.close()
    return 0


def auto_auth(dry_run: bool = False) -> int:
    live_mode = classify_auth_json(read_auth_file())
    conn = connect_db()
    try:
        backup_mode = classify_auth_text(get_setting(conn, SETTING_OFFICIAL_AUTH))
    finally:
        conn.close()

    if live_mode in ("official", "official+api_key"):
        print("\n== Auth auto-save ==")
        return capture_official_auth(dry_run=dry_run)
    if live_mode not in ("official", "official+api_key") and backup_mode in ("official", "official+api_key"):
        print("\n== Auth auto-restore ==")
        return restore_official_auth(dry_run=dry_run)

    warn(
        "Auth is not official and no official backup exists. "
        "Sign in with ChatGPT once, confirm quota/account info appears, then run this BAT again."
    )
    return 0


def self_check() -> int:
    assert load_minimal_toml("[features]\napps = false\n")["features"]["apps"] is False
    assert toml_value_from_line("CODEX_CLI_PATH = 'C:\\\\x\\\\codex.exe'\n", "CODEX_CLI_PATH") == "C:\\\\x\\\\codex.exe"
    assert "model_reasoning_effort" in SKIP_TOP_LEVEL_KEYS
    embedded = embedded_public_config()
    assert toml_value_from_line(embedded, "model_reasoning_effort") == "ultra"
    assert toml_value_from_line(embedded, "model_catalog_json") == str(
        CODEX_HOME / "models-wooai-supported-v0.144.4.json"
    )
    public = extract_public_config(embedded)
    assert "model_reasoning_effort" not in public
    assert "model_catalog_json" in public
    grok, grok_changes = normalize_model_reasoning_effort(
        'model = "grok-4.5"\nmodel_reasoning_effort = "ultra"\n'
    )
    assert toml_value_from_line(grok, "model_reasoning_effort") == "high"
    assert grok_changes == ["~ model_reasoning_effort (grok-4.5: high)"]
    grok_medium = 'model = "grok-4.5"\nmodel_reasoning_effort = "medium"\n'
    assert normalize_model_reasoning_effort(grok_medium) == (grok_medium, [])
    sol, sol_changes = normalize_model_reasoning_effort(
        'model = "gpt-5.6-sol"\nmodel_reasoning_effort = "xhigh"\n'
    )
    assert toml_value_from_line(sol, "model_reasoning_effort") == "ultra"
    assert sol_changes == ["~ model_reasoning_effort (gpt-5.6-sol: ultra)"]
    sol_missing, sol_missing_changes = normalize_model_reasoning_effort(
        'model = "gpt-5.6-sol"\napproval_policy = "never"\n'
    )
    assert toml_value_from_line(sol_missing, "model_reasoning_effort") == "ultra"
    assert sol_missing_changes == ["~ model_reasoning_effort (gpt-5.6-sol: ultra)"]
    legacy = 'model = "gpt-5.5"\nmodel_reasoning_effort = "xhigh"\n'
    assert normalize_model_reasoning_effort(legacy) == (legacy, [])
    runtime = load_runtime_paths()
    assert runtime_paths_complete(runtime), runtime
    assert Path(runtime["codexCliPath"]).name.lower() == "codex.exe" and Path(runtime["codexCliPath"]).exists(), runtime["codexCliPath"]
    assert "service_tier" not in embedded_public_config()
    merged, _changes = merge_public('service_tier = "priority"\n', "[features]\napps = false\n")
    assert 'service_tier = "priority"' not in merged
    assert "[features]" in merged
    target = """model = "old"
stale = true

[features]
apps = true

[projects.'c:\\x']
trust_level = "trusted"

[mcp_servers.node_repl]
command = 'node_repl.exe'

[hooks.state."old"]
trusted_hash = "sha256:old"
"""
    source = """check_for_update_on_startup = false

[hooks.state."new"]
trusted_hash = "sha256:new"

[mcp_servers.chrome_devtools]
command = "npx.cmd"
"""
    mirrored, _changes = merge_public(target, source)
    assert 'model = "old"' in mirrored
    assert 'stale = true' not in mirrored
    assert "[features]" not in mirrored
    assert "[projects.'c:\\x']" in mirrored
    assert "[mcp_servers.node_repl]" in mirrored
    assert "[mcp_servers.chrome_devtools]" in mirrored
    assert '[hooks.state."old"]' not in mirrored
    assert '[hooks.state."new"]' in mirrored
    local_target = """model = "gpt-5.6-sol"

[projects.'c:\\old']
trust_level = "trusted"
"""
    local_source = """approval_policy = "never"

[projects.'e:\\ideaprojects']
trust_level = "trusted"
"""
    local_merged, local_changes = merge_local_shared_tables(local_target, local_source)
    assert "[projects.'c:\\old']" not in local_merged
    assert "[projects.'e:\\ideaprojects']" in local_merged
    assert local_changes == ["~ local shared tables (projects)"]
    assert merge_local_shared_tables(local_target, "approval_policy = \"never\"\n") == (
        local_target,
        [],
    )
    text = read_text(LIVE_CONFIG)
    assert "apps = false" in text
    assert "mcp_servers.openaiDeveloperDocs" in text and "enabled = false" in text
    info("Self-check passed.")
    return 0


def all_in_one(dry_run: bool = False) -> int:
    status()
    print("\n== Runtime path auto-repair ==")
    repair_runtime(dry_run=dry_run)
    auto_auth(dry_run=dry_run)
    print("\n== Public config auto-repair ==")
    return sync_public_config("auto", dry_run=dry_run)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="One BAT entry for Codex + CC-Switch config and auth state."
    )
    parser.add_argument(
        "command",
        nargs="?",
        default="all",
        choices=[
            "auto",
            "status",
            "sync",
            "sync-live",
            "repair-runtime",
            "capture-auth",
            "restore-auth",
            "self-check",
            "all",
            "dry-run",
            "help",
        ],
        help="Command to run. Default: all.",
    )
    args = parser.parse_args()

    if args.command == "help":
        parser.print_help()
        return 0
    if args.command == "status":
        return status()
    if args.command == "sync":
        return sync_public_config("auto")
    if args.command == "sync-live":
        return sync_public_config("live")
    if args.command == "repair-runtime":
        return repair_runtime()
    if args.command == "capture-auth":
        return capture_official_auth()
    if args.command == "restore-auth":
        return restore_official_auth()
    if args.command == "self-check":
        return self_check()
    if args.command in ("all", "auto"):
        return all_in_one()
    if args.command == "dry-run":
        return all_in_one(dry_run=True)
    return 2


if __name__ == "__main__":
    sys.exit(main())
