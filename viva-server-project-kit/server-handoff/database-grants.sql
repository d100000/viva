-- Run as viva_migrator after every schema migration set.
-- New tables must be added explicitly; CI must fail on unclassified grants.

BEGIN;
SET search_path TO viva, public;

REVOKE ALL ON SCHEMA viva FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA viva FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA viva FROM PUBLIC;

GRANT USAGE ON SCHEMA viva TO viva_api, viva_gateway, viva_worker;

-- Control plane and worker share the current modular-monolith data model, but
-- grants remain explicitly enumerated so every future table is fail-closed
-- until reviewed and added here.
GRANT SELECT, INSERT, UPDATE, DELETE ON
    users,
    user_identities,
    devices,
    refresh_token_families,
    refresh_tokens,
    auth_challenges,
    plans,
    plan_versions,
    subscriptions,
    billing_orders,
    billing_refunds,
    incoming_webhooks,
    provider_accounts,
    asr_sessions,
    llm_requests,
    usage_ledger,
    usage_counters,
    quota_adjustments,
    idempotency_keys,
    privacy_requests,
    diagnostic_reports,
    diagnostic_uploads,
    client_configs,
    admin_role_bindings,
    support_notes,
    audit_logs,
    transactional_outbox,
    provider_daily_reconciliation
TO viva_api, viva_worker;
GRANT USAGE, SELECT ON SEQUENCE usage_ledger_id_seq, audit_logs_id_seq
TO viva_api, viva_worker;
REVOKE UPDATE, DELETE ON usage_ledger, audit_logs FROM viva_api, viva_worker;

-- Realtime Gateway: no identity ciphertext, auth challenge, privacy, order,
-- refund, support-note or admin-role access. Column grants also keep plaintext
-- display names, encrypted device names and external billing IDs out of scope.
GRANT SELECT (id, account_type, status, token_version)
    ON users TO viva_gateway;
GRANT SELECT (
    id, user_id, key_thumbprint, public_jwk, assurance_level,
    app_version, protocol_version, status, last_seen_at, revoked_at
) ON devices TO viva_gateway;
GRANT SELECT (
    id, status, asr_audio_ms_limit, max_asr_concurrency, max_session_ms,
    allowed_model_tiers, features, effective_from, sales_end_at, retired_at
) ON plan_versions TO viva_gateway;
GRANT SELECT (
    user_id, plan_version_id, status, current_period_start,
    current_period_end, cancel_at_period_end
) ON subscriptions TO viva_gateway;
GRANT SELECT (
    id, provider, purpose, region, endpoint, resource_id, model_alias,
    secret_ref, secret_version, status, weight, max_concurrency,
    last_health_at, last_error_code
) ON provider_accounts TO viva_gateway;
GRANT SELECT ON usage_counters TO viva_gateway;
GRANT SELECT (user_id, resource, quantity, starts_at, expires_at)
    ON quota_adjustments TO viva_gateway;

GRANT SELECT, INSERT, UPDATE ON asr_sessions TO viva_gateway;
GRANT SELECT, INSERT, UPDATE ON usage_counters TO viva_gateway;
GRANT SELECT, INSERT ON usage_ledger TO viva_gateway;
GRANT INSERT ON audit_logs, transactional_outbox TO viva_gateway;
GRANT USAGE, SELECT ON SEQUENCE usage_ledger_id_seq, audit_logs_id_seq TO viva_gateway;

REVOKE UPDATE, DELETE ON usage_ledger, audit_logs FROM viva_gateway;

COMMIT;
