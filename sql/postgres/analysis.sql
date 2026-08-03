select 
    count(trip_id) as trip_per_zone,
    dim_location.zone
from fact_trips
left JOIN dim_location
    on fact_trips.pickup_location_id =dim_location.location_id
group BY dim_location.zone
ORDER BY trip_per_zone DESC
LIMIT 10

SELECT EXTRACT(HOUR FROM pickup_time) AS pickup_hour, count(*)
FROM fact_trips 
GROUP BY 1 
ORDER BY COUNT DESC 
limit 10;


SELECT
        sum(fact_trips.fare_amount)/COUNT(fact_trips.fare_amount) as Average_fair,
        dim_location.borough

FROM
        fact_trips
left JOIN dim_location
        on fact_trips.pickup_location_id = dim_location.location_id
GROUP BY dim_location.borough
ORDER BY average_fair

SELECT
        ROUND(100.0 * COUNT(*) FILTER (WHERE tip_amount != 0) / COUNT(*), 2) AS per_tip
FROM fact_trips;