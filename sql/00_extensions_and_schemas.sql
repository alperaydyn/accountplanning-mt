-- ============================================================================
-- Account Planning Database — Extensions & Schema Creation
-- ============================================================================
-- Version: 0.1.0
-- Description: Creates required extensions and all logical schemas.
-- ============================================================================

-- Required Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";       -- UUID generation
CREATE EXTENSION IF NOT EXISTS "pgcrypto";         -- Encryption functions
CREATE EXTENSION IF NOT EXISTS "btree_gist";       -- GiST index support (exclusion constraints)

-- ============================================================================
-- Schema Creation
-- ============================================================================

-- Core: Tenancy, Identity & Access, Organization
CREATE SCHEMA IF NOT EXISTS core;
COMMENT ON SCHEMA core IS 'Tenant management, IAM (ABAC), organization hierarchy';

-- Product: Catalog, Versions, Relationships
CREATE SCHEMA IF NOT EXISTS product;
COMMENT ON SCHEMA product IS 'Product catalog, categories, versioning, cross-sell relationships';

-- Customer: Data, Segments, 360 Cache, KVKK/GDPR
CREATE SCHEMA IF NOT EXISTS customer;
COMMENT ON SCHEMA customer IS 'Customer data, segments, relationships, consent, 360 cache';

-- Performance: Metrics, Targets, Scorecards
CREATE SCHEMA IF NOT EXISTS perf;
COMMENT ON SCHEMA perf IS 'Performance metrics, multi-level targets, composite scorecards';

-- Analytics: Models, Scores, Explanations
CREATE SCHEMA IF NOT EXISTS analytics;
COMMENT ON SCHEMA analytics IS 'ML model registry, prediction scores, SHAP explanations';

-- Action: Workflows, DAG, Execution
CREATE SCHEMA IF NOT EXISTS action;
COMMENT ON SCHEMA action IS 'Action types, DAG dependencies, workflow execution, SLA/escalation';

-- Content: Briefings, Templates, Feedback
CREATE SCHEMA IF NOT EXISTS content;
COMMENT ON SCHEMA content IS 'AI-generated briefings, content templates, read tracking, feedback';

-- Audit: Logs, Diffs, AI Traceability
CREATE SCHEMA IF NOT EXISTS audit;
COMMENT ON SCHEMA audit IS 'Field-level audit logs, AI reasoning chains, data access logs';

-- Config: Change Management, Feature Flags
CREATE SCHEMA IF NOT EXISTS config;
COMMENT ON SCHEMA config IS 'Change management workflows, feature flags, config versioning';

-- Integration: ETL, Webhooks, Event Store
CREATE SCHEMA IF NOT EXISTS integration;
COMMENT ON SCHEMA integration IS 'Data source sync, webhook management, event sourcing';

-- Agent: AI Memory, Conversations, Prompts
CREATE SCHEMA IF NOT EXISTS agent;
COMMENT ON SCHEMA agent IS 'AI agent conversations, short/long-term memory, prompt templates';

-- Notification: Alerts & Delivery
CREATE SCHEMA IF NOT EXISTS notification;
COMMENT ON SCHEMA notification IS 'In-app and external notification channels, delivery tracking';

-- Document: Files & Attachments
CREATE SCHEMA IF NOT EXISTS document;
COMMENT ON SCHEMA document IS 'Document metadata, versioning, entity linking, access logs';

-- i18n: Localization
CREATE SCHEMA IF NOT EXISTS i18n;
COMMENT ON SCHEMA i18n IS 'Multi-language support, translations with human review workflow';

-- Reporting: Views & Snapshots
CREATE SCHEMA IF NOT EXISTS reporting;
COMMENT ON SCHEMA reporting IS 'Report definitions, materialized view registry, cached snapshots';
