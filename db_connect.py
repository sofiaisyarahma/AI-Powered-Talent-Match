# db_connect.py
from sqlalchemy import create_engine, text
import pandas as pd
import streamlit as st    

# --- Supabase Pooler Connection (IPv4 + SSL) ---
DATABASE_URL = (
    "postgresql+psycopg2://postgres.ozrslcahiekgbhjgavdn:"
    "nbkUvCOJINUznlXt@aws-1-ap-southeast-1.pooler.supabase.com:"
    "5432/postgres?sslmode=require"
)
# --- Create engine with SSL and pre-ping ---
engine = create_engine(DATABASE_URL, pool_pre_ping=True)

def run_query(query: str, params=None):
    """
    Run SELECT or INSERT/UPDATE safely with SQLAlchemy.
    Automatically handles RETURNING queries.
    """
    query_obj = text(query)
    with engine.begin() as conn:
        if query.strip().lower().startswith("select"):
            return pd.read_sql(query_obj, conn, params=params)
        else:
            result = conn.execute(query_obj, params or {})
            try:
                df = pd.DataFrame(result.fetchall(), columns=result.keys())
                return df
            except Exception:
                return None



