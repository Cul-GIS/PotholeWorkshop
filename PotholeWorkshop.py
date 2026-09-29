# =====================================================================
# NYC Pothole Complaints by Neighborhood — the Python version
#
# This script makes the same map as the QGIS exercise in
# PotholeWorkshop.md: the rate of pothole-related 311 complaints per
# 1,000 residents in each NYC Neighborhood Tabulation Area (NTA), 2026.
# It follows the same steps as PotholeWorkshop.R, with the same section
# numbers.
#
# HOW TO RUN IT
#   1. Open this file in your Python editor (VS Code, Spyder, IDLE...).
#   2. Change the one line in section 1 so it points at the
#      PotholeWorkshop folder on your computer.
#   3. Run the whole file (in VS Code, the ▷ button at the top right).
#
# The first run installs the packages it needs, which can take a few
# minutes. Note: the Python console built into QGIS can't install them;
# use a regular Python.
#
# The map is saved to outputs/NTA_PotholeTotals.png and the data to
# outputs/NTA_PotholeTotals.gpkg, which you can open in QGIS. The map
# also opens in a window at the end; close it to finish the script.
#
# A few Python basics for reading the code:
#   #        starts a comment; Python ignores the rest of the line
#   x = 5    saves a result under a name
#   df["Population"]   one column of a table
# =====================================================================


# ---- 0. Packages ----------------------------------------------------
# Installs anything missing, then loads it. Warnings about "numba" or
# similar are harmless.

import subprocess
import sys

try:
    import geopandas, mapclassify, matplotlib
except ImportError:
    print("Installing packages (first run only)...")
    subprocess.check_call([sys.executable, "-m", "pip", "install",
                           "geopandas", "mapclassify", "matplotlib"])

import os
import geopandas as gpd               # reading, joining and measuring spatial data
import mapclassify                    # natural breaks classification
import matplotlib.pyplot as plt       # drawing the map
import pandas as pd                   # reading and summarising tables


# ---- 1. Working directory -------------------------------------------
# CHANGE THIS to the PotholeWorkshop folder on your computer. Use
# forward slashes (/), even on Windows. For example:
#   Windows: "C:/Users/yourname/Downloads/PotholeWorkshop"
#   Mac:     "/Users/yourname/Downloads/PotholeWorkshop"

os.chdir("C:/Users/yourname/Downloads/PotholeWorkshop")

if not os.path.exists("data/Pothole_311_complaints_2026.csv"):
    sys.exit("Can't find the data folder. Check the os.chdir() line in section 1.")
os.makedirs("outputs", exist_ok=True)


# ---- 2. Tract polygons ----------------------------------------------
# QGIS: drag cul_nyc_tracts_2020.gpkg into the map window.
#
# to_crs() puts the layer in EPSG:2263 (NY State Plane, feet), the same
# CRS the QGIS exercise uses.

tracts = gpd.read_file("data/cul_nyc_tracts_2020.gpkg").to_crs(2263)

print("tracts read:", len(tracts))                 # expect 2325


# ---- 3. Population table --------------------------------------------
# QGIS: "Clean up the population table". The cleaned file ships in
# data/, so here we just read it.
#
# dtype keeps FIPS as text, like setting the field to "Text (string)"
# in QGIS, so it matches the GEOID field in the tracts.

pop = pd.read_csv("data/Population2024.csv", dtype={"FIPS": str})

print("population rows:", len(pop))                # expect 2327


# ---- 4. Join, then dissolve to NTA ----------------------------------
# QGIS: Layer Properties > Joins (GEOID = FIPS), then Processing
# Toolbox > Aggregate, grouped by NTA2020, summing Population.
#
# merge() is the join. dissolve() merges the tract shapes in each group
# into one NTA shape and adds up their Population.

tracts_pop = tracts.merge(pop, left_on="GEOID", right_on="FIPS", how="left")

print("tracts with no population match:",          # expect 0
      tracts_pop["Population"].isna().sum())

ntas = (
    tracts_pop[["NTA2020", "NTAName", "Population", "geometry"]]
    .dissolve(by=["NTA2020", "NTAName"], aggfunc="sum")
    .reset_index()
)

print("NTAs:", len(ntas))                          # expect 262


# ---- 5. Complaints as points ----------------------------------------
# QGIS: Data Source Manager > Delimited Text, X = Longitude,
# Y = Latitude, CRS EPSG:4326; then export reprojected to EPSG:2263.
#
# The CSV in data/ has already been filtered on the NYC Open Data portal
# to pothole complaints, January-August 2026, with coordinates.

complaints = pd.read_csv("data/Pothole_311_complaints_2026.csv", low_memory=False)
complaints = complaints.dropna(subset=["Latitude", "Longitude"])

potholes = gpd.GeoDataFrame(
    complaints,
    geometry=gpd.points_from_xy(complaints["Longitude"], complaints["Latitude"]),
    crs=4326,
).to_crs(2263)

print("complaints mapped:", len(potholes))         # expect 27158


# ---- 6. Count points in polygon -------------------------------------
# QGIS: Vector > Analysis Tools > Count Points in Polygon, count field
# named PotholeComplaints.
#
# sjoin() tags each complaint with the NTA it falls in; value_counts()
# counts them per NTA.

hits = gpd.sjoin(potholes[["geometry"]], ntas[["NTA2020", "geometry"]],
                 predicate="intersects")
counts = hits["NTA2020"].value_counts()
ntas["PotholeComplaints"] = ntas["NTA2020"].map(counts).fillna(0).astype(int)

# A few complaints are geocoded just offshore and land in no NTA.
print("complaints inside an NTA:", ntas["PotholeComplaints"].sum())  # expect 27137


# ---- 7. Rate --------------------------------------------------------
# QGIS: Field Calculator, new decimal field PotholeRate:
#   ( "PotholeComplaints" / "Population" ) * 1000
#
# Parks, cemeteries and airports have their own NTAs with no residents.
# You can't divide by zero, so they're left out (QGIS shows them grey).

ntas = ntas[ntas["Population"] > 0].copy()
ntas["PotholeRate"] = ntas["PotholeComplaints"] / ntas["Population"] * 1000

print("NTAs with residents:", len(ntas))           # expect 214

# Some NTAs are mostly park or cemetery with only a handful of
# residents, so their "rate" is huge: 30 complaints and 12 residents is
# 2,500 per 1,000. Here are the highest rates:

print(ntas.drop(columns="geometry")
          .sort_values("PotholeRate", ascending=False)
          .head(8)
          .round(1)
          .to_string(index=False))

# On the map, these few NTAs take most of the color classes, and every
# ordinary neighborhood ends up in the bottom one. A rate is only as
# stable as the population underneath it. To try a population floor,
# remove the # from the next line and run the script again.

# ntas = ntas[ntas["Population"] >= 500]


# ---- 8. Classify and map --------------------------------------------
# QGIS: Symbology > Graduated, value PotholeRate, mode Natural Breaks
# (Jenks), 5 classes.
#
# FisherJenks is Python's version of Natural Breaks. It may not match
# QGIS or R exactly; neither is wrong. Another fix for the
# small-population problem above: change "FisherJenks" to "Quantiles"
# (in both places below).

breaks = mapclassify.FisherJenks(ntas["PotholeRate"], k=5)
print("class upper bounds:", breaks.bins.round(2).tolist())

fig, ax = plt.subplots(figsize=(9, 9))
ntas.plot(
    ax=ax,
    column="PotholeRate",
    scheme="FisherJenks",
    k=5,
    cmap="YlOrRd",
    edgecolor="white",
    linewidth=0.1,
    legend=True,
    legend_kwds={"title": "Pothole complaints\nper 1,000 residents",
                 "loc": "upper left", "fmt": "{:.2f}"},
)
ax.set_axis_off()
ax.set_title("NYC pothole complaints by Neighborhood Tabulation Area, 2026\n"
             "311 Street Condition / Pothole, January through August",
             loc="left")
fig.text(0.02, 0.02, "Sources: NYC Open Data 311 Service Requests; ACS 2020-2024",
         fontsize=8)

fig.savefig("outputs/NTA_PotholeTotals.png", dpi=200, bbox_inches="tight")


# ---- 9. Export ------------------------------------------------------
# Saves a GeoPackage with the same layer and field names as the QGIS
# exercise, so you can open both in QGIS and compare. (Close it in QGIS
# before re-running, or the file can't be overwritten.)

ntas.to_file("outputs/NTA_PotholeTotals.gpkg", layer="NTA_PotholeTotals")

print("Done. Results are in the outputs folder.")

plt.show()   # opens the map in a window
