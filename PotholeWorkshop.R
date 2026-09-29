# =====================================================================
# NYC Pothole Complaints by Neighborhood — the R version
#
# This script makes the same map as the QGIS exercise in
# PotholeWorkshop.md: the rate of pothole-related 311 complaints per
# 1,000 residents in each NYC Neighborhood Tabulation Area (NTA), 2026.
#
# HOW TO RUN IT
#   1. Open this file in RStudio.
#   2. Change the one line in section 1 so it points at the
#      PotholeWorkshop folder on your computer.
#   3. Click "Source" (top right of this pane), or press
#      Ctrl+Shift+Enter (Cmd+Shift+Enter on a Mac).
#
# Or run it one line at a time with Ctrl+Enter (Cmd+Enter on a Mac) to
# see what each step does. The first run installs the packages it
# needs, which can take a few minutes.
#
# The map is saved to outputs/NTA_PotholeTotals.png and the data to
# outputs/NTA_PotholeTotals.gpkg, which you can open in QGIS.
#
# A few R basics for reading the code:
#   #    starts a comment; R ignores the rest of the line
#   <-   saves a result under a name, e.g.  x <- 5
#   |>   "and then": passes the result on the left into the next step
# =====================================================================


# ---- 0. Packages ----------------------------------------------------
# Installs anything missing, then loads it. Warnings like "package 'sf'
# was built under R version ..." are harmless.

packages <- c("sf", "dplyr", "ggplot2", "classInt")
missing  <- packages[!packages %in% rownames(installed.packages())]
if (length(missing) > 0) install.packages(missing)

library(sf)        # reading, joining and measuring spatial data
library(dplyr)     # joining and summarising tables
library(ggplot2)   # drawing the map
library(classInt)  # natural breaks classification


# ---- 1. Working directory -------------------------------------------
# CHANGE THIS to the PotholeWorkshop folder on your computer. Use
# forward slashes (/), even on Windows. For example:
#   Windows: "C:/Users/yourname/Downloads/PotholeWorkshop"
#   Mac:     "/Users/yourname/Downloads/PotholeWorkshop"
#
# Or, in RStudio: Session > Set Working Directory > To Source File
# Location, and then delete or comment out the setwd() line.

setwd("C:/Users/yourname/Downloads/PotholeWorkshop")

if (!file.exists("data/Pothole_311_complaints_2026.csv")) {
  stop("Can't find the data folder. Check the setwd() line in section 1.")
}
dir.create("outputs", showWarnings = FALSE)


# ---- 2. Tract polygons ----------------------------------------------
# QGIS: drag cul_nyc_tracts_2020.gpkg into the map window.
#
# st_transform() puts the layer in EPSG:2263 (NY State Plane, feet), the
# same CRS the QGIS exercise uses.

tracts <- st_read("data/cul_nyc_tracts_2020.gpkg", quiet = TRUE) |>
  st_transform(2263)

cat("tracts read:", nrow(tracts), "\n")          # expect 2325


# ---- 3. Population table --------------------------------------------
# QGIS: "Clean up the population table". The cleaned file ships in
# data/, so here we just read it.
#
# colClasses keeps FIPS as text, like setting the field to "Text
# (string)" in QGIS, so it matches the GEOID field in the tracts.

pop <- read.csv("data/Population2024.csv",
                colClasses = c(FIPS = "character"),
                fileEncoding = "UTF-8-BOM")

cat("population rows:", nrow(pop), "\n")         # expect 2327


# ---- 4. Join, then dissolve to NTA ----------------------------------
# QGIS: Layer Properties > Joins (GEOID = FIPS), then Processing
# Toolbox > Aggregate, grouped by NTA2020, summing Population.
#
# In R, summarise() merges the tract shapes in each group into one NTA
# shape, so the dissolve happens automatically.

tracts_pop <- tracts |>
  left_join(pop, by = c("GEOID" = "FIPS"))

cat("tracts with no population match:",          # expect 0
    sum(is.na(tracts_pop$Population)), "\n")

ntas <- tracts_pop |>
  group_by(NTA2020, NTAName) |>
  summarise(Population = sum(Population, na.rm = TRUE), .groups = "drop")

cat("NTAs:", nrow(ntas), "\n")                   # expect 262


# ---- 5. Complaints as points ----------------------------------------
# QGIS: Data Source Manager > Delimited Text, X = Longitude,
# Y = Latitude, CRS EPSG:4326; then export reprojected to EPSG:2263.
#
# The CSV in data/ has already been filtered on the NYC Open Data portal
# to pothole complaints, January-August 2026, with coordinates.

potholes <- read.csv("data/Pothole_311_complaints_2026.csv") |>
  filter(!is.na(Latitude), !is.na(Longitude)) |>
  st_as_sf(coords = c("Longitude", "Latitude"), crs = 4326) |>
  st_transform(2263)

cat("complaints mapped:", nrow(potholes), "\n")  # expect 27158


# ---- 6. Count points in polygon -------------------------------------
# QGIS: Vector > Analysis Tools > Count Points in Polygon, count field
# named PotholeComplaints.
#
# st_intersects() finds which complaints fall in each NTA; lengths()
# counts them.

ntas$PotholeComplaints <- lengths(st_intersects(ntas, potholes))

# A few complaints are geocoded just offshore and land in no NTA.
cat("complaints inside an NTA:", sum(ntas$PotholeComplaints), "\n")  # expect 27137


# ---- 7. Rate --------------------------------------------------------
# QGIS: Field Calculator, new decimal field PotholeRate:
#   ( "PotholeComplaints" / "Population" ) * 1000
#
# Parks, cemeteries and airports have their own NTAs with no residents.
# You can't divide by zero, so they're left out (QGIS shows them grey).

ntas <- ntas |>
  filter(Population > 0) |>
  mutate(PotholeRate = PotholeComplaints / Population * 1000)

cat("NTAs with residents:", nrow(ntas), "\n")    # expect 214

# Some NTAs are mostly park or cemetery with only a handful of
# residents, so their "rate" is huge: 30 complaints and 12 residents is
# 2,500 per 1,000. Here are the highest rates:

ntas |>
  st_drop_geometry() |>
  arrange(desc(PotholeRate)) |>
  head(8) |>
  print()

# On the map, these few NTAs take most of the color classes, and every
# ordinary neighborhood ends up in the bottom one. A rate is only as
# stable as the population underneath it. To try a population floor,
# remove the # from the next line and run the script again.

# ntas <- ntas |> filter(Population >= 500)


# ---- 8. Classify and map --------------------------------------------
# QGIS: Symbology > Graduated, value PotholeRate, mode Natural Breaks
# (Jenks), 5 classes.
#
# R's Jenks and QGIS's Natural Breaks are different implementations, so
# the class breaks may not match exactly. Neither is wrong. Another fix
# for the small-population problem above: change "jenks" to "quantile".

breaks <- classIntervals(ntas$PotholeRate, n = 5, style = "jenks")$brks
print(round(breaks, 2))

map <- ggplot(ntas) +
  geom_sf(aes(fill = PotholeRate), colour = "white", linewidth = 0.1) +
  scale_fill_fermenter(
    palette   = "YlOrRd",
    direction = 1,
    breaks    = breaks[-c(1, length(breaks))],   # inner breaks only
    name      = "Pothole complaints\nper 1,000 residents"
  ) +
  labs(
    title    = "NYC pothole complaints by Neighborhood Tabulation Area, 2026",
    subtitle = "311 Street Condition / Pothole, January through August",
    caption  = "Sources: NYC Open Data 311 Service Requests; ACS 2020-2024"
  ) +
  theme_void()

print(map)   # shows the map in RStudio's Plots pane

ggsave("outputs/NTA_PotholeTotals.png", map, width = 9, height = 9, dpi = 200)


# ---- 9. Export ------------------------------------------------------
# Saves a GeoPackage with the same layer and field names as the QGIS
# exercise, so you can open both in QGIS and compare. (Close it in QGIS
# before re-running, or the file can't be overwritten.)

st_write(ntas, "outputs/NTA_PotholeTotals.gpkg", layer = "NTA_PotholeTotals",
         delete_dsn = TRUE, quiet = TRUE)

cat("Done. Results are in the outputs folder.\n")
