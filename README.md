# Advancement Analytics Data Model — Snowflake

Unified data model and prospect scoring system built in Snowflake SQL
for Northeastern University's Advancement Services division.

## Project Overview
This project consolidates constituent biographical data, institutional
giving history, engagement records, and external philanthropic data
into a single source of truth for advancement reporting and major gift
prospect prioritization.

## Files
- `advancement_analytics_model.sql` — Full Snowflake DDL, scoring
   views, unified reporting model, and five analytical queries
- `Advancement_Data_Dictionary.docx` — Complete documentation of
   every table, view, column, and scoring component

## Key Features
- Five raw source tables with full Snowflake DDL
- Affinity Score model (internal CRM data, scale 0–13)
- Propensity Score model (external giving data, scale 0–8)
- Unified V_UNIFIED_PROSPECT_MODEL with NTILE(4) grade assignment
- Five production-ready analytical queries
- Full data dictionary for team reference and onboarding

## Skills Demonstrated
Snowflake SQL · Data Modeling · Window Functions · ETL/ELT Design ·
Scoring Model Development · Advancement Analytics
