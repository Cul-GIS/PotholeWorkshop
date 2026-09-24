# =====================================================================
# NYC Pothole Complaints by NTA — the R path
#
# Companion to PotholeWorkshop.md, parallel to PotholeWorkshop.py.
# Sections are numbered to match the Python script, and the comment at
# the head of each section quotes the QGIS step it replaces so the two
# can be read side by side.
#
# This is not a step-for-step translation of the QGIS walkthrough: in
# several places QGIS needs a dialog and R needs a single function, and
# those are called out below. The five operations are the same in both:
#
#   1. join a table to polygons
#   2. dissolve polygons and sum an attribute
#   3. make points from coordinates and reproject
#   4. count points in polygon
#   5. derive a rate and classify it
#
# Field and layer names match the QGIS version (PotholeComplaints,
# PotholeRate, NTA_PotholeTotals) so the outputs can be compared
# directly. The cat() checkpoints should match the counts you see in
# the QGIS layer panel.
# =====================================================================


# ---- 0. Packages ----------------------------------------------------
# Run this line once, then leave it commented out.
#
# install.packages(c("sf", "dplyr", "readr", "stringr", "ggplot2", "classInt"))

library(sf)        # everything spatial
library(dplyr)     # joins, group_by, mutate
library(readr)     # read_csv
library(stringr)   # str_sub, str_detect
library(ggplot2)   # the map
library(classInt)  # natural breaks


# ---- 1. Config ------------------------------------------------------
# CHANGE THESE to match your files. Everything below should run
# unmodified. A wrong field name surfaces at the join, not here, so the
# script prints names() on each layer as it reads it.
#
# The md's "create a directory to store all the files for this
# exercise" is `wd` below. Paths are absolute on purpose, so the script
# behaves the same from RStudio, from Rscript, or from any working
# directory; point `wd` at your own copy of the repo.

wd <- "C:/Users/ericg/Documents/GitHub/PotholeWorkshop"

# --- inputs. These are file paths, not data; they are read in
# --- sections 2, 3 and 5.

# The tract geopackage from Geodata@Columbia. It contains a single
# layer, named "2020", so st_read() finds it without being told which.
tract_path <- file.path(wd, "data", "cul_nyc_tracts_2020.gpkg")

# The 311 export. The copy in data/ has already had the four portal
# filters from the md applied (street condition / pothole / Jan-Aug
# 2026 / latitude not null), so it is 27,158 rows rather than 40M.
pot_path   <- file.path(wd, "data", "Pothole_311_complaints_2026.csv")

# Population: either the raw data.census.gov download, or the cleaned
# CSV the md has you build by hand. Set ONE of these; leave the other
# NULL.
acs_raw    <- NULL                                          # or file.path(wd, "data", "ACSDT5Y2024.B01003-Data.csv")
pop_clean  <- file.path(wd, "data", "Population2024.csv")   # the cleaned CSV, ships with this repo

# --- outputs
out_dir    <- file.path(wd, "outputs")
out_gpkg   <- file.path(out_dir, "NTA_PotholeTotals.gpkg")
out_png    <- file.path(out_dir, "NTA_PotholeTotals.png")

dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

crs_ft     <- 2263   # NAD83 / New York Long Island (ftUS) — the md's export CRS
crs_ll     <- 4326   # "EPSG:4326 – WGS 84", what the 311 lat/lon columns are in

# Tract layer fields. These are the three the md singles out in the
# attribute table: "GEOID, NTA2020, and NTAName".
f_geoid    <- "GEOID"      # 11-digit FIPS, unique per tract
f_nta      <- "NTA2020"    # NTA code, shared by every tract in an NTA
f_ntaname  <- "NTAName"    # vernacular NTA name

# 311 export columns. The portal relabelled these, and a CSV downloaded
# through the UI may carry either set of headers — the names the md
# uses in its filter list are the ones in the shipped file. Section 5
# prints names(raw); set these to match what you actually downloaded.
f_problem  <- "Problem (formerly Complaint Type)"     # older exports: "Complaint Type"
f_detail   <- "Problem Detail (formerly Descriptor)"  # older exports: "Descriptor"
f_lat      <- "Latitude"
f_lon      <- "Longitude"


# ---- 2. Tract polygons ----------------------------------------------
# md, "Get the tract geography": drag the .gpkg out of the Browser
# panel into the map window, then right-click the layer and choose
# "Open Attribute Table" to inspect the fields.
#
# The file is already in EPSG:2263, but transform anyway, so the script
# still works if you swap in a layer that isn't and so that every later
# operation happens in feet.

tracts <- st_read(tract_path, quiet = TRUE) |>
  st_transform(crs_ft)

print(names(tracts))                # <- check against section 1
cat("tracts read:", nrow(tracts), "\n")


# ---- 3. Population table --------------------------------------------
# md, "Clean up the population table": open the ACS csv in a
# spreadsheet, delete the second row, delete every data column except
# the first, use =RIGHT(A2,11) to trim the "1400000US" prefix off
# GEO_ID, paste-special as values, rename the two remaining fields
# "FIPS" and "Population", save as Population2024.csv.
#
# That whole sequence is the four lines below. data.census.gov exports
# two header rows: read_csv takes the first as column names, so the
# human-readable labels arrive as data row 1 and slice(-1) drops them.
# That is the "delete the second row" step. str_sub(GEO_ID, -11) is
# =RIGHT(A2,11).

if (!is.null(acs_raw)) {
  pop <- read_csv(acs_raw, show_col_types = FALSE) |>
    slice(-1) |>
    transmute(
      FIPS       = str_sub(GEO_ID, -11),       # 1400000US36061019500 -> 36061019500
      Population = as.numeric(B01003_001E)     # character until we say otherwise
    )
} else {
  # The pre-cleaned CSV from the data folder, for anyone who skipped
  # ahead. col_character() on FIPS is the md's "Change the FIPS field
  # type to Text (string)" step, and for the same reason: read as a
  # number, the code is no longer the same kind of thing as the GEOID
  # in the geopackage and the join below matches nothing.
  pop <- read_csv(pop_clean, col_types = cols(FIPS = col_character())) |>
    mutate(Population = as.numeric(Population))
}

cat("population rows:", nrow(pop), "\n")

# Note: tidycensus removes sections 2 and 3 entirely, fetching geometry
# and estimate already joined:
#
#   library(tidycensus)
#   tracts_pop <- get_acs(geography = "tract", variables = "B01003_001",
#                         state = "NY",
#                         county = c("New York", "Kings", "Queens",
#                                    "Bronx", "Richmond"),
#                         year = 2024, geometry = TRUE)
#
# The manual path is kept here so the steps line up with the QGIS
# version, but for real work use tidycensus.


# ---- 4. Join, then dissolve to NTA ----------------------------------
# md, "Join the population data in QGIS": Layer Properties > Joins, add
# a join on FIPS/GEOID with the "Custom field name prefix" left blank,
# then Export > Save Features As to a geopackage named
# TractsWithPopulation, because "the table join is stored in memory."
#
# md, "Build the NTA boundaries": Processing Toolbox > Aggregate, group
# by NTA2020, first_value on NTA2020 and NTAName, sum on Population,
# delete the fields you do not need, save as NTAPopulation.
#
# left_join() is the table join, and it is permanent the moment it
# runs, so there is no TractsWithPopulation step here. In sf,
# summarise() unions the geometries of each group for you, so the
# dissolve is implicit in the group_by — the biggest structural
# difference between the two paths. Naming only NTA2020, NTAName and
# Population is the "delete the other fields" step.

tracts_pop <- tracts |>
  left_join(pop, by = setNames("FIPS", f_geoid))

# Unmatched tracts should be 0. The usual culprit is a FIPS that lost a
# leading zero in the spreadsheet, which is also why QGIS makes you set
# that field to Text (string) on import.
cat("tracts with no population match:", sum(is.na(tracts_pop$Population)), "\n")

ntas <- tracts_pop |>
  group_by(NTA2020 = .data[[f_nta]], NTAName = .data[[f_ntaname]]) |>
  summarise(Population = sum(Population, na.rm = TRUE), .groups = "drop")

cat("NTAs after dissolve:", nrow(ntas), "\n")


# ---- 5. Complaints as points ----------------------------------------
# md, "Get the pothole complaint data" and "Turn the points into a
# layer": Data Source Manager > Delimited Text with "Point
# coordinates", X = longitude, Y = latitude, geometry CRS
# "EPSG:4326 – WGS 84"; then Export > Save Features As to a geopackage
# named PotholeLocations, reprojected to EPSG:2263.
#
# st_as_sf() is the first dialog and st_transform() is the second. R
# holds the result in memory, so PotholeLocations is never written to
# disk. The md writes it because, in its words, the QGIS
# delimited-text layer is "just a visual expression of the table's
# locations" until you export it.
#
# The filter reproduces the portal filters from the md. Note that the
# portal uses CONTAINS, not equals, so str_detect is the faithful
# translation — == would silently give you a different population of
# records and a checkpoint that does not match. On the shipped CSV,
# which is already filtered, these lines are redundant but harmless;
# they matter if you did the download yourself.

raw <- read_csv(pot_path, show_col_types = FALSE)
print(names(raw))                   # <- check f_problem / f_detail

potholes <- raw |>
  filter(
    str_detect(str_to_lower(.data[[f_problem]]), "street condition"),
    str_detect(str_to_lower(.data[[f_detail]]),  "pothole"),
    !is.na(.data[[f_lat]]), !is.na(.data[[f_lon]])
  ) |>
  st_as_sf(coords = c(f_lon, f_lat), crs = crs_ll) |>
  st_transform(crs_ft)

# The md's filters bring the portal "down to around 27,000 incidents."
# Worth saying out loud, because the portal filter hides it: the
# "Latitude is not null" condition is doing real work — roughly half of
# all pothole complaints carry no coordinates and never reach the map.
cat("rows in export:", nrow(raw),
    " | mapped:", nrow(potholes), "\n")        # expect 27,158


# ---- 6. Count points in polygon -------------------------------------
# md, "Turn the points into a layer and count them per NTA":
# Vector > Analysis Tools > Count Points in Polygon, with the NTA layer
# as the polygons and PotholeLocations as the points, the count field
# named PotholeComplaints, output saved as NTA_PotholeTotals.
#
# st_intersects() returns, for each NTA, the indices of the points
# inside it; lengths() turns those lists into counts. One line, no new
# layer.

ntas$PotholeComplaints <- lengths(st_intersects(ntas, potholes))

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
# complaint is being counted in two neighborhoods, and Count Points in
# Polygon is doing it too.
hits    <- st_intersects(potholes, ntas)
matched <- sum(lengths(hits) > 0)
cat("complaints inside an NTA:", matched,
    " | dropped:", nrow(potholes) - matched,
    " | double-counted:", sum(lengths(hits)) - matched, "\n")


# ---- 7. Rate --------------------------------------------------------
# md, "Calculate the complaint rate and map it": Field Calculator,
# "Create a new field", name PotholeRate, output type "Decimal number",
# expression
#
#   ( "PotholeComplaints" / "Population" ) * 1000
#
# The 2020 NTA scheme includes airports, parks and cemeteries with no
# residents. QGIS divides by zero there and returns NULL, which renders
# as unclassified grey rather than failing — so the holes in the QGIS
# map are these. Dropping them explicitly here keeps them out of the
# Jenks calculation too.
#
# There is no equivalent of the md's "end the editing session by
# toggling the Edit button": mutate() returns a new object instead of
# putting a layer into edit mode.

zero_pop <- ntas |> filter(Population == 0) |> pull(NTAName)
cat("NTAs with no residents, excluded:", length(zero_pop), "\n")
print(zero_pop)

ntas <- ntas |>
  filter(Population > 0) |>
  mutate(PotholeRate = PotholeComplaints / Population * 1000)

print(summary(ntas$PotholeRate))


# ---- 8. Classify and map --------------------------------------------
# md, last step: Layer Properties > Symbology, "Graduated", value
# PotholeRate, choose a color ramp and a classification scheme, click
# Classify.
#
# classInt's Jenks and QGIS's Natural Breaks are separate
# implementations and will not always return the same break values.
# Neither is wrong. Printing both side by side is the clearest possible
# demonstration that a choropleth's class boundaries are a decision
# made by software rather than a property of the data.

brks <- classIntervals(ntas$PotholeRate, n = 5, style = "jenks")$brks
print(round(brks, 2))    # compare to what QGIS gave you

# Look hard at the map this produces, in QGIS as much as here. Section 7
# removed the NTAs with no residents at all, but it did not remove the
# ones with almost none, and those are the same parks and cemeteries:
# Highland Park-Cypress Hills Cemeteries (North) has 12 residents and
# 30 complaints, a "rate" of 2,500 per 1,000. Seven such NTAs take four
# of the five classes, and the 207 neighborhoods anyone actually lives
# in are all crushed into the bottom one. The map is technically
# correct and reads as a map of where the cemeteries are.
#
# This is the small-denominator problem, and it is the real lesson of
# the exercise: a rate is only as stable as the population underneath
# it. Print the offenders, then decide.
ntas |>
  st_drop_geometry() |>
  slice_max(PotholeRate, n = 8) |>
  print()

# Three standard fixes, none of them "the" answer:
#
#   1. Set a population floor, e.g. filter(Population >= 500). Simple,
#      defensible, and you must say so in the caption.
#   2. Classify with quantiles instead of Jenks — style = "quantile"
#      above — which spreads the 214 NTAs evenly over five classes and
#      lets the outliers sit alone in the top one.
#   3. Map the raw PotholeComplaints count instead of the rate, and let
#      the reader supply the population themselves.
#
# Option 1 as a one-liner, to try against the map below:
#
#   ntas <- ntas |> filter(Population >= 500)

p <- ggplot(ntas) +
  geom_sf(aes(fill = PotholeRate), colour = "white", linewidth = 0.1) +
  scale_fill_fermenter(
    palette   = "YlOrRd",
    direction = 1,
    breaks    = brks[-c(1, length(brks))],   # interior breaks only
    name      = "Pothole complaints\nper 1,000 residents"
  ) +
  labs(
    title    = "NYC pothole complaints by Neighborhood Tabulation Area, 2026",
    subtitle = "311 Street Condition / Pothole, January through August",
    caption  = "Sources: NYC Open Data 311 Service Requests; ACS 2020-2024"
  ) +
  theme_void()

ggsave(out_png, p, width = 9, height = 9, dpi = 200)
cat("wrote", out_png, "\n")


# ---- 9. Export ------------------------------------------------------
# Same GeoPackage the QGIS path produces, with the same layer and field
# names, so the two can be opened side by side and compared.

st_write(ntas, out_gpkg, layer = "NTA_PotholeTotals",
         delete_dsn = TRUE, quiet = TRUE)
cat("wrote", out_gpkg, "\n")


# =====================================================================
# If you want a second year
#
# This is the part that is cheap in R and tedious in QGIS. Read both
# years, bind them with a period column, and the count and rate steps
# run once instead of twice:
#
#   pts <- bind_rows(
#     read_potholes("data/311_PotholeComplaints_2025.csv") |>
#       mutate(period = "2025"),
#     read_potholes("data/311_PotholeComplaints_2026.csv") |>
#       mutate(period = "2026")
#   )
#
#   counts <- ntas |>
#     st_join(pts) |>
#     st_drop_geometry() |>
#     count(NTA2020, period) |>
#     tidyr::pivot_wider(names_from = period, values_from = n,
#                        values_fill = 0)
#
# Join back, difference the two rates, and map the difference on a
# diverging ramp centred on the citywide change rather than on zero.
# =====================================================================
