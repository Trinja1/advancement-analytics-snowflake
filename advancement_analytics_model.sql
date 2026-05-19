-- ============================================================
-- ADVANCEMENT ANALYTICS DATA MODEL
-- Unified Constituent & Giving Schema
-- Author : Trina Watson, Senior Data Scientist
-- Platform: Snowflake
-- Purpose : Consolidate constituent bio, giving history,
--           engagement, and external philanthropy data
--           into a single source of truth for
--           advancement reporting and prospect analytics.
-- ============================================================


-- ============================================================
-- SECTION 1: RAW SOURCE TABLES (Simulated CRM Inputs)
-- ============================================================

-- ------------------------------------------------------------
-- 1A. CONSTITUENT — Core biographical and demographic data
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE RAW.CONSTITUENT (
    CONSTITUENT_ID        VARCHAR(10)     NOT NULL,
    FIRST_NAME            VARCHAR(50),
    LAST_NAME             VARCHAR(50),
    FULL_NAME             VARCHAR(100)    GENERATED ALWAYS AS (FIRST_NAME || ' ' || LAST_NAME),
    CLASS_YEAR            INTEGER,
    DEGREE_TYPE           VARCHAR(20),        -- 'UG', 'GRAD', 'CERT'
    CONSTITUENT_TYPE      VARCHAR(20),        -- 'Alumni UG', 'Alumni Grad', 'Friend', 'Parent', 'Past Parent'
    PRIMARY_EMAIL         VARCHAR(100),
    CITY                  VARCHAR(50),
    STATE                 VARCHAR(2),
    IS_DECEASED           BOOLEAN         DEFAULT FALSE,
    IS_DISQUALIFIED       BOOLEAN         DEFAULT FALSE,
    RESEARCH_RATING       VARCHAR(30),        -- e.g. '$100,000-249,999'
    RESEARCH_RATING_AMT   NUMBER(15,2),       -- Numeric version for filtering/sorting
    NU_AFFILIATION_FLAG   BOOLEAN         DEFAULT FALSE,
    CREATED_AT            TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT            TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

-- ------------------------------------------------------------
-- 1B. NU_GIFT — Giving history to Northeastern University
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE RAW.NU_GIFT (
    GIFT_ID               VARCHAR(20)     NOT NULL,
    CONSTITUENT_ID        VARCHAR(10)     NOT NULL,
    GIFT_DATE             DATE,
    FISCAL_YEAR           INTEGER,            -- FY mapped from gift date (Jul-Jun)
    GIFT_AMOUNT           NUMBER(15,2),
    GIFT_LEVEL            VARCHAR(20),        -- 'Annual','Leadership','Major'
    FUND_CODE             VARCHAR(20),
    FUND_NAME             VARCHAR(100),
    GIFT_TYPE             VARCHAR(20),        -- 'Outright','Pledge','Bequest'
    IS_HARD_CREDIT        BOOLEAN         DEFAULT TRUE,
    CREATED_AT            TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

-- ------------------------------------------------------------
-- 1C. ENGAGEMENT — Events, visits, and campus interactions
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE RAW.ENGAGEMENT (
    ENGAGEMENT_ID         VARCHAR(20)     NOT NULL,
    CONSTITUENT_ID        VARCHAR(10)     NOT NULL,
    ENGAGEMENT_TYPE       VARCHAR(30),        -- 'Personal Visit','Event','Volunteer','Board'
    ENGAGEMENT_DATE       DATE,
    FISCAL_YEAR           INTEGER,
    STAFF_NAME            VARCHAR(100),
    NOTES                 VARCHAR(500),
    CREATED_AT            TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

-- ------------------------------------------------------------
-- 1D. EXTERNAL_GIVING — Philanthropy to non-NU organizations
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE RAW.EXTERNAL_GIVING (
    EXT_GIFT_ID           VARCHAR(20)     NOT NULL,
    CONSTITUENT_ID        VARCHAR(10)     NOT NULL,
    ORGANIZATION_NAME     VARCHAR(200),
    ORG_CATEGORY          VARCHAR(50),        -- 'Higher Ed','Non-Profit','Religious','Other'
    LOW_GIFT_AMOUNT       NUMBER(15,2),
    HIGH_GIFT_AMOUNT      NUMBER(15,2),
    GIFT_YEAR             INTEGER,
    IS_NONPROFIT          BOOLEAN         DEFAULT TRUE,
    CREATED_AT            TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

-- ------------------------------------------------------------
-- 1E. PROSPECT_ASSIGNMENT — MGO portfolio assignments
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE RAW.PROSPECT_ASSIGNMENT (
    ASSIGNMENT_ID         VARCHAR(20)     NOT NULL,
    CONSTITUENT_ID        VARCHAR(10)     NOT NULL,
    ASSIGNED_TO           VARCHAR(100),       -- Major Gift Officer name
    ASSIGNMENT_DATE       DATE,
    STATUS                VARCHAR(20),        -- 'Active','Inactive','Prospect'
    STAGE                 VARCHAR(30),        -- 'Identification','Cultivation','Solicitation','Stewardship'
    PROSPECT_GRADE        VARCHAR(2),         -- 'A','B','C','D'
    CREATED_AT            TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);


-- ============================================================
-- SECTION 2: INTERMEDIATE TRANSFORMATION LAYERS
-- ============================================================

-- ------------------------------------------------------------
-- 2A. NU Giving Summary per Constituent
--     Aggregates all NU gift history into one row per donor
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW ANALYTICS.V_NU_GIVING_SUMMARY AS

WITH gift_base AS (
    SELECT
        CONSTITUENT_ID,
        COUNT(DISTINCT GIFT_ID)                                 AS TOTAL_GIFT_COUNT,
        COUNT(DISTINCT FISCAL_YEAR)                             AS GIVING_YEARS,
        SUM(GIFT_AMOUNT)                                        AS LIFETIME_GIVING,
        MAX(GIFT_AMOUNT)                                        AS LARGEST_GIFT,
        AVG(GIFT_AMOUNT)                                        AS AVG_GIFT,
        MIN(FISCAL_YEAR)                                        AS FIRST_GIVING_FY,
        MAX(FISCAL_YEAR)                                        AS MOST_RECENT_FY,

        -- Giving level flags
        MAX(CASE WHEN GIFT_LEVEL = 'Major'      THEN 1 ELSE 0 END) AS HAS_MAJOR_GIFT,
        MAX(CASE WHEN GIFT_LEVEL = 'Leadership' THEN 1 ELSE 0 END) AS HAS_LEADERSHIP_GIFT,
        MAX(CASE WHEN GIFT_LEVEL = 'Annual'     THEN 1 ELSE 0 END) AS HAS_ANNUAL_GIFT,

        -- Recency flag: gave in FY15 or FY16 (campaign endpoint years)
        MAX(CASE WHEN FISCAL_YEAR IN (2015, 2016) THEN 1 ELSE 0 END) AS RECENT_GIVER_FLAG,

        -- Consistency score: how many campaign years did they give?
        COUNT(DISTINCT CASE
            WHEN FISCAL_YEAR BETWEEN 2010 AND 2016
            THEN FISCAL_YEAR END)                               AS CAMPAIGN_GIVING_YEARS

    FROM RAW.NU_GIFT
    WHERE IS_HARD_CREDIT = TRUE
    GROUP BY CONSTITUENT_ID
),

consistency_scored AS (
    SELECT
        *,
        CASE
            WHEN CAMPAIGN_GIVING_YEARS >= 5 THEN 2
            WHEN CAMPAIGN_GIVING_YEARS IN (3,4) THEN 1
            ELSE 0
        END AS CONSISTENCY_SCORE
    FROM gift_base
)

SELECT * FROM consistency_scored;


-- ------------------------------------------------------------
-- 2B. Engagement Summary per Constituent
--     Counts visits, events, and recent engagement activity
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW ANALYTICS.V_ENGAGEMENT_SUMMARY AS

SELECT
    CONSTITUENT_ID,
    COUNT(DISTINCT ENGAGEMENT_ID)                               AS TOTAL_ENGAGEMENTS,
    COUNT(DISTINCT CASE
        WHEN ENGAGEMENT_TYPE = 'Personal Visit'
        THEN ENGAGEMENT_ID END)                                 AS TOTAL_VISITS,

    -- Recent visit flag: visited in FY14, FY15, or FY16
    MAX(CASE
        WHEN ENGAGEMENT_TYPE = 'Personal Visit'
         AND FISCAL_YEAR IN (2014, 2015, 2016)
        THEN 1 ELSE 0 END)                                      AS RECENT_VISIT_FLAG,

    MAX(FISCAL_YEAR)                                            AS MOST_RECENT_ENGAGEMENT_FY,
    COUNT(DISTINCT FISCAL_YEAR)                                 AS ENGAGEMENT_YEARS

FROM RAW.ENGAGEMENT
GROUP BY CONSTITUENT_ID;


-- ------------------------------------------------------------
-- 2C. External Giving Summary per Constituent
--     Summarizes non-NU philanthropic behavior (Propensity inputs)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW ANALYTICS.V_EXTERNAL_GIVING_SUMMARY AS

SELECT
    CONSTITUENT_ID,
    COUNT(DISTINCT EXT_GIFT_ID)                                 AS TOTAL_EXT_GIFTS,
    COUNT(DISTINCT ORGANIZATION_NAME)                           AS TOTAL_ORGS_SUPPORTED,
    MAX(GIFT_YEAR)                                              AS MOST_RECENT_EXT_GIFT_YEAR,
    SUM(HIGH_GIFT_AMOUNT)                                       AS TOTAL_EXT_GIVING_HIGH,
    MAX(HIGH_GIFT_AMOUNT)                                       AS LARGEST_EXT_GIFT,

    -- Higher Ed giving count (for Propensity bonus)
    COUNT(DISTINCT CASE
        WHEN ORG_CATEGORY = 'Higher Ed'
        THEN EXT_GIFT_ID END)                                   AS HIGHER_ED_GIFT_COUNT,

    -- Nonprofit affiliation flag
    MAX(CASE WHEN IS_NONPROFIT = TRUE THEN 1 ELSE 0 END)        AS HAS_NONPROFIT_AFFILIATION,

    -- Spread flag: gives to 5+ organizations
    CASE WHEN COUNT(DISTINCT ORGANIZATION_NAME) >= 5
        THEN 1 ELSE 0 END                                       AS BROAD_GIVING_FLAG,

    -- Frequency flag: 10+ gifts total
    CASE WHEN COUNT(DISTINCT EXT_GIFT_ID) >= 10
        THEN 1 ELSE 0 END                                       AS HIGH_FREQUENCY_FLAG,

    -- Recency flag: gave in 2011 or later
    MAX(CASE WHEN GIFT_YEAR >= 2011 THEN 1 ELSE 0 END)          AS RECENT_EXT_GIVER_FLAG

FROM RAW.EXTERNAL_GIVING
GROUP BY CONSTITUENT_ID;


-- ============================================================
-- SECTION 3: SCORING MODELS
-- ============================================================

-- ------------------------------------------------------------
-- 3A. Affinity Score
--     Measures connection and commitment to Northeastern.
--     Based on internal CRM data only.
--     Scale: 0-13 (higher = stronger NU affinity)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW ANALYTICS.V_AFFINITY_SCORE AS

SELECT
    c.CONSTITUENT_ID,
    c.FULL_NAME,
    c.CONSTITUENT_TYPE,
    c.RESEARCH_RATING,
    c.RESEARCH_RATING_AMT,

    -- Component 1: Gift Amount (NU only)
    CASE
        WHEN g.HAS_MAJOR_GIFT      = 1 THEN 3
        WHEN g.HAS_LEADERSHIP_GIFT = 1 THEN 2
        WHEN g.HAS_ANNUAL_GIFT     = 1 THEN 1
        ELSE 0
    END                                                         AS AMOUNT_SCORE,

    -- Component 2: Giving Consistency over campaign period
    COALESCE(g.CONSISTENCY_SCORE, 0)                            AS CONSISTENCY_SCORE,

    -- Component 3: Constituent Type
    CASE c.CONSTITUENT_TYPE
        WHEN 'Alumni UG'    THEN 3
        WHEN 'Alumni Grad'  THEN 2
        WHEN 'Parent'       THEN 1
        ELSE 0
    END                                                         AS CONSTITUENT_SCORE,

    -- Component 4: Recent NU Giving (FY15 or FY16)
    COALESCE(g.RECENT_GIVER_FLAG, 0)                            AS RECENCY_SCORE,

    -- Component 5: Personal Visit history
    CASE WHEN COALESCE(e.TOTAL_VISITS, 0) > 0 THEN 1 ELSE 0
    END                                                         AS VISIT_SCORE,

    -- Component 6: Recent Personal Visit (FY14-16)
    COALESCE(e.RECENT_VISIT_FLAG, 0)                            AS RECENT_VISIT_SCORE,

    -- Component 7: NU Affiliation (clubs, boards, committees)
    CASE WHEN c.NU_AFFILIATION_FLAG = TRUE THEN 1 ELSE 0
    END                                                         AS NU_AFFILIATION_SCORE,

    -- Penalty: Declined Opportunity (applied in total calc below)
    -- (Declined opps tracked in engagement table as 'Declined Opp' type)
    CASE WHEN EXISTS (
        SELECT 1 FROM RAW.ENGAGEMENT e2
        WHERE e2.CONSTITUENT_ID = c.CONSTITUENT_ID
          AND e2.ENGAGEMENT_TYPE = 'Declined Opp'
    ) THEN -2 ELSE 0 END                                        AS DECLINED_OPP_PENALTY,

    -- TOTAL AFFINITY SCORE
    (
        CASE WHEN g.HAS_MAJOR_GIFT = 1 THEN 3
             WHEN g.HAS_LEADERSHIP_GIFT = 1 THEN 2
             WHEN g.HAS_ANNUAL_GIFT = 1 THEN 1 ELSE 0 END
        + COALESCE(g.CONSISTENCY_SCORE, 0)
        + CASE c.CONSTITUENT_TYPE
            WHEN 'Alumni UG'   THEN 3
            WHEN 'Alumni Grad' THEN 2
            WHEN 'Parent'      THEN 1
            ELSE 0 END
        + COALESCE(g.RECENT_GIVER_FLAG, 0)
        + CASE WHEN COALESCE(e.TOTAL_VISITS, 0) > 0 THEN 1 ELSE 0 END
        + COALESCE(e.RECENT_VISIT_FLAG, 0)
        + CASE WHEN c.NU_AFFILIATION_FLAG = TRUE THEN 1 ELSE 0 END
        + CASE WHEN EXISTS (
            SELECT 1 FROM RAW.ENGAGEMENT e3
            WHERE e3.CONSTITUENT_ID = c.CONSTITUENT_ID
              AND e3.ENGAGEMENT_TYPE = 'Declined Opp'
          ) THEN -2 ELSE 0 END
    )                                                           AS TOTAL_AFFINITY_SCORE

FROM RAW.CONSTITUENT c
LEFT JOIN ANALYTICS.V_NU_GIVING_SUMMARY  g ON c.CONSTITUENT_ID = g.CONSTITUENT_ID
LEFT JOIN ANALYTICS.V_ENGAGEMENT_SUMMARY e ON c.CONSTITUENT_ID = e.CONSTITUENT_ID
WHERE c.IS_DECEASED     = FALSE
  AND c.IS_DISQUALIFIED = FALSE;


-- ------------------------------------------------------------
-- 3B. Propensity Score
--     Measures general philanthropic inclination using
--     EXTERNAL giving data only (non-NU sources).
--     Scale: 0-8 (higher = stronger external giving behavior)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW ANALYTICS.V_PROPENSITY_SCORE AS

SELECT
    c.CONSTITUENT_ID,
    c.FULL_NAME,

    -- Component 1: External Gift Amount tier
    CASE
        WHEN COALESCE(ext.LARGEST_EXT_GIFT, 0) >= 10000 THEN 2
        WHEN COALESCE(ext.LARGEST_EXT_GIFT, 0) >= 1000  THEN 1
        ELSE 0
    END                                                         AS EXT_AMOUNT_SCORE,

    -- Component 2: Recency of external giving (2011+)
    COALESCE(ext.RECENT_EXT_GIVER_FLAG, 0)                     AS EXT_RECENCY_SCORE,

    -- Component 3: Spread (gives to 5+ orgs)
    COALESCE(ext.BROAD_GIVING_FLAG, 0)                         AS EXT_SPREAD_SCORE,

    -- Component 4: Frequency (10+ gifts across all orgs)
    COALESCE(ext.HIGH_FREQUENCY_FLAG, 0)                       AS EXT_FREQUENCY_SCORE,

    -- Component 5: Nonprofit affiliation
    COALESCE(ext.HAS_NONPROFIT_AFFILIATION, 0)                 AS NONPROFIT_AFFILIATION_SCORE,

    -- Component 6: Higher Education giving bonus
    CASE
        WHEN COALESCE(ext.LARGEST_EXT_GIFT, 0) >= 10000        THEN 2
        WHEN COALESCE(ext.HIGHER_ED_GIFT_COUNT, 0) >= 10       THEN 1
        ELSE 0
    END                                                         AS HIGHER_ED_BONUS_SCORE,

    -- TOTAL PROPENSITY SCORE
    (
        CASE WHEN COALESCE(ext.LARGEST_EXT_GIFT,0) >= 10000 THEN 2
             WHEN COALESCE(ext.LARGEST_EXT_GIFT,0) >= 1000  THEN 1
             ELSE 0 END
        + COALESCE(ext.RECENT_EXT_GIVER_FLAG, 0)
        + COALESCE(ext.BROAD_GIVING_FLAG, 0)
        + COALESCE(ext.HIGH_FREQUENCY_FLAG, 0)
        + COALESCE(ext.HAS_NONPROFIT_AFFILIATION, 0)
        + CASE WHEN COALESCE(ext.LARGEST_EXT_GIFT,0) >= 10000 THEN 2
               WHEN COALESCE(ext.HIGHER_ED_GIFT_COUNT,0) >= 10 THEN 1
               ELSE 0 END
    )                                                           AS TOTAL_PROPENSITY_SCORE

FROM RAW.CONSTITUENT c
LEFT JOIN ANALYTICS.V_EXTERNAL_GIVING_SUMMARY ext ON c.CONSTITUENT_ID = ext.CONSTITUENT_ID
WHERE c.IS_DECEASED     = FALSE
  AND c.IS_DISQUALIFIED = FALSE;


-- ============================================================
-- SECTION 4: UNIFIED REPORTING MODEL
--            Single source of truth for all advancement reporting
-- ============================================================

CREATE OR REPLACE VIEW ANALYTICS.V_UNIFIED_PROSPECT_MODEL AS

SELECT

    -- ── Identity ──────────────────────────────────────────────
    c.CONSTITUENT_ID,
    c.FULL_NAME,
    c.FIRST_NAME,
    c.LAST_NAME,
    c.CLASS_YEAR,
    c.DEGREE_TYPE,
    c.CONSTITUENT_TYPE,
    c.CITY,
    c.STATE,
    c.RESEARCH_RATING,
    c.RESEARCH_RATING_AMT,
    c.NU_AFFILIATION_FLAG,

    -- ── NU Giving ─────────────────────────────────────────────
    COALESCE(g.TOTAL_GIFT_COUNT,        0)  AS NU_GIFT_COUNT,
    COALESCE(g.GIVING_YEARS,            0)  AS NU_GIVING_YEARS,
    COALESCE(g.LIFETIME_GIVING,         0)  AS NU_LIFETIME_GIVING,
    COALESCE(g.LARGEST_GIFT,            0)  AS NU_LARGEST_GIFT,
    COALESCE(g.AVG_GIFT,                0)  AS NU_AVG_GIFT,
    COALESCE(g.MOST_RECENT_FY,          0)  AS NU_MOST_RECENT_FY,
    COALESCE(g.CAMPAIGN_GIVING_YEARS,   0)  AS CAMPAIGN_GIVING_YEARS,
    COALESCE(g.HAS_MAJOR_GIFT,          0)  AS HAS_MAJOR_GIFT,
    COALESCE(g.HAS_LEADERSHIP_GIFT,     0)  AS HAS_LEADERSHIP_GIFT,
    COALESCE(g.RECENT_GIVER_FLAG,       0)  AS NU_RECENT_GIVER,

    -- ── Engagement ────────────────────────────────────────────
    COALESCE(e.TOTAL_VISITS,            0)  AS TOTAL_VISITS,
    COALESCE(e.TOTAL_ENGAGEMENTS,       0)  AS TOTAL_ENGAGEMENTS,
    COALESCE(e.RECENT_VISIT_FLAG,       0)  AS RECENT_VISIT_FLAG,
    COALESCE(e.MOST_RECENT_ENGAGEMENT_FY, 0) AS MOST_RECENT_ENGAGEMENT_FY,

    -- ── External Giving ───────────────────────────────────────
    COALESCE(ext.TOTAL_EXT_GIFTS,       0)  AS EXT_GIFT_COUNT,
    COALESCE(ext.TOTAL_ORGS_SUPPORTED,  0)  AS EXT_ORGS_COUNT,
    COALESCE(ext.LARGEST_EXT_GIFT,      0)  AS EXT_LARGEST_GIFT,
    COALESCE(ext.HIGHER_ED_GIFT_COUNT,  0)  AS HIGHER_ED_GIFT_COUNT,
    COALESCE(ext.HAS_NONPROFIT_AFFILIATION, 0) AS HAS_NONPROFIT_AFFILIATION,
    COALESCE(ext.RECENT_EXT_GIVER_FLAG, 0)  AS EXT_RECENT_GIVER,

    -- ── Scores ────────────────────────────────────────────────
    aff.TOTAL_AFFINITY_SCORE,
    prop.TOTAL_PROPENSITY_SCORE,

    -- Combined score (equal weighting)
    ROUND(
        (aff.TOTAL_AFFINITY_SCORE + prop.TOTAL_PROPENSITY_SCORE) / 2.0
    , 2)                                    AS COMBINED_SCORE,

    -- ── Prospect Grade (A/B/C/D) ──────────────────────────────
    -- Derived from combined score percentile buckets
    -- matching cluster model output from prospect segmentation
    CASE
        WHEN NTILE(4) OVER (
            ORDER BY (aff.TOTAL_AFFINITY_SCORE + prop.TOTAL_PROPENSITY_SCORE) DESC
        ) = 1 THEN 'A'
        WHEN NTILE(4) OVER (
            ORDER BY (aff.TOTAL_AFFINITY_SCORE + prop.TOTAL_PROPENSITY_SCORE) DESC
        ) = 2 THEN 'B'
        WHEN NTILE(4) OVER (
            ORDER BY (aff.TOTAL_AFFINITY_SCORE + prop.TOTAL_PROPENSITY_SCORE) DESC
        ) = 3 THEN 'C'
        ELSE 'D'
    END                                     AS PROSPECT_GRADE,

    -- ── Assignment ────────────────────────────────────────────
    pa.ASSIGNED_TO,
    pa.STATUS                               AS ASSIGNMENT_STATUS,
    pa.STAGE                                AS PROSPECT_STAGE,

    -- ── Metadata ──────────────────────────────────────────────
    c.UPDATED_AT                            AS RECORD_LAST_UPDATED

FROM RAW.CONSTITUENT                    c
LEFT JOIN ANALYTICS.V_NU_GIVING_SUMMARY      g   ON c.CONSTITUENT_ID = g.CONSTITUENT_ID
LEFT JOIN ANALYTICS.V_ENGAGEMENT_SUMMARY     e   ON c.CONSTITUENT_ID = e.CONSTITUENT_ID
LEFT JOIN ANALYTICS.V_EXTERNAL_GIVING_SUMMARY ext ON c.CONSTITUENT_ID = ext.CONSTITUENT_ID
LEFT JOIN ANALYTICS.V_AFFINITY_SCORE         aff  ON c.CONSTITUENT_ID = aff.CONSTITUENT_ID
LEFT JOIN ANALYTICS.V_PROPENSITY_SCORE       prop ON c.CONSTITUENT_ID = prop.CONSTITUENT_ID
LEFT JOIN RAW.PROSPECT_ASSIGNMENT            pa   ON c.CONSTITUENT_ID = pa.CONSTITUENT_ID

WHERE c.IS_DECEASED     = FALSE
  AND c.IS_DISQUALIFIED = FALSE;


-- ============================================================
-- SECTION 5: ANALYTICAL QUERIES
-- ============================================================

-- ------------------------------------------------------------
-- 5A. Top 50 Unassigned Prospects by Combined Score
--     Primary use case: identify next best prospects for MGO
--     assignment without requiring manual re-research
-- ------------------------------------------------------------
SELECT
    CONSTITUENT_ID,
    FULL_NAME,
    CONSTITUENT_TYPE,
    RESEARCH_RATING,
    TOTAL_AFFINITY_SCORE,
    TOTAL_PROPENSITY_SCORE,
    COMBINED_SCORE,
    PROSPECT_GRADE,
    NU_LIFETIME_GIVING,
    EXT_LARGEST_GIFT,
    TOTAL_VISITS,
    RECENT_VISIT_FLAG
FROM ANALYTICS.V_UNIFIED_PROSPECT_MODEL
WHERE ASSIGNMENT_STATUS IS NULL
   OR ASSIGNMENT_STATUS = 'Prospect'
ORDER BY COMBINED_SCORE DESC
LIMIT 50;


-- ------------------------------------------------------------
-- 5B. Grade Distribution Summary
--     How many prospects fall into each grade tier?
-- ------------------------------------------------------------
SELECT
    PROSPECT_GRADE,
    COUNT(*)                                AS PROSPECT_COUNT,
    ROUND(AVG(TOTAL_AFFINITY_SCORE), 2)     AS AVG_AFFINITY_SCORE,
    ROUND(AVG(TOTAL_PROPENSITY_SCORE), 2)   AS AVG_PROPENSITY_SCORE,
    ROUND(AVG(COMBINED_SCORE), 2)           AS AVG_COMBINED_SCORE,
    ROUND(AVG(NU_LIFETIME_GIVING), 2)       AS AVG_LIFETIME_GIVING,
    COUNT(CASE WHEN HAS_MAJOR_GIFT = 1
          THEN 1 END)                       AS COUNT_WITH_MAJOR_GIFT
FROM ANALYTICS.V_UNIFIED_PROSPECT_MODEL
GROUP BY PROSPECT_GRADE
ORDER BY PROSPECT_GRADE;


-- ------------------------------------------------------------
-- 5C. Giving Trend by Fiscal Year (Campaign Period FY08-FY17)
--     Tracks total NU giving volume across the Empower campaign
-- ------------------------------------------------------------
SELECT
    FISCAL_YEAR,
    COUNT(DISTINCT CONSTITUENT_ID)          AS UNIQUE_DONORS,
    COUNT(DISTINCT GIFT_ID)                 AS TOTAL_GIFTS,
    SUM(GIFT_AMOUNT)                        AS TOTAL_GIVING,
    ROUND(AVG(GIFT_AMOUNT), 2)              AS AVG_GIFT,
    MAX(GIFT_AMOUNT)                        AS LARGEST_GIFT,
    SUM(CASE WHEN GIFT_LEVEL = 'Major'
        THEN GIFT_AMOUNT ELSE 0 END)        AS MAJOR_GIFT_TOTAL,
    SUM(CASE WHEN GIFT_LEVEL = 'Leadership'
        THEN GIFT_AMOUNT ELSE 0 END)        AS LEADERSHIP_GIFT_TOTAL
FROM RAW.NU_GIFT
WHERE FISCAL_YEAR BETWEEN 2008 AND 2017
  AND IS_HARD_CREDIT = TRUE
GROUP BY FISCAL_YEAR
ORDER BY FISCAL_YEAR;


-- ------------------------------------------------------------
-- 5D. Constituent Type Performance Breakdown
--     Which constituent types generate the most giving value?
-- ------------------------------------------------------------
SELECT
    CONSTITUENT_TYPE,
    COUNT(DISTINCT CONSTITUENT_ID)          AS TOTAL_CONSTITUENTS,
    COUNT(DISTINCT CASE WHEN NU_LIFETIME_GIVING > 0
          THEN CONSTITUENT_ID END)          AS TOTAL_DONORS,
    ROUND(
        COUNT(DISTINCT CASE WHEN NU_LIFETIME_GIVING > 0
              THEN CONSTITUENT_ID END)
        / NULLIF(COUNT(DISTINCT CONSTITUENT_ID), 0) * 100
    , 1)                                    AS DONOR_PARTICIPATION_RATE,
    ROUND(SUM(NU_LIFETIME_GIVING), 2)       AS TOTAL_LIFETIME_GIVING,
    ROUND(AVG(NU_LIFETIME_GIVING), 2)       AS AVG_LIFETIME_GIVING,
    ROUND(AVG(TOTAL_AFFINITY_SCORE), 2)     AS AVG_AFFINITY_SCORE
FROM ANALYTICS.V_UNIFIED_PROSPECT_MODEL
GROUP BY CONSTITUENT_TYPE
ORDER BY TOTAL_LIFETIME_GIVING DESC;


-- ------------------------------------------------------------
-- 5E. High-Capacity Unvisited Prospects
--     Prospects with high research ratings and no visit on record
--     — a quick-win list for MGO outreach planning
-- ------------------------------------------------------------
SELECT
    CONSTITUENT_ID,
    FULL_NAME,
    CONSTITUENT_TYPE,
    RESEARCH_RATING,
    RESEARCH_RATING_AMT,
    PROSPECT_GRADE,
    TOTAL_AFFINITY_SCORE,
    TOTAL_PROPENSITY_SCORE,
    NU_LIFETIME_GIVING,
    EXT_LARGEST_GIFT
FROM ANALYTICS.V_UNIFIED_PROSPECT_MODEL
WHERE TOTAL_VISITS      = 0
  AND RESEARCH_RATING_AMT >= 500000
  AND PROSPECT_GRADE    IN ('A', 'B')
ORDER BY RESEARCH_RATING_AMT DESC, COMBINED_SCORE DESC;
