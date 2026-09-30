---
title: Pothole Workshop
---

{% comment %}
The published page is PotholeWorkshop.md with two changes: the data link
points at the IntroGIS.zip download, and the "Data and companion files"
section is dropped. To publish the walkthrough unchanged, replace the
lines below with a plain include_relative of PotholeWorkshop.md.
{% endcomment %}

{% capture walkthrough %}{% include_relative PotholeWorkshop.md %}{% endcapture %}
{% assign walkthrough = walkthrough | split: "## Data and companion files" | first %}
{% assign walkthrough = walkthrough | replace: "https://github.com/Cul-GIS/PotholeWorkshop/tree/main/data", "https://www.columbia.edu/acis/eds/gis/images/IntroGIS.zip" %}
{{ walkthrough }}
