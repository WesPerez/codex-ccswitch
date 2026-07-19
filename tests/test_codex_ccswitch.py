import importlib.util
import base64
import datetime as dt
import json
import os
import sqlite3
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BAT = ROOT / "codex-ccswitch.bat"
MARKER = "### PYTHON_PAYLOAD ###"


def official_auth(label: str, refreshed: str = "2026-07-19T00:00:00Z") -> dict:
    return {
        "auth_mode": "chatgpt",
        "tokens": {
            "access_token": f"access-{label}",
            "refresh_token": f"refresh-{label}",
            "id_token": f"id-{label}",
        },
        "last_refresh": refreshed,
    }


def jwt_with_expiry(expiry: dt.datetime) -> str:
    header = base64.urlsafe_b64encode(b'{"alg":"none"}').decode().rstrip("=")
    payload = base64.urlsafe_b64encode(
        json.dumps({"exp": int(expiry.timestamp())}).encode()
    ).decode().rstrip("=")
    return f"{header}.{payload}.signature"


def catalog_entry(model: str, efforts: tuple[str, ...], default: str | None = None) -> dict:
    entry = {
        "slug": model,
        "display_name": model,
        "context_window": 100000,
        "supported_reasoning_levels": [{"effort": value} for value in efforts],
    }
    if default is not None:
        entry["default_reasoning_level"] = default
    return entry


def load_payload(home: Path):
    raw = BAT.read_text(encoding="utf-8")
    code = raw.split(MARKER, 1)[1].lstrip()
    payload = home / "codex_ccswitch_under_test.py"
    payload.write_text(code, encoding="utf-8")
    old_profile = os.environ.get("USERPROFILE")
    os.environ["USERPROFILE"] = str(home)
    try:
        name = f"codex_ccswitch_under_test_{id(home)}"
        spec = importlib.util.spec_from_file_location(name, payload)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
    finally:
        if old_profile is None:
            os.environ.pop("USERPROFILE", None)
        else:
            os.environ["USERPROFILE"] = old_profile
    module.HOME = home
    module.CODEX_HOME = home / ".codex"
    module.TOOLS_HOME = module.CODEX_HOME / "tools"
    module.LIVE_CONFIG = module.CODEX_HOME / "config.toml"
    module.AUTH_JSON = module.CODEX_HOME / "auth.json"
    module.GLOBAL_STATE = module.CODEX_HOME / ".codex-global-state.json"
    module.CHROME_NATIVE_HOSTS_V2 = module.CODEX_HOME / "chrome-native-hosts-v2.json"
    module.CHROME_PLUGIN_CACHE = module.CODEX_HOME / "plugins" / "cache" / "openai-bundled" / "chrome"
    module.NATIVE_HOST_MANIFEST = home / "native-host.json"
    module.CCSWITCH_HOME = home / ".cc-switch"
    module.CCSWITCH_DB = module.CCSWITCH_HOME / "cc-switch.db"
    module.CCSWITCH_SETTINGS = module.CCSWITCH_HOME / "settings.json"
    module.BACKUP_ROOT = module.CODEX_HOME / ".tmp"
    module.CODEX_HOME.mkdir(parents=True)
    module.CCSWITCH_HOME.mkdir(parents=True)
    return module


def create_db(module, backup_auth=None):
    auth = backup_auth or official_auth("old", "2026-07-04T00:00:00Z")
    conn = sqlite3.connect(module.CCSWITCH_DB)
    conn.executescript(
        """
        CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE providers(
            id TEXT, app_type TEXT, name TEXT, settings_config TEXT,
            created_at INTEGER, sort_index INTEGER, meta TEXT, is_current BOOLEAN
        );
        CREATE TABLE proxy_live_backup(
            app_type TEXT PRIMARY KEY, original_config TEXT, backed_up_at TEXT
        );
        CREATE TABLE proxy_config(
            app_type TEXT PRIMARY KEY, enabled INTEGER, proxy_enabled INTEGER
        );
        """
    )
    auth_text = json.dumps(auth)
    conn.execute(
        "INSERT INTO settings(key,value) VALUES(?,?)",
        (module.SETTING_OFFICIAL_AUTH, auth_text),
    )
    conn.execute(
        "INSERT INTO settings(key,value) VALUES(?,?)",
        (module.SETTING_COMMON, 'approval_policy = "never"\n'),
    )
    conn.execute(
        "INSERT INTO settings(key,value) VALUES(?,?)",
        (module.SETTING_CANONICAL, 'approval_policy = "never"\n'),
    )
    settings_config = json.dumps({"auth": auth, "config": 'model_reasoning_effort = "xhigh"\n'})
    conn.execute(
        "INSERT INTO providers VALUES(?,?,?,?,?,?,?,?)",
        ("codex-official", "codex", "OpenAI Official", settings_config, 1, 0, "{}", 0),
    )
    conn.execute(
        "INSERT INTO proxy_live_backup VALUES(?,?,?)",
        ("codex", json.dumps({"auth": auth, "config": 'model = "gpt-5.6-sol"\n'}), "old"),
    )
    conn.execute("INSERT INTO proxy_config VALUES(?,?,?)", ("codex", 1, 1))
    conn.commit()
    conn.close()


def provider_row(
    provider_id: str,
    name: str,
    config: str,
    auth: dict | None = None,
    *,
    is_current: int = 0,
    sort_index: int = 0,
    meta: dict | None = None,
):
    return (
        provider_id,
        "codex",
        name,
        json.dumps(
            {
                "auth": auth if auth is not None else {"OPENAI_API_KEY": f"key-{provider_id}"},
                "config": config,
            }
        ),
        1,
        sort_index,
        json.dumps(meta or {"commonConfigEnabled": True}),
        is_current,
    )


def healthy_live_config(
    *,
    model: str = "gpt-5.6-sol",
    effort: str = "max",
    catalog: str = "live-models.json",
    service_tier: str = "priority",
    model_provider: str = "custom",
    extra_top: str = "",
) -> str:
    parts = [
        f'model = "{model}"',
        f'model_provider = "{model_provider}"',
        f'model_reasoning_effort = "{effort}"',
        f'model_catalog_json = "{catalog}"',
        f'service_tier = "{service_tier}"',
        'personality = "pragmatic"',
        'plan_mode_reasoning_effort = "high"',
        'model_verbosity = "high"',
    ]
    if extra_top:
        parts.append(extra_top.rstrip("\n"))
    parts.extend(
        [
            'approval_policy = "never"',
            'sandbox_mode = "danger-full-access"',
            "",
            "[desktop]",
            'followUpQueueMode = "steer"',
            "",
            "[features]",
            "apps = false",
            "",
            "[model_providers.custom]",
            'name = "Custom"',
            'base_url = "https://example.invalid/v1"',
            'experimental_bearer_token = "live-secret"',
            "",
        ]
    )
    return chr(10).join(parts)


class CodexCcSwitchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codex-ccswitch-test-")
        self.home = Path(self.temp.name)
        self.mod = load_payload(self.home)

    def tearDown(self):
        self.temp.cleanup()

    def test_public_config_excludes_private_provider_and_local_state(self):
        text = r'''
model = "gpt-5.6-sol"
model_provider = "custom"
model_reasoning_effort = "max"
model_catalog_json = "C:\\private\\models.json"
service_tier = "priority"
personality = "pragmatic"
approval_policy = "never"

[features]
apps = false

[model_providers.custom]
experimental_bearer_token = "secret"

[projects.'c:\\private']
trust_level = "trusted"

[hooks.state."private"]
trusted_hash = "sha256:private"

[mcp_servers.example.env]
ACCESS_TOKEN = "secret"
'''
        public = self.mod.extract_public_config(text)
        self.assertIn("approval_policy", public)
        self.assertIn("[features]", public)
        for marker in (
            "model =",
            "model_provider",
            "model_reasoning_effort",
            "model_catalog_json",
            "service_tier",
            "personality",
            "model_providers",
            "projects",
            "hooks.state",
            "ACCESS_TOKEN",
        ):
            self.assertNotIn(marker, public)

    def test_merge_preserves_target_private_values(self):
        target = '''model = "grok-4.5"\nmodel_reasoning_effort = "high"\nservice_tier = "default"\n\n[hooks.state."local"]\ntrusted_hash = "sha256:local"\n'''
        merged, _ = self.mod.merge_public(target, '[features]\napps = false\n')
        self.assertIn('model = "grok-4.5"', merged)
        self.assertIn('model_reasoning_effort = "high"', merged)
        self.assertIn('service_tier = "default"', merged)
        self.assertIn('[hooks.state."local"]', merged)
        self.assertIn("[features]", merged)

    def test_reasoning_repairs_only_missing_or_invalid(self):
        sol = 'model = "gpt-5.6-sol"\nmodel_reasoning_effort = "max"\n'
        self.assertEqual(self.mod.normalize_model_reasoning_effort(sol), (sol, []))
        missing, changes = self.mod.normalize_model_reasoning_effort('model = "gpt-5.6-sol"\n')
        self.assertEqual(self.mod.top_level_toml_value(missing, "model_reasoning_effort"), "max")
        self.assertTrue(changes)
        grok, _ = self.mod.normalize_model_reasoning_effort(
            'model = "grok-4.5"\nmodel_reasoning_effort = "ultra"\n'
        )
        self.assertEqual(self.mod.top_level_toml_value(grok, "model_reasoning_effort"), "high")

    def test_null_api_key_is_not_classified_as_api_key(self):
        auth = official_auth("live")
        auth["OPENAI_API_KEY"] = None
        self.assertEqual(self.mod.classify_auth_json(auth), "official")
        self.assertEqual(self.mod.classify_auth_json({"OPENAI_API_KEY": ""}), "unknown")
        self.assertEqual(self.mod.classify_auth_json({"OPENAI_API_KEY": "key"}), "api_key")

    def test_catalog_repair_prefers_complete_recent_catalog(self):
        weak = {"models": [catalog_entry("gpt-5.6-sol", ("high",))]}
        strong = {"models": [catalog_entry(
            "gpt-5.6-sol", ("low", "medium", "high", "xhigh", "max", "ultra"), "max"
        )]}
        weak_path = self.mod.CODEX_HOME / "weak-models.json"
        weak_path.write_text(json.dumps(weak), encoding="utf-8")
        strong_path = self.mod.CODEX_HOME / "models-strong.json"
        strong_path.write_text(json.dumps(strong), encoding="utf-8")
        repaired, changes = self.mod.repair_model_catalog_reference(
            f'model = "gpt-5.6-sol"\nmodel_catalog_json = {json.dumps(str(weak_path))}\n'
        )
        self.assertEqual(self.mod.load_minimal_toml(repaired)["model_catalog_json"], str(strong_path))
        self.assertTrue(changes)

    def test_catalog_repair_rejects_empty_and_untrusted_catalogs(self):
        empty_path = self.mod.CODEX_HOME / "models-empty.json"
        empty_path.write_text(
            json.dumps({"models": [catalog_entry("gpt-5.6-sol", tuple())]}), encoding="utf-8"
        )
        fake_path = self.mod.CODEX_HOME / "unrelated.json"
        fake_path.write_text(
            json.dumps({"models": [catalog_entry(
                "gpt-5.6-sol", ("low", "medium", "high", "xhigh", "max", "ultra"), "ultra"
            )]}),
            encoding="utf-8",
        )
        valid_path = self.mod.CODEX_HOME / "valid-models.json"
        valid_path.write_text(
            json.dumps({"models": [catalog_entry("gpt-5.6-sol", ("high", "max"), "max")]}),
            encoding="utf-8",
        )
        repaired, _ = self.mod.repair_model_catalog_reference(
            f'model = "gpt-5.6-sol"\nmodel_catalog_json = {json.dumps(str(empty_path))}\n'
        )
        self.assertEqual(self.mod.load_minimal_toml(repaired)["model_catalog_json"], str(valid_path))

    def test_reasoning_uses_repaired_catalog_capabilities(self):
        path = self.mod.CODEX_HOME / "custom-models.json"
        path.write_text(
            json.dumps({"models": [catalog_entry("custom-reasoner", ("low", "medium"), "medium")]}),
            encoding="utf-8",
        )
        text = (
            f'model = "custom-reasoner"\nmodel_catalog_json = {json.dumps(str(path))}\n'
            'model_reasoning_effort = "ultra"\n'
        )
        repaired, changes = self.mod.normalize_model_reasoning_effort(text)
        self.assertEqual(self.mod.top_level_toml_value(repaired, "model_reasoning_effort"), "medium")
        self.assertEqual(self.mod.top_level_toml_value(repaired, "model_catalog_json"), str(path))
        self.assertTrue(changes)

    def test_incomplete_catalog_does_not_downgrade_valid_known_effort(self):
        path = self.mod.CODEX_HOME / "weak-models.json"
        path.write_text(
            json.dumps({"models": [catalog_entry("gpt-5.6-sol", ("high",), "high")]}),
            encoding="utf-8",
        )
        text = (
            f'model = "gpt-5.6-sol"\nmodel_catalog_json = {json.dumps(str(path))}\n'
            'model_reasoning_effort = "ultra"\n'
        )
        self.assertEqual(self.mod.normalize_model_reasoning_effort(text), (text, []))

    def test_configured_untrusted_catalog_is_replaced(self):
        fake_path = self.mod.CODEX_HOME / "notes.json"
        valid_path = self.mod.CODEX_HOME / "valid-models.json"
        payload = {"models": [catalog_entry("gpt-5.6-sol", ("high", "max"), "max")]}
        fake_path.write_text(json.dumps(payload), encoding="utf-8")
        valid_path.write_text(json.dumps(payload), encoding="utf-8")
        repaired, changes = self.mod.repair_model_catalog_reference(
            f'model = "gpt-5.6-sol"\nmodel_catalog_json = {json.dumps(str(fake_path))}\n'
        )
        self.assertEqual(self.mod.top_level_toml_value(repaired, "model_catalog_json"), str(valid_path))
        self.assertTrue(changes)

    def test_valid_current_catalog_for_unknown_model_is_not_replaced(self):
        current = self.mod.CODEX_HOME / "current-models.json"
        other = self.mod.CODEX_HOME / "other-models.json"
        current.write_text(
            json.dumps({"models": [catalog_entry("custom-model", ("medium",), "medium")]}),
            encoding="utf-8",
        )
        other.write_text(
            json.dumps({"models": [catalog_entry("custom-model", ("low", "medium", "high"), "medium")]}),
            encoding="utf-8",
        )
        text = f'model = "custom-model"\nmodel_catalog_json = {json.dumps(str(current))}\n'
        self.assertEqual(self.mod.repair_model_catalog_reference(text), (text, []))

    def test_auto_public_source_rejects_truncated_live_config(self):
        create_db(self.mod)
        self.mod.LIVE_CONFIG.write_text(
            'model = "gpt-5.6-sol"\napproval_policy = "never"\n', encoding="utf-8"
        )
        conn = self.mod.connect_db()
        try:
            source, label = self.mod.choose_public_source(conn, "auto")
        finally:
            conn.close()
        self.assertEqual(source, 'approval_policy = "never"\n')
        self.assertIn(self.mod.SETTING_CANONICAL, label)

    def test_sync_live_rejects_truncated_public_config(self):
        create_db(self.mod)
        self.mod.LIVE_CONFIG.write_text('approval_policy = "never"\n', encoding="utf-8")
        conn = self.mod.connect_db()
        try:
            with self.assertRaises(SystemExit):
                self.mod.choose_public_source(conn, "live")
        finally:
            conn.close()

    def test_sync_rejects_state_changed_during_process_stop(self):
        create_db(self.mod)
        original = (
            'approval_policy = "never"\nsandbox_mode = "danger-full-access"\n\n'
            '[desktop]\nfollowUpQueueMode = "steer"\n\n[features]\napps = false\n'
        )
        changed = original.replace("apps = false", "apps = true")
        self.mod.LIVE_CONFIG.write_text(original, encoding="utf-8")

        def mutate_while_stopping():
            self.mod.LIVE_CONFIG.write_text(changed, encoding="utf-8")
            return []

        self.mod.stop_cc_switch_for_write = mutate_while_stopping
        self.mod.restart_cc_switch = lambda paths: None
        with self.assertRaises(SystemExit):
            self.mod.sync_public_config("live")
        self.assertEqual(self.mod.LIVE_CONFIG.read_text(encoding="utf-8"), changed)

    def test_all_runs_auth_before_runtime_and_sync(self):
        order = []
        self.mod.status = lambda: order.append("status") or 0
        self.mod.auto_auth = lambda dry_run=False: order.append("auth") or 0
        self.mod.repair_runtime = lambda dry_run=False: order.append("runtime") or 0
        self.mod.sync_public_config = lambda source, dry_run=False: order.append("sync") or 0
        self.assertEqual(self.mod.all_in_one(dry_run=True), 0)
        self.assertEqual(order, ["status", "auth", "sync", "runtime"])

    def test_auto_auth_never_restores_implicitly(self):
        create_db(self.mod)
        self.mod.AUTH_JSON.write_text(json.dumps({"OPENAI_API_KEY": "fixture-key"}), encoding="utf-8")
        self.mod.restore_official_auth = lambda *args, **kwargs: self.fail("restore must not be called")
        self.assertEqual(self.mod.auto_auth(), 2)

    def test_all_stops_before_writes_when_live_auth_is_not_official(self):
        create_db(self.mod)
        self.mod.AUTH_JSON.write_text(json.dumps({"OPENAI_API_KEY": "fixture-key"}), encoding="utf-8")
        order = []
        self.mod.status = lambda: order.append("status") or 0
        self.mod.repair_runtime = lambda dry_run=False: self.fail("runtime must not run")
        self.mod.sync_public_config = lambda *args, **kwargs: self.fail("sync must not run")
        self.assertEqual(self.mod.all_in_one(), 2)
        self.assertEqual(order, ["status"])

    def test_capture_updates_all_restore_references_while_process_is_stopped(self):
        old = official_auth("old", "2026-07-04T00:00:00Z")
        live = official_auth("new", "2026-07-19T00:00:00Z")
        live["OPENAI_API_KEY"] = None
        create_db(self.mod, old)
        self.mod.LIVE_CONFIG.write_text('model = "gpt-5.6-sol"\n', encoding="utf-8")
        self.mod.AUTH_JSON.write_text(json.dumps(live), encoding="utf-8")
        order = []
        self.mod.stop_cc_switch_for_write = lambda: order.append("stop") or []
        self.mod.restart_cc_switch = lambda paths: order.append("restart")
        self.assertEqual(self.mod.capture_official_auth(), 0)
        self.assertEqual(order, ["stop", "restart"])
        conn = sqlite3.connect(self.mod.CCSWITCH_DB)
        saved = json.loads(
            conn.execute("SELECT value FROM settings WHERE key=?", (self.mod.SETTING_OFFICIAL_AUTH,)).fetchone()[0]
        )
        provider = json.loads(
            conn.execute("SELECT settings_config FROM providers WHERE id='codex-official'").fetchone()[0]
        )["auth"]
        proxy = json.loads(
            conn.execute("SELECT original_config FROM proxy_live_backup WHERE app_type='codex'").fetchone()[0]
        )["auth"]
        conn.close()
        self.assertNotIn("OPENAI_API_KEY", saved)
        self.assertEqual(saved, provider)
        self.assertEqual(saved, proxy)
        self.assertEqual(saved["last_refresh"], live["last_refresh"])

    def test_equivalent_compact_auth_json_does_not_trigger_capture(self):
        auth = official_auth("same")
        create_db(self.mod, auth)
        self.mod.AUTH_JSON.write_text(json.dumps(auth, indent=2) + "\n", encoding="utf-8")
        self.mod.stop_cc_switch_for_write = lambda: self.fail("no write should be needed")
        self.assertEqual(self.mod.capture_official_auth(), 0)

    def test_null_api_key_in_auth_references_does_not_trigger_rewrite(self):
        auth = official_auth("same")
        create_db(self.mod, auth)
        conn = self.mod.connect_db()
        try:
            provider = json.loads(
                conn.execute("SELECT settings_config FROM providers WHERE id='codex-official'").fetchone()[0]
            )
            provider["auth"]["OPENAI_API_KEY"] = None
            proxy = json.loads(
                conn.execute("SELECT original_config FROM proxy_live_backup WHERE app_type='codex'").fetchone()[0]
            )
            proxy["auth"]["OPENAI_API_KEY"] = None
            conn.execute("UPDATE providers SET settings_config=? WHERE id='codex-official'", (json.dumps(provider),))
            conn.execute("UPDATE proxy_live_backup SET original_config=? WHERE app_type='codex'", (json.dumps(proxy),))
            conn.commit()
            changes = self.mod.repair_official_auth_references(conn, json.dumps(auth), dry_run=True)
        finally:
            conn.close()
        self.assertEqual(changes, [])

    def test_capture_preserves_live_public_state_in_proxy_recovery_snapshot(self):
        auth = official_auth("same")
        create_db(self.mod, auth)
        self.mod.AUTH_JSON.write_text(json.dumps(auth), encoding="utf-8")
        self.mod.LIVE_CONFIG.write_text(
            'model = "gpt-5.6-sol"\napproval_policy = "never"\n'
            'sandbox_mode = "danger-full-access"\n\n[desktop]\nfollowUpQueueMode = "steer"\n\n'
            '[features]\napps = false\n\n[hooks.state."current"]\n'
            'trusted_hash = "sha256:current"\n',
            encoding="utf-8",
        )
        self.mod.stop_cc_switch_for_write = lambda: []
        self.mod.restart_cc_switch = lambda paths: None
        self.assertEqual(self.mod.capture_official_auth(), 0)
        conn = sqlite3.connect(self.mod.CCSWITCH_DB)
        proxy = json.loads(
            conn.execute("SELECT original_config FROM proxy_live_backup WHERE app_type='codex'").fetchone()[0]
        )
        conn.close()
        self.assertIn("apps = false", proxy["config"])
        self.assertIn('[hooks.state."current"]', proxy["config"])

    def test_capture_refuses_older_live_and_force_allows_it(self):
        newer = official_auth("newer", "2026-07-20T00:00:00Z")
        older = official_auth("older", "2026-07-19T00:00:00Z")
        create_db(self.mod, newer)
        self.mod.AUTH_JSON.write_text(json.dumps(older), encoding="utf-8")
        with self.assertRaises(SystemExit):
            self.mod.capture_official_auth()

        self.mod.stop_cc_switch_for_write = lambda: []
        self.mod.restart_cc_switch = lambda paths: None
        self.assertEqual(self.mod.capture_official_auth(force=True), 0)
        conn = sqlite3.connect(self.mod.CCSWITCH_DB)
        saved = json.loads(
            conn.execute("SELECT value FROM settings WHERE key=?", (self.mod.SETTING_OFFICIAL_AUTH,)).fetchone()[0]
        )
        conn.close()
        self.assertEqual(saved["last_refresh"], older["last_refresh"])

    def test_capture_refuses_same_timestamp_with_different_tokens(self):
        create_db(self.mod, official_auth("db", "2026-07-19T00:00:00Z"))
        self.mod.AUTH_JSON.write_text(
            json.dumps(official_auth("live", "2026-07-19T00:00:00Z")), encoding="utf-8"
        )
        with self.assertRaises(SystemExit):
            self.mod.capture_official_auth()

    def test_restore_refuses_to_overwrite_different_live_official_auth(self):
        create_db(self.mod, official_auth("old", "2026-07-04T00:00:00Z"))
        self.mod.AUTH_JSON.write_text(
            json.dumps(official_auth("new", "2026-07-19T00:00:00Z")), encoding="utf-8"
        )
        with self.assertRaises(SystemExit):
            self.mod.restore_official_auth()

    def test_restore_repairs_references_without_rewriting_matching_live_auth(self):
        auth = official_auth("same")
        create_db(self.mod, auth)
        self.mod.AUTH_JSON.write_text(json.dumps(auth), encoding="utf-8")
        before = self.mod.AUTH_JSON.read_bytes()
        conn = sqlite3.connect(self.mod.CCSWITCH_DB)
        provider = json.loads(
            conn.execute("SELECT settings_config FROM providers WHERE id='codex-official'").fetchone()[0]
        )
        provider["auth"] = official_auth("stale", "2026-07-01T00:00:00Z")
        conn.execute(
            "UPDATE providers SET settings_config=? WHERE id='codex-official'",
            (json.dumps(provider),),
        )
        conn.commit()
        conn.close()
        self.mod.stop_cc_switch_for_write = lambda: []
        self.mod.restart_cc_switch = lambda paths: None
        writes = []
        original_write = self.mod.write_text

        def recording_write(path, text):
            writes.append(path)
            return original_write(path, text)

        self.mod.write_text = recording_write
        self.assertEqual(self.mod.restore_official_auth(), 0)
        self.assertEqual(self.mod.AUTH_JSON.read_bytes(), before)
        self.assertNotIn(self.mod.AUTH_JSON, writes)

    def test_restore_rejects_expired_backup_unless_forced(self):
        expired = official_auth("expired")
        expired["tokens"]["access_token"] = jwt_with_expiry(
            dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=1)
        )
        create_db(self.mod, expired)
        self.mod.AUTH_JSON.write_text(json.dumps({"OPENAI_API_KEY": "fixture-key"}), encoding="utf-8")
        with self.assertRaises(SystemExit):
            self.mod.restore_official_auth()
        self.mod.stop_cc_switch_for_write = lambda: []
        self.mod.restart_cc_switch = lambda paths: None
        self.assertEqual(self.mod.restore_official_auth(force=True), 0)
        self.assertEqual(self.mod.classify_auth_json(self.mod.read_auth_file()), "official")

    def test_restore_rolls_back_database_when_live_file_write_fails(self):
        auth = official_auth("backup")
        create_db(self.mod, auth)
        self.mod.AUTH_JSON.write_text(json.dumps({"OPENAI_API_KEY": "fixture-key"}), encoding="utf-8")
        conn = sqlite3.connect(self.mod.CCSWITCH_DB)
        provider = json.loads(
            conn.execute("SELECT settings_config FROM providers WHERE id='codex-official'").fetchone()[0]
        )
        provider["auth"] = {"OPENAI_API_KEY": "old-provider-key"}
        conn.execute("UPDATE providers SET settings_config=? WHERE id='codex-official'", (json.dumps(provider),))
        conn.commit()
        conn.close()
        self.mod.stop_cc_switch_for_write = lambda: []
        self.mod.restart_cc_switch = lambda paths: None
        original_write = self.mod.write_text
        failed = False

        def fail_live_once(path, text):
            nonlocal failed
            if path == self.mod.AUTH_JSON and not failed:
                failed = True
                raise OSError("injected auth write failure")
            return original_write(path, text)

        self.mod.write_text = fail_live_once
        with self.assertRaises(OSError):
            self.mod.restore_official_auth(force=True)
        conn = sqlite3.connect(self.mod.CCSWITCH_DB)
        restored_provider = json.loads(
            conn.execute("SELECT settings_config FROM providers WHERE id='codex-official'").fetchone()[0]
        )
        conn.close()
        self.assertEqual(restored_provider["auth"], {"OPENAI_API_KEY": "old-provider-key"})
        self.assertEqual(self.mod.read_auth_file(), {"OPENAI_API_KEY": "fixture-key"})

    def test_empty_live_local_state_clears_stale_provider_state(self):
        target = """model = \"gpt-5.6-sol\"

[projects.'c:\\stale']
trust_level = \"trusted\"

[hooks.state.\"stale\"]
trusted_hash = \"sha256:stale\"
"""
        merged, changes = self.mod.merge_local_shared_tables(target, 'approval_policy = "never"\n')
        self.assertNotIn("projects", merged)
        self.assertNotIn("hooks.state", merged)
        self.assertTrue(changes)

    def test_status_reports_live_newer_auth_drift(self):
        old = official_auth("old", "2026-07-04T00:00:00Z")
        live = official_auth("new", "2026-07-19T00:00:00Z")
        text = self.mod.describe_auth_drift(live, json.dumps(old))
        self.assertIn("DRIFT", text)
        self.assertIn("live newer", text)


    def test_restart_snapshot_captures_live_model_policy_keeps_routing(self):
        target = chr(10).join([
            'model = "grok-4.5"',
            'model_provider = "old-provider"',
            'model_reasoning_effort = "high"',
            'model_catalog_json = "old-models.json"',
            'service_tier = "default"',
            '',
            '[features]',
            'apps = true',
            '',
            '[model_providers.old-provider]',
            'name = "Old"',
            'base_url = "https://old.example/v1"',
            'experimental_bearer_token = "old-secret"',
            '',
        ])
        live = healthy_live_config(
            model='gpt-5.6-sol',
            effort='max',
            catalog='new-models.json',
            service_tier='priority',
            model_provider='custom',
        )
        merged, changes = self.mod.merge_live_state_for_restart(
            target,
            live,
            include_provider_policy=True,
        )
        self.assertIn('model = "gpt-5.6-sol"', merged)
        self.assertIn('model_reasoning_effort = "max"', merged)
        self.assertIn('model_catalog_json = "new-models.json"', merged)
        self.assertIn('service_tier = "priority"', merged)
        self.assertIn('personality = "pragmatic"', merged)
        self.assertIn('model_verbosity = "high"', merged)
        self.assertIn('model_provider = "old-provider"', merged)
        self.assertIn('[model_providers.old-provider]', merged)
        self.assertIn('experimental_bearer_token = "old-secret"', merged)
        self.assertNotIn('[model_providers.custom]', merged)
        self.assertIn('apps = false', merged)
        self.assertIn('~ current provider model policy', changes)

    def test_current_provider_policy_capture_follows_live_model_fields(self):
        target = chr(10).join([
            'model = "grok-4.5"',
            'model_provider = "proxy-a"',
            'model_reasoning_effort = "medium"',
            'model_catalog_json = "provider-a.json"',
            'service_tier = "default"',
            'personality = "friendly"',
            'plan_mode_reasoning_effort = "low"',
            'model_verbosity = "low"',
            '',
            '[features]',
            'apps = true',
            '',
        ])
        live = healthy_live_config(
            model='gpt-5.6-terra',
            effort='ultra',
            catalog='live-catalog.json',
            service_tier='priority',
            model_provider='should-not-copy',
        )
        merged, changes = self.mod.merge_current_provider_policy(target, live)
        self.assertEqual(changes, ['~ current provider model policy'])
        self.assertEqual(self.mod.top_level_toml_value(merged, 'model'), 'gpt-5.6-terra')
        self.assertEqual(self.mod.top_level_toml_value(merged, 'model_reasoning_effort'), 'ultra')
        self.assertEqual(self.mod.top_level_toml_value(merged, 'model_catalog_json'), 'live-catalog.json')
        self.assertEqual(self.mod.top_level_toml_value(merged, 'service_tier'), 'priority')
        self.assertEqual(self.mod.top_level_toml_value(merged, 'personality'), 'pragmatic')
        self.assertEqual(self.mod.top_level_toml_value(merged, 'plan_mode_reasoning_effort'), 'high')
        self.assertEqual(self.mod.top_level_toml_value(merged, 'model_verbosity'), 'high')
        self.assertEqual(self.mod.top_level_toml_value(merged, 'model_provider'), 'proxy-a')
        self.assertIn('[features]', merged)

    def test_current_provider_policy_capture_preserves_model_providers_and_auth_material(self):
        target = chr(10).join([
            'model = "old"',
            'model_provider = "proxy-a"',
            'model_reasoning_effort = "high"',
            'experimental_bearer_token = "provider-token"',
            '',
            '[model_providers.proxy-a]',
            'name = "Proxy A"',
            'base_url = "https://proxy-a.example/v1"',
            'experimental_bearer_token = "table-token"',
            'OPENAI_API_KEY = "provider-table-key"',
            '',
        ])
        live = healthy_live_config(model_provider='custom')
        merged, changes = self.mod.merge_current_provider_policy(target, live)
        self.assertTrue(changes)
        self.assertEqual(self.mod.top_level_toml_value(merged, 'model_provider'), 'proxy-a')
        self.assertIn('[model_providers.proxy-a]', merged)
        self.assertIn('experimental_bearer_token = "table-token"', merged)
        self.assertIn('OPENAI_API_KEY = "provider-table-key"', merged)
        self.assertIn('experimental_bearer_token = "provider-token"', merged)
        self.assertNotIn('[model_providers.custom]', merged)
        self.assertNotIn('live-secret', merged)
        self.assertNotIn('base_url = "https://example.invalid/v1"', merged)

    def test_current_provider_policy_capture_skips_unhealthy_live_without_model(self):
        target = chr(10).join([
            'model = "grok-4.5"',
            'model_reasoning_effort = "high"',
            'model_catalog_json = "keep-me.json"',
            '',
        ])
        unhealthy = chr(10).join([
            'approval_policy = "never"',
            'sandbox_mode = "danger-full-access"',
            'model_reasoning_effort = "max"',
            'service_tier = "priority"',
            '',
        ])
        self.assertEqual(self.mod.merge_current_provider_policy(target, unhealthy), (target, []))

    def test_current_provider_policy_capture_only_updates_current_provider_in_sandbox_db(self):
        auth = official_auth('shared')
        create_db(self.mod, auth)
        current_config = chr(10).join([
            'model = "grok-4.5"',
            'model_provider = "proxy-a"',
            'model_reasoning_effort = "medium"',
            'model_catalog_json = "provider-a.json"',
            'service_tier = "default"',
            '',
            '[model_providers.proxy-a]',
            'name = "Proxy A"',
            'base_url = "https://proxy-a.example/v1"',
            'experimental_bearer_token = "proxy-a-secret"',
            '',
        ])
        other_config = chr(10).join([
            'model = "gpt-5.5"',
            'model_provider = "proxy-b"',
            'model_reasoning_effort = "xhigh"',
            'model_catalog_json = "provider-b.json"',
            'service_tier = "default"',
            '',
            '[model_providers.proxy-b]',
            'name = "Proxy B"',
            'base_url = "https://proxy-b.example/v1"',
            'experimental_bearer_token = "proxy-b-secret"',
            '',
        ])
        conn = sqlite3.connect(self.mod.CCSWITCH_DB)
        conn.execute(
            'INSERT INTO providers VALUES(?,?,?,?,?,?,?,?)',
            provider_row(
                'provider-a', 'Proxy A', current_config, {'OPENAI_API_KEY': 'key-a'}, is_current=1, sort_index=1
            ),
        )
        conn.execute(
            'INSERT INTO providers VALUES(?,?,?,?,?,?,?,?)',
            provider_row(
                'provider-b', 'Proxy B', other_config, {'OPENAI_API_KEY': 'key-b'}, is_current=0, sort_index=2
            ),
        )
        conn.commit()
        conn.close()
        live = healthy_live_config(
            model='gpt-5.6-sol', effort='max', catalog='captured-models.json',
            service_tier='priority', model_provider='custom',
        )
        self.mod.LIVE_CONFIG.write_text(live, encoding='utf-8')
        self.mod.CCSWITCH_SETTINGS.write_text(json.dumps({'currentProviderCodex': 'provider-a'}), encoding='utf-8')
        conn = self.mod.connect_db()
        try:
            q = "SELECT id, settings_config FROM providers WHERE app_type='codex' ORDER BY sort_index, created_at"
            rows = conn.execute(q).fetchall()
            current_id = self.mod.get_current_codex_provider_summary(conn).get('id')
            self.assertEqual(current_id, 'provider-a')
            for row in rows:
                settings = self.mod.read_json_object(row['settings_config'], 'provider:' + row['id'])
                old_config = settings.get('config') if isinstance(settings.get('config'), str) else ''
                if row['id'] != current_id:
                    continue
                new_config, changes = self.mod.merge_current_provider_policy(old_config, live)
                self.assertTrue(changes)
                settings['config'] = new_config
                conn.execute(
                    "UPDATE providers SET settings_config=? WHERE id=? AND app_type='codex'",
                    (json.dumps(settings, ensure_ascii=False), row['id']),
                )
            conn.commit()
        finally:
            conn.close()
        conn = sqlite3.connect(self.mod.CCSWITCH_DB)
        current = json.loads(conn.execute("SELECT settings_config FROM providers WHERE id='provider-a'").fetchone()[0])
        other = json.loads(conn.execute("SELECT settings_config FROM providers WHERE id='provider-b'").fetchone()[0])
        official = json.loads(conn.execute("SELECT settings_config FROM providers WHERE id='codex-official'").fetchone()[0])
        conn.close()
        current_cfg = current['config']
        other_cfg = other['config']
        self.assertEqual(self.mod.top_level_toml_value(current_cfg, 'model'), 'gpt-5.6-sol')
        self.assertEqual(self.mod.top_level_toml_value(current_cfg, 'model_reasoning_effort'), 'max')
        self.assertEqual(self.mod.top_level_toml_value(current_cfg, 'model_catalog_json'), 'captured-models.json')
        self.assertEqual(self.mod.top_level_toml_value(current_cfg, 'service_tier'), 'priority')
        self.assertEqual(self.mod.top_level_toml_value(current_cfg, 'model_provider'), 'proxy-a')
        self.assertIn('[model_providers.proxy-a]', current_cfg)
        self.assertIn('experimental_bearer_token = "proxy-a-secret"', current_cfg)
        self.assertEqual(current['auth'], {'OPENAI_API_KEY': 'key-a'})
        self.assertEqual(other_cfg, other_config)
        self.assertEqual(other['auth'], {'OPENAI_API_KEY': 'key-b'})
        self.assertEqual(self.mod.top_level_toml_value(other_cfg, 'model'), 'gpt-5.5')
        self.assertEqual(self.mod.top_level_toml_value(other_cfg, 'model_reasoning_effort'), 'xhigh')
        self.assertIn('experimental_bearer_token = "proxy-b-secret"', other_cfg)
        self.assertEqual(official['auth']['tokens']['access_token'], 'access-shared')
        self.assertIn('model_reasoning_effort = "xhigh"', official['config'])

    def test_collect_template_repairs_applies_live_policy_only_to_current_provider(self):
        auth = official_auth("shared")
        create_db(self.mod, auth)
        current_config = chr(10).join([
            'model = "grok-4.5"',
            'model_provider = "proxy-a"',
            'model_reasoning_effort = "medium"',
            'model_catalog_json = "provider-a.json"',
            'service_tier = "default"',
            '',
            '[model_providers.proxy-a]',
            'base_url = "https://proxy-a.example/v1"',
            'experimental_bearer_token = "proxy-a-secret"',
            '',
        ])
        other_config = chr(10).join([
            'model = "gpt-5.5"',
            'model_provider = "proxy-b"',
            'model_reasoning_effort = "xhigh"',
            'model_catalog_json = "provider-b.json"',
            'service_tier = "default"',
            '',
            '[model_providers.proxy-b]',
            'base_url = "https://proxy-b.example/v1"',
            'experimental_bearer_token = "proxy-b-secret"',
            '',
        ])
        conn = sqlite3.connect(self.mod.CCSWITCH_DB)
        conn.execute(
            "INSERT INTO providers VALUES(?,?,?,?,?,?,?,?)",
            provider_row(
                "provider-a",
                "Proxy A",
                current_config,
                {"OPENAI_API_KEY": "key-a"},
                is_current=1,
                sort_index=1,
            ),
        )
        conn.execute(
            "INSERT INTO providers VALUES(?,?,?,?,?,?,?,?)",
            provider_row(
                "provider-b",
                "Proxy B",
                other_config,
                {"OPENAI_API_KEY": "key-b"},
                sort_index=2,
            ),
        )
        conn.commit()
        conn.close()
        live = healthy_live_config(
            model="gpt-5.6-sol",
            effort="max",
            catalog="captured-models.json",
            service_tier="priority",
        )
        self.mod.CCSWITCH_SETTINGS.write_text(
            json.dumps({"currentProviderCodex": "provider-a"}),
            encoding="utf-8",
        )
        conn = self.mod.connect_db()
        try:
            current_id, policy_source = self.mod.prepare_current_provider_policy_source(conn, live)
            updates, proxy_update = self.mod.collect_template_repairs(
                conn,
                self.mod.extract_public_config(live),
                live,
                {},
                current_provider_id_value=current_id,
                current_policy_text=policy_source,
            )
        finally:
            conn.close()
        by_id = {
            provider_id: json.loads(settings_text)
            for provider_id, _name, settings_text, _meta, _changes in updates
        }
        current = by_id["provider-a"]
        other = by_id["provider-b"]
        self.assertEqual(current["auth"], {"OPENAI_API_KEY": "key-a"})
        self.assertEqual(self.mod.top_level_toml_value(current["config"], "model"), "gpt-5.6-sol")
        self.assertEqual(self.mod.top_level_toml_value(current["config"], "model_reasoning_effort"), "max")
        self.assertEqual(self.mod.top_level_toml_value(current["config"], "service_tier"), "priority")
        self.assertEqual(self.mod.top_level_toml_value(current["config"], "model_provider"), "proxy-a")
        self.assertIn("proxy-a-secret", current["config"])
        self.assertNotIn("live-secret", current["config"])
        self.assertEqual(other["auth"], {"OPENAI_API_KEY": "key-b"})
        self.assertEqual(self.mod.top_level_toml_value(other["config"], "model"), "gpt-5.5")
        self.assertEqual(self.mod.top_level_toml_value(other["config"], "model_reasoning_effort"), "xhigh")
        self.assertEqual(self.mod.top_level_toml_value(other["config"], "model_provider"), "proxy-b")
        self.assertIn("proxy-b-secret", other["config"])
        self.assertIsNotNone(proxy_update)
        proxy_config = json.loads(proxy_update[0])["config"]
        self.assertEqual(self.mod.top_level_toml_value(proxy_config, "model"), "gpt-5.6-sol")
        self.assertEqual(self.mod.top_level_toml_value(proxy_config, "model_reasoning_effort"), "max")

    def test_capture_auth_also_persists_config_only_edit_before_restart(self):
        auth = official_auth("same")
        create_db(self.mod, auth)
        provider_config = chr(10).join([
            'model = "grok-4.5"',
            'model_provider = "proxy-a"',
            'model_reasoning_effort = "medium"',
            '',
            '[model_providers.proxy-a]',
            'base_url = "https://proxy-a.example/v1"',
            'experimental_bearer_token = "provider-secret"',
            '',
        ])
        conn = sqlite3.connect(self.mod.CCSWITCH_DB)
        conn.execute(
            "INSERT INTO providers VALUES(?,?,?,?,?,?,?,?)",
            provider_row(
                "provider-a",
                "Proxy A",
                provider_config,
                {"OPENAI_API_KEY": "key-a"},
                is_current=1,
                sort_index=1,
            ),
        )
        conn.commit()
        conn.close()
        self.mod.CCSWITCH_SETTINGS.write_text(
            json.dumps({"currentProviderCodex": "provider-a"}),
            encoding="utf-8",
        )
        self.mod.AUTH_JSON.write_text(json.dumps(auth), encoding="utf-8")
        self.mod.LIVE_CONFIG.write_text(
            healthy_live_config(model="gpt-5.6-sol", effort="ultra", service_tier="priority"),
            encoding="utf-8",
        )
        calls = []
        self.mod.stop_cc_switch_for_write = lambda: calls.append("stop") or []
        self.mod.restart_cc_switch = lambda paths: calls.append("restart")
        self.assertEqual(self.mod.capture_official_auth(), 0)
        self.assertEqual(calls, ["stop", "restart"])
        conn = sqlite3.connect(self.mod.CCSWITCH_DB)
        current = json.loads(
            conn.execute("SELECT settings_config FROM providers WHERE id='provider-a'").fetchone()[0]
        )
        proxy = json.loads(
            conn.execute("SELECT original_config FROM proxy_live_backup WHERE app_type='codex'").fetchone()[0]
        )
        conn.close()
        self.assertEqual(current["auth"], {"OPENAI_API_KEY": "key-a"})
        self.assertEqual(self.mod.top_level_toml_value(current["config"], "model"), "gpt-5.6-sol")
        self.assertEqual(self.mod.top_level_toml_value(current["config"], "model_reasoning_effort"), "ultra")
        self.assertEqual(self.mod.top_level_toml_value(current["config"], "model_provider"), "proxy-a")
        self.assertIn("provider-secret", current["config"])
        self.assertEqual(self.mod.top_level_toml_value(proxy["config"], "model"), "gpt-5.6-sol")
        self.assertEqual(self.mod.top_level_toml_value(proxy["config"], "model_reasoning_effort"), "ultra")

    def test_current_provider_policy_upsert_keeps_missing_target_policy(self):
        target = (
            'model = "grok-4.5"\nmodel_reasoning_effort = "high"\n'
            'model_catalog_json = "keep-models.json"\nservice_tier = "default"\n'
        )
        live = 'model = "gpt-5.6-sol"\nmodel_reasoning_effort = "max"\n'
        merged, changes = self.mod.merge_current_provider_policy(target, live)
        self.assertTrue(changes)
        self.assertEqual(self.mod.top_level_toml_value(merged, "model"), "gpt-5.6-sol")
        self.assertEqual(self.mod.top_level_toml_value(merged, "model_reasoning_effort"), "max")
        self.assertEqual(self.mod.top_level_toml_value(merged, "model_catalog_json"), "keep-models.json")
        self.assertEqual(self.mod.top_level_toml_value(merged, "service_tier"), "default")

    def test_proxy_snapshot_guard_requires_enabled_non_placeholder_backup(self):
        create_db(self.mod)
        conn = self.mod.connect_db()
        try:
            normal = {
                "config": (
                    '[shell_environment_policy.set]\nNO_PROXY = "127.0.0.1,localhost"\n\n'
                    '[model_providers.custom]\nbase_url = "https://upstream.example/v1"\n'
                )
            }
            self.assertTrue(self.mod.proxy_backup_config_patch_allowed(conn, normal))
            placeholder = {"config": '[model_providers.custom]\nbase_url = "http://127.0.0.1:15721/v1"\n'}
            self.assertFalse(self.mod.proxy_backup_config_patch_allowed(conn, placeholder))
            conn.execute("UPDATE proxy_config SET enabled=0, proxy_enabled=0 WHERE app_type='codex'")
            self.assertFalse(self.mod.proxy_backup_config_patch_allowed(conn, normal))
        finally:
            conn.close()

    def test_current_provider_resolution_prefers_valid_settings_and_fails_closed_on_ambiguity(self):
        create_db(self.mod)
        conn = sqlite3.connect(self.mod.CCSWITCH_DB)
        conn.execute(
            "INSERT INTO providers VALUES(?,?,?,?,?,?,?,?)",
            provider_row("provider-a", "A", 'model = "gpt-5.6-sol"\n', is_current=1, sort_index=1),
        )
        conn.execute(
            "INSERT INTO providers VALUES(?,?,?,?,?,?,?,?)",
            provider_row("provider-b", "B", 'model = "grok-4.5"\n', is_current=0, sort_index=2),
        )
        conn.commit()
        conn.close()
        self.mod.CCSWITCH_SETTINGS.write_text(
            json.dumps({"currentProviderCodex": "provider-b"}),
            encoding="utf-8",
        )
        conn = self.mod.connect_db()
        try:
            self.assertEqual(self.mod.current_codex_provider_id(conn), "provider-b")
            conn.execute("UPDATE providers SET is_current=1 WHERE id='provider-b'")
            self.mod.CCSWITCH_SETTINGS.unlink()
            self.assertEqual(self.mod.current_codex_provider_id(conn), "")
        finally:
            conn.close()

    def test_inline_model_catalog_snapshot_does_not_receive_catalog_pointer(self):
        create_db(self.mod)
        conn = self.mod.connect_db()
        try:
            original = {
                "auth": official_auth("old"),
                "config": 'model = "grok-4.5"\nmodel_reasoning_effort = "high"\n',
                "modelCatalog": [{"slug": "gpt-5.6-sol"}],
            }
            conn.execute(
                "UPDATE proxy_live_backup SET original_config=? WHERE app_type='codex'",
                (json.dumps(original),),
            )
            conn.execute("UPDATE providers SET is_current=1 WHERE id='codex-official'")
            live = healthy_live_config(catalog="external-models.json")
            current_id, policy_source = self.mod.prepare_current_provider_policy_source(conn, live)
            _updates, proxy_update = self.mod.collect_template_repairs(
                conn,
                self.mod.extract_public_config(live),
                live,
                {},
                current_provider_id_value=current_id,
                current_policy_text=policy_source,
            )
        finally:
            conn.close()
        self.assertIsNotNone(proxy_update)
        proxy = json.loads(proxy_update[0])
        self.assertIn("modelCatalog", proxy)
        self.assertNotIn("model_catalog_json", proxy["config"])

    def test_unhealthy_live_public_config_is_not_used_as_auto_source(self):
        create_db(self.mod)
        self.mod.LIVE_CONFIG.write_text(
            chr(10).join([
                'model = "gpt-5.6-sol"',
                'model_reasoning_effort = "max"',
                'service_tier = "priority"',
                'approval_policy = "never"',
                '',
            ]),
            encoding='utf-8',
        )
        conn = self.mod.connect_db()
        try:
            source, label = self.mod.choose_public_source(conn, 'auto')
        finally:
            conn.close()
        self.assertEqual(source, 'approval_policy = "never"' + chr(10))
        self.assertIn(self.mod.SETTING_CANONICAL, label)
        self.assertNotIn('service_tier', source)
        self.assertNotIn('model_reasoning_effort', source)

    def test_atomic_write_leaves_no_temporary_file(self):
        path = self.home / "state.txt"
        self.mod.write_text(path, "first\n")
        self.mod.write_text(path, "second\n")
        self.assertEqual(path.read_text(encoding="utf-8"), "second\n")
        self.assertEqual(list(self.home.glob(".state.txt.tmp-*")), [])


if __name__ == "__main__":
    unittest.main()
