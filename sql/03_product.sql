-- ============================================================================
-- Account Planning — product Schema
-- ============================================================================
-- Product categories (closure table), versioned products, lifecycle,
-- and cross-sell/bundle/upsell relationships.
-- ============================================================================
--
-- BUSINESS OVERVIEW
-- -----------------
-- The `product` schema is the authoritative catalog for every financial or
-- non-financial product the bank (or any tenant) offers.  Account Managers
-- use this catalog when building account plans: they look up what products a
-- customer currently holds, identify gaps, and recommend new products.
--
-- Key design decisions:
--   • Multi-tenant isolation  — every row is scoped to a tenant_id so that
--     different business-units or bank subsidiaries can maintain independent
--     catalogs without data leakage.
--   • Closure-table hierarchy — categories are stored as a classic adjacency
--     list (product.category) with a precomputed closure table
--     (product.category_closure) so that "fetch all descendants of Loans" is
--     a single indexed join, not a recursive CTE.
--   • Versioned catalog       — products evolve over time (e.g., interest
--     rates change, fee structures change).  product_version preserves the
--     full specification at each point in time so that customer holdings
--     recorded against a specific version remain historically accurate.
--   • Smart relationships     — product_relationship captures bundles,
--     cross-sell signals, upsell paths, and prerequisites.  The AI agent
--     layer reads these relationships to generate next-best-offer suggestions.
--
-- DATA PRODUCERS (who writes to these tables)
-- -------------------------------------------
--   • Product Management Service  — internal admin UI / backoffice tool used
--     by product owners to create, version, and retire products.
--   • Migration / ETL pipelines   — one-time or periodic jobs that import the
--     existing product catalogue from core banking or a product information
--     management (PIM) system.
--   • AI Relationship Engine      — when ML models discover new cross-sell
--     patterns, they write strength scores back into product_relationship.
--
-- DATA CONSUMERS (who reads from these tables)
-- ---------------------------------------------
--   • Account Planning API        — surfaces the catalog to front-end
--     planners when they build or review an account plan.
--   • Customer Schema (04)        — customer.customer_product references
--     product.product to record what a customer currently holds.
--   • Content / Playbook Engine   — retrieves product specs and relationships
--     to generate personalised playbooks and battle cards.
--   • AI / Agent Layer (12)       — uses product relationships and category
--     hierarchy to reason about next-best products in agentic workflows.
--   • Reporting / Analytics (16)  — joins product data to customer holdings
--     and transactions to produce penetration-rate and wallet-share reports.
-- ============================================================================


-- ============================================================================
-- 3.1 PRODUCT CATEGORIES (Closure Table)
-- ============================================================================
--
-- BUSINESS CONCEPT
-- ----------------
-- Every product belongs to a category, and categories form a tree.  A typical
-- bank hierarchy looks like:
--
--   Financial Products (level 0)
--   └── Loans (level 1)
--       ├── TL Cash Loans (level 2)
--       │   ├── Standard Cash Loan (level 3)
--       │   └── Revolving Credit (level 3)
--       └── FX Loans (level 2)
--   └── Deposits (level 1)
--       ├── Demand Deposits (level 2)
--       └── Time Deposits (level 2)
--
-- Account managers see a product picker filtered by category; analysts slice
-- portfolio reports by category level (e.g., "total Loan penetration" vs.
-- "TL Cash Loan penetration").
--
-- WHY A CLOSURE TABLE?
-- --------------------
-- A closure table pre-materialises every ancestor→descendant relationship in
-- a separate table (category_closure).  The alternative — recursive CTEs —
-- is readable but expensive at scale (millions of customer-product rows being
-- grouped by category hierarchy).  With the closure table, querying "show me
-- all products under Loans" is:
--
--   SELECT p.*
--   FROM product.product p
--   JOIN product.category c ON c.id = p.category_id
--   JOIN product.category_closure cc ON cc.descendant_id = c.id
--   WHERE cc.ancestor_id = '<loans-uuid>'
--     AND cc.tenant_id   = '<tenant-uuid>';
--
-- WHEN IS THE CLOSURE TABLE UPDATED?
-- ------------------------------------
-- When a category is inserted or its parent_id changes, the application
-- service (or a DB trigger) re-computes the closure rows for that subtree.
-- This is a write-time cost that pays off at every query.
--
-- PRODUCED BY  : Product Management Service (admin backoffice)
-- CONSUMED BY  : Account Planning API (product picker), Reporting (16),
--                AI Agent (12) for hierarchy-aware reasoning
-- ============================================================================

CREATE TABLE IF NOT EXISTS product.category (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    parent_id       UUID REFERENCES product.category(id),
    code            VARCHAR(100) NOT NULL,
    name            VARCHAR(255) NOT NULL,
    level           INTEGER NOT NULL DEFAULT 0,
    display_order   INTEGER NOT NULL DEFAULT 0,
    is_active       BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code)
);

-- Example rows:
--   (tenant_id='t1', code='LOANS',        name='Loans',         level=0, parent_id=NULL)
--   (tenant_id='t1', code='TL_CASH',      name='TL Cash Loans', level=1, parent_id=<LOANS id>)
--   (tenant_id='t1', code='REVOLVING',    name='Revolving Credit', level=2, parent_id=<TL_CASH id>)

COMMENT ON TABLE product.category IS 'Dynamic product category hierarchy. Levels defined per tenant (e.g., Loans > TL Cash > Revolving).';

-- ----------------------------------------------------------------------------
-- Closure table — one row per (ancestor, descendant) pair, including self.
--
-- Example rows for the Loans → TL Cash → Revolving chain:
--   (ancestor=LOANS,     descendant=LOANS,     depth=0)
--   (ancestor=LOANS,     descendant=TL_CASH,   depth=1)
--   (ancestor=LOANS,     descendant=REVOLVING, depth=2)
--   (ancestor=TL_CASH,   descendant=TL_CASH,   depth=0)
--   (ancestor=TL_CASH,   descendant=REVOLVING, depth=1)
--   (ancestor=REVOLVING, descendant=REVOLVING, depth=0)
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS product.category_closure (
    ancestor_id     UUID NOT NULL REFERENCES product.category(id),
    descendant_id   UUID NOT NULL REFERENCES product.category(id),
    depth           INTEGER NOT NULL DEFAULT 0,
    tenant_id       UUID NOT NULL REFERENCES core.tenant(id),
    PRIMARY KEY (ancestor_id, descendant_id)
);

COMMENT ON TABLE product.category_closure IS 'Closure table for product category hierarchy traversal. Maintained by the application layer whenever a category is created or re-parented.';


-- ============================================================================
-- 3.2 PRODUCTS
-- ============================================================================
--
-- BUSINESS CONCEPT
-- ----------------
-- A product is any offer the bank can extend to a customer — a loan type,
-- a deposit account, an investment fund, a credit card, an insurance policy,
-- etc.  Each product sits in exactly one category and carries:
--
--   • A machine-readable code (e.g., "CC_PLATINUM") used by integrations.
--   • A human-readable name (e.g., "Platinum Credit Card").
--   • A flexible JSONB specifications bag for industry-specific attributes
--     (e.g., credit card: {"credit_limit_range": [5000, 250000], "rewards": true}).
--   • An optional lifecycle status that tracks whether the product is still
--     being sold, is being wound down, or has been discontinued.
--
-- LIFECYCLE STATES
-- ----------------
--   draft        — product is defined but not yet approved for sale.
--   active        — product is currently available for new customers.
--   discontinued  — product is no longer sold to new customers, but existing
--                   customers retain it.
--   sunset        — final state before removal; all existing positions are
--                   being migrated or paid off.
--
-- Use case: when a banker searches the product catalog for cross-sell
-- opportunities, only 'active' products are shown.  'discontinued' products
-- remain visible in a customer's existing holdings so historical plans stay
-- accurate.
--
-- PRODUCED BY  : Product Management Service (create/edit), ETL from core
--                banking PIM (bulk import)
-- CONSUMED BY  : Account Planning API, customer.customer_product (FK),
--                Content Engine (playbook generation), AI Agent (12),
--                Reporting (16)
-- ============================================================================

CREATE TABLE IF NOT EXISTS product.product (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id               UUID NOT NULL REFERENCES core.tenant(id),
    category_id             UUID NOT NULL REFERENCES product.category(id),
    code                    VARCHAR(100) NOT NULL,
    name                    VARCHAR(255) NOT NULL,
    description             TEXT,
    specifications          JSONB NOT NULL DEFAULT '{}',
    has_lifecycle           BOOLEAN NOT NULL DEFAULT false,
    lifecycle_status        VARCHAR(30)
                            CHECK (lifecycle_status IS NULL OR lifecycle_status IN ('draft', 'active', 'discontinued', 'sunset')),
    lifecycle_effective_date DATE,
    is_active               BOOLEAN NOT NULL DEFAULT true,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code),
    CONSTRAINT chk_product_lifecycle CHECK (
        (has_lifecycle = false AND lifecycle_status IS NULL) OR
        (has_lifecycle = true AND lifecycle_status IS NOT NULL)
    )
);

-- Example rows:
--   code='CC_PLATINUM',   name='Platinum Credit Card',
--     category=<credit-cards>, has_lifecycle=true, lifecycle_status='active',
--     specifications={"credit_limit_range":[5000,250000],"cashback_pct":1.5}
--
--   code='CASH_LOAN_STD', name='Standard Cash Loan',
--     category=<tl-cash>, has_lifecycle=true, lifecycle_status='discontinued',
--     specifications={"max_tenor_months":60,"min_amount":5000}

COMMENT ON TABLE product.product IS 'Product catalog. Lifecycle tracking is optional per product (has_lifecycle flag).';
COMMENT ON COLUMN product.product.specifications IS 'Flexible JSONB for industry-specific product specs (e.g., credit limits, tenor ranges, reward rates).';


-- ============================================================================
-- 3.3 PRODUCT VERSIONS
-- ============================================================================
--
-- BUSINESS CONCEPT
-- ----------------
-- Product terms change over time — an interest rate is repriced, a fee
-- structure is revised, a new tier of benefits is added.  When this happens
-- it must NOT overwrite the previous definition because:
--   a) Customers who signed up under the old terms are still on those terms.
--   b) Historical account plans must reference the product spec that was
--      valid at the time the plan was created.
--   c) Auditors and regulators need a clear record of what was offered when.
--
-- product_version solves this by creating a new immutable snapshot each time
-- a product changes.  The `is_current` flag identifies the version that new
-- customers would receive today.  The `effective_from / effective_until`
-- dates let the system retrieve the version that was "current" at any point
-- in history.
--
-- APPROVAL WORKFLOW
-- -----------------
-- A new version is created in 'draft' form by a product manager (created_by).
-- It may require sign-off from a senior approver (approved_by) before
-- is_current can be flipped to true.  This lightweight two-field pattern is
-- sufficient for many banks; more elaborate workflows live in config.change_request (10).
--
-- EXAMPLE TIMELINE
-- ----------------
--   v1 (2022-01-01 → 2023-06-30): rate=14%, max_tenor=48 months
--   v2 (2023-07-01 → 2024-12-31): rate=12%, max_tenor=60 months
--   v3 (2025-01-01 → NULL):       rate=11%, max_tenor=72 months  ← is_current=true
--
-- A customer who took the loan in 2022 is still on v1 terms.  Any account
-- plan built in 2022 references v1.  The AI agent always recommends based
-- on the is_current version.
--
-- PRODUCED BY  : Product Management Service (version creation & approval),
--                Config Change Request workflow (10)
-- CONSUMED BY  : Account Planning API (display current terms to bankers),
--                customer.customer_product (records which version a customer
--                holds), AI Agent (12) reasoning, Reporting (16)
-- ============================================================================

CREATE TABLE IF NOT EXISTS product.product_version (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID NOT NULL REFERENCES core.tenant(id),
    product_id          UUID NOT NULL REFERENCES product.product(id),
    version_number      INTEGER NOT NULL,
    version_label       VARCHAR(100),
    specifications      JSONB NOT NULL DEFAULT '{}',
    terms               JSONB NOT NULL DEFAULT '{}',
    change_summary      TEXT,
    is_current          BOOLEAN NOT NULL DEFAULT false,
    effective_from      DATE NOT NULL,
    effective_until     DATE,
    created_by          UUID REFERENCES core.user_(id),
    approved_by         UUID REFERENCES core.user_(id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (product_id, version_number),
    CONSTRAINT chk_version_dates CHECK (effective_until IS NULL OR effective_until > effective_from)
);

-- Example rows:
--   product_id=<CC_PLATINUM>, version_number=1, version_label='Launch',
--     effective_from='2023-01-01', effective_until='2024-06-30',
--     terms={"annual_fee":500,"cashback_pct":1.0}, is_current=false
--
--   product_id=<CC_PLATINUM>, version_number=2, version_label='2024 Relaunch',
--     effective_from='2024-07-01', effective_until=NULL,
--     terms={"annual_fee":0,"cashback_pct":1.5}, is_current=true

COMMENT ON TABLE product.product_version IS 'Product version history. Customer holdings and historical account plans reference specific versions to preserve point-in-time accuracy.';
COMMENT ON COLUMN product.product_version.is_current IS 'Only one version per product should be current. Enforced at application layer (flip old is_current=false before setting new=true).';


-- ============================================================================
-- 3.4 PRODUCT RELATIONSHIPS
-- ============================================================================
--
-- BUSINESS CONCEPT
-- ----------------
-- Products rarely exist in isolation.  Banks design product ecosystems where
-- certain products complement, require, or naturally lead to others.  This
-- table captures those relationships so that:
--
--   • Account Managers see contextual suggestions ("customers with CC_PLATINUM
--     often also benefit from TRAVEL_INSURANCE").
--   • The AI Agent can reason about a coherent wallet share strategy ("this
--     customer has a mortgage but no home insurance — relationship type:
--     complementary, strength: 0.85").
--   • Business rules can enforce prerequisites ("customer must have a current
--     account before applying for a credit card").
--
-- RELATIONSHIP TYPES
-- ------------------
--   bundle        — products are sold together as a package (e.g., a payroll
--                   account + debit card + internet banking in one offer).
--   cross_sell    — a distinct product that is frequently purchased after or
--                   alongside the source product.
--   upsell        — a premium/upgraded version of the source product
--                   (e.g., Gold Card → Platinum Card).
--   prerequisite  — target product requires source product to exist
--                   (e.g., credit card requires demand deposit account).
--   complementary — adds value but is not a strict requirement (e.g., mortgage
--                   + home insurance).
--   substitute    — an alternative when the source is unavailable or unsuitable
--                   (e.g., standard cash loan → overdraft facility).
--
-- STRENGTH SCORE
-- --------------
-- The strength field (0.00–1.00) quantifies how strongly the relationship
-- should be acted upon.  It can be:
--   • Hard-coded by product managers based on business strategy.
--   • Machine-learning derived (the AI engine updates it based on observed
--     uptake rates and revenue impact).
-- A higher score moves the recommendation higher in the AI agent's suggestion
-- list and in the account plan's next-best-action panel.
--
-- PRODUCED BY  : Product Management Service (manual relationship definition),
--                AI Relationship Engine (automated strength updates via ML)
-- CONSUMED BY  : AI Agent (12) for next-best-offer reasoning, Account Planning
--                API (cross-sell/upsell recommendation widget), Content Engine
--                (playbook bullet points referencing related products),
--                Reporting (16) for relationship coverage analytics
-- ============================================================================

CREATE TABLE IF NOT EXISTS product.product_relationship (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id               UUID NOT NULL REFERENCES core.tenant(id),
    source_product_id       UUID NOT NULL REFERENCES product.product(id),
    target_product_id       UUID NOT NULL REFERENCES product.product(id),
    relationship_type       VARCHAR(50) NOT NULL
                            CHECK (relationship_type IN ('bundle', 'cross_sell', 'upsell', 'prerequisite', 'complementary', 'substitute')),
    strength                DECIMAL(3,2) DEFAULT 0.50
                            CHECK (strength >= 0.00 AND strength <= 1.00),
    metadata                JSONB NOT NULL DEFAULT '{}',
    is_active               BOOLEAN NOT NULL DEFAULT true,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, source_product_id, target_product_id, relationship_type),
    CONSTRAINT chk_product_rel_diff CHECK (source_product_id != target_product_id)
);

-- Example rows:
--   source=CC_PLATINUM, target=TRAVEL_INSURANCE,
--     relationship_type='complementary', strength=0.85,
--     metadata={"trigger":"international_transaction_detected"}
--
--   source=CC_GOLD, target=CC_PLATINUM,
--     relationship_type='upsell', strength=0.70,
--     metadata={"upsell_threshold_spend_monthly":3000}
--
--   source=MORTGAGE, target=DEMAND_DEPOSIT,
--     relationship_type='prerequisite', strength=1.00,
--     metadata={}

COMMENT ON TABLE product.product_relationship IS 'Relationships between products: bundles, cross-sell, upsell, prerequisites, complementary offers, and substitutes.';
COMMENT ON COLUMN product.product_relationship.strength IS 'Recommendation weight (0.00–1.00): 1.00 = mandatory prerequisite or highest priority upsell; 0.50 = default; lower values = weak or situational signal. Updated by AI engine over time.';
