# =====================================================================
# NYC Pothole Complaints by NTA — the R path
#
# Companion to PotholeWorkshop.md. This is not a step-for-step
# translation of the QGIS walkthrough: in several places QGIS needs a
# dialog and R needs a single function, and those are called out in the
# comments. The five operations are the same in both:
#
#   1. join a table to polygons
#   2. dissolve polygons and sum an attribute
#   3. make points from coordinates and reproject
#   4. count points in polygon
#   5. derive a rate and classify it
#
# Field and layer names match the QGIS version (PotholeComplaints,
# PotholeRate, NTA_PotholeTotals) so the two outputs can be compared
# directly. The cat() checkpoints should match the counts you see in
# the QGIS layer panel.
# =====================================================================


# ---- 0. Packages ----------------------------------------------------
# install.packages(c("sf", "dplyr", "readr", "stringr", "ggplot2", "classInt"))

library(sf)        # everything spatial
library(dplyr)     # joins, group_by, mutate
library(readr)     # read_csv
library(stringr)   # str_sub, str_detect
library(ggplot2)   # the map
library(classInt)  # natural breaks

# ---- 1. Config ------------------------------------------------------
# CHANGE THESE to match your files. Everything below should run
# unmodified. A wrong field name surfaces at the join, not here, so run
# names() on each layer after reading it.

tract_path <- "data/cul_nyc_tracts_2020.gpkg"
pot_path   <- "data/Pothole_311_complaints_2026.csv"

# Population: either the raw data.census.gov download, or the cleaned
# CSV the workshop has you build. Set ONE of these; leave the other NULL.
acs_raw    <- NULL                                  # or "data/ACSDT5Y2024.B01003-Data.csv"
pop_clean  <- "data/Population2024.csv"             # the cleaned CSV, ships with this repo

out_gpkg   <- "outputs/NTA_PotholeTotals.gpkg"
out_png    <- "outputs/NTA_PotholeTotals.png"

crs_ft     <- 2263   # NAD83 / New York Long Island (ftUS) — as in QGIS
crs_ll     <- 4326   # what the 311 lat/lon columns are in

# Tract layer fields:
f_geoid    <- "GEOID"      # 11-character tract identifier
f_nta      <- "NTA2020"    # NTA code
f_ntaname  <- "NTAName"    # NTA name

# 311 export columns. The portal relabelled these in Dec 2025 and a CSV
# downloaded through the UI may carry either set of headers. Run
# names(read_csv(pot_path, n_max = 1)) and set accordingly.
f_problem  <- "Complaint Type"   # newer exports: "Problem"
f_detail   <- "Descriptor"       # newer exports: "Problem Detail"


# ---- 2. Tract polygons ----------------------------------------------
# QGIS: drag the .gpkg in, then Layer Properties to check the CRS.
# Transform immediately so every later operation happens in feet.

tracts <- st_read(tract_path, quiet = TRUE) |>
  st_transform(crs_ft)

names(tracts)                       # <- check against section 1
cat("tracts read:", nrow(tracts), "\n")


# ---- 3. Population table --------------------------------------------
# QGIS: open the ACS csv in a spreadsheet, delete the label row, keep
# two columns, use =RIGHT(A2,11) to trim GEO_ID, paste-special as
# values, rename, save as Population2024.csv.
#
# That whole sequence is the four lines below. data.census.gov exports
# two header rows: read_csv takes the first as column names, so the
# human-readable labels arrive as data row 1 and slice(-1) drops them.
# That is the "delete the second row" step.

if (!is.null(acs_raw)) {
  pop <- read_csv(acs_raw, show_col_types = FALSE) |>
    slice(-1) |>
    transmute(
      FIPS       = str_sub(GEO_ID, -11),       # 1400000US36061019500 -> 36061019500
      Population = as.numeric(B01003_001E)     # character until we say otherwise
    )
} else {
  # The pre-cleaned CSV from the data folder, for anyone who skipped ahead.
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
# QGIS: Properties > Joins to attach the table, export to make it
# permanent, then Processing > Aggregate grouping on NTA2020, with
# first_value on the name fields and sum on Population.
#
# In sf, summarise() unions the geometries for you, so the dissolve is
# implicit in the group_by. That is the biggest structural difference
# between the two paths, and the reason there's no intermediate
# TractsWithPopulation layer here.

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
# QGIS: Data Source Manager > Delimited Text, X = longitude,
# Y = latitude, CRS = EPSG:4326, then Export > Save As in EPSG:2263.
#
# The filter below reproduces the four portal filters. Note that the
# portal uses CONTAINS, not equals, so str_detect is the faithful
# translation — == would silently give you a different population of
# records and a checkpoint that doesn't match.
#
# If you downloaded the pre-filtered CSV from the data folder, comment
# the three filter lines out.

raw <- read_csv(pot_path, show_col_types = FALSE)
names(raw)                          # <- check f_problem / f_detail

potholes <- raw |>
  filter(
    str_detect(str_to_lower(.data[[f_problem]]), "street condition"),
    str_detect(str_to_lower(.data[[f_detail]]),  "pothole"),
    !is.na(Latitude), !is.na(Longitude)
  ) |>
  st_as_sf(coords = c("Longitude", "Latitude"), crs = crs_ll) |>
  st_transform(crs_ft)

# Worth reporting out loud, because the portal filter hides it: roughly
# half of all pothole complaints carry no coordinates and never reach
# the map at all.
cat("rows in export:", nrow(raw),
    " | mapped:", nrow(potholes), "\n")        # expect 27,158


# ---- 6. Count points in polygon -------------------------------------
# QGIS: Vector > Analysis Tools > Count Points in Polygon, writing a
# PotholeComplaints field to a new layer.
#
# st_intersects() returns, for each NTA, the indices of the points
# inside it; lengths() turns those lists into counts. One line, no new
# layer.

ntas$PotholeComplaints <- lengths(st_intersects(ntas, potholes))

# The checkpoint that matters: points falling outside every NTA, i.e.
# geocodes landing in water or just past the shoreline. A handful is
# normal. Hundreds means a CRS problem.
cat("complaints inside an NTA:", sum(ntas$PotholeComplaints),
    " | dropped:", nrow(potholes) - sum(ntas$PotholeComplaints), "\n")


# ---- 7. Rate --------------------------------------------------------
# QGIS: Field Calculator, new decimal field PotholeRate, expression
# ( "PotholeComplaints" / "Population" ) * 1000
#
# The 2020 NTA scheme includes airports, parks and cemeteries with no
# residents. QGIS divides by zero there and returns NULL, which renders
# as unclassified grey rather than failing — so the holes in the QGIS
# map are these. Dropping them explicitly here keeps them out of the
# Jenks calculation too.

zero_pop <- ntas |> filter(Population == 0) |> pull(NTAName)
cat("NTAs with no residents, excluded:", length(zero_pop), "\n")
print(zero_pop)

ntas <- ntas |>
  filter(Population > 0) |>
  mutate(PotholeRate = PotholeComplaints / Population * 1000)

summary(ntas$PotholeRate)


# ---- 8. Classify and map --------------------------------------------
# QGIS: Symbology > Graduated on PotholeRate, pick a ramp and a
# classification, Classify.
#
# classInt's Jenks and QGIS's Natural Breaks are separate
# implementations and will not always return the same break values.
# Neither is wrong. Printing both side by side is the clearest possible
# demonstration that a choropleth's class boundaries are a decision
# made by software rather than a property of the data.

brks <- classIntervals(ntas$PotholeRate, n = 5, style = "jenks")$brks
print(round(brks, 2))    # compare to what QGIS gave you

ggplot(ntas) +
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

dir.create("outputs", showWarnings = FALSE)
ggsave(out_png, width = 9, height = 9, dpi = 200)


# ---- 9. Export ------------------------------------------------------
# Same GeoPackage the QGIS path produces, with the same field names, so
# the two can be opened side by side and compared.

st_write(ntas, out_gpkg, delete_dsn = TRUE, quiet = TRUE)
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
