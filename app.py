# app.py
import streamlit as st
import pandas as pd
import plotly.express as px
from db_connect import run_query
# from openai import OpenAI 
import os

# --- Streamlit Page Setup ---
st.set_page_config(page_title="AI-Powered Talent Match by Sofi Aisyarahma", layout="wide")
st.title("AI-Powered Talent Match by Sofi Aisyarahma")

# --- Sidebar Inputs ---
st.sidebar.header("Input Parameters")
role_name = st.sidebar.text_input("Role Name", "Data Analyst")
job_level = st.sidebar.selectbox("Job Level", ["Junior", "Mid", "Senior"])
role_purpose = st.sidebar.text_area("Role Purpose", "Analyze business and operational data.")
benchmark_ids = st.sidebar.text_input("Benchmark Employee IDs (comma-separated)", "1001,1002,1003")

# --- Run Button ---
if st.sidebar.button("Run Talent Match"):
    benchmark_list = [int(i.strip()) for i in benchmark_ids.split(",") if i.strip().isdigit()]

    # --- 1. Insert into talent_benchmarks and get job_id ---
    insert_sql = """
    INSERT INTO talent_benchmarks (role_name, job_level, role_purpose, selected_talent_ids)
    VALUES (:role_name, :job_level, :role_purpose, :selected_talent_ids)
    RETURNING job_vacancy_id;
    """

    params = {
        "role_name": role_name,
        "job_level": job_level,
        "role_purpose": role_purpose,
        "selected_talent_ids": benchmark_list
    }

    df_job = run_query(insert_sql, params)
    if df_job is None or df_job.empty:
        st.error("Failed to insert or retrieve job_vacancy_id from database.")
        st.stop()

    job_id = int(df_job["job_vacancy_id"].iloc[0])
    st.success(f"Created Job Vacancy ID: {job_id}")

    # --- 2. Load and inject parameters into the SQL engine file ---
    with open("AI_Powered_Talent_Match.sql") as f:
        main_sql = f.read()

    # Replace placeholders with actual values
    replacements = {
        "{{ job_vacancy_id }}": str(job_id),
        "{{ role_name }}": role_name,
        "{{ role_level }}": job_level,
        "{{ role_purpose }}": role_purpose,
        "{{ selected_talent_ids }}": ",".join(map(str, benchmark_list)),
        "{{ weights_config }}": "{}"
    }

    for k, v in replacements.items():
        main_sql = main_sql.replace(k, v)

    # --- 3. Execute main query ---
    results = run_query(main_sql)
    if results is None or results.empty:
        st.warning("No results returned. Check SQL logic or parameters.")
        st.stop()

    # --- 4. Display Results ---
    st.subheader("Ranked Talent List")
    ranked_df = results[['employee_name', 'final_match_rate']].sort_values('final_match_rate', ascending=False)
    st.dataframe(ranked_df)

    # --- 5. Distribution Chart ---
    fig = px.histogram(results, x="final_match_rate", nbins=15, color_discrete_sequence=["skyblue"])
    fig.update_layout(title="Distribution of Talent Match Scores", xaxis_title="Match Rate", yaxis_title="Count")
    st.plotly_chart(fig, use_container_width=True)

    # --- 6. AI Summary ---
    st.subheader("AI Summary of Insights")

    import requests
    import json
    import os

    # Prepare your top candidate data
    top_data = results[['employee_name', 'final_match_rate']].head(10).to_dict(orient="records")

    ai_prompt = f"""
    Role: {role_name}
    Purpose: {role_purpose}
    Based on this ranking data:
    {top_data}

    Write a concise 150-word summary describing what traits top candidates share
    and how they align with the role.
    """

    try:
        # Build request payload
        payload = {
            "model": "openai/gpt-4o",  # or "gpt-4o-mini" for faster, cheaper
            "messages": [
                {"role": "system", "content": "You are an expert HR data analyst writing a short insight summary."},
                {"role": "user", "content": ai_prompt}
            ]
        }

        # Send request to OpenRouter API
        response = requests.post(
            url="https://openrouter.ai/api/v1/chat/completions",
            headers={
                "Authorization": f"Bearer {os.getenv('OPENROUTER_API_KEY', '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')}",
                "Content-Type": "application/json",
                "HTTP-Referer": "https://your-site-url.com",  # optional, for ranking
                "X-Title": "AI Talent Match Dashboard"        # optional
            },
            data=json.dumps(payload)
        )

        # Handle response
        if response.status_code == 200:
            ai_data = response.json()
            ai_summary = ai_data["choices"][0]["message"]["content"]
            st.write(ai_summary)
        else:
            st.error(f"AI Summary failed ({response.status_code}): {response.text}")

    except Exception as e:
        st.error(f"AI Summary failed: {e}")

