# Offline headphone profiles

Nine exact models from OPRA revision `0b88ecd4e2bef7cf69fd5d50f1d06fb586c10865`
(repository snapshot dated 2026-07-01). All selected EQ records credit
**oratory1990**, with the target described by OPRA as **Harman Target**.
An OPRA snapshot date is not a measurement date. Operating modes absent from
the source records are explicitly unknown; Aeon does not infer them.

OPRA explicitly licenses its product and EQ database under CC BY-SA 4.0:
https://github.com/opra-project/OPRA/tree/0b88ecd4e2bef7cf69fd5d50f1d06fb586c10865
The full upstream LICENSE and third-party notices accompany this subset.
The transformed data in profiles.json is also CC BY-SA 4.0. Creator names,
original measurement URLs, source URLs and revision are retained in each record.
The browser displays the OPRA logo, description, project link and creator credits;
it permits sharing the catalogue and full license offline.

Adaptation: renamed JSON fields and assigned stable Aeon IDs; mapped peak_dip,
low_shelf and high_shelf to Aeon's version-2 digital-Q filters. Frequencies,
Q, gains, counts and recommended preamps are unchanged. source-records.json
retains original selected records for deterministic comparison. This subset does
not incorporate AutoEq-generated curves or assert software licensing covers
measurement data. The OPRA logo is reproduced unchanged for its required credit.

AirPods Max was excluded because the selected source contains a 17 Hz filter
outside Aeon's validated input range. No filter was silently clamped or dropped.
Bundled data is separate from saved/imported profiles. Only explicit Apply stores
and activates a profile. No profile is enabled by default, and route changes keep
the existing unmatched-route bypass policy.
