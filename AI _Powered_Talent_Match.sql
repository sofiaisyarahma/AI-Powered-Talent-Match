/* ============================================================
   TALENT MATCH SCORING ENGINE (Psychometric-Only Model)
   ------------------------------------------------------------
   Author: Sofi Aisyarahma
   Purpose:
     Calculate employee match scores against benchmark traits
     using Pauli, GTQ, TIKI, IQ, PAPI Kostick, MBTI, DISC,
     and CliftonStrengths data.
   ============================================================ */


/* ------------------------------------------------------------
   PARAMETERS — inputs for job & benchmark setup
------------------------------------------------------------ */
WITH
params AS (
  SELECT
    {{ job_vacancy_id }}                 AS job_vacancy_id,
    '{{ role_name }}'                    AS role_name,
    '{{ role_level }}'                   AS role_level,
    '{{ role_purpose }}'                 AS role_purpose,
    ARRAY[{{ selected_talent_ids }}]::INT[] AS selected_talent_ids,  -- e.g. ARRAY[1001,1005,1010]
    '{{ weights_config }}'::JSONB        AS weights_config           -- TGV weights
),

/* ------------------------------------------------------------
   BENCHMARK BASELINES — numeric medians from top performers
------------------------------------------------------------ */
numeric_baseline AS (
  VALUES
    ('gtq', 27.0, 'Cognitive Complexity & Problem-Solving'),
    ('iq', 110.0, 'Cognitive Complexity & Problem-Solving'),
    ('tiki', 6.0, 'Cognitive Complexity & Problem-Solving'),
    ('pauli', 64.0, 'Motivation & Drive'),
    ('papi_a', 5.0, 'Motivation & Drive'),
    ('papi_b', 5.0, 'Social Orientation & Collaboration'),
    ('papi_c', 5.0, 'Conscientiousness & Reliability'),
    ('papi_d', 5.0, 'Conscientiousness & Reliability'),
    ('papi_e', 5.0, 'Adaptability & Stress Tolerance'),
    ('papi_g', 5.0, 'Motivation & Drive'),
    ('papi_k', 5.0, 'Leadership & Influence'),
    ('papi_l', 5.0, 'Leadership & Influence'),
    ('papi_n', 5.0, 'Motivation & Drive'),
    ('papi_o', 5.0, 'Social Orientation & Collaboration'),
    ('papi_p', 5.0, 'Leadership & Influence'),
    ('papi_s', 5.0, 'Social Orientation & Collaboration'),
    ('papi_t', 5.0, 'Adaptability & Stress Tolerance')
) AS nb(tv_name, benchmark_value, tgv_name),

/* ------------------------------------------------------------
  UNIFY TALENT VARIABLES (TV)
------------------------------------------------------------ */
tv_union AS (
  -- numeric TVs
  SELECT employee_id, 'gtq' AS tv_name, gtq_score::NUMERIC AS tv_value,
         'Cognitive Complexity & Problem-Solving' AS tgv_name, 'numeric' AS data_type
  FROM profiles_psych
  UNION ALL
  SELECT employee_id, 'iq', iq_score::NUMERIC, 'Cognitive Complexity & Problem-Solving', 'numeric' FROM profiles_psych
  UNION ALL
  SELECT employee_id, 'tiki', tiki_score::NUMERIC, 'Cognitive Complexity & Problem-Solving', 'numeric' FROM profiles_psych
  UNION ALL
  SELECT employee_id, 'pauli', pauli_score::NUMERIC, 'Motivation & Drive', 'numeric' FROM profiles_psych
  UNION ALL
  SELECT employee_id, column_name AS tv_name, column_value::NUMERIC AS tv_value,
         CASE
           WHEN column_name IN ('papi_a','papi_g','papi_n') THEN 'Motivation & Drive'
           WHEN column_name IN ('papi_k','papi_l','papi_p') THEN 'Leadership & Influence'
           WHEN column_name IN ('papi_b','papi_o','papi_s') THEN 'Social Orientation & Collaboration'
           WHEN column_name IN ('papi_c','papi_d') THEN 'Conscientiousness & Reliability'
           WHEN column_name IN ('papi_e','papi_t') THEN 'Adaptability & Stress Tolerance'
         END AS tgv_name,
         'numeric' AS data_type
  FROM papi_scores
  CROSS JOIN LATERAL (
    VALUES
      ('papi_a', papi_a), ('papi_b', papi_b), ('papi_c', papi_c),
      ('papi_d', papi_d), ('papi_e', papi_e), ('papi_g', papi_g),
      ('papi_k', papi_k), ('papi_l', papi_l), ('papi_n', papi_n),
      ('papi_o', papi_o), ('papi_p', papi_p), ('papi_s', papi_s),
      ('papi_t', papi_t)
  ) AS unpivot(column_name, column_value)
  WHERE column_value IS NOT NULL

  -- categorical TVs
  UNION ALL
  SELECT employee_id, 'mbti_type', mbti_type::TEXT, 'Creativity & Innovation Orientation', 'categorical'
  FROM profiles_psych
  UNION ALL
  SELECT employee_id, 'disc_type', disc_type::TEXT, 'Leadership & Influence', 'categorical'
  FROM profiles_psych
  UNION ALL
  SELECT employee_id, CONCAT('strength_', rank) AS tv_name, theme::TEXT,
         'Motivation & Drive', 'categorical'
  FROM strengths
),

/* ------------------------------------------------------------
  TV MATCH RATE (numeric & categorical)
------------------------------------------------------------ */
tv_match AS (
  SELECT
    t.employee_id,
    t.tv_name,
    t.tgv_name,
    t.data_type,
	CASE
	  WHEN t.data_type = 'numeric' AND b.benchmark_value IS NOT NULL THEN
		CASE
		  -- Normal scoring (higher = better)
		  WHEN t.tv_name NOT IN ('papi_k') THEN
			LEAST((t.tv_value / NULLIF(b.benchmark_value, 0)) * 100, 100)

		  -- Inverse scoring for PAPI_K (lower = better)
		  WHEN t.tv_name = 'papi_k' THEN
			LEAST(((2 * b.benchmark_value - t.tv_value) / NULLIF(b.benchmark_value, 0)) * 100, 100)
		END
      WHEN t.data_type = 'categorical' THEN
        CASE
          -- exact match for DISC and CliftonStrengths
          WHEN t.tv_name LIKE 'strength_%' AND t.tv_value IN (
               SELECT theme FROM strengths WHERE employee_id = ANY((SELECT selected_talent_ids FROM params))
          ) THEN 100
          WHEN t.tv_name = 'disc_type' AND t.tv_value IN (
               SELECT disc_type FROM profiles_psych WHERE employee_id = ANY((SELECT selected_talent_ids FROM params))
          ) THEN 100
          -- partial match for MBTI (example: ENFP contains N or P)
          WHEN t.tv_name = 'mbti_type' AND EXISTS (
               SELECT 1 FROM profiles_psych p
               WHERE p.employee_id = ANY((SELECT selected_talent_ids FROM params))
                 AND (
                    (p.mbti_type ILIKE '%N%' AND t.tv_value ILIKE '%N%')
                 OR (p.mbti_type ILIKE '%P%' AND t.tv_value ILIKE '%P%')
                 )
          ) THEN 100
          ELSE 0
        END
    END AS tv_match_rate
  FROM tv_union t
  LEFT JOIN numeric_baseline b
         ON t.tv_name = b.tv_name
),

/* ------------------------------------------------------------
  TGV MATCH RATE (average TV matches within each TGV)
------------------------------------------------------------ */
tgv_match AS (
  SELECT
    employee_id,
    tgv_name,
    AVG(tv_match_rate) AS tgv_match_rate
  FROM tv_match
  WHERE tv_match_rate IS NOT NULL
  GROUP BY employee_id, tgv_name
),

/* ------------------------------------------------------------
  APPLY TGV WEIGHTS (equal or JSONB custom)
------------------------------------------------------------ */
weighted_tgv AS (
  SELECT
    t.employee_id,
    t.tgv_name,
    t.tgv_match_rate,
    COALESCE((p.weights_config ->> t.tgv_name)::NUMERIC, 1.0) AS tgv_weight
  FROM tgv_match t
  CROSS JOIN params p
),

/* ------------------------------------------------------------
  FINAL MATCH RATE (weighted average across all TGVs)
------------------------------------------------------------ */
final_match AS (
  SELECT
    employee_id,
    ROUND(SUM(tgv_match_rate * tgv_weight) / NULLIF(SUM(tgv_weight),0), 2) AS final_match_rate
  FROM weighted_tgv
  GROUP BY employee_id
)

/* ------------------------------------------------------------
  OUTPUT — full results with TGV breakdown
------------------------------------------------------------ */
SELECT
  p.job_vacancy_id,
  p.role_name,
  p.role_level,
  p.role_purpose,
  e.employee_id,
  e.employee_name,
  f.final_match_rate,
  JSON_AGG(
    JSON_BUILD_OBJECT(
      'TGV', t.tgv_name,
      'TGV_Match', ROUND(t.tgv_match_rate,2),
      'Weight', ROUND(t.tgv_weight,2)
    ) ORDER BY t.tgv_name
  ) AS tgv_breakdown
FROM params p
JOIN final_match f ON TRUE
JOIN employees e ON e.employee_id = f.employee_id
JOIN weighted_tgv t ON t.employee_id = f.employee_id
GROUP BY p.job_vacancy_id, p.role_name, p.role_level, p.role_purpose,
         e.employee_id, e.employee_name, f.final_match_rate
ORDER BY f.final_match_rate DESC;


--How to Run It (Insert the parameters)
--pass this directly into the query
SET job_vacancy_id = 301;
SET role_name = 'Senior Analyst';
SET job_level = 'Manager';
SET role_purpose = 'Deliver insight and decision support';
SET selected_talent_ids = '1001,1003,1008';
SET weights_config = '{
  "Cognitive Complexity & Problem-Solving": 0.25,
  "Motivation & Drive": 0.20,
  "Leadership & Influence": 0.15,
  "Social Orientation & Collaboration": 0.15,
  "Creativity & Innovation Orientation": 0.10,
  "Conscientiousness & Reliability": 0.08,
  "Adaptability & Stress Tolerance": 0.07
}';
