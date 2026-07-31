-- Local PostgreSQL bootstrap only.
-- Production creates these roles with IaC/DBA automation and injects four
-- independent credentials from Secret Manager. Never reuse these passwords.

\set ON_ERROR_STOP on

DO $do$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'viva_migrator') THEN
        EXECUTE 'CREATE ROLE viva_migrator LOGIN PASSWORD ''viva-migrator-local-only'' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'viva_api') THEN
        EXECUTE 'CREATE ROLE viva_api LOGIN PASSWORD ''viva-api-local-only'' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'viva_gateway') THEN
        EXECUTE 'CREATE ROLE viva_gateway LOGIN PASSWORD ''viva-gateway-local-only'' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'viva_worker') THEN
        EXECUTE 'CREATE ROLE viva_worker LOGIN PASSWORD ''viva-worker-local-only'' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION';
    END IF;
END
$do$;

ALTER ROLE viva_migrator SET search_path TO viva, public;
ALTER ROLE viva_api SET search_path TO viva, public;
ALTER ROLE viva_gateway SET search_path TO viva, public;
ALTER ROLE viva_worker SET search_path TO viva, public;

ALTER DATABASE viva OWNER TO viva_migrator;
REVOKE CONNECT ON DATABASE viva FROM PUBLIC;
GRANT CONNECT ON DATABASE viva TO viva_migrator, viva_api, viva_gateway, viva_worker;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
