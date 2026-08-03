"""NYC taxi lakehouse dashboard.

Queries Athena directly -- no local copy of the data, no database server. Every
figure on screen comes from agg_daily_zone (1.37M rows, ~23 MB) rather than the
218M-row fact, so a full dashboard refresh scans single-digit megabytes.

Run:
    streamlit run dashboard/app.py

Requires AWS credentials on the machine (~/.aws/credentials) with Athena and
S3 read access. Uses the `taxi` workgroup, which caps any single query at 2 GiB.
"""

from __future__ import annotations

import awswrangler as wr
import pandas as pd
import plotly.graph_objects as go
import streamlit as st

DATABASE = "nyc_taxi"
WORKGROUP = "taxi"

st.set_page_config(page_title="NYC Taxi Lakehouse", page_icon="🚕", layout="wide")

# --------------------------------------------------------------------------
# Palette -- the validated reference instance. Both modes are *selected*, not
# an automatic flip: the dark column is the same hues re-stepped for the dark
# surface. Slots are assigned in fixed order and never cycled.
# --------------------------------------------------------------------------

LIGHT = {
    "surface": "#fcfcfb", "text": "#0b0b0b", "secondary": "#52514e",
    "muted": "#898781", "grid": "#e1e0d9", "axis": "#c3c2b7",
    "series": ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4"],
    # Sequential blue, light -> dark, for magnitude encoding.
    "ramp": ["#9ec5f4", "#86b6ef", "#6da7ec", "#5598e7", "#3987e5",
             "#2a78d6", "#256abf", "#1c5cab", "#184f95", "#104281"],
    "deemph": "#c3c2b7",
}

DARK = {
    "surface": "#1a1a19", "text": "#ffffff", "secondary": "#c3c2b7",
    "muted": "#898781", "grid": "#2c2c2a", "axis": "#383835",
    "series": ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181"],
    "ramp": ["#184f95", "#1c5cab", "#256abf", "#2a78d6", "#3987e5",
             "#5598e7", "#6da7ec", "#86b6ef", "#9ec5f4", "#b7d3f6"],
    "deemph": "#52514e",
}

P = DARK if (st.get_option("theme.base") or "light") == "dark" else LIGHT


# --------------------------------------------------------------------------
# Data access
# --------------------------------------------------------------------------

@st.cache_data(ttl=3600, show_spinner="Querying Athena…")
def q(sql: str) -> pd.DataFrame:
    """Run SQL on Athena and return a DataFrame.

    ctas_approach=False keeps this a plain query -- the CTAS path would create
    and drop a temporary table per call, which is slower and writes to S3 for
    no benefit at this size. Cached for an hour so re-renders on filter changes
    cost nothing; the underlying data only moves once a month.
    """
    return wr.athena.read_sql_query(
        sql, database=DATABASE, workgroup=WORKGROUP, ctas_approach=False
    )


@st.cache_data(ttl=3600)
def monthly() -> pd.DataFrame:
    return q("""
        SELECT d."year"                                          AS yr,
               d."month"                                         AS mo,
               SUM(a.trips)                                      AS trips,
               SUM(a.total_revenue)                              AS revenue,
               SUM(a.total_fare)                                 AS fare,
               SUM(a.trips)        FILTER (WHERE a.payment_type = 1) AS card_trips,
               SUM(a.tipped_trips) FILTER (WHERE a.payment_type = 1) AS card_tipped
        FROM nyc_taxi.agg_daily_zone a
        JOIN nyc_taxi.dim_date d ON a.pickup_date_key = d.date_key
        GROUP BY d."year", d."month"
        ORDER BY 1, 2
    """)


@st.cache_data(ttl=3600)
def by_zone() -> pd.DataFrame:
    return q("""
        SELECT l.zone, l.borough, d."year" AS yr, SUM(a.trips) AS trips
        FROM nyc_taxi.agg_daily_zone a
        JOIN nyc_taxi.dim_location l ON a.pickup_location_id = l.location_id
        JOIN nyc_taxi.dim_date     d ON a.pickup_date_key    = d.date_key
        GROUP BY l.zone, l.borough, d."year"
    """)


@st.cache_data(ttl=3600)
def by_payment() -> pd.DataFrame:
    return q("""
        SELECT p.payment_desc, d."year" AS yr,
               SUM(a.trips)        AS trips,
               SUM(a.tipped_trips) AS tipped,
               SUM(a.total_tip)    AS tip_total
        FROM nyc_taxi.agg_daily_zone a
        JOIN nyc_taxi.dim_payment p ON a.payment_type    = p.payment_type
        JOIN nyc_taxi.dim_date    d ON a.pickup_date_key = d.date_key
        GROUP BY p.payment_desc, d."year"
    """)


@st.cache_data(ttl=3600)
def by_borough() -> pd.DataFrame:
    """Card-only measures, because a cash tip is never recorded -- comparing
    raw tip rates across boroughs compares payment mix, not generosity."""
    return q("""
        SELECT l.borough, d."year" AS yr,
               SUM(a.trips)                                          AS trips,
               SUM(a.trips)        FILTER (WHERE a.payment_type = 1) AS card_trips,
               SUM(a.tipped_trips) FILTER (WHERE a.payment_type = 1) AS card_tipped,
               SUM(a.total_tip)    FILTER (WHERE a.payment_type = 1) AS card_tip_total
        FROM nyc_taxi.agg_daily_zone a
        JOIN nyc_taxi.dim_location l ON a.pickup_location_id = l.location_id
        JOIN nyc_taxi.dim_date     d ON a.pickup_date_key    = d.date_key
        WHERE l.borough NOT IN ('Unknown', 'N/A')
        GROUP BY l.borough, d."year"
    """)


# --------------------------------------------------------------------------
# Chart chrome -- recessive grid, muted axes, no chart junk
# --------------------------------------------------------------------------

def style(fig: go.Figure, height: int = 320, showlegend: bool = False) -> go.Figure:
    fig.update_layout(
        height=height,
        showlegend=showlegend,
        margin=dict(l=8, r=8, t=8, b=8),
        paper_bgcolor=P["surface"],
        plot_bgcolor=P["surface"],
        font=dict(family='system-ui, -apple-system, "Segoe UI", sans-serif',
                  size=12, color=P["secondary"]),
        hoverlabel=dict(bgcolor=P["surface"], bordercolor=P["axis"],
                        font=dict(color=P["text"], size=12)),
        legend=dict(orientation="h", yanchor="bottom", y=1.0, x=0,
                    font=dict(color=P["secondary"])),
    )
    fig.update_xaxes(showgrid=False, linecolor=P["axis"], zeroline=False,
                     tickfont=dict(color=P["muted"], size=11))
    fig.update_yaxes(gridcolor=P["grid"], griddash="solid", linecolor=P["axis"],
                     zeroline=False, tickfont=dict(color=P["muted"], size=11))
    return fig


def table_view(df: pd.DataFrame, label: str = "Table view") -> None:
    """Three light-mode slots sit below 3:1 contrast, which obligates relief:
    visible labels or a table. This provides the table half."""
    with st.expander(label):
        st.dataframe(df, width="stretch", hide_index=True)


# --------------------------------------------------------------------------
# Page
# --------------------------------------------------------------------------

st.title("NYC Yellow Taxi")
st.caption("218M trips · 2021–2026 · Athena over partitioned parquet in S3")

m, z, pay = monthly(), by_zone(), by_payment()

years = sorted(m["yr"].unique())
picked = st.sidebar.multiselect("Years", years, default=years)
if not picked:
    st.warning("Select at least one year.")
    st.stop()

m, z, pay = (df[df["yr"].isin(picked)] for df in (m, z, pay))

# --- KPI row: headline numbers are stat tiles, not a one-bar chart ---------

trips = int(m["trips"].sum())
revenue = float(m["revenue"].sum())
card_t = int(m["card_trips"].sum())
card_tip = int(m["card_tipped"].sum())

k1, k2, k3, k4 = st.columns(4)
k1.metric("Trips", f"{trips/1e6:.1f}M")
k2.metric("Revenue", f"${revenue/1e9:.2f}B")
k3.metric("Avg fare", f"${m['fare'].sum()/trips:,.2f}")
k4.metric("Tipped (card only)", f"{100*card_tip/card_t:.1f}%")

st.divider()

# --- Trend over time: one series, so no legend -- the title names it -------

left, right = st.columns([3, 2])

with left:
    st.subheader("Trips per month")
    ts = m.assign(period=pd.to_datetime(
        m["yr"].astype(str) + "-" + m["mo"].astype(str).str.zfill(2) + "-01"))
    fig = go.Figure(go.Scatter(
        x=ts["period"], y=ts["trips"], mode="lines",
        line=dict(color=P["series"][0], width=2),
        hovertemplate="%{x|%b %Y}<br>%{y:,.0f} trips<extra></extra>",
    ))
    st.plotly_chart(style(fig), width="stretch")
    table_view(ts[["yr", "mo", "trips", "revenue"]])

# --- Magnitude comparison: sequential ramp, more-is-darker ----------------

with right:
    st.subheader("Top pickup zones")
    top = (z.groupby("zone", as_index=False)["trips"].sum()
             .nlargest(10, "trips").sort_values("trips"))
    fig = go.Figure(go.Bar(
        x=top["trips"], y=top["zone"], orientation="h",
        marker=dict(color=[P["ramp"][min(9, i)] for i in range(len(top))],
                    cornerradius=4, line=dict(width=0)),
        hovertemplate="%{y}<br>%{x:,.0f} trips<extra></extra>",
    ))
    st.plotly_chart(style(fig, height=320), width="stretch")
    table_view(top.sort_values("trips", ascending=False))

st.divider()

# --- Part-to-whole over time: categorical, tail folded into "Other" -------

c1, c2 = st.columns(2)

# --- Emphasis: one mark is the point, the rest are context ----------------
#
# Charting tip RATE here fails: cash records 0.02%, so its bar has no width
# and the accent colour -- the whole point -- is invisible. Charting trip
# VOLUME instead makes cash a large, visible bar and carries the rate as a
# direct label. Same finding, and it can actually be seen.

with c1:
    st.subheader("Where tips go unrecorded")
    t = pay.groupby("payment_desc", as_index=False)[["trips", "tipped"]].sum()
    t = t[t["trips"] > 10_000]
    t["pct"] = 100 * t["tipped"] / t["trips"]
    t = t.sort_values("trips")

    colors = [P["series"][1] if d == "Cash" else P["deemph"]
              for d in t["payment_desc"]]
    fig = go.Figure(go.Bar(
        x=t["trips"], y=t["payment_desc"], orientation="h",
        marker=dict(color=colors, cornerradius=4, line=dict(width=0)),
        text=[f"{v/1e6:,.1f}M · {p:.1f}% tipped"
              for v, p in zip(t["trips"], t["pct"])],
        textposition="outside",
        textfont=dict(color=P["secondary"], size=11),
        hovertemplate="%{y}<br>%{x:,.0f} trips<extra></extra>",
    ))
    fig.update_xaxes(range=[0, t["trips"].max() * 1.55])
    st.plotly_chart(style(fig), width="stretch")
    st.caption(
        "Cash reads ~0% not because those riders don't tip, but because the "
        "meter never records a cash tip. Those 32.7M trips are tip-blind — any "
        "tipping comparison that doesn't filter to card is really comparing "
        "payment mix."
    )
    table_view(t)

# --- Magnitude comparison, sequential ramp --------------------------------
#
# Card-only rates span 6% to 96%, so zero is a meaningful baseline and a bar
# is the right form. (A dot plot would be the fix only if the values clustered
# in a narrow band well above zero, where a zero-baseline bar flattens them.)

with c2:
    st.subheader("Card-only tip rate by borough")
    bb = by_borough()
    bb = bb[bb["yr"].isin(picked)]
    g = bb.groupby("borough", as_index=False)[["card_trips", "card_tipped"]].sum()
    g = g[g["card_trips"] > 100_000]
    g["pct"] = 100 * g["card_tipped"] / g["card_trips"]
    g = g.sort_values("pct")

    fig = go.Figure(go.Bar(
        x=g["pct"], y=g["borough"], orientation="h",
        marker=dict(color=[P["ramp"][min(9, i * 3)] for i in range(len(g))],
                    cornerradius=4, line=dict(width=0)),
        text=[f"{v:.1f}%" for v in g["pct"]],
        textposition="outside",
        textfont=dict(color=P["secondary"], size=11),
        customdata=g["card_trips"],
        hovertemplate="%{y}<br>%{x:.2f}% of card trips tipped"
                      "<br>%{customdata:,.0f} card trips<extra></extra>",
    ))
    fig.update_xaxes(range=[0, 118])
    st.plotly_chart(style(fig), width="stretch")
    st.caption(
        "Restricted to credit-card trips, where a tip is observable at all. "
        "Filtering to card does **not** close the borough gap — Bronx card "
        "trips record a tip 6.3% of the time versus Manhattan's 95.6%. Payment "
        "mix explains part of the difference, not all of it. Note the volumes "
        "differ hugely (Bronx 0.4M card trips vs Manhattan 140M); treat this as "
        "a lead to investigate, not a conclusion."
    )
    table_view(g)
