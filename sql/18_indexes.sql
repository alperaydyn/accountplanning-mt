-- ============================================================================
-- Account Planning — Performance Indexes
-- ============================================================================
-- Strategic indexes for high-frequency query patterns.
-- All tenant-scoped indexes lead with tenant_id for RLS-efficient scans.
-- ============================================================================

-- ============================================================================
-- CORE SCHEMA
-- ============================================================================

-- Closure table: fast descendant lookups (e.g., "all units under region X")
CREATE INDEX IF NOT EXISTS idx_org_closure_descendant
    ON core.org_unit_closure(tenant_id, descendant_id, depth);

CREATE INDEX IF NOT EXISTS idx_org_closure_ancestor
    ON core.org_unit_closure(tenant_id, ancestor_id, depth);

-- Employee lookups
CREATE INDEX IF NOT EXISTS idx_employee_user
    ON core.employee(tenant_id, user_id);

-- Active org assignments
CREATE INDEX IF NOT EXISTS idx_emp_org_active
    ON core.employee_org_assignment(tenant_id, employee_id)
    WHERE effective_until IS NULL;

CREATE INDEX IF NOT EXISTS idx_emp_org_unit
    ON core.employee_org_assignment(tenant_id, org_unit_id)
    WHERE effective_until IS NULL;

-- Active delegations
CREATE INDEX IF NOT EXISTS idx_delegation_delegate
    ON core.delegation(tenant_id, delegate_id)
    WHERE is_active = true;

-- User external ID lookup (SSO/LDAP login)
CREATE INDEX IF NOT EXISTS idx_user_external
    ON core.user_(tenant_id, identity_provider, external_id)
    WHERE deleted_at IS NULL;

-- ============================================================================
-- PRODUCT SCHEMA
-- ============================================================================

-- Category closure
CREATE INDEX IF NOT EXISTS idx_cat_closure_descendant
    ON product.category_closure(tenant_id, descendant_id, depth);

-- Current product version
CREATE INDEX IF NOT EXISTS idx_product_version_current
    ON product.product_version(tenant_id, product_id)
    WHERE is_current = true;

-- Product relationships
CREATE INDEX IF NOT EXISTS idx_product_rel_source
    ON product.product_relationship(tenant_id, source_product_id)
    WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_product_rel_target
    ON product.product_relationship(tenant_id, target_product_id)
    WHERE is_active = true;

-- ============================================================================
-- CUSTOMER SCHEMA
-- ============================================================================

-- Customer external ID (core system lookup)
CREATE INDEX IF NOT EXISTS idx_customer_external
    ON customer.customer(tenant_id, external_id)
    WHERE deleted_at IS NULL;

-- Customer type filter
CREATE INDEX IF NOT EXISTS idx_customer_type
    ON customer.customer(tenant_id, customer_type)
    WHERE is_active = true AND deleted_at IS NULL;

-- Active segments
CREATE INDEX IF NOT EXISTS idx_customer_segment_active
    ON customer.customer_segment(tenant_id, customer_id, segment_type)
    WHERE effective_until IS NULL;

-- Customer products
CREATE INDEX IF NOT EXISTS idx_customer_product_active
    ON customer.customer_product(tenant_id, customer_id)
    WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_customer_product_by_product
    ON customer.customer_product(tenant_id, product_id)
    WHERE status = 'active';

-- Customer assignments (active)
CREATE INDEX IF NOT EXISTS idx_customer_assignment_employee
    ON customer.customer_assignment(tenant_id, employee_id)
    WHERE effective_until IS NULL;

CREATE INDEX IF NOT EXISTS idx_customer_assignment_customer
    ON customer.customer_assignment(tenant_id, customer_id)
    WHERE effective_until IS NULL;

-- Customer 360 cache freshness
CREATE INDEX IF NOT EXISTS idx_360_refresh
    ON customer.customer_360_cache(tenant_id, last_refreshed_at);

-- Active consents
CREATE INDEX IF NOT EXISTS idx_consent_customer
    ON customer.consent(tenant_id, customer_id, consent_type)
    WHERE status = 'granted';

-- Transactions by date
CREATE INDEX IF NOT EXISTS idx_transaction_customer_date
    ON customer.customer_transaction(tenant_id, customer_id, transaction_date DESC);

-- Customer relationships
CREATE INDEX IF NOT EXISTS idx_cust_rel_source
    ON customer.customer_relationship(tenant_id, source_customer_id)
    WHERE is_active = true;

-- ============================================================================
-- PERF SCHEMA
-- ============================================================================

-- Targets by entity
CREATE INDEX IF NOT EXISTS idx_target_entity
    ON perf.target(tenant_id, target_level, target_entity_id)
    WHERE is_active = true;

-- Targets by metric and period
CREATE INDEX IF NOT EXISTS idx_target_metric_period
    ON perf.target(tenant_id, metric_id, period_start, period_end)
    WHERE is_active = true;

-- Realizations by target
CREATE INDEX IF NOT EXISTS idx_realization_target
    ON perf.realization(tenant_id, target_id, snapshot_date DESC);

-- ============================================================================
-- ANALYTICS SCHEMA
-- ============================================================================

-- Model score lookups (hot query path)
CREATE INDEX IF NOT EXISTS idx_model_score_lookup
    ON analytics.model_score(tenant_id, model_id, customer_id, scored_at DESC);

-- Model score by batch
CREATE INDEX IF NOT EXISTS idx_model_score_batch
    ON analytics.model_score(batch_id)
    WHERE batch_id IS NOT NULL;

-- Latest scores per model (for dashboards)
CREATE INDEX IF NOT EXISTS idx_model_score_latest
    ON analytics.model_score(tenant_id, model_id, scored_at DESC);

-- Explanations by score
CREATE INDEX IF NOT EXISTS idx_explanation_score
    ON analytics.model_explanation(tenant_id, model_score_id);

-- ============================================================================
-- ACTION SCHEMA
-- ============================================================================

-- Open actions for an employee (daily view)
CREATE INDEX IF NOT EXISTS idx_action_assigned_open
    ON action.action(tenant_id, assigned_to)
    WHERE completed_at IS NULL AND cancelled_at IS NULL;

-- Actions by customer (customer view)
CREATE INDEX IF NOT EXISTS idx_action_customer_open
    ON action.action(tenant_id, customer_id)
    WHERE completed_at IS NULL AND cancelled_at IS NULL;

-- SLA tracking (overdue detection job)
CREATE INDEX IF NOT EXISTS idx_action_sla
    ON action.action(tenant_id, sla_deadline)
    WHERE completed_at IS NULL AND cancelled_at IS NULL AND sla_deadline IS NOT NULL;

-- Due date tracking
CREATE INDEX IF NOT EXISTS idx_action_due
    ON action.action(tenant_id, due_date)
    WHERE completed_at IS NULL AND cancelled_at IS NULL AND due_date IS NOT NULL;

-- Workflow aggregation
CREATE INDEX IF NOT EXISTS idx_action_workflow
    ON action.action(tenant_id, workflow_id)
    WHERE workflow_id IS NOT NULL;

-- Action dependencies (unsatisfied)
CREATE INDEX IF NOT EXISTS idx_action_dep_unsatisfied
    ON action.action_dependency(tenant_id, successor_action_id)
    WHERE is_satisfied = false;

-- Recurrence scheduler
CREATE INDEX IF NOT EXISTS idx_recurrence_next
    ON action.action_recurrence(tenant_id, next_occurrence)
    WHERE is_active = true;

-- Execution log by action
CREATE INDEX IF NOT EXISTS idx_exec_log_action
    ON action.action_execution_log(tenant_id, action_id, created_at DESC);

-- ============================================================================
-- CONTENT SCHEMA
-- ============================================================================

-- Current briefings by audience
CREATE INDEX IF NOT EXISTS idx_briefing_audience
    ON content.briefing(tenant_id, audience_scope, audience_entity_id)
    WHERE is_current = true;

-- Briefing series versions
CREATE INDEX IF NOT EXISTS idx_briefing_series
    ON content.briefing(tenant_id, series_id, version DESC)
    WHERE series_id IS NOT NULL;

-- Unread briefings (for notification badge)
CREATE INDEX IF NOT EXISTS idx_briefing_read_user
    ON content.briefing_read_tracking(tenant_id, user_id, briefing_id);

-- ============================================================================
-- AUDIT SCHEMA
-- ============================================================================

-- Audit by resource (entity history)
CREATE INDEX IF NOT EXISTS idx_audit_resource
    ON audit.audit_log(tenant_id, resource_type, resource_id, occurred_at DESC);

-- Audit by user
CREATE INDEX IF NOT EXISTS idx_audit_user
    ON audit.audit_log(tenant_id, user_id, occurred_at DESC);

-- AI reasoning by session
CREATE INDEX IF NOT EXISTS idx_ai_reasoning_session
    ON audit.ai_reasoning_log(tenant_id, session_id, occurred_at)
    WHERE session_id IS NOT NULL;

-- AI reasoning by trigger entity
CREATE INDEX IF NOT EXISTS idx_ai_reasoning_trigger
    ON audit.ai_reasoning_log(tenant_id, trigger_entity_type, trigger_entity_id, occurred_at DESC);

-- Data access by customer (GDPR subject access request)
CREATE INDEX IF NOT EXISTS idx_data_access_resource
    ON audit.data_access_log(tenant_id, resource_type, resource_id, occurred_at DESC);

-- ============================================================================
-- CONFIG SCHEMA
-- ============================================================================

-- Active config per type per environment
CREATE INDEX IF NOT EXISTS idx_config_version_active
    ON config.config_version(tenant_id, config_type, environment)
    WHERE is_active = true;

-- Pending change requests
CREATE INDEX IF NOT EXISTS idx_change_request_pending
    ON config.change_request(tenant_id, status)
    WHERE status IN ('pending_approval', 'draft');

-- ============================================================================
-- INTEGRATION SCHEMA
-- ============================================================================

-- Event store: aggregate replay
CREATE INDEX IF NOT EXISTS idx_event_aggregate
    ON integration.event(tenant_id, aggregate_type, aggregate_id, sequence_number);

-- Event store by type (event consumers)
CREATE INDEX IF NOT EXISTS idx_event_type
    ON integration.event(tenant_id, event_type, occurred_at DESC);

-- Pending webhook deliveries
CREATE INDEX IF NOT EXISTS idx_webhook_delivery_pending
    ON integration.webhook_delivery(tenant_id, status, next_retry_at)
    WHERE status IN ('pending', 'retrying');

-- Sync jobs by source
CREATE INDEX IF NOT EXISTS idx_sync_job_source
    ON integration.sync_job(tenant_id, data_source_id, created_at DESC);

-- ============================================================================
-- AGENT SCHEMA
-- ============================================================================

-- Conversations by user
CREATE INDEX IF NOT EXISTS idx_conv_user
    ON agent.conversation(tenant_id, user_id, started_at DESC);

-- Conversations by customer
CREATE INDEX IF NOT EXISTS idx_conv_customer
    ON agent.conversation(tenant_id, customer_id, started_at DESC)
    WHERE customer_id IS NOT NULL;

-- Messages by conversation (ordered)
CREATE INDEX IF NOT EXISTS idx_conv_msg_order
    ON agent.conversation_message(tenant_id, conversation_id, message_order);

-- Short-term memory by session
CREATE INDEX IF NOT EXISTS idx_stm_session
    ON agent.memory_short_term(tenant_id, session_id)
    WHERE session_id IS NOT NULL;

-- Short-term memory cleanup (expired)
CREATE INDEX IF NOT EXISTS idx_stm_expires
    ON agent.memory_short_term(expires_at)
    WHERE expires_at IS NOT NULL;

-- Long-term memory by entity (AI agent context retrieval)
CREATE INDEX IF NOT EXISTS idx_ltm_entity
    ON agent.memory_long_term(tenant_id, entity_type, entity_id)
    WHERE is_active = true;

-- Current prompt templates
CREATE INDEX IF NOT EXISTS idx_prompt_current
    ON agent.prompt_template(tenant_id, code)
    WHERE is_current = true AND status = 'active';

-- ============================================================================
-- NOTIFICATION SCHEMA
-- ============================================================================

-- Unread notifications for a user
CREATE INDEX IF NOT EXISTS idx_notification_user_unread
    ON notification.notification(tenant_id, recipient_user_id, created_at DESC)
    WHERE status NOT IN ('read', 'dismissed');

-- Pending notifications (delivery job)
CREATE INDEX IF NOT EXISTS idx_notification_pending
    ON notification.notification(tenant_id, status, scheduled_at)
    WHERE status IN ('pending', 'queued');

-- ============================================================================
-- DOCUMENT SCHEMA
-- ============================================================================

-- Documents linked to entity
CREATE INDEX IF NOT EXISTS idx_doc_link_entity
    ON document.document_link(tenant_id, entity_type, entity_id);

-- ============================================================================
-- I18N SCHEMA
-- ============================================================================

-- Translation lookup (hot path)
CREATE INDEX IF NOT EXISTS idx_translation_lookup
    ON i18n.translation(tenant_id, locale, namespace)
    WHERE human_reviewed = true;

-- ============================================================================
-- REPORTING SCHEMA
-- ============================================================================

-- Active report snapshots
CREATE INDEX IF NOT EXISTS idx_report_snapshot_active
    ON reporting.report_snapshot(tenant_id, report_id, generated_at DESC)
    WHERE expires_at IS NULL OR expires_at > now();
