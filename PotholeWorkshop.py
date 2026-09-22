# =====================================================================
# NYC Pothole Complaints by NTA — the Python path
#
# Companion to PotholeWorkshop.md, parallel to PotholeWorkshop.R.
# Sections are numbered to match the R script, and field and layer
# names match the QGIS version (PotholeComplaints, PotholeRate,
# NTA_PotholeTotals), so all three outputs can be compared directly.
#
# The five operations are the same everywhere:
#
#   1. join a table to polygons
#   2. dissolve polygons and sum an attribute
#   3. make points from coordinates and reproject
#   4. count points in polygon
#   5. derive a rate and classify it
#
# Run it top to bottom as a script, or paste it section by section into
# a notebook. The print() checkpoints should match the counts you see
# in the QGIS layer panel.
# =====================================================================


# ---- 0. Packages ----------------------------------------------------
# pip install geopandas mapclassify matplotlib
# (optionally numba too: mapclassify warns without it, harmlessly)
#
# Note: this needs a normal Python environment. The Python console
# built into QGIS does not ship with geopandas.

from pathlib import Path

import geopandas as gpd
import mapclassify
import matplotlib.pyplot as plt
import pandas as pd


# ---- 1. Config ------------------------------------------------------
# CHANGE THESE to match your files. Everything below should run
# unmodified. A wrong field name surfaces at the merge, not here, so
# check .columns on each layer after reading it.

tract_path = "data/cul_nyc_tracts_2020.gpkg"
pot_path   = "data/Pothole_311_complaints_2026.csv"

# Population: either the raw data.census.gov download, or the cleaned
# CSV the workshop has you build. Set ONE of these; leave the other None.
acs_raw   = None                                  # or "data/ACSDT5Y2024.B01003-Data.csv"
pop_clean = "data/Population2024.csv"             # the cleaned CSV, ships with this repo

out_gpkg = "outputs/NTA_PotholeTotals.gpkg"
out_png  = "outputs/NTA_PotholeTotals.png"

crs_ft = 2263   # NAD83 / New York Long Island (ftUS) — as in QGIS
crs_ll = 4326   # what the 311 lat/lon columns are in

# Tract layer fields:
f_geoid   = "GEOID"     # 11-character tract identifier
f_nta     = "NTA2020"   # NTA code
f_ntaname = "NTAName"   # NTA name

# 311 export columns. The portal relabelled these in Dec 2025, and a CSV
# downloaded through the UI may carry either set of headers. Check with
# pd.read_csv(pot_path, nrows=0).columns and set accordingly.
f_problem = "Complaint Type"   # newer exports: "Problem"
f_detail  = "Descriptor"       # newer exports: "Problem Detail"
f_lat     = "Latitude"
f_lon     = "Longitude"


# ---- 2. Tract polygons ----------------------------------------------
# QGIS: drag the .gpkg in, then Layer Properties to check the CRS.
# Transform immediately so every later operation happens in feet.

tracts = gpd.read_file(tract_path).to_crs(crs_ft)

print(list(tracts.columns))              # <- check against section 1
print(f"tracts read: {len(tracts)}")


# ---- 3. Population table --------------------------------------------
# QGIS: open the ACS csv in a spreadsheet, delete the label row, keep
# two columns, use =RIGHT(A2,11) to trim GEO_ID, paste-special as
# values, rename, save as Population2024.csv.
#
# skiprows=[1] drops the second line of the file at read time. That is
# the "delete the second row" step, and because the label row never
# enters the frame, pandas infers the estimate column as numeric on its
# own. (The R version has to drop the row and then convert.)
#
# .str[-11:] is =RIGHT(A2,11).

if acs_raw is not None:
    pop = pd.read_csv(acs_raw, skiprows=[1])
    pop = pd.DataFrame({
        "FIPS":       pop["GEO_ID"].str[-11:],   # 1400000US36061019500 -> 36061019500
        "Population": pop["B01003_001E"],
    })
else:
    # The pre-cleaned CSV from the data folder, for anyone who skipped
    # ahead. dtype=str on FIPS is the QGIS "set FIPS to Text (string)"
    # step: without it pandas reads the column as integers and the
    # merge below matches nothing.
    pop = pd.read_csv(pop_clean, dtype={"FIPS": str})

print(f"population rows: {len(pop)}")

# Note: the Census Bureau's API returns this same table as one URL,
# which is what tidycensus (R) and pygris (Python) wrap:
#
#   url = ("https://api.census.gov/data/2024/acs/acs5"
#          "?get=B01003_001E&for=tract:*"
#          "&in=state:36&in=county:005,047,061,081,085")
#   api = pd.read_json(url)
#   api.columns = api.iloc[0]; api = api[1:]
#   pop = pd.DataFrame({
#       "FIPS": api["state"] + api["county"] + api["tract"],
#       "Population": api["B01003_001E"].astype(int),
#   })
#
# The manual path is kept here so the steps line up with QGIS.


# ---- 4. Join, then dissolve to NTA ----------------------------------
# QGIS: Properties > Joins to attach the table, export to make it
# permanent, then Processing > Aggregate grouping on NTA2020, with
# first_value on the name fields and sum on Population.
#
# .merge() is the table join. .dissolve() is Aggregate: selecting the
# columns first is the "delete the fields you don't need" step, and
# aggfunc="sum" is the sum on Population. Like R, there is no
# intermediate TractsWithPopulation file.

tracts_pop = tracts.merge(pop, left_on=f_geoid, right_on="FIPS", how="left")

# Unmatched tracts should be 0. The usual culprit is a FIPS that lost a
# leading zero somewhere along the way.
print(f"tracts with no population match: {tracts_pop['Population'].isna().sum()}")

ntas = (
    tracts_pop[[f_nta, f_ntaname, "Population", "geometry"]]
    .dissolve(by=[f_nta, f_ntaname], aggfunc="sum")
    .reset_index()
    .rename(columns={f_nta: "NTA2020", f_ntaname: "NTAName"})
)

print(f"NTAs after dissolve: {len(ntas)}")


# ---- 5. Complaints as points ----------------------------------------
# QGIS: Data Source Manager > Delimited Text, X = longitude,
# Y = latitude, CRS = EPSG:4326, then Export > Save As in EPSG:2263.
#
# The filter reproduces the portal filters. The portal uses CONTAINS,
# not equals, so .str.contains(case=False) is the faithful translation;
# == would silently select a different set of records and your
# checkpoint wouldn't match. na=False keeps rows with a blank field from
# breaking the filter.
#
# If you downloaded the pre-filtered CSV from the data folder, the
# first two conditions are redundant but harmless.

raw = pd.read_csv(pot_path, low_memory=False)
print(list(raw.columns))                 # <- check f_problem / f_detail

keep = (
    raw[f_problem].str.contains("street condition", case=False, na=False)
    & raw[f_detail].str.contains("pothole", case=False, na=False)
    & raw[f_lat].notna()
    & raw[f_lon].notna()
)

# Optional date window, if your export covers more than Jan-Aug 2026:
#
#   created = pd.to_datetime(raw["Created Date"],
#                            format="%m/%d/%Y %I:%M:%S %p")
#   keep &= (created >= "2026-01-01") & (created < "2026-09-01")

pts = raw[keep]
potholes = gpd.GeoDataFrame(
    pts,
    geometry=gpd.points_from_xy(pts[f_lon], pts[f_lat]),
    crs=crs_ll,
).to_crs(crs_ft)

# Worth reporting out loud, because the portal filter hides it: roughly
# half of all pothole complaints carry no coordinates and never reach
# the map at all.
print(f"rows in export: {len(raw)} | mapped: {len(potholes)}")   # expect 27,158


# ---- 6. Count points in polygon -------------------------------------
# QGIS: Vector > Analysis Tools > Count Points in Polygon, writing a
# PotholeComplaints field to a new layer.
#
# sjoin attaches the NTA code to every point that intersects an NTA;
# groupby().size() counts them. predicate="intersects" matches the R
# version (st_intersects).

hits = gpd.sjoin(
    potholes[["geometry"]],
    ntas[["NTA2020", "geometry"]],
    how="inner",
    predicate="intersects",
)

counts = hits.groupby("NTA2020").size()
ntas["PotholeComplaints"] = ntas["NTA2020"].map(counts).fillna(0).astype(int)

# Two checkpoints, and the second is the interesting one.
#
# dropped: points that fell outside every NTA — geocodes landing in
# water or just past the shoreline. A handful is normal; hundreds means
# a CRS problem.
#
# double-counted: points that intersect MORE than one NTA. That happens
# when a point sits exactly on a shared boundary, and NTA boundaries in
# NYC mostly follow street centerlines — which is precisely where
# pothole complaints get geocoded. If this is nonzero, the same
# complaint is being counted in two neighborhoods, and the QGIS and R
# versions are doing it too.
matched = hits.index.nunique()
print(f"complaints inside an NTA: {matched} | "
      f"dropped: {len(potholes) - matched} | "
      f"double-counted: {len(hits) - matched}")


# ---- 7. Rate --------------------------------------------------------
# QGIS: Field Calculator, new decimal field PotholeRate, expression
# ( "PotholeComplaints" / "Population" ) * 1000
#
# The 2020 NTA scheme includes airports, parks and cemeteries with no
# residents. QGIS divides by zero there and returns NULL, which renders
# as unclassified grey rather than failing — so the holes in the QGIS
# map are these. Dropping them explicitly also keeps them out of the
# classification.

zero_pop = ntas.loc[ntas["Population"] == 0, "NTAName"].tolist()
print(f"NTAs with no residents, excluded: {len(zero_pop)}")
print(zero_pop)

ntas = ntas[ntas["Population"] > 0].copy()
ntas["PotholeRate"] = ntas["PotholeComplaints"] / ntas["Population"] * 1000

print(ntas["PotholeRate"].describe())


# ---- 8. Classify and map --------------------------------------------
# QGIS: Symbology > Graduated on PotholeRate, pick a ramp and a
# classification, Classify.
#
# A trap worth knowing: mapclassify has a class called NaturalBreaks,
# but it is a heuristic with random starting points and can return
# different breaks on different runs. FisherJenks is the exact Jenks
# optimization, and it's the one to compare against QGIS and R's
# classInt. Print all three sets of breaks side by side: they will
# mostly agree, and where they don't, that's the point — the class
# boundaries on a choropleth are a decision made by software.

fj = mapclassify.FisherJenks(ntas["PotholeRate"], k=5)
print("Fisher-Jenks upper bounds:", fj.bins.round(2).tolist())

fig, ax = plt.subplots(figsize=(9, 9))
ntas.plot(
    column="PotholeRate",
    scheme="FisherJenks",
    k=5,
    cmap="YlOrRd",
    edgecolor="white",
    linewidth=0.1,
    legend=True,
    legend_kwds={"title": "Pothole complaints\nper 1,000 residents",
                 "loc": "upper left", "fmt": "{:.2f}"},
    ax=ax,
)
ax.set_axis_off()
ax.set_title("NYC pothole complaints by Neighborhood Tabulation Area, 2026\n"
             "311 Street Condition / Pothole, January through August",
             loc="left")
fig.text(0.02, 0.02,
         "Sources: NYC Open Data 311 Service Requests; ACS 2020-2024",
         fontsize=8)

Path("outputs").mkdir(exist_ok=True)
fig.savefig(out_png, dpi=200, bbox_inches="tight")


# ---- 9. Export ------------------------------------------------------
# Same GeoPackage the QGIS path produces, with the same field names, so
# the three can be opened side by side and compared.

Path(out_gpkg).unlink(missing_ok=True)
ntas.to_file(out_gpkg, driver="GPKG", layer="NTA_PotholeTotals")
print(f"wrote {out_gpkg}")


# =====================================================================
# If you want a second year
#
# As in R, this is the part that is cheap in code and tedious in QGIS.
# Filter both files the same way, stack them with a period column, and
# the count runs once:
#
#   pts = pd.concat([
#       potholes_2025.assign(period="2025"),
#       potholes_2026.assign(period="2026"),
#   ])
#
#   hits = gpd.sjoin(pts[["period", "geometry"]],
#                    ntas[["NTA2020", "geometry"]],
#                    how="inner", predicate="intersects")
#
#   counts = hits.groupby(["NTA2020", "period"]).size().unstack(fill_value=0)
#
# Join back to ntas, difference the two rates, and map the difference on
# a diverging ramp (e.g. cmap="RdBu_r") centred on the citywide change
# rather than on zero.
# =====================================================================
