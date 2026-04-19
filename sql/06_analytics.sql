-- ============================================================================
-- Account Planning — analytics Schema
-- ============================================================================
-- ML model registry (future A/B testing), prediction scores with temporal
-- metadata, and SHAP-based explanations for action reasoning.
-- ============================================================================

-- ============================================================================
-- 6.1 MODEL REGISTRY
-- ============================================================================

CREATE TABLE IF NOT EXISTS analytics.model (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id               UUID NOT NULL REFERENCES core.tenant(id),
    code                    VARCHAR(100) NOT NULL,
    name                    VARCHAR(255) NOT NULL,
    description             TEXT,
    model_type              VARCHAR(50) NOT NULL
                            CHECK (model_type IN ('classification', 'regression', 'ranking', 'recommendation', 'clustering', 'anomaly_detection')),
    target_entity           VARCHAR(30) NOT NULL
                            CHECK (target_entity IN ('customer', 'product', 'customer_product', 'transaction')),
    base_time_frame         VARCHAR(50) NOT NULL,
    prediction_horizon      VARCHAR(50) NOT NULL,
    refresh_frequency       VARCHAR(30) NOT NULL DEFAULT 'monthly'
                            CHECK (refresh_frequency IN ('hourly', 'daily', 'weekly', 'monthly', 'quarterly', 'on_demand')),
    version                 VARCHAR(50) NOT NULL,
    status                  VARCHAR(30) NOT NULL DEFAULT 'development'
                            CHECK (status IN ('development', 'staging', 'production', 'retired', 'ab_testing')),
    -- [FUTURE] Model performance metrics for automatic A/B testing and impact calculation.
    -- These fields are reserved for future enhancements:
    --   - performance_metrics: AUC, precision, recall, F1, lift, etc.
    --   - training_metadata: hyperparameters, training data stats, feature list
    --   - ab_test_config: A/B test group assignments, traffic split, impact KPIs
    performance_metrics     JSONB,
    training_metadata       JSONB,
    ab_test_config          JSONB,
    is_active               BOOLEAN NOT NULL DEFAULT true,
    deployed_at             TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code, version)
);

COMMENT ON TABLE analytics.model IS 'Lightweight ML model registry. [FUTURE] Will support automatic A/B testing and impact calculation.';
COMMENT ON COLUMN analytics.model.base_time_frame IS 'Input data window, e.g., 1_month, 3_months, 1_year';
COMMENT ON COLUMN analytics.model.prediction_horizon IS 'What the score predicts, e.g., next_1_month, next_quarter';
COMMENT ON COLUMN analytics.model.performance_metrics IS '[FUTURE] Model performance: {"auc": 0.85, "precision": 0.72, "recall": 0.68}';
COMMENT ON COLUMN analytics.model.training_metadata IS '[FUTURE] Hyperparameters, feature list, training data stats';
COMMENT ON COLUMN analytics.model.ab_test_config IS '[FUTURE] A/B config: traffic split, control/treatment groups, impact KPIs';

-- ============================================================================
-- 6.2 MODEL SCORES
-- ============================================================================
-- PARTITIONED by scored_at (monthly). This is the highest-volume table:
-- 1-2 million rows per cycle per tenant × 100 tenants.

CREATE TABLE IF NOT EXISTS analytics.model_score (
    id                  UUID NOT NULL DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL,
    model_id            UUID NOT NULL,
    customer_id         UUID NOT NULL,
    product_id          UUID,
    score               DECIMAL(10,6) NOT NULL,
    score_label         VARCHAR(50),
    rank                INTEGER,
    base_period_start   DATE NOT NULL,
    base_period_end     DATE NOT NULL,
    prediction_date     DATE NOT NULL,
    scored_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at          TIMESTAMPTZ,
    batch_id            UUID,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id, scored_at)
) PARTITION BY RANGE (scored_at);

COMMENT ON TABLE analytics.model_score IS 'ML model prediction scores. Range-partitioned by scored_at (monthly). High volume: ~200M total.';
COMMENT ON COLUMN analytics.model_score.base_period_start IS 'Start of the input data window used for this prediction';
COMMENT ON COLUMN analytics.model_score.base_period_end IS 'End of the input data window used for this prediction';
COMMENT ON COLUMN analytics.model_score.prediction_date IS 'The date/period this score predicts (e.g., churn in next 30 days from this date)';
COMMENT ON COLUMN analytics.model_score.batch_id IS 'Groups scores from the same batch scoring run';

-- Create initial monthly partitions (12 months)
-- In production, a partition management job creates future partitions and detaches old ones.
CREATE TABLE IF NOT EXISTS analytics.model_score_y2026m01 PARTITION OF analytics.model_score
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE IF NOT EXISTS analytics.model_score_y2026m02 PARTITION OF analytics.model_score
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE IF NOT EXISTS analytics.model_score_y2026m03 PARTITION OF analytics.model_score
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE IF NOT EXISTS analytics.model_score_y2026m04 PARTITION OF analytics.model_score
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE IF NOT EXISTS analytics.model_score_y2026m05 PARTITION OF analytics.model_score
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE IF NOT EXISTS analytics.model_score_y2026m06 PARTITION OF analytics.model_score
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE IF NOT EXISTS analytics.model_score_y2026m07 PARTITION OF analytics.model_score
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE IF NOT EXISTS analytics.model_score_y2026m08 PARTITION OF analytics.model_score
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE IF NOT EXISTS analytics.model_score_y2026m09 PARTITION OF analytics.model_score
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE IF NOT EXISTS analytics.model_score_y2026m10 PARTITION OF analytics.model_score
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE IF NOT EXISTS analytics.model_score_y2026m11 PARTITION OF analytics.model_score
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE IF NOT EXISTS analytics.model_score_y2026m12 PARTITION OF analytics.model_score
    FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');

-- ============================================================================
-- 6.3 MODEL EXPLANATIONS (SHAP / Feature Importance)
-- ============================================================================

CREATE TABLE IF NOT EXISTS analytics.model_explanation (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id               UUID NOT NULL REFERENCES core.tenant(id),
    model_score_id          UUID NOT NULL,
    explanation_type        VARCHAR(30) NOT NULL
                            CHECK (explanation_type IN ('shap', 'lime', 'feature_importance', 'text', 'rule_based')),
    feature_contributions   JSONB,
    top_reasons             JSONB,
    customer_hints          JSONB,
    raw_explanation         JSONB,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE analytics.model_explanation IS 'Model prediction explanations (SHAP, LIME, text). Feeds action reasons and sales rep hints.';
COMMENT ON COLUMN analytics.model_explanation.feature_contributions IS '[{"feature": "avg_balance_3m", "value": 15000, "shap_value": 0.35}]';
COMMENT ON COLUMN analytics.model_explanation.top_reasons IS 'Human-readable reasons for AI/agent consumption';
COMMENT ON COLUMN analytics.model_explanation.customer_hints IS 'Actionable hints for sales reps derived from model explanations';
