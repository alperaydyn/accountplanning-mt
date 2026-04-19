-- ============================================================================
-- Account Planning — Repo Database (Separate DB)
-- ============================================================================
-- Description: Application-level settings, not tenant-scoped.
--              This script runs against the REPO database, not the main DB.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================================
-- repo.app_setting — Global application configuration
-- ============================================================================
CREATE TABLE IF NOT EXISTS app_setting (
    key             VARCHAR(255) PRIMARY KEY,
    value           JSONB NOT NULL,
    description     TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE app_setting IS 'Global application settings (key-value pairs)';

-- ============================================================================
-- repo.supported_module — Available feature modules
-- ============================================================================
CREATE TABLE IF NOT EXISTS supported_module (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    module_code     VARCHAR(100) NOT NULL UNIQUE,
    display_name    VARCHAR(255) NOT NULL,
    description     TEXT,
    is_active       BOOLEAN NOT NULL DEFAULT true,
    default_config  JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE supported_module IS 'Registry of available feature modules (actions, briefings, analytics, etc.)';

-- ============================================================================
-- repo.db_migration — Migration version tracking
-- ============================================================================
CREATE TABLE IF NOT EXISTS db_migration (
    version         VARCHAR(50) PRIMARY KEY,
    description     TEXT,
    applied_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    checksum        VARCHAR(64) NOT NULL
);

COMMENT ON TABLE db_migration IS 'Tracks applied database migration versions';

-- Seed default modules
INSERT INTO supported_module (module_code, display_name, description, default_config) VALUES
    ('core',           'Core Platform',        'Tenant management, IAM, organization',                '{}'),
    ('products',       'Product Catalog',       'Product management and versioning',                   '{}'),
    ('customers',      'Customer Management',   'Customer data, segments, 360 cache',                  '{}'),
    ('performance',    'Performance Tracking',  'Metrics, targets, scorecards',                        '{}'),
    ('analytics',      'Analytics & Models',    'ML model registry, scores, explanations',             '{}'),
    ('actions',        'Action Workflows',      'DAG-based action management, SLA, escalation',        '{}'),
    ('briefings',      'AI Briefings',          'AI-generated briefings and insights',                 '{}'),
    ('automation',     'AI Automation',         'Automated action execution via agents',               '{"requires": ["actions"]}'),
    ('notifications',  'Notifications',         'In-app and external notification delivery',           '{}'),
    ('documents',      'Document Management',   'File storage, versioning, entity linking',            '{}'),
    ('reporting',      'In-App Reporting',       'Materialized views and report snapshots',             '{}')
ON CONFLICT (module_code) DO NOTHING;
