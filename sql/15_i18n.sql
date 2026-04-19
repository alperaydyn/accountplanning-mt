-- ============================================================================
-- Account Planning — i18n Schema
-- ============================================================================
-- Multi-language support per tenant/user. All translations require human
-- review before production use — no auto-translate-only content.
-- ============================================================================

-- ============================================================================
-- 15.1 SUPPORTED LANGUAGES
-- ============================================================================

CREATE TABLE IF NOT EXISTS i18n.supported_language (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    locale          VARCHAR(10) NOT NULL,
    name            VARCHAR(100) NOT NULL,
    is_default      BOOLEAN NOT NULL DEFAULT false,
    is_active       BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, locale)
);

COMMENT ON TABLE i18n.supported_language IS 'Languages supported per tenant. BCP 47 locale codes (tr, en, de, ar, etc.).';

-- ============================================================================
-- 15.2 TRANSLATIONS
-- ============================================================================

CREATE TABLE IF NOT EXISTS i18n.translation (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id               UUID NOT NULL REFERENCES core.tenant(id),
    locale                  VARCHAR(10) NOT NULL,
    namespace               VARCHAR(100) NOT NULL,
    key                     VARCHAR(255) NOT NULL,
    value                   TEXT NOT NULL,
    is_machine_translated   BOOLEAN NOT NULL DEFAULT false,
    human_reviewed          BOOLEAN NOT NULL DEFAULT false,
    reviewed_by             UUID REFERENCES core.user_(id),
    reviewed_at             TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, locale, namespace, key)
);

COMMENT ON TABLE i18n.translation IS 'Translation strings with human review workflow. Only human_reviewed=true served in production.';
COMMENT ON COLUMN i18n.translation.namespace IS 'Grouping: action_status, product_category, ui_label, metric_name, error_message, etc.';
COMMENT ON COLUMN i18n.translation.is_machine_translated IS 'Flag for auto-translated entries — must be human-reviewed before production use';
COMMENT ON COLUMN i18n.translation.human_reviewed IS 'REQUIRED true for production. Application layer enforces this constraint.';

-- ============================================================================
-- 15.3 USER LANGUAGE PREFERENCE
-- ============================================================================

CREATE TABLE IF NOT EXISTS i18n.user_language_preference (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    user_id             UUID NOT NULL REFERENCES core.user_(id),
    locale              VARCHAR(10) NOT NULL,
    fallback_locale     VARCHAR(10),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, user_id)
);

COMMENT ON TABLE i18n.user_language_preference IS 'Per-user language preference with optional fallback.';
