-- ============================================================================
-- Account Planning — Row-Level Security (RLS) Policies
-- ============================================================================
-- Every tenant-scoped table is protected by RLS using the session variable
-- app.current_tenant_id. The application layer MUST set this on every
-- database connection before executing queries.
--
-- Usage:
--   SET app.current_tenant_id = '<tenant-uuid>';
-- ============================================================================

-- ============================================================================
-- HELPER: Function to get current tenant ID safely
-- ============================================================================

CREATE OR REPLACE FUNCTION core.current_tenant_id() RETURNS UUID AS $$
BEGIN
    RETURN current_setting('app.current_tenant_id', true)::uuid;
EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'app.current_tenant_id is not set. All queries require a tenant context.';
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION core.current_tenant_id() IS 'Returns the current tenant UUID from session settings. Raises exception if not set.';

-- ============================================================================
-- CORE SCHEMA
-- ============================================================================

ALTER TABLE core.user_ ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON core.user_
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE core.sso_config ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON core.sso_config
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE core.abac_policy ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON core.abac_policy
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE core.delegation ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON core.delegation
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE core.impersonation_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON core.impersonation_log
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE core.org_unit ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON core.org_unit
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE core.org_unit_closure ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON core.org_unit_closure
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE core.employee ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON core.employee
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE core.employee_org_assignment ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON core.employee_org_assignment
    USING (tenant_id = core.current_tenant_id());

-- ============================================================================
-- PRODUCT SCHEMA
-- ============================================================================

ALTER TABLE product.category ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON product.category
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE product.category_closure ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON product.category_closure
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE product.product ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON product.product
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE product.product_version ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON product.product_version
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE product.product_relationship ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON product.product_relationship
    USING (tenant_id = core.current_tenant_id());

-- ============================================================================
-- CUSTOMER SCHEMA
-- ============================================================================

ALTER TABLE customer.customer ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON customer.customer
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE customer.customer_segment ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON customer.customer_segment
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE customer.customer_relationship ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON customer.customer_relationship
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE customer.customer_product ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON customer.customer_product
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE customer.customer_product_metric ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON customer.customer_product_metric
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE customer.customer_transaction ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON customer.customer_transaction
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE customer.customer_assignment ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON customer.customer_assignment
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE customer.consent ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON customer.consent
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE customer.data_retention_policy ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON customer.data_retention_policy
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE customer.customer_360_cache ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON customer.customer_360_cache
    USING (tenant_id = core.current_tenant_id());

-- ============================================================================
-- PERF SCHEMA
-- ============================================================================

ALTER TABLE perf.metric_definition ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON perf.metric_definition
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE perf.target ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON perf.target
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE perf.realization ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON perf.realization
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE perf.scorecard ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON perf.scorecard
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE perf.scorecard_component ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON perf.scorecard_component
    USING (tenant_id = core.current_tenant_id());

-- ============================================================================
-- ANALYTICS SCHEMA
-- ============================================================================

ALTER TABLE analytics.model ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON analytics.model
    USING (tenant_id = core.current_tenant_id());

-- Note: RLS on partitioned tables applies to the parent, propagates to partitions
ALTER TABLE analytics.model_score ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON analytics.model_score
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE analytics.model_explanation ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON analytics.model_explanation
    USING (tenant_id = core.current_tenant_id());

-- ============================================================================
-- ACTION SCHEMA
-- ============================================================================

ALTER TABLE action.status_definition ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON action.status_definition
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE action.action_type ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON action.action_type
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE action.action_type_dependency ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON action.action_type_dependency
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE action.action ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON action.action
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE action.action_dependency ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON action.action_dependency
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE action.action_recurrence ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON action.action_recurrence
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE action.action_escalation_rule ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON action.action_escalation_rule
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE action.action_execution_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON action.action_execution_log
    USING (tenant_id = core.current_tenant_id());

-- ============================================================================
-- CONTENT SCHEMA
-- ============================================================================

ALTER TABLE content.template ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON content.template
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE content.briefing ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON content.briefing
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE content.briefing_read_tracking ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON content.briefing_read_tracking
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE content.briefing_feedback ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON content.briefing_feedback
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE content.product_insight ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON content.product_insight
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE content.action_insight ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON content.action_insight
    USING (tenant_id = core.current_tenant_id());

-- ============================================================================
-- AUDIT SCHEMA
-- ============================================================================

ALTER TABLE audit.audit_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON audit.audit_log
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE audit.ai_reasoning_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON audit.ai_reasoning_log
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE audit.data_access_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON audit.data_access_log
    USING (tenant_id = core.current_tenant_id());

-- ============================================================================
-- CONFIG SCHEMA
-- ============================================================================

ALTER TABLE config.change_request ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON config.change_request
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE config.change_request_approval ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON config.change_request_approval
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE config.feature_flag ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON config.feature_flag
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE config.config_version ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON config.config_version
    USING (tenant_id = core.current_tenant_id());

-- ============================================================================
-- INTEGRATION SCHEMA
-- ============================================================================

ALTER TABLE integration.data_source ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON integration.data_source
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE integration.sync_job ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON integration.sync_job
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE integration.webhook ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON integration.webhook
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE integration.webhook_delivery ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON integration.webhook_delivery
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE integration.event ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON integration.event
    USING (tenant_id = core.current_tenant_id());

-- ============================================================================
-- AGENT SCHEMA
-- ============================================================================

ALTER TABLE agent.conversation ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON agent.conversation
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE agent.conversation_message ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON agent.conversation_message
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE agent.memory_short_term ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON agent.memory_short_term
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE agent.memory_long_term ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON agent.memory_long_term
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE agent.preference ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON agent.preference
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE agent.prompt_template ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON agent.prompt_template
    USING (tenant_id = core.current_tenant_id());

-- ============================================================================
-- NOTIFICATION SCHEMA
-- ============================================================================

ALTER TABLE notification.channel ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON notification.channel
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE notification.template ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON notification.template
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE notification.notification ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON notification.notification
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE notification.preference ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON notification.preference
    USING (tenant_id = core.current_tenant_id());

-- ============================================================================
-- DOCUMENT SCHEMA
-- ============================================================================

ALTER TABLE document.document ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON document.document
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE document.document_version ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON document.document_version
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE document.document_link ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON document.document_link
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE document.document_access_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON document.document_access_log
    USING (tenant_id = core.current_tenant_id());

-- ============================================================================
-- I18N SCHEMA
-- ============================================================================

ALTER TABLE i18n.supported_language ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON i18n.supported_language
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE i18n.translation ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON i18n.translation
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE i18n.user_language_preference ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON i18n.user_language_preference
    USING (tenant_id = core.current_tenant_id());

-- ============================================================================
-- REPORTING SCHEMA
-- ============================================================================

ALTER TABLE reporting.report_definition ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON reporting.report_definition
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE reporting.materialized_view_registry ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON reporting.materialized_view_registry
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE reporting.report_snapshot ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON reporting.report_snapshot
    USING (tenant_id = core.current_tenant_id());

ALTER TABLE reporting.report_access_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON reporting.report_access_log
    USING (tenant_id = core.current_tenant_id());

-- ============================================================================
-- NOTE: The core.tenant table itself does NOT have RLS.
-- Tenant lookup is needed before setting the session variable.
-- The core.tenant_module table also uses tenant_id but access is controlled
-- at the application layer during tenant context initialization.
-- ============================================================================
